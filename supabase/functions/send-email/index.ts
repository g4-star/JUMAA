import { corsHeaders } from '../_shared/cors.ts';

const BREVO_API_KEY = Deno.env.get('BREVO_API_KEY');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY');
const EMAIL_FROM = Deno.env.get('EMAIL_FROM') ?? 'JUMAA <your-verified-email@example.com>';

interface EmailRequest {
  to: string;
  subject: string;
  html: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders,
    });
  }

  try {
    if (req.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Method not allowed.' }), {
        status: 405,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
      throw new Error('Supabase authentication is not configured.');
    }

    const authorization = req.headers.get('Authorization') ?? '';
    if (!authorization.startsWith('Bearer ')) {
      return new Response(JSON.stringify({ error: 'Authentication required.' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const authResponse = await fetch(SUPABASE_URL + '/auth/v1/user', {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: authorization },
    });
    if (!authResponse.ok) {
      return new Response(JSON.stringify({ error: 'Authentication required.' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    const caller = await authResponse.json();

    const profileResponse = await fetch(
      SUPABASE_URL + '/rest/v1/profiles?id=eq.' + encodeURIComponent(caller.id) + '&select=role',
      { headers: { apikey: SUPABASE_ANON_KEY, Authorization: authorization } },
    );
    if (!profileResponse.ok) {
      throw new Error('Could not verify email permissions.');
    }
    const profiles = await profileResponse.json();
    const role = Array.isArray(profiles) ? profiles[0]?.role?.toString().toLowerCase() : null;
    if (!['owner', 'landlord', 'jumaa_owner'].includes(role ?? '')) {
      return new Response(JSON.stringify({ error: 'You are not allowed to send platform emails.' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (!BREVO_API_KEY) {
      throw new Error('BREVO_API_KEY is not configured.');
    }

    const body = await req.json() as Partial<EmailRequest>;
    const recipient = typeof body.to === 'string' ? body.to.trim() : '';
    const subject = typeof body.subject === 'string' ? body.subject.trim() : '';
    const html = typeof body.html === 'string' ? body.html : '';

    if (
      !recipient ||
      !subject ||
      !html ||
      subject.length > 200 ||
      html.length > 50000 ||
      !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)
    ) {
      return new Response(
        JSON.stringify({
          error: 'A valid recipient, subject (max 200 characters) and email body (max 50 KB) are required.',
        }),
        {
          status: 400,
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
          },
        },
      );
    }

    const response = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: {
        'api-key': BREVO_API_KEY,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: JSON.stringify({
        sender: {
          name: 'JUMAA',
          email: EMAIL_FROM,
        },
        to: [
          {
            email: recipient,
          },
        ],
        subject,
        htmlContent: html,
      }),
    });

    const result = await response.json();

    if (!response.ok) {
      console.error('Brevo API error:', result);

      return new Response(
        JSON.stringify({
          error: result,
        }),
        {
          status: response.status,
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
          },
        },
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        messageId: result.messageId,
      }),
      {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
        },
      },
    );
  } catch (error) {
    console.error(error);

    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : String(error),
      }),
      {
        status: 500,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
        },
      },
    );
  }
});
