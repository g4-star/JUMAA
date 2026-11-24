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
    const propertyId = String(body.property_id ?? "").trim();
    const period = String(body.period ?? "").trim();
    const dueDate = String(body.due_date ?? "").trim();
    if (!propertyId || !/^\d{4}-(0[1-9]|1[0-2])$/.test(period) || !/^\d{4}-\d{2}-\d{2}$/.test(dueDate)) {
      return json({ error: "Provide a property, billing month (YYYY-MM) and due date (YYYY-MM-DD)." }, 400);
    }
    const periodStart = `${period}-01`;
    const parsedDueDate = new Date(`${dueDate}T00:00:00.000Z`);
    if (Number.isNaN(parsedDueDate.getTime()) || parsedDueDate.toISOString().slice(0, 10) !== dueDate) {
      return json({ error: "Enter a real calendar due date." }, 400);
    }
    if (dueDate < periodStart) return json({ error: "The due date cannot be before the billing month." }, 400);

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: property, error: propertyError } = await admin
      .from("properties").select("id,owner_id,landlord_id").eq("id", propertyId).maybeSingle();
    if (propertyError) throw propertyError;
    if (!property || (property.owner_id !== user.id && property.landlord_id !== user.id)) {
      return json({ error: "Only this property's owner or assigned landlord can generate rent charges." }, 403);
    }

    const { data: tenants, error: tenantError } = await admin
      .from("tenants").select("id,unit_id,account_status,move_in_date").eq("property_id", propertyId);
    if (tenantError) throw tenantError;
    const activeTenants = (tenants ?? []).filter((t) => {
      if (!t.unit_id || t.account_status === "suspended") return false;
      if (t.move_in_date && String(t.move_in_date).slice(0, 7) > period) return false;
      return true;
    });
    if (activeTenants.length === 0) return json({ success: true, created: 0, message: "No active tenants with assigned units were found." });

    const unitIds = [...new Set(activeTenants.map((t) => t.unit_id))];
    const { data: units, error: unitError } = await admin
      .from("units").select("id,monthly_rent").in("id", unitIds);
    if (unitError) throw unitError;
    const rentByUnit = new Map((units ?? []).map((u) => [u.id, Number(u.monthly_rent)]));
    const charges = activeTenants.flatMap((tenant) => {
      const amount = rentByUnit.get(tenant.unit_id);
      if (!Number.isFinite(amount) || amount <= 0) return [];
      return [{
        tenant_id: tenant.id,
        property_id: propertyId,
        unit_id: tenant.unit_id,
        period_start: periodStart,
        due_date: dueDate,
        amount_due: Math.round(amount * 100) / 100,
        created_by: user.id,
      }];
    });
    if (charges.length === 0) {
      return json({ success: true, created: 0, message: "No positive monthly_rent values were found for assigned units." });
    }

    const { data: inserted, error: insertError } = await admin
      .from("rent_charge_records")
      .upsert(charges, { onConflict: "tenant_id,period_start", ignoreDuplicates: true })
      .select("id,tenant_id");
    if (insertError) throw insertError;

    const tenantIds = [...new Set(charges.map((c) => c.tenant_id))];
    for (const tenantId of tenantIds) {
      const { error } = await admin.rpc("apply_tenant_rent_credits", { p_tenant_id: tenantId });
      if (error) throw error;
    }

    return json({
      success: true,
      created: inserted?.length ?? 0,
      skipped_or_existing: charges.length - (inserted?.length ?? 0),
      message: "Monthly rent charges generated. Existing charges for this tenant and month were left unchanged; available rent credits were applied.",
    });
  } catch (error) {
    console.error("rent-charge-generate error", error);
    return json({ error: "Could not generate monthly rent charges." }, 500);
  }
});
