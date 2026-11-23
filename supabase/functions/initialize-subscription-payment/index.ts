import { corsHeaders } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY");

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function adminFetch(path: string, options: RequestInit = {}) {
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
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY || !PAYSTACK_SECRET_KEY) {
      return jsonResponse({ success: false, error: "Payment service is not fully configured." }, 500);
    }

    const authorization = req.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) {
      return jsonResponse({ success: false, error: "Sign in before starting a subscription payment." }, 401);
    }

    // Resolve the caller from the supplied access token. Never trust owner_id
    // from the request body as proof of property ownership.
    const authResponse = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: authorization },
    });
    if (!authResponse.ok) {
      return jsonResponse({ success: false, error: "Your session is invalid or expired. Sign in again." }, 401);
    }
    const authUser = await authResponse.json();
    const ownerId = String(authUser.id ?? "");
    if (!ownerId) return jsonResponse({ success: false, error: "Authenticated user could not be resolved." }, 401);

    const body = await req.json();
    const propertyId = String(body.property_id ?? "");
    if (!propertyId || (body.owner_id && String(body.owner_id) !== ownerId)) {
      return jsonResponse({ success: false, error: "Invalid property payment request." }, 400);
    }

    const profileResponse = await adminFetch(
      `profiles?id=eq.${encodeURIComponent(ownerId)}&select=id,role,email`,
    );
    if (!profileResponse.ok) throw new Error("Could not verify owner profile.");
    const profiles = await profileResponse.json();
    const profile = profiles?.[0];
    const role = String(profile?.role ?? "").toLowerCase();
    if (!profile || !["owner", "jumaa_owner"].includes(role)) {
      return jsonResponse({ success: false, error: "Only property owners can pay JUMAA subscriptions." }, 403);
    }

    const propertyResponse = await adminFetch(
      `properties?id=eq.${encodeURIComponent(propertyId)}&owner_id=eq.${encodeURIComponent(ownerId)}&select=id,name,owner_id`,
    );
    if (!propertyResponse.ok) throw new Error("Could not verify property ownership.");
    const properties = await propertyResponse.json();
    if (!Array.isArray(properties) || properties.length !== 1) {
      return jsonResponse({ success: false, error: "This property does not belong to your account." }, 404);
    }
    const property = properties[0];

    const subscriptionResponse = await adminFetch(
      `subscriptions?owner_id=eq.${encodeURIComponent(ownerId)}&property_id=eq.${encodeURIComponent(propertyId)}&select=*`,
    );
    if (!subscriptionResponse.ok) throw new Error("Could not load the property subscription.");
    const subscriptions = await subscriptionResponse.json();
    if (!Array.isArray(subscriptions) || subscriptions.length !== 1) {
      return jsonResponse({ success: false, error: "No unique subscription exists for this property. Contact JUMAA support." }, 409);
    }
    const subscription = subscriptions[0];

    const unitsResponse = await adminFetch(
      `units?property_id=eq.${encodeURIComponent(propertyId)}&select=id`,
    );
    if (!unitsResponse.ok) throw new Error("Could not calculate the property's unit count.");
    const units = await unitsResponse.json();
    const unitCount = Array.isArray(units) ? units.length : 0;
    if (unitCount <= 0) return jsonResponse({ success: false, error: "Add at least one unit before subscribing." }, 400);

    const rateResponse = await adminFetch("rpc/get_jumaa_monthly_rate", {
      method: "POST",
      body: JSON.stringify({ p_unit_count: unitCount }),
    });
    if (!rateResponse.ok) throw new Error("Could not calculate the JUMAA subscription rate.");
    const monthlyRate = Number(await rateResponse.json());
    if (!Number.isFinite(monthlyRate) || monthlyRate <= 0) {
      return jsonResponse({ success: false, error: "This property requires a custom subscription plan." }, 400);
    }

    const credit = Math.max(Number(subscription.credit_amount ?? 0), 0);
    const dueNow = Math.max(Math.round((monthlyRate - credit) * 100) / 100, 0);
    if (dueNow <= 0) {
      return jsonResponse({
        success: true,
        payment_required: false,
        message: "Your available property credit already covers the next billing period.",
        monthly_amount: monthlyRate,
        available_credit: credit,
        amount_due: 0,
      });
    }

    const amount = Number(body.amount ?? dueNow);
    if (!Number.isFinite(amount) || amount < dueNow || Math.round(amount * 100) !== amount * 100) {
      return jsonResponse({
        success: false,
        error: `The minimum amount due after applying property credit is KES ${dueNow.toFixed(2)}.`,
        minimum_amount: dueNow,
        available_credit: credit,
      }, 400);
    }

    const pendingResponse = await adminFetch(
      `subscription_payments?subscription_id=eq.${encodeURIComponent(subscription.id)}&status=in.(pending,processing)&select=id&limit=1`,
    );
    if (!pendingResponse.ok) throw new Error("Could not check existing payment attempts.");
    if ((await pendingResponse.json()).length > 0) {
      return jsonResponse({ success: false, error: "A payment is already pending for this property. Complete it or wait for its status to update." }, 409);
    }

    const email = String(authUser.email ?? profile.email ?? "").trim();
    if (!email) return jsonResponse({ success: false, error: "Your account needs a valid email address for Paystack." }, 400);

    const reference = `JUMAA-${crypto.randomUUID().replaceAll("-", "")}`;
    const paystackResponse = await fetch("https://api.paystack.co/transaction/initialize", {
      method: "POST",
      headers: { Authorization: `Bearer ${PAYSTACK_SECRET_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        email,
        amount: Math.round(amount * 100),
        currency: "KES",
        reference,
        channels: ["mobile_money", "card", "bank"],
        metadata: {
          payment_type: "jumaa_subscription",
          owner_id: ownerId,
          property_id: propertyId,
          property_name: property.name,
          subscription_id: subscription.id,
          monthly_amount: monthlyRate,
          available_credit: credit,
          amount_due_before_payment: dueNow,
          units_count: unitCount,
        },
      }),
    });
    const paystack = await paystackResponse.json();
    if (!paystackResponse.ok || !paystack?.status || !paystack?.data?.authorization_url) {
      console.error("Paystack initialization failed:", paystack?.message ?? "Unknown error");
      return jsonResponse({ success: false, error: paystack?.message ?? "Could not initialize Paystack payment." }, 400);
    }

    const insertResponse = await adminFetch("subscription_payments", {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({
        owner_id: ownerId,
        property_id: propertyId,
        subscription_id: subscription.id,
        amount,
        monthly_rate: monthlyRate,
        units_count: unitCount,
        months_covered: 0,
        amount_applied: 0,
        credit_generated: 0,
        payment_method: "paystack",
        reference,
        status: "pending",
      }),
    });
    if (!insertResponse.ok) {
      console.error("Could not persist pending payment:", await insertResponse.text());
      return jsonResponse({ success: false, error: "Payment could not be safely recorded. Please try again." }, 500);
    }

    // Keep the subscription's pricing snapshot in sync with the actual units.
    await adminFetch(`subscriptions?id=eq.${encodeURIComponent(subscription.id)}`, {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ unit_count: unitCount, monthly_amount: monthlyRate, updated_at: new Date().toISOString() }),
    });

    return jsonResponse({
      success: true,
      reference,
      authorization_url: paystack.data.authorization_url,
      access_code: paystack.data.access_code,
      subscription_id: subscription.id,
      property_name: property.name,
      amount,
      monthly_amount: monthlyRate,
      available_credit: credit,
      amount_due: dueNow,
      unit_count: unitCount,
    });
  } catch (error) {
    console.error("SUBSCRIPTION PAYMENT INITIALIZATION ERROR:", error);
    return jsonResponse({ success: false, error: error instanceof Error ? error.message : "Payment initialization failed." }, 500);
  }
});
