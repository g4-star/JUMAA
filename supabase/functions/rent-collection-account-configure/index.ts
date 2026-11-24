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

const clean = (value: unknown, max = 160) => {
  const result = String(value ?? "").trim();
  return result ? result.slice(0, max) : null;
};

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
    const propertyId = clean(body.property_id, 64);
    if (!propertyId) return json({ error: "Property is required." }, 400);

    const mpesaPaybill = clean(body.mpesa_paybill, 32);
    const mpesaTill = clean(body.mpesa_till, 32);
    const mpesaReference = clean(body.mpesa_account_reference, 64);
    const bankName = clean(body.bank_name, 100);
    const bankAccountName = clean(body.bank_account_name, 120);
    const bankAccountNumber = clean(body.bank_account_number, 64);
    const bankBranch = clean(body.bank_branch, 100);
    const instructions = clean(body.payment_instructions, 500);
    const isActive = body.is_active === true;

    if (mpesaPaybill && !/^[0-9]{5,10}$/.test(mpesaPaybill)) {
      return json({ error: "Paybill must contain 5–10 digits." }, 400);
    }
    if (mpesaTill && !/^[0-9]{5,10}$/.test(mpesaTill)) {
      return json({ error: "Till number must contain 5–10 digits." }, 400);
    }
    if (bankAccountNumber && !/^[A-Za-z0-9-]{5,64}$/.test(bankAccountNumber)) {
      return json({ error: "Enter a valid bank account number." }, 400);
    }
    if (isActive && !mpesaPaybill && !mpesaTill && !bankAccountNumber) {
      return json({ error: "Add at least one M-Pesa or bank destination before activating collection." }, 400);
    }

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: property, error: propertyError } = await admin
      .from("properties")
      .select("id,owner_id,landlord_id")
      .eq("id", propertyId)
      .maybeSingle();
    if (propertyError) throw propertyError;
    if (!property || (property.owner_id !== user.id && property.landlord_id !== user.id)) {
      return json({ error: "Only this property's owner or assigned landlord can manage its collection account." }, 403);
    }

    const { error: saveError } = await admin.from("rent_collection_accounts").upsert({
      property_id: propertyId,
      mpesa_paybill: mpesaPaybill,
      mpesa_till: mpesaTill,
      mpesa_account_reference: mpesaReference,
      bank_name: bankName,
      bank_account_name: bankAccountName,
      bank_account_number: bankAccountNumber,
      bank_branch: bankBranch,
      payment_instructions: instructions,
      is_active: isActive,
      updated_at: new Date().toISOString(),
    }, { onConflict: "property_id" });
    if (saveError) throw saveError;

    return json({ success: true, message: isActive
      ? "Property rent collection instructions saved and activated."
      : "Property rent collection instructions saved but remain inactive." });
  } catch (error) {
    console.error("rent-collection-account-configure error", error);
    return json({ error: "Could not save the property's rent collection account." }, 500);
  }
});
