import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) return json({ error: "Sign in required." }, 401);
    const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false, autoRefreshToken: false } });
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Invalid session." }, 401);
    const body = await req.json();
    const paymentId = String(body.payment_id ?? "").trim();
    const providerReference = String(body.provider_reference ?? "").trim();
    const note = String(body.verification_note ?? "").trim();
    if (!paymentId || !providerReference || note.length < 8) return json({ error: "Payment, transaction reference and a verification note are required." }, 400);

    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: payment, error: paymentError } = await admin.from("rent_payment_records")
      .select("id,property_id,status,amount,payment_reference")
      .eq("id", paymentId).maybeSingle();
    if (paymentError) throw paymentError;
    if (!payment) return json({ error: "Payment record not found." }, 404);
    if (!["pending", "submitted"].includes(payment.status)) return json({ error: "Only pending or submitted rent payments can be verified." }, 409);

    const { data: property, error: propertyError } = await admin.from("properties")
      .select("id,owner_id,landlord_id").eq("id", payment.property_id).maybeSingle();
    if (propertyError) throw propertyError;
    if (!property || (property.owner_id !== user.id && property.landlord_id !== user.id)) {
      return json({ error: "Only the assigned landlord or property owner can reconcile this payment." }, 403);
    }

    // This is an auditable manual reconciliation action. The operator must
    // independently confirm funds in the landlord's M-Pesa/bank statement.
    const receiptNumber = `JUMAA-R-${new Date().getUTCFullYear()}-${crypto.randomUUID().replaceAll("-", "").slice(0, 10).toUpperCase()}`;
    const { data: updated, error: updateError } = await admin.from("rent_payment_records")
      .update({
        status: "verified",
        provider_reference: providerReference,
        receipt_number: receiptNumber,
        verified_at: new Date().toISOString(),
        verified_by: user.id,
        notes: note,
        updated_at: new Date().toISOString(),
      })
      .eq("id", paymentId).in("status", ["pending", "submitted"])
      .select("id,status,amount,provider_reference,receipt_number,verified_at").maybeSingle();
    if (updateError) throw updateError;
    if (!updated) return json({ error: "Payment changed while it was being reconciled. Refresh and try again." }, 409);

    // Allocation is idempotent and runs only after the payment is verified.
    const { error: allocationError } = await admin.rpc("allocate_rent_payment", { p_payment_id: paymentId });
    if (allocationError) {
      console.error("Rent payment verified but allocation needs retry:", allocationError);
      return json({ success: true, payment: updated, allocation_pending: true,
        message: "Payment verified and receipt issued. Rent allocation needs administrator review." });
    }
    return json({ success: true, payment: updated, allocation_pending: false });
  } catch (error) {
    console.error("rent-payment-reconcile error", error);
    return json({ error: "Could not reconcile the rent payment." }, 500);
  }
});
