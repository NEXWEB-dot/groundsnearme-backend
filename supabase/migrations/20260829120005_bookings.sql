-- ============================================================================
-- GroundsNearMe — 0005 · bookings
-- Double-booking is prevented by a GiST exclusion constraint, not by
-- application logic: two overlapping live bookings on the same ground cannot
-- exist even under concurrent requests.
-- ============================================================================

-- btree_gist lives in the `extensions` schema on Supabase; the default gist
-- opclass for uuid is only visible while `extensions` is on the search_path.
set search_path = public, extensions;

create table if not exists public.bookings (
  id                uuid primary key default gen_random_uuid(),
  booking_ref       text not null unique,
  ground_id         uuid not null references public.grounds(id) on delete cascade,
  player_id         uuid references public.profiles(id) on delete set null,

  booking_date      date not null,
  start_time        time not null,
  end_time          time not null,
  duration_minutes  int  not null check (duration_minutes > 0),

  -- Naive local (Asia/Karachi) half-open interval. Generated, so it can never
  -- drift from the date/time columns. Handles bookings that cross midnight.
  slot tsrange generated always as (
    tsrange(
      (booking_date + start_time),
      ((case when end_time <= start_time then booking_date + 1 else booking_date end) + end_time),
      '[)'
    )
  ) stored,

  status            public.booking_status not null default 'pending',
  payment_status    public.payment_status not null default 'unpaid',
  source            public.booking_source not null default 'web',

  price_per_hour    integer not null check (price_per_hour > 0),
  total_amount      numeric(12,2) not null check (total_amount >= 0),
  currency          char(3) not null default 'PKR',
  commission_rate   numeric(5,4) not null default 0,
  commission_amount numeric(12,2) not null default 0 check (commission_amount >= 0),

  contact_name      text,
  contact_phone     text,
  players_expected  int check (players_expected is null or players_expected between 1 and 40),
  notes             text,

  -- Unconfirmed bookings hold the slot only until this moment.
  hold_expires_at   timestamptz,
  confirmed_at      timestamptz,
  cancelled_at      timestamptz,
  cancelled_by      uuid references public.profiles(id) on delete set null,
  cancellation_reason text,
  completed_at      timestamptz,

  created_by        uuid references public.profiles(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint bookings_ref_format check (booking_ref ~ '^GNM-[0-9]{4}-[A-Z0-9]{6}$'),

  -- The core guarantee: no two live bookings may overlap on one ground.
  constraint bookings_no_overlap exclude using gist (
    ground_id with =,
    slot      with &&
  ) where (status in ('pending','confirmed'))
);

comment on table public.bookings is
  'A slot reservation. player_id is null for bookings staff/owners enter on '
  'behalf of a walk-in or WhatsApp customer — those still block the slot.';
comment on constraint bookings_no_overlap on public.bookings is
  'Prevents double-booking at the database level (SQLSTATE 23P01 on conflict).';

create index if not exists bookings_ground_date_idx on public.bookings (ground_id, booking_date);
create index if not exists bookings_player_idx      on public.bookings (player_id, booking_date desc);
create index if not exists bookings_status_idx      on public.bookings (status);
create index if not exists bookings_created_idx     on public.bookings (created_at desc);
create index if not exists bookings_hold_idx        on public.bookings (hold_expires_at)
  where status = 'pending';

drop trigger if exists bookings_set_updated_at on public.bookings;
create trigger bookings_set_updated_at
  before update on public.bookings
  for each row execute function public.tg_set_updated_at();

-- ---------------------------------------------------------------------------
-- Status timestamps are derived, never client-supplied.
-- ---------------------------------------------------------------------------
create or replace function public.tg_bookings_stamp_status()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    case new.status
      when 'confirmed' then
        new.confirmed_at   := coalesce(new.confirmed_at, now());
        new.hold_expires_at := null;
      when 'cancelled' then new.cancelled_at := coalesce(new.cancelled_at, now());
      when 'expired'   then new.cancelled_at := coalesce(new.cancelled_at, now());
      when 'completed' then new.completed_at := coalesce(new.completed_at, now());
      else null;
    end case;
  end if;
  return new;
end
$$;

drop trigger if exists bookings_stamp_status on public.bookings;
create trigger bookings_stamp_status
  before update on public.bookings
  for each row execute function public.tg_bookings_stamp_status();

-- Human-readable reference: GNM-YYMM-XXXXXX
create or replace function public.generate_booking_ref()
returns text
language sql
volatile
as $$
  select 'GNM-' || to_char(now() at time zone 'Asia/Karachi', 'YYMM') || '-'
      || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
$$;
