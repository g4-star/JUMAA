import { corsHeaders } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const CRON_SECRET = Deno.env.get("SUBSCRIPTION_REMINDER_CRON_SECRET");
const BREVO_API_KEY = Deno.env.get("BREVO_API_KEY");
const EMAIL_FROM = Deno.env.get("EMAIL_FROM") ?? "no-reply@jumaa.app";
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID");
const FIREBASE_CLIENT_EMAIL = Deno.env.get("FIREBASE_CLIENT_EMAIL");
const FIREBASE_PRIVATE_KEY = Deno.env.get("FIREBASE_PRIVATE_KEY");

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
function headers() {
  return {
    apikey: SERVICE_KEY!,
    Authorization: `Bearer ${SERVICE_KEY}`,
    "Content-Type": "application/json",
  };
}
async function db(path: string, options: RequestInit = {}) {
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...options,
    headers: { ...headers(), ...(options.headers ?? {}) },
  });
}
function escapeHtml(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[c]!);
}
function b64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function pemBuffer(pem: string): ArrayBuffer {
  const raw = atob(pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, ""));
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes.buffer;
}
async function fcmAccessToken(): Promise<string> {
  if (!FIREBASE_CLIENT_EMAIL || !FIREBASE_PRIVATE_KEY) throw new Error("Firebase service account is not configured.");
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const payload = b64url(new TextEncoder().encode(JSON.stringify({
    iss: FIREBASE_CLIENT_EMAIL,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  })));
  const unsigned = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBuffer(FIREBASE_PRIVATE_KEY.replace(/\\n/g, "\n")),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const assertion = `${unsigned}.${b64url(new Uint8Array(signature))}`;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${encodeURIComponent(assertion)}`,
  });
  const result = await response.json();
  if (!response.ok || !result.access_token) throw new Error("Could not obtain Firebase access token.");
  return result.access_token;
}
async function sendPush(token: string, title: string, message: string, data: Record<string, string>) {
  if (!FIREBASE_PROJECT_ID) throw new Error("FIREBASE_PROJECT_ID is not configured.");
  const accessToken = await fcmAccessToken();
  const response = await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: {
        token,
        notification: { title, body: message },
        data,
        android: { priority: "high", notification: { sound: "default" } },
        apns: { payload: { aps: { sound: "default" } } },
      },
    }),
  });
  if (!response.ok) throw new Error(`FCM delivery failed: ${response.status}`);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ success: false, error: "Method not allowed." }, 405);
  if (!SUPABASE_URL || !SERVICE_KEY || !CRON_SECRET) {
    return json({ success: false, error: "Reminder worker is not configured." }, 503);
  }
  if (req.headers.get("x-subscription-cron-secret") !== CRON_SECRET) {
    return json({ success: false, error: "Unauthorized." }, 401);
  }

  try {
    // Enqueue only the configured reminder milestones for each property's
    // effective due date. A temporary grace period changes this deadline;
    // a shifted cycle changes next_payment_at itself.
    const subscriptionsResponse = await db(
      "subscriptions?status=in.(trial,active,expired)&next_payment_at=not.is.null&select=id,owner_id,property_id,next_payment_at,grace_until",
    );
    if (!subscriptionsResponse.ok) throw new Error("Could not load subscriptions for reminder scheduling.");
    const subscriptions = await subscriptionsResponse.json();
    const now = new Date();
    const todayUtc = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
    const queued: string[] = [];

    for (const sub of subscriptions) {
      const normalDue = new Date(sub.next_payment_at);
      const grace = sub.grace_until ? new Date(sub.grace_until) : null;
      const due = grace && grace > normalDue ? grace : normalDue;
      const dueUtc = Date.UTC(due.getUTCFullYear(), due.getUTCMonth(), due.getUTCDate());
      const days = Math.round((dueUtc - todayUtc) / 86400000);
      if (![7, 3, 1, 0].includes(days)) continue;

      const response = await db(
        "subscription_reminder_events?on_conflict=subscription_id,due_date,days_before",
        {
          method: "POST",
          headers: { Prefer: "resolution=ignore-duplicates,return=minimal" },
          body: JSON.stringify({
            subscription_id: sub.id,
            owner_id: sub.owner_id,
            property_id: sub.property_id,
            due_date: due.toISOString().slice(0, 10),
            days_before: days,
            status: "pending",
          }),
        },
      );
      if (!response.ok) console.error("Could not enqueue reminder:", await response.text());
      else queued.push(`${sub.id}:${days}`);
    }

    const eventsResponse = await db(
      "subscription_reminder_events?status=in.(pending,failed)&select=*&order=created_at.asc&limit=100",
    );
    if (!eventsResponse.ok) throw new Error("Could not load pending subscription reminders.");
    const events = await eventsResponse.json();
    const results = [];

    for (const event of events) {
      const attemptResponse = await db(
        `subscription_reminder_events?id=eq.${encodeURIComponent(event.id)}`,
        {
          method: "PATCH",
          headers: { Prefer: "return=minimal" },
          body: JSON.stringify({
            status: "processing",
            attempts: Number(event.attempts ?? 0) + 1,
            last_error: null,
          }),
        },
      );
      if (!attemptResponse.ok) continue;

      try {
        const [profileResponse, propertyResponse] = await Promise.all([
          db(`profiles?id=eq.${encodeURIComponent(event.owner_id)}&select=id,full_name,email`),
          db(`properties?id=eq.${encodeURIComponent(event.property_id)}&select=id,name`),
        ]);
        if (!profileResponse.ok || !propertyResponse.ok) throw new Error("Could not load reminder recipient or property.");
        const profile = (await profileResponse.json())[0];
        const property = (await propertyResponse.json())[0];
        if (!profile || !property) throw new Error("Reminder owner or property no longer exists.");

        const dueDate = new Date(`${event.due_date}T00:00:00Z`);
        const dueLabel = dueDate.toLocaleDateString("en-KE", { day: "numeric", month: "long", year: "numeric", timeZone: "Africa/Nairobi" });
        const title = event.days_before === 0
          ? "JUMAA subscription payment due today"
          : `JUMAA subscription due in ${event.days_before} days`;
        const message = event.days_before === 0
          ? `Your JUMAA subscription for ${property.name} is due today (${dueLabel}). Open JUMAA to pay or view your available credit.`
          : `Your JUMAA subscription for ${property.name} is due on ${dueLabel}, in ${event.days_before} days. Open JUMAA to review the amount and available credit.`;

        let inAppSentAt = event.in_app_sent_at;
        let pushSentAt = event.push_sent_at;
        let emailSentAt = event.email_sent_at;

        if (!inAppSentAt) {
          const notificationResponse = await db(
            "owner_notifications?on_conflict=billing_event_id",
            {
              method: "POST",
              headers: { Prefer: "resolution=ignore-duplicates,return=minimal" },
              body: JSON.stringify({
                owner_id: event.owner_id,
                title,
                message,
                notification_type: `subscription_due_${event.days_before}`,
                is_read: false,
                billing_event_id: event.id,
              }),
            },
          );
          if (!notificationResponse.ok) throw new Error("Could not create in-app reminder.");
          inAppSentAt = new Date().toISOString();
        }

        if (!pushSentAt) {
          const tokenResponse = await db(
            `push_tokens?user_id=eq.${encodeURIComponent(event.owner_id)}&select=id,token`,
          );
          if (!tokenResponse.ok) throw new Error("Could not load owner push tokens.");
          const tokens = await tokenResponse.json();
          for (const token of tokens) {
            await sendPush(token.token, title, message, {
              type: "subscription_reminder",
              property_id: String(event.property_id),
              subscription_id: String(event.subscription_id),
              reminder_event_id: String(event.id),
            });
          }
          // No registered device is a completed delivery attempt; in-app and
          // email still ensure the owner receives the reminder.
          pushSentAt = new Date().toISOString();
        }

        if (!emailSentAt) {
          if (profile.email && BREVO_API_KEY) {
            const emailResponse = await fetch("https://api.brevo.com/v3/smtp/email", {
              method: "POST",
              headers: { "api-key": BREVO_API_KEY, "Content-Type": "application/json" },
              body: JSON.stringify({
                sender: { name: "JUMAA", email: EMAIL_FROM },
                to: [{ email: profile.email }],
                subject: title,
                htmlContent: `<div style="font-family:Arial,sans-serif;line-height:1.6"><h2>${escapeHtml(title)}</h2><p>Hello ${escapeHtml(profile.full_name ?? "Property Owner")},</p><p>${escapeHtml(message)}</p><p>Property: <strong>${escapeHtml(property.name)}</strong></p><p>Due date: <strong>${escapeHtml(dueLabel)}</strong></p><p>Please open JUMAA to review your subscription, available credit and payment options.</p></div>`,
              }),
            });
            if (!emailResponse.ok) throw new Error(`Brevo email delivery failed: ${emailResponse.status}`);
          }
          emailSentAt = new Date().toISOString();
        }

        const complete = Boolean(inAppSentAt && pushSentAt && emailSentAt);
        const update = await db(`subscription_reminder_events?id=eq.${encodeURIComponent(event.id)}`, {
          method: "PATCH",
          headers: { Prefer: "return=minimal" },
          body: JSON.stringify({
            in_app_sent_at: inAppSentAt,
            push_sent_at: pushSentAt,
            email_sent_at: emailSentAt,
            status: complete ? "sent" : "failed",
            sent_at: complete ? new Date().toISOString() : null,
            last_error: null,
          }),
        });
        if (!update.ok) throw new Error("Could not update reminder delivery state.");
        results.push({ id: event.id, status: complete ? "sent" : "partial" });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Reminder delivery failed.";
        await db(`subscription_reminder_events?id=eq.${encodeURIComponent(event.id)}`, {
          method: "PATCH",
          headers: { Prefer: "return=minimal" },
          body: JSON.stringify({ status: "failed", last_error: message }),
        });
        results.push({ id: event.id, status: "failed", error: message });
      }
    }

    return json({ success: true, queued: queued.length, processed: results.length, results });
  } catch (error) {
    console.error("SUBSCRIPTION REMINDER WORKER ERROR:", error);
    return json({ success: false, error: error instanceof Error ? error.message : "Reminder worker failed." }, 500);
  }
});
