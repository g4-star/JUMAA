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
    const amount = Number(body.amount);
    const method = String(body.payment_method ?? "");
    if (!Number.isFinite(amount) || amount <= 0 || amount > 10000000) {
      return json({ error: "Enter a valid rent amount." }, 400);
    }
    if (!["mpesa", "bank_transfer"].includes(method)) {
      return json({ error: "Choose M-Pesa or bank transfer." }, 400);
    }

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // Resolve the tenant exclusively from the verified session. Never trust
    // tenant/property/unit IDs supplied by the mobile client.
    const { data: tenant, error: tenantError } = await admin
      .from("tenants")
      .select("id,property_id,unit_id,auth_user_id,account_status")
      .eq("auth_user_id", user.id)
      .maybeSingle();
    if (tenantError) throw tenantError;
    if (!tenant || tenant.account_status === "suspended") {
      return json({ error: "No active tenant record is linked to this account." }, 403);
    }

    const { data: account, error: accountError } = await admin
      .from("rent_collection_accounts")
      .select("mpesa_paybill,mpesa_till,mpesa_account_reference,bank_name,bank_account_name,bank_account_number,bank_branch,payment_instructions,is_active")
      .eq("property_id", tenant.property_id)
      .eq("is_active", true)
      .maybeSingle();
    if (accountError) throw accountError;
    if (!account) return json({ error: "Rent payment instructions have not yet been configured for this property." }, 409);

    if (method === "mpesa" && !account.mpesa_paybill && !account.mpesa_till) {
      return json({ error: "M-Pesa is not configured for this property. Choose bank transfer or contact your landlord." }, 409);
    }
    if (method === "bank_transfer" && !account.bank_account_number) {
      return json({ error: "Bank transfer is not configured for this property. Choose M-Pesa or contact your landlord." }, 409);
    }

    const reference = `JMR-${crypto.randomUUID().replaceAll("-", "").slice(0, 16).toUpperCase()}`;
    const { data: payment, error: insertError } = await admin
      .from("rent_payment_records")
      .insert({
        tenant_id: tenant.id,
        property_id: tenant.property_id,
        unit_id: tenant.unit_id,
        amount: Math.round(amount * 100) / 100,
        payment_method: method,
        payment_reference: reference,
        status: "pending",
      })
      .select("id,amount,currency,payment_method,status,payment_reference,created_at")
      .single();
    if (insertError) throw insertError;

    // This creates a tracked payment instruction, not a claim that money
    // has moved. A verified M-Pesa callback or authorized reconciliation
    // action must transition it to verified.
    return json({
      success: true,
      payment,
      instructions: method === "mpesa"
        ? {
            type: account.mpesa_paybill ? "paybill" : "till",
            paybill: account.mpesa_paybill,
            till: account.mpesa_till,
            account_reference: account.mpesa_account_reference || reference,
            payment_reference: reference,
            note: "Complete payment in M-Pesa, then retain the confirmation code. Your rent is credited only after transaction verification.",
          }
        : {
            type: "bank_transfer",
            bank_name: account.bank_name,
            account_name: account.bank_account_name,
            account_number: account.bank_account_number,
            branch: account.bank_branch,
            payment_reference: reference,
            instructions: account.payment_instructions,
            note: "Use the payment reference as the bank transfer narration. Your rent is credited only after transaction verification.",
          },
    });
  } catch (error) {
    console.error("rent-payment-intent error", error);
    return json({ error: "Could not create the rent payment instruction." }, 500);
  }
});
