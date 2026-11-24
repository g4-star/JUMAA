import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json',
    },
  });
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed.' }, 405);
  }

  try {
    if (
      !SUPABASE_URL ||
      !SUPABASE_ANON_KEY ||
      !SUPABASE_SERVICE_ROLE_KEY
    ) {
      console.error('Phone login is missing required Supabase configuration.');
      return json({ error: 'Phone login is temporarily unavailable.' }, 500);
    }

    const body = await req.json();
    const phone = String(body?.phone ?? '').trim();
    const password = String(body?.password ?? '');

    if (!phone || !password) {
      return json({ error: 'Enter your phone number and password.' }, 400);
    }

    // Resolve the phone number privately on the server. The lookup function
    // is executable only by service_role and returns at most two matches so
    // ambiguous phone numbers are rejected.
    const lookupResponse = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/lookup_jumaa_login_profile_by_phone`,
      {
        method: 'POST',
        headers: {
          apikey: SUPABASE_SERVICE_ROLE_KEY,
          Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ p_phone: phone }),
      },
    );

    if (!lookupResponse.ok) {
      console.error(
        'Phone login profile lookup failed:',
        lookupResponse.status,
      );
      return json({ error: 'Phone login is temporarily unavailable.' }, 500);
    }

    const profiles = await lookupResponse.json();
    if (
      !Array.isArray(profiles) ||
      profiles.length !== 1 ||
      typeof profiles[0]?.email !== 'string' ||
      !profiles[0].email
    ) {
      // Keep unknown and ambiguous numbers indistinguishable.
      return json({ error: 'Invalid phone number or password.' }, 401);
    }

    // Let Supabase Auth verify the password and issue the session. The
    // profile email is never sent back separately or logged.
    const authResponse = await fetch(
      `${SUPABASE_URL}/auth/v1/token?grant_type=password`,
      {
        method: 'POST',
        headers: {
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          email: profiles[0].email,
          password,
        }),
      },
    );

    if (!authResponse.ok) {
      // Do not expose whether the phone exists or the password was wrong.
      return json({ error: 'Invalid phone number or password.' }, 401);
    }

    const session = await authResponse.json();
    if (
      typeof session?.access_token !== 'string' ||
      typeof session?.refresh_token !== 'string'
    ) {
      console.error('Supabase Auth returned an incomplete phone login session.');
      return json({ error: 'Phone login is temporarily unavailable.' }, 500);
    }

    return json(session);
  } catch (error) {
    console.error(
      'Phone login error:',
      error instanceof Error ? error.message : 'Unknown error',
    );
    return json({ error: 'Phone login is temporarily unavailable.' }, 500);
  }
});
