
-- Backfill phone numbers captured in Supabase Auth metadata for older accounts.
-- This does not overwrite a phone number already stored on the profile.
update public.profiles as p
set phone = nullif(btrim(u.raw_user_meta_data ->> 'phone'), '')
from auth.users as u
where u.id = p.id
  and (p.phone is null or btrim(p.phone) = '')
  and nullif(btrim(u.raw_user_meta_data ->> 'phone'), '') is not null;

-- Resolve a phone number to a profile only for the server-side phone-login flow.
-- The function deliberately returns only the minimum fields needed by the Edge Function.
-- It is not executable by anon or authenticated clients.

create or replace function public.lookup_jumaa_login_profile_by_phone(
  p_phone text
)
returns table (
  user_id uuid,
  email text
)
language sql
stable
security definer
set search_path = ''
as $function$
  with supplied_phone as (
    select regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') as digits
  ),
  normalized_input as (
    select
      case
        when digits ~ '^254[17][0-9]{8}$' then digits
        when digits ~ '^0[17][0-9]{8}$' then '254' || substr(digits, 2)
        when digits ~ '^[17][0-9]{8}$' then '254' || digits
        else digits
      end as canonical
    from supplied_phone
  ),
  normalized_profiles as (
    select
      p.id,
      p.email,
      case
        when phone_digits ~ '^254[17][0-9]{8}$' then phone_digits
        when phone_digits ~ '^0[17][0-9]{8}$' then '254' || substr(phone_digits, 2)
        when phone_digits ~ '^[17][0-9]{8}$' then '254' || phone_digits
        else phone_digits
      end as canonical
    from public.profiles as p
    cross join lateral (
      select regexp_replace(coalesce(p.phone, ''), '[^0-9]', '', 'g') as phone_digits
    ) as normalized
    where p.phone is not null
      and p.email is not null
  )
  select profiles.id, profiles.email
  from normalized_profiles as profiles
  cross join normalized_input as supplied
  where supplied.canonical <> ''
    and profiles.canonical = supplied.canonical
  limit 2;
$function$;

revoke all
on function public.lookup_jumaa_login_profile_by_phone(text)
from public, anon, authenticated;

grant execute
on function public.lookup_jumaa_login_profile_by_phone(text)
to service_role;
