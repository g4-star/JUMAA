-- Tenant rent collection ledger. Separate from JUMAA subscription_payments.
-- Landlords retain direct control of their M-Pesa and bank settlement accounts.
create table if not exists public.rent_collection_accounts (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null unique references public.properties(id) on delete cascade,
  mpesa_paybill text,
  mpesa_till text,
  mpesa_account_reference text,
  bank_name text,
  bank_account_name text,
  bank_account_number text,
  bank_branch text,
  payment_instructions text,
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint rent_collection_account_method_check check (
    mpesa_paybill is not null or mpesa_till is not null
    or bank_account_number is not null
  )
);

create table if not exists public.rent_payment_records (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  property_id uuid not null references public.properties(id) on delete restrict,
  unit_id uuid references public.units(id) on delete set null,
  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'KES' check (currency = 'KES'),
  payment_method text not null check (payment_method in ('mpesa','bank_transfer')),
  status text not null default 'pending'
    check (status in ('pending','submitted','verified','rejected','reversed')),
  payment_reference text not null unique,
  provider_reference text,
  payer_phone text,
  payer_account_name text,
  proof_storage_path text,
  submitted_at timestamptz,
  verified_at timestamptz,
  verified_by uuid references auth.users(id) on delete set null,
  rejection_reason text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists rent_payment_provider_reference_unique
  on public.rent_payment_records(provider_reference)
  where provider_reference is not null;
create index if not exists rent_payment_tenant_created_idx
  on public.rent_payment_records(tenant_id, created_at desc);
create index if not exists rent_payment_property_status_idx
  on public.rent_payment_records(property_id, status, created_at desc);

alter table public.rent_collection_accounts enable row level security;
alter table public.rent_payment_records enable row level security;

-- Tenants may only read their own payment history. All writes and account
-- configuration are performed by authenticated server-side functions.
drop policy if exists "Tenants read own rent payment records" on public.rent_payment_records;
create policy "Tenants read own rent payment records"
  on public.rent_payment_records for select to authenticated
  using (exists (
    select 1 from public.tenants t
    where t.id = rent_payment_records.tenant_id
      and t.auth_user_id = (select auth.uid())
  ));

-- Tenants can see the active payment instructions for their assigned property.
drop policy if exists "Tenants read assigned rent collection instructions" on public.rent_collection_accounts;
create policy "Tenants read assigned rent collection instructions"
  on public.rent_collection_accounts for select to authenticated
  using (is_active and exists (
    select 1 from public.tenants t
    where t.property_id = rent_collection_accounts.property_id
      and t.auth_user_id = (select auth.uid())
  ));

revoke all on public.rent_collection_accounts from anon, authenticated;
grant select on public.rent_collection_accounts to authenticated;
revoke all on public.rent_payment_records from anon, authenticated;
grant select on public.rent_payment_records to authenticated;

comment on table public.rent_payment_records is
  'Tenant rent ledger; deliberately separate from JUMAA subscription billing.';
comment on table public.rent_collection_accounts is
  'Landlord-designated M-Pesa and bank payment instructions per property. No JUMAA custody of rent.';
