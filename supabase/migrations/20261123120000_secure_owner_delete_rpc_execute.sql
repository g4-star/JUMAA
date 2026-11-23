-- Allow signed-in clients to invoke the owner deletion RPC.
-- Authorization remains enforced inside the SECURITY DEFINER function.
GRANT USAGE ON SCHEMA public TO authenticated;

REVOKE EXECUTE
ON FUNCTION public.delete_jumaa_apartment_owner(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.delete_jumaa_apartment_owner(uuid)
TO authenticated;

-- The function uses schema-qualified references (public.* and auth.uid()).
-- An empty search_path prevents object-shadowing attacks.
ALTER FUNCTION public.delete_jumaa_apartment_owner(uuid)
SET search_path = '';
