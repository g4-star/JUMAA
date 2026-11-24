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
    const transactionReference = String(body.transaction_reference ?? "").trim().toUpperCase();
    if (!paymentId || !/^[A-Z0-9-]{6,32}$/.test(transactionReference)) {
      return json({ error: "Enter a valid M-Pesa or bank transaction reference." }, 400);
    }
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: tenant } = await admin.from("tenants").select("id").eq("auth_user_id", user.id).maybeSingle();
    if (!tenant) return json({ error: "Tenant account not found." }, 403);
    const { data: payment, error: paymentError } = await admin.from("rent_payment_records")
      .select("id,status").eq("id", paymentId).eq("tenant_id", tenant.id).maybeSingle();
    if (paymentError) throw paymentError;
    if (!payment) return json({ error: "Payment record not found." }, 404);
    if (payment.status !== "pending") return json({ error: "Only pending payments can receive a transaction reference." }, 409);
    const { data: updated, error: updateError } = await admin.from("rent_payment_records")
      .update({ provider_reference: transactionReference, status: "submitted", submitted_at: new Date().toISOString(), updated_at: new Date().toISOString() })
      .eq("id", paymentId).eq("tenant_id", tenant.id).eq("status", "pending")
      .select("id,status,provider_reference,submitted_at").maybeSingle();
    if (updateError) throw updateError;
    if (!updated) return json({ error: "Payment changed while submitting the reference. Refresh and try again." }, 409);
    return json({ success: true, payment: updated, message: "Transaction reference submitted for landlord verification." });
  } catch (error) {
    console.error("rent-payment-submit-reference error", error);
    return json({ error: "Could not submit the transaction reference." }, 500);
  }
});
