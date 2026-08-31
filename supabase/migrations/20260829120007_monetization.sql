-- ============================================================================
-- GroundsNearMe — 0007 · monetization
--   owner_subscriptions : monthly premium, tracked as paid/unpaid per cycle.
--                         No auto-recurring billing at launch — JazzCash /
--                         EasyPaisa links are issued per cycle and marked paid.
--   commission_ledger   : one row per commissionable booking, feeding the
--                         private (superadmin-only) financial dashboard.
-- ============================================================================

create table if not exists public.owner_subscriptions (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references public.profiles(id) on delete cascade,
  ground_id           uuid references public.grounds(id) on delete set null,
  tier                public.listing_tier not null default 'pro',
  cycle_start         date not null,
  cycle_end           date not null,
  amount              numeric(12,2) not null check (amount >= 0),
  currency            char(3) not null default 'PKR',
  status              public.subscription_status not null default 'unpaid',
  payment_method      public.payment_method,
  payment_link        text,
  invoice_ref         text unique,
  paid_at             timestamptz,
  reminder_sent_at    timestamptz,
  notes               text,
  created_by          uuid references public.profiles(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint owner_subscriptions_cycle check (cycle_end > cycle_start),
  constraint owner_subscriptions_cycle_unique unique (owner_id, ground_id, cycle_start)
);

comment on table public.owner_subscriptions is
  'One row per owner per billing cycle. Manual/semi-automated recurring '
  'payment: a link is sent each cycle and the row is flipped to paid.';

create index if not exists owner_subscriptions_owner_idx  on public.owner_subscriptions (owner_id, cycle_start desc);
create index if not exists owner_subscriptions_status_idx on public.owner_subscriptions (status, cycle_end);
create index if not exists owner_subscriptions_month_idx
  on public.owner_subscriptions (cycle_start);

drop trigger if exists owner_subscriptions_set_updated_at on public.owner_subscriptions;
create trigger owner_subscriptions_set_updated_at
  before update on public.owner_subscriptions
  for each row execute function public.tg_set_updated_at();

create or replace function public.tg_subscription_stamp_paid()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    new.paid_at := coalesce(new.paid_at, now());
  end if;
  return new;
end
$$;

drop trigger if exists owner_subscriptions_stamp_paid on public.owner_subscriptions;
create trigger owner_subscriptions_stamp_paid
  before update on public.owner_subscriptions
  for each row execute function public.tg_subscription_stamp_paid();

-- ---------------------------------------------------------------------------

create table if not exists public.commission_ledger (
  id                uuid primary key default gen_random_uuid(),
  booking_id        uuid not null unique references public.bookings(id) on delete cascade,
  ground_id         uuid not null references public.grounds(id) on delete cascade,
  owner_id          uuid references public.profiles(id) on delete set null,
  earned_month      date not null,
  gross_amount      numeric(12,2) not null check (gross_amount >= 0),
  commission_rate   numeric(5,4) not null check (commission_rate >= 0),
  commission_amount numeric(12,2) not null check (commission_amount >= 0),
  currency          char(3) not null default 'PKR',
  status            public.commission_status not null default 'accrued',
  collected_at      timestamptz,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint commission_earned_month_is_first_of_month
    check (extract(day from earned_month) = 1)
);

comment on table public.commission_ledger is
  'Immutable-by-convention accrual record. Only superadmin (Shayan) can read it.';

create index if not exists commission_ledger_month_idx  on public.commission_ledger (earned_month);
create index if not exists commission_ledger_ground_idx on public.commission_ledger (ground_id, earned_month);
create index if not exists commission_ledger_status_idx on public.commission_ledger (status);

drop trigger if exists commission_ledger_set_updated_at on public.commission_ledger;
create trigger commission_ledger_set_updated_at
  before update on public.commission_ledger
  for each row execute function public.tg_set_updated_at();

-- ---------------------------------------------------------------------------
-- Accrue commission when a booking is completed. Reverse it if the booking is
-- later cancelled. Zero-rate bookings (the launch default) accrue nothing.
-- ---------------------------------------------------------------------------
create or replace function public.tg_bookings_accrue_commission()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
begin
  if new.status = 'completed' and old.status is distinct from 'completed'
     and new.commission_amount > 0 then

    select owner_id into v_owner from public.grounds where id = new.ground_id;

    insert into public.commission_ledger (
      booking_id, ground_id, owner_id, earned_month,
      gross_amount, commission_rate, commission_amount, currency
    )
    values (
      new.id, new.ground_id, v_owner,
      date_trunc('month', new.booking_date)::date,
      new.total_amount, new.commission_rate, new.commission_amount, new.currency
    )
    on conflict (booking_id) do nothing;

  elsif new.status in ('cancelled','expired','no_show')
        and old.status = 'completed' then

    update public.commission_ledger
       set status = 'written_off',
           notes  = coalesce(notes || ' | ', '') || 'booking reverted to ' || new.status
     where booking_id = new.id and status <> 'collected';
  end if;

  return new;
end
$$;

drop trigger if exists bookings_accrue_commission on public.bookings;
create trigger bookings_accrue_commission
  after update of status on public.bookings
  for each row execute function public.tg_bookings_accrue_commission();
