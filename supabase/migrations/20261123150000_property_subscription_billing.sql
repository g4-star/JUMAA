-- Property-scoped JUMAA subscription billing.
-- Safe to commit and review; this migration is NOT applied to production by this PR.

begin;

alter table public.subscriptions
  add column if not exists trial_started_at timestamptz,
  add column if not exists billing_anchor_date date,
  add column if not exists next_payment_at timestamptz,
  add column if not exists grace_until timestamptz,
  add column if not exists outstanding_balance numeric(12,2) not null default 0,
  add column if not exists credit_amount numeric(12,2) not null default 0,
  add column if not exists billing_timezone text not null default 'Africa/Nairobi';

alter table public.owner_notifications
  add column if not exists billing_event_id uuid;
create unique index if not exists owner_notifications_billing_event_unique
  on public.owner_notifications(billing_event_id)
  where billing_event_id is not null;

alter table public.subscription_payments
  add column if not exists amount_applied numeric(12,2) not null default 0,
  add column if not exists balance_after numeric(12,2) not null default 0,
  add column if not exists period_start date,
  add column if not exists period_end date,
  add column if not exists receipt_number text;

create table if not exists public.subscription_reschedules (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions(id) on delete restrict,
  owner_id uuid not null references public.profiles(id) on delete restrict,
  property_id uuid not null references public.properties(id) on delete restrict,
  mode text not null check (mode in ('shift_cycle', 'temporary_grace')),
  original_due_at timestamptz not null,
  new_due_at timestamptz not null,
  reason text not null check (length(trim(reason)) >= 5),
  admin_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (new_due_at > original_due_at)
);

create index if not exists subscription_reschedules_property_created_idx
  on public.subscription_reschedules(property_id, created_at desc);
create index if not exists subscription_reschedules_owner_created_idx
  on public.subscription_reschedules(owner_id, created_at desc);

alter table public.subscription_reschedules enable row level security;

drop policy if exists "Owners and JUMAA admins can view subscription reschedules"
  on public.subscription_reschedules;
create policy "Owners and JUMAA admins can view subscription reschedules"
on public.subscription_reschedules
for select to authenticated
using (
  owner_id = (select auth.uid())
  or exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and lower(coalesce(p.role, '')) = 'jumaa_owner'
  )
);

revoke insert, update, delete on public.subscription_reschedules from anon, authenticated;
grant select on public.subscription_reschedules to authenticated;

-- A property has its own immutable trial start and independent billing calendar.
create or replace function public.jumaa_add_months(p_date date, p_months integer)
returns date
language sql
immutable
strict
set search_path = ''
as $$
  select make_date(
    extract(year from (date_trunc('month', p_date)::date + make_interval(months => p_months)))::integer,
    extract(month from (date_trunc('month', p_date)::date + make_interval(months => p_months)))::integer,
    least(
      extract(day from p_date)::integer,
      extract(day from (
        date_trunc('month', p_date)::date
        + make_interval(months => p_months + 1)
        - interval '1 day'
      ))::integer
    )
  );
$$;

-- Called only by property/unit triggers. It deliberately derives ownership
-- from properties.owner_id and verifies that the profile is an owner.
create or replace function public.ensure_jumaa_property_subscription(
  p_property_id uuid,
  p_trial_start timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_property public.properties%rowtype;
  v_subscription public.subscriptions%rowtype;
  v_units integer;
  v_rate numeric(12,2);
  v_now timestamptz := now();
  v_trial_start timestamptz := coalesce(p_trial_start, now());
begin
  select * into v_property
  from public.properties
  where id = p_property_id;

  if not found or v_property.owner_id is null then
    return;
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = v_property.owner_id
      and lower(coalesce(p.role, '')) in ('owner', 'jumaa_owner')
  ) then
    return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_property_id::text, 0));

  select count(*)::integer into v_units
  from public.units u
  where u.property_id = p_property_id;

  v_rate := public.get_jumaa_monthly_rate(v_units);

  select * into v_subscription
  from public.subscriptions s
  where s.property_id = p_property_id
  order by s.created_at asc nulls last
  limit 1
  for update;

  if found then
    update public.subscriptions
    set unit_count = v_units,
        monthly_amount = v_rate,
        trial_started_at = coalesce(trial_started_at, created_at, v_trial_start),
        trial_ends_at = coalesce(
          trial_ends_at,
          coalesce(trial_started_at, created_at, v_trial_start) + interval '30 days'
        ),
        billing_anchor_date = coalesce(
          billing_anchor_date,
          (coalesce(trial_ends_at, v_trial_start + interval '30 days'))::date
        ),
        next_payment_at = coalesce(
          next_payment_at,
          trial_ends_at,
          subscription_ends_at,
          v_trial_start + interval '30 days'
        ),
        updated_at = v_now
    where id = v_subscription.id;
  else
    insert into public.subscriptions (
      owner_id,
      property_id,
      monthly_amount,
      unit_count,
      status,
      trial_started_at,
      trial_ends_at,
      billing_anchor_date,
      next_payment_at,
      credit_amount,
      outstanding_balance,
      billing_timezone,
      created_at,
      updated_at
    ) values (
      v_property.owner_id,
      p_property_id,
      v_rate,
      v_units,
      'trial',
      v_trial_start,
      v_trial_start + interval '30 days',
      (v_trial_start + interval '30 days')::date,
      v_trial_start + interval '30 days',
      0,
      0,
      'Africa/Nairobi',
      v_now,
      v_now
    );
  end if;
