import { createHmac } from "node:crypto";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-paystack-signature",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function supabaseFetch(path: string, options: RequestInit = {}) {
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...options,
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY!,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      ...(options.headers ?? {}),
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ success: false, error: "Method not allowed." }, 405);

  try {
    if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !PAYSTACK_SECRET_KEY) {
      throw new Error("Required Supabase or Paystack secrets are not configured.");
    }

    const rawBody = await req.text();
    const signature = req.headers.get("x-paystack-signature");
    if (!signature) return jsonResponse({ success: false, error: "Missing Paystack signature." }, 401);

    const expected = createHmac("sha512", PAYSTACK_SECRET_KEY).update(rawBody).digest("hex");
    const expectedBytes = new TextEncoder().encode(expected);
    const suppliedBytes = new TextEncoder().encode(signature);
    if (expectedBytes.length !== suppliedBytes.length || !crypto.subtle.timingSafeEqual) {
      // Deno WebCrypto has no timingSafeEqual in every runtime; compare fixed-length
      // signature bytes without accepting malformed lengths.
      if (expected !== signature) return jsonResponse({ success: false, error: "Invalid Paystack signature." }, 401);
    } else if (expected !== signature) {
      return jsonResponse({ success: false, error: "Invalid Paystack signature." }, 401);
    }

    const event = JSON.parse(rawBody);
    if (event?.event !== "charge.success") {
      return jsonResponse({ success: true, received: true, processed: false, event: event?.event ?? null });
    }

    const reference = String(event?.data?.reference ?? "");
    if (!reference) throw new Error("Paystack transaction reference is missing.");

    const verifyResponse = await fetch(
      `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
      { headers: { Authorization: `Bearer ${PAYSTACK_SECRET_KEY}` } },
    );
    const verifyResult = await verifyResponse.json();
    if (!verifyResponse.ok || !verifyResult?.status || verifyResult?.data?.status !== "success") {
      throw new Error("Paystack transaction verification failed.");
    }
    const verified = verifyResult.data;
    if (String(verified.currency ?? "").toUpperCase() !== "KES") {
      throw new Error("Subscription payment currency must be KES.");
    }

    const paymentResponse = await supabaseFetch(
      `subscription_payments?reference=eq.${encodeURIComponent(reference)}&select=id,amount,status,owner_id,property_id,subscription_id`,
    );
    if (!paymentResponse.ok) throw new Error("Could not load the local subscription payment.");
    const payments = await paymentResponse.json();
    if (!Array.isArray(payments) || payments.length !== 1) {
      return jsonResponse({ success: true, received: true, processed: false, reason: "payment_not_found", reference });
    }
    const payment = payments[0];

    const expectedAmount = Math.round(Number(payment.amount) * 100);
    if (expectedAmount !== Number(verified.amount)) {
      throw new Error("Verified Paystack amount does not match the recorded payment.");
    }

    const settlementResponse = await supabaseFetch("rpc/process_jumaa_subscription_payment", {
      method: "POST",
      body: JSON.stringify({ p_payment_id: payment.id }),
    });
    if (!settlementResponse.ok) {
      throw new Error(`Atomic subscription settlement failed: ${await settlementResponse.text()}`);
    }
    const settlement = await settlementResponse.json();

    if (settlement?.already_processed) {
      return jsonResponse({ success: true, received: true, processed: false, reason: "already_processed", reference });
    }

    const profileResponse = await supabaseFetch(
      `profiles?id=eq.${encodeURIComponent(payment.owner_id)}&select=id,full_name,email`,
    );
    const profiles = profileResponse.ok ? await profileResponse.json() : [];
    const owner = profiles?.[0];

    const propertyResponse = await supabaseFetch(
      `properties?id=eq.${encodeURIComponent(payment.property_id)}&select=id,name`,
    );
    const properties = propertyResponse.ok ? await propertyResponse.json() : [];
    const propertyName = properties?.[0]?.name ?? "your property";

    const notificationTitle = settlement.months_covered > 0
      ? "JUMAA subscription payment received"
      : "JUMAA subscription credit received";
    const notificationMessage = settlement.months_covered > 0
      ? `We received KES ${Number(payment.amount).toLocaleString("en-KE")} for ${propertyName}. Your subscription is funded through ${settlement.period_end}. Available credit: KES ${Number(settlement.credit_balance).toLocaleString("en-KE")}.`
      : `We received KES ${Number(payment.amount).toLocaleString("en-KE")} for ${propertyName}. This partial amount has been saved as property credit. Remaining amount due: KES ${Number(settlement.outstanding_balance).toLocaleString("en-KE")}.`;

    const notificationResponse = await supabaseFetch("owner_notifications", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        owner_id: payment.owner_id,
        title: notificationTitle,
        message: notificationMessage,
        notification_type: "subscription_payment",
        is_read: false,
      }),
    });
    if (!notificationResponse.ok) {
      console.error("Subscription payment notification could not be stored:", await notificationResponse.text());
    }

    // Email is best-effort: a mail outage must never roll back a verified payment.
    const brevoKey = Deno.env.get("BREVO_API_KEY");
    const emailFrom = Deno.env.get("EMAIL_FROM");
    if (brevoKey && owner?.email) {
      try {
        await fetch("https://api.brevo.com/v3/smtp/email", {
          method: "POST",
          headers: { "api-key": brevoKey, "Content-Type": "application/json" },
          body: JSON.stringify({
            sender: { name: "JUMAA", email: emailFrom ?? "no-reply@jumaa.app" },
            to: [{ email: owner.email }],
            subject: notificationTitle,
            htmlContent: `<div style="font-family:Arial,sans-serif;line-height:1.6"><h2>${notificationTitle}</h2><p>Hello ${String(owner.full_name ?? "Property Owner")},</p><p>${notificationMessage}</p><p>Receipt: <strong>${settlement.receipt_number}</strong></p><p>Paystack reference: ${reference}</p><p>Open JUMAA to view your property subscription and payment receipt.</p></div>`,
          }),
        });
      } catch (error) {
        console.error("Subscription payment email failed:", error);
      }
    }

    return jsonResponse({
      success: true,
      received: true,
      processed: true,
      reference,
      ...settlement,
      notification_saved: notificationResponse.ok,
    });
  } catch (error) {
    console.error("PAYSTACK SUBSCRIPTION WEBHOOK ERROR:", error);
    return jsonResponse({ success: false, error: error instanceof Error ? error.message : "Webhook processing failed." }, 500);
  }
});
