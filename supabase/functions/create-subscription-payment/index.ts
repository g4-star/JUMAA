import { corsHeaders } from "../_shared/cors.ts";

// The legacy direct-charge endpoint accepted owner_id from the request body
// and did not authenticate the caller. All subscription payments now go
// through initialize-subscription-payment, which validates the session,
// owner role, property ownership, current rate, and available credit.
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  return new Response(JSON.stringify({
    success: false,
    error: "This legacy payment endpoint is disabled. Use initialize-subscription-payment.",
  }), {
    status: 410,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
