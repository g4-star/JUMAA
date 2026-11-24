import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) return json({ error: "Sign in required." }, 401);
    const userClient = createClient(url, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Invalid session." }, 401);

    const body = await req.json();
    const paymentId = String(body.payment_id ?? "").trim();
    const reason = String(body.rejection_reason ?? "").trim().slice(0, 500);
    if (!paymentId || reason.length < 8) {
      return json({ error: "Payment ID and a clear rejection reason are required." }, 400);
    }

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: payment, error: paymentError } = await admin
      .from("rent_payment_records")
      .select("id,property_id,status")
      .eq("id", paymentId)
      .maybeSingle();
    if (paymentError) throw paymentError;
    if (!payment) return json({ error: "Payment record not found." }, 404);
    if (!["pending", "submitted"].includes(payment.status)) {
      return json({ error: "Only pending or submitted payments can be rejected." }, 409);
    }

    const { data: property, error: propertyError } = await admin
      .from("properties")
      .select("id,owner_id,landlord_id")
      .eq("id", payment.property_id)
      .maybeSingle();
    if (propertyError) throw propertyError;
    if (!property || (property.owner_id !== user.id && property.landlord_id !== user.id)) {
      return json({ error: "Only this property's owner or assigned landlord can reject the payment." }, 403);
    }

    const now = new Date().toISOString();
    const { data: updated, error: updateError } = await admin
      .from("rent_payment_records")
      .update({
        status: "rejected",
        rejection_reason: reason,
        rejected_at: now,
        rejected_by: user.id,
        updated_at: now,
      })
      .eq("id", paymentId)
      .in("status", ["pending", "submitted"])
      .select("id,status,rejection_reason,rejected_at")
      .maybeSingle();
    if (updateError) throw updateError;
    if (!updated) return json({ error: "Payment changed while processing. Refresh and try again." }, 409);
    return json({ success: true, payment: updated });
  } catch (error) {
    console.error("rent-payment-reject error", error);
    return json({ error: "Could not reject the rent payment." }, 500);
  }
});
