-- Add auditable receipt and rejection metadata to the rent ledger.
-- This migration does not move funds or alter JUMAA subscription billing.
alter table public.rent_payment_records
  add column if not exists receipt_number text,
  add column if not exists rejected_at timestamptz,
  add column if not exists rejected_by uuid references auth.users(id) on delete set null;

create unique index if not exists rent_payment_receipt_number_unique
  on public.rent_payment_records(receipt_number)
  where receipt_number is not null;

comment on column public.rent_payment_records.receipt_number is
  'JUMAA receipt identifier assigned only after an authorized verification.';
comment on column public.rent_payment_records.rejected_by is
  'Authenticated property owner or assigned landlord who rejected the submission.';

-- Property managers may read their own property's account instructions.
drop policy if exists "Property managers read rent collection accounts" on public.rent_collection_accounts;
create policy "Property managers read rent collection accounts"
  on public.rent_collection_accounts for select to authenticated
  using (exists (
    select 1 from public.properties p
    where p.id = rent_collection_accounts.property_id
      and (p.owner_id = (select auth.uid()) or p.landlord_id = (select auth.uid()))
  ));
