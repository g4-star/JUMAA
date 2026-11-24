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

-- Monthly rent obligations support statements, partial payments and arrears.
create table if not exists public.rent_charge_records (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  property_id uuid not null references public.properties(id) on delete restrict,
  unit_id uuid references public.units(id) on delete set null,
  period_start date not null,
  due_date date not null,
  amount_due numeric(12,2) not null check (amount_due > 0),
  amount_paid numeric(12,2) not null default 0 check (amount_paid >= 0 and amount_paid <= amount_due),
  status text not null default 'due' check (status in ('due','partial','paid')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, period_start)
);

create index if not exists rent_charge_property_due_idx
  on public.rent_charge_records(property_id, due_date, status);
create index if not exists rent_charge_tenant_period_idx
  on public.rent_charge_records(tenant_id, period_start desc);

alter table public.rent_payment_records
  add column if not exists unallocated_amount numeric(12,2) not null default 0
  check (unallocated_amount >= 0);

create table if not exists public.rent_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.rent_payment_records(id) on delete restrict,
  charge_id uuid not null references public.rent_charge_records(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique (payment_id, charge_id)
);

alter table public.rent_charge_records enable row level security;
alter table public.rent_payment_allocations enable row level security;

drop policy if exists "Tenants read own rent charges" on public.rent_charge_records;
create policy "Tenants read own rent charges"
  on public.rent_charge_records for select to authenticated
  using (exists (
    select 1 from public.tenants t
    where t.id = rent_charge_records.tenant_id
      and t.auth_user_id = (select auth.uid())
  ));

drop policy if exists "Property managers read rent charges" on public.rent_charge_records;
create policy "Property managers read rent charges"
  on public.rent_charge_records for select to authenticated
  using (exists (
    select 1 from public.properties p
    where p.id = rent_charge_records.property_id
      and (p.owner_id = (select auth.uid()) or p.landlord_id = (select auth.uid()))
  ));

drop policy if exists "Tenants read own rent allocations" on public.rent_payment_allocations;
create policy "Tenants read own rent allocations"
  on public.rent_payment_allocations for select to authenticated
  using (exists (
    select 1 from public.rent_payment_records rp
    join public.tenants t on t.id = rp.tenant_id
    where rp.id = rent_payment_allocations.payment_id
      and t.auth_user_id = (select auth.uid())
  ));

drop policy if exists "Property managers read rent allocations" on public.rent_payment_allocations;
create policy "Property managers read rent allocations"
  on public.rent_payment_allocations for select to authenticated
  using (exists (
    select 1 from public.rent_payment_records rp
    join public.properties p on p.id = rp.property_id
    where rp.id = rent_payment_allocations.payment_id
      and (p.owner_id = (select auth.uid()) or p.landlord_id = (select auth.uid()))
  ));

revoke all on public.rent_charge_records, public.rent_payment_allocations from anon, authenticated;
grant select on public.rent_charge_records, public.rent_payment_allocations to authenticated;
grant select, insert, update, delete on public.rent_charge_records, public.rent_payment_allocations to service_role;

-- Apply a verified payment to the tenant's oldest unpaid charges first.
-- Any excess remains as a tenant rent credit in unallocated_amount.
create or replace function public.allocate_rent_payment(p_payment_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_payment public.rent_payment_records%rowtype;
  v_charge public.rent_charge_records%rowtype;
  v_remaining numeric(12,2);
  v_apply numeric(12,2);
begin
  select * into v_payment
  from public.rent_payment_records
  where id = p_payment_id
  for update;

  if not found or v_payment.status <> 'verified' then
    raise exception 'Only verified rent payments can be allocated';
  end if;

  if exists (select 1 from public.rent_payment_allocations where payment_id = p_payment_id) then
    return;
  end if;

  v_remaining := v_payment.amount;
  for v_charge in
    select * from public.rent_charge_records
    where tenant_id = v_payment.tenant_id and amount_paid < amount_due
    order by due_date asc, period_start asc
    for update
  loop
    exit when v_remaining <= 0;
    v_apply := least(v_remaining, v_charge.amount_due - v_charge.amount_paid);
    insert into public.rent_payment_allocations(payment_id, charge_id, amount)
    values (p_payment_id, v_charge.id, v_apply);
    update public.rent_charge_records
      set amount_paid = amount_paid + v_apply,
          status = case when amount_paid + v_apply >= amount_due then 'paid' else 'partial' end,
          updated_at = now()
      where id = v_charge.id;
    v_remaining := v_remaining - v_apply;
  end loop;

  update public.rent_payment_records
    set unallocated_amount = greatest(v_remaining, 0),
        updated_at = now()
    where id = p_payment_id;
end;
$$;

-- Apply previously unallocated overpayments to newly generated rent charges.
create or replace function public.apply_tenant_rent_credits(p_tenant_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_payment public.rent_payment_records%rowtype;
  v_charge public.rent_charge_records%rowtype;
  v_apply numeric(12,2);
  v_allocation_id uuid;
begin
  for v_payment in
    select * from public.rent_payment_records
    where tenant_id = p_tenant_id and status = 'verified' and unallocated_amount > 0
    order by verified_at asc, created_at asc
    for update
  loop
    for v_charge in
      select * from public.rent_charge_records
      where tenant_id = p_tenant_id and amount_paid < amount_due
      order by due_date asc, period_start asc
      for update
    loop
      exit when v_payment.unallocated_amount <= 0;
      v_apply := least(v_payment.unallocated_amount, v_charge.amount_due - v_charge.amount_paid);
      insert into public.rent_payment_allocations(payment_id, charge_id, amount)
      values (v_payment.id, v_charge.id, v_apply)
      on conflict (payment_id, charge_id) do nothing
      returning id into v_allocation_id;
      if found then
        update public.rent_charge_records
          set amount_paid = amount_paid + v_apply,
              status = case when amount_paid + v_apply >= amount_due then 'paid' else 'partial' end,
              updated_at = now()
          where id = v_charge.id;
        update public.rent_payment_records
          set unallocated_amount = greatest(unallocated_amount - v_apply, 0),
              updated_at = now()
          where id = v_payment.id
          returning * into v_payment;
      end if;
    end loop;
  end loop;
end;
$$;

revoke all on function public.allocate_rent_payment(uuid) from public, anon, authenticated;
revoke all on function public.apply_tenant_rent_credits(uuid) from public, anon, authenticated;
grant execute on function public.allocate_rent_payment(uuid) to service_role;
grant execute on function public.apply_tenant_rent_credits(uuid) to service_role;

comment on table public.rent_charge_records is
  'Monthly tenant rent obligations used for statements, partial payments and arrears.';
comment on table public.rent_payment_allocations is
  'Auditable allocation of verified tenant rent payments to monthly rent charges.';