end;
$$;

revoke all on function public.ensure_jumaa_property_subscription(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.jumaa_property_subscription_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_table_name = 'properties' then
    perform public.ensure_jumaa_property_subscription(new.id, coalesce(new.created_at, now()));
  elsif tg_op = 'DELETE' then
    perform public.ensure_jumaa_property_subscription(old.property_id, null);
  else
    perform public.ensure_jumaa_property_subscription(new.property_id, null);
    if tg_op = 'UPDATE' and old.property_id is distinct from new.property_id then
      perform public.ensure_jumaa_property_subscription(old.property_id);
    end if;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$;

revoke all on function public.jumaa_property_subscription_trigger() from public, anon, authenticated;

drop trigger if exists jumaa_create_property_subscription on public.properties;
create trigger jumaa_create_property_subscription
after insert on public.properties
for each row execute function public.jumaa_property_subscription_trigger();

drop trigger if exists jumaa_sync_subscription_units on public.units;
create trigger jumaa_sync_subscription_units
after insert or update of property_id or delete on public.units
for each row execute function public.jumaa_property_subscription_trigger();

-- Existing eligible properties without any subscription receive a single
-- rollout trial. Existing subscriptions/payment history are never overwritten.
do $$
declare
  r record;
begin
  for r in
    select p.id
    from public.properties p
    join public.profiles pr on pr.id = p.owner_id
    where lower(coalesce(pr.role, '')) in ('owner', 'jumaa_owner')
      and not exists (
        select 1 from public.subscriptions s where s.property_id = p.id
      )
      and not exists (
        select 1 from public.subscription_payments sp where sp.property_id = p.id
      )
  loop
    perform public.ensure_jumaa_property_subscription(r.id, now());
  end loop;
end;
$$;

-- Admin-only rescheduling: mode explicitly chooses whether future billing
-- dates move (shift_cycle) or only the current deadline receives grace.
create or replace function public.reschedule_jumaa_subscription(
  p_subscription_id uuid,
  p_new_due_at timestamptz,
  p_mode text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := auth.uid();
  v_sub public.subscriptions%rowtype;
  v_original timestamptz;
  v_new timestamptz;
  v_reschedule_id uuid;
  v_notification_id uuid;
begin
  if v_admin is null or not exists (
    select 1 from public.profiles p
    where p.id = v_admin and lower(coalesce(p.role, '')) = 'jumaa_owner'
  ) then
    raise exception 'Only JUMAA administrators can reschedule subscriptions.';
  end if;

  if p_mode not in ('shift_cycle', 'temporary_grace') then
    raise exception 'Reschedule mode must be shift_cycle or temporary_grace.';
  end if;

  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception 'Please provide a reason of at least five characters.';
  end if;

  if p_new_due_at is null or p_new_due_at <= now() then
    raise exception 'The revised due date must be in the future.';
  end if;

  select * into v_sub
  from public.subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception 'Subscription not found.';
  end if;

  v_original := coalesce(v_sub.next_payment_at, v_sub.trial_ends_at, v_sub.subscription_ends_at);
  if v_original is null or p_new_due_at <= v_original then
    raise exception 'The revised date must be later than the current due date.';
  end if;

  if p_mode = 'shift_cycle' then
    update public.subscriptions
    set billing_anchor_date = p_new_due_at::date,
        next_payment_at = p_new_due_at,
        subscription_ends_at = case
          when status = 'active' then p_new_due_at
          else subscription_ends_at
        end,
        grace_until = null,
        updated_at = now()
    where id = p_subscription_id;
  else
    update public.subscriptions
    set grace_until = p_new_due_at,
        updated_at = now()
    where id = p_subscription_id;
  end if;

  update public.subscription_reminder_events
  set status = 'cancelled',
      last_error = 'Cancelled because the administrator rescheduled the due date.'
  where subscription_id = v_sub.id
    and status in ('pending', 'failed');

  insert into public.subscription_reschedules (
    subscription_id, owner_id, property_id, mode,
    original_due_at, new_due_at, reason, admin_id
  ) values (
    v_sub.id, v_sub.owner_id, v_sub.property_id, p_mode,
    v_original, p_new_due_at, trim(p_reason), v_admin
  ) returning id into v_reschedule_id;

  insert into public.owner_notifications (
    owner_id, title, message, notification_type, is_read
  ) values (
    v_sub.owner_id,
    'JUMAA subscription payment rescheduled',
    case when p_mode = 'shift_cycle'
      then 'Your property billing cycle has been moved to ' || to_char(p_new_due_at at time zone 'Africa/Nairobi', 'DD Mon YYYY HH24:MI') || '.'
      else 'Your property has been granted a temporary payment grace period until ' || to_char(p_new_due_at at time zone 'Africa/Nairobi', 'DD Mon YYYY HH24:MI') || '. Your regular billing date remains unchanged.'
    end,
    'subscription_rescheduled',
    false
  ) returning id into v_notification_id;

  return jsonb_build_object(
    'success', true,
    'reschedule_id', v_reschedule_id,
    'notification_id', v_notification_id,
    'mode', p_mode,
    'original_due_at', v_original,
    'new_due_at', p_new_due_at
  );
end;
$$;

revoke all on function public.reschedule_jumaa_subscription(uuid, timestamptz, text, text) from public, anon;
grant execute on function public.reschedule_jumaa_subscription(uuid, timestamptz, text, text) to authenticated;

-- Atomic settlement: locks both rows, consumes current property credit first,
-- extends only for fully funded months, and leaves every remainder as credit.
create or replace function public.process_jumaa_subscription_payment(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.subscription_payments%rowtype;
  v_sub public.subscriptions%rowtype;
  v_amount numeric(12,2);
  v_rate numeric(12,2);
  v_credit_before numeric(12,2);
  v_available numeric(12,2);
  v_months integer;
  v_consumed numeric(12,2);
  v_applied numeric(12,2);
  v_credit_after numeric(12,2);
  v_period_start date;
  v_period_end date;
  v_now timestamptz := now();
  v_receipt text;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'This operation is restricted to the payment service.';
  end if;

  select * into v_payment
  from public.subscription_payments
  where id = p_payment_id
  for update;

  if not found then
    raise exception 'Subscription payment not found.';
  end if;

  if v_payment.status = 'success' then
    return jsonb_build_object(
      'success', true, 'already_processed', true,
      'payment_id', v_payment.id, 'subscription_id', v_payment.subscription_id
    );
  end if;

  if v_payment.status not in ('pending', 'processing') then
    raise exception 'Only pending or processing payments can be settled.';
  end if;

  select * into v_sub
  from public.subscriptions
  where id = v_payment.subscription_id
  for update;

  if not found or v_sub.owner_id <> v_payment.owner_id or v_sub.property_id <> v_payment.property_id then
    raise exception 'Payment subscription ownership mismatch.';
  end if;

  v_amount := round(v_payment.amount, 2);
  v_rate := round(v_sub.monthly_amount, 2);
  v_credit_before := greatest(coalesce(v_sub.credit_amount, 0), 0);

  if v_amount <= 0 or v_rate <= 0 then
    raise exception 'Payment amount or property subscription rate is invalid.';
  end if;

  v_available := v_credit_before + v_amount;
  v_months := floor(v_available / v_rate)::integer;
  v_consumed := v_months * v_rate;
  v_applied := least(v_amount, greatest(v_consumed - v_credit_before, 0));
  v_credit_after := greatest(v_available - v_consumed, 0);

  v_period_start := coalesce(
    v_sub.next_payment_at::date,
    v_sub.trial_ends_at::date,
    current_date
  );
  if v_period_start < current_date then
    v_period_start := current_date;
  end if;

  v_period_end := case
    when v_months > 0 then public.jumaa_add_months(v_period_start, v_months)
    else v_period_start
  end;

  v_receipt := coalesce(
    v_payment.receipt_number,
    'JUMAA-RCP-' || upper(substr(regexp_replace(coalesce(v_payment.reference, v_payment.id::text), '[^A-Za-z0-9]', '', 'g'), greatest(length(regexp_replace(coalesce(v_payment.reference, v_payment.id::text), '[^A-Za-z0-9]', '', 'g')) - 11, 1), 12))
  );

  update public.subscription_payments
  set status = 'success',
      months_covered = v_months,
      amount_applied = v_applied,
      credit_generated = greatest(v_amount - v_applied, 0),
      balance_after = greatest(v_rate - v_credit_after, 0),
      period_start = case when v_months > 0 then v_period_start else null end,
      period_end = case when v_months > 0 then v_period_end else null end,
      receipt_number = v_receipt,
      paid_at = v_now
  where id = v_payment.id;

  update public.subscriptions
  set status = case when v_months > 0 then 'active' else status end,
      subscription_starts_at = case
        when v_months > 0 then coalesce(subscription_starts_at, v_period_start::timestamptz)
        else subscription_starts_at
      end,
      subscription_ends_at = case
        when v_months > 0 then v_period_end::timestamptz
        else subscription_ends_at
      end,
      next_payment_at = case
        when v_months > 0 then v_period_end::timestamptz
        else next_payment_at
      end,
      billing_anchor_date = case
        when v_months > 0 then v_period_end
        else billing_anchor_date
      end,
      credit_amount = v_credit_after,
      outstanding_balance = greatest(v_rate - v_credit_after, 0),
      grace_until = null,
      updated_at = v_now
  where id = v_sub.id;

  return jsonb_build_object(
    'success', true,
    'already_processed', false,
    'payment_id', v_payment.id,
    'subscription_id', v_sub.id,
    'months_covered', v_months,
    'amount_applied', v_applied,
    'credit_generated', greatest(v_amount - v_applied, 0),
    'credit_balance', v_credit_after,
    'outstanding_balance', greatest(v_rate - v_credit_after, 0),
    'period_start', case when v_months > 0 then v_period_start else null end,
    'period_end', case when v_months > 0 then v_period_end else null end,
    'receipt_number', v_receipt
  );
end;
$$;

revoke all on function public.process_jumaa_subscription_payment(uuid) from public, anon, authenticated;
grant execute on function public.process_jumaa_subscription_payment(uuid) to service_role;

-- Backfill billing dates for existing subscription rows without resetting
-- their trial, status, payment history, or credit balances.
update public.subscriptions
set trial_started_at = coalesce(trial_started_at, created_at),
    next_payment_at = coalesce(next_payment_at, trial_ends_at, subscription_ends_at),
    billing_anchor_date = coalesce(
      billing_anchor_date,
      coalesce(next_payment_at, trial_ends_at, subscription_ends_at)::date
    ),
    credit_amount = coalesce(credit_amount, 0),
    outstanding_balance = coalesce(outstanding_balance, 0)
where true;


-- Durable reminder outbox. A daily scheduled Edge Function delivers these
-- through in-app notifications, FCM and Brevo, retrying failed deliveries.
create table if not exists public.subscription_reminder_events (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions(id) on delete restrict,
  owner_id uuid not null references public.profiles(id) on delete restrict,
  property_id uuid not null references public.properties(id) on delete restrict,
  due_date date not null,
  days_before integer not null check (days_before in (7, 3, 1, 0)),
  status text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'failed', 'cancelled')),
  attempts integer not null default 0,
  last_error text,
  in_app_sent_at timestamptz,
  push_sent_at timestamptz,
  email_sent_at timestamptz,
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  unique(subscription_id, due_date, days_before)
);
create index if not exists subscription_reminder_events_pending_idx
  on public.subscription_reminder_events(status, created_at)
  where status in ('pending', 'failed');
alter table public.subscription_reminder_events enable row level security;
drop policy if exists "JUMAA admins can view subscription reminder events"
  on public.subscription_reminder_events;
create policy "JUMAA admins can view subscription reminder events"
on public.subscription_reminder_events
for select to authenticated
using (exists (
  select 1 from public.profiles p
  where p.id = (select auth.uid())
    and lower(coalesce(p.role, '')) = 'jumaa_owner'
));
revoke insert, update, delete on public.subscription_reminder_events from anon, authenticated;
grant select on public.subscription_reminder_events to authenticated;


-- Claim reminders atomically so overlapping scheduled invocations cannot
-- send duplicate push/email messages. A crashed worker can be reclaimed
-- after fifteen minutes.
create or replace function public.claim_jumaa_subscription_reminder(p_event_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'This operation is restricted to the reminder service.';
  end if;

  update public.subscription_reminder_events
  set status = 'processing',
      locked_at = now(),
      attempts = attempts + 1,
      last_error = null
  where id = p_event_id
    and (
      status in ('pending', 'failed')
      or (status = 'processing' and locked_at < now() - interval '15 minutes')
    );

  return found;
end;
$;
revoke all on function public.claim_jumaa_subscription_reminder(uuid) from public, anon, authenticated;
grant execute on function public.claim_jumaa_subscription_reminder(uuid) to service_role;

commit;
