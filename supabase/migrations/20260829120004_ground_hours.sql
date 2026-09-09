-- ============================================================================
-- GroundsNearMe — 0004 · ground opening hours + closures
-- All times are Asia/Karachi wall-clock. Pakistan has no DST, so naive local
-- time is unambiguous and is used consistently across the schema.
-- day_of_week: 0 = Sunday … 6 = Saturday (matches Postgres extract(dow)).
-- ============================================================================

create table if not exists public.ground_hours (
  id           uuid primary key default gen_random_uuid(),
  ground_id    uuid not null references public.grounds(id) on delete cascade,
  day_of_week  smallint not null check (day_of_week between 0 and 6),
  opens_at     time not null,
  closes_at    time not null,
  is_closed    boolean not null default false,
  created_at   timestamptz not null default now(),
  constraint ground_hours_unique unique (ground_id, day_of_week)
);

comment on table public.ground_hours is
  'Weekly opening hours per ground. closes_at <= opens_at means the ground '
  'closes after midnight (e.g. 09:00 → 02:00).';

create index if not exists ground_hours_ground_idx on public.ground_hours (ground_id);

-- ---------------------------------------------------------------------------

create table if not exists public.ground_closures (
  id          uuid primary key default gen_random_uuid(),
  ground_id   uuid not null references public.grounds(id) on delete cascade,
  starts_on   date not null,
  ends_on     date not null,
  reason      text,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  constraint ground_closures_range check (ends_on >= starts_on)
);

comment on table public.ground_closures is
  'Inclusive date ranges when a ground takes no bookings (maintenance, Eid, rain).';

create index if not exists ground_closures_ground_idx
  on public.ground_closures (ground_id, starts_on, ends_on);

-- ---------------------------------------------------------------------------
-- Convenience: seed a Mon–Sun schedule for a ground in one call.
-- ---------------------------------------------------------------------------
create or replace function public.set_ground_hours_all_days(
  p_ground_id uuid,
  p_opens_at  time,
  p_closes_at time
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.ground_hours (ground_id, day_of_week, opens_at, closes_at)
  select p_ground_id, d, p_opens_at, p_closes_at
  from generate_series(0, 6) as d
  on conflict (ground_id, day_of_week) do update
    set opens_at  = excluded.opens_at,
        closes_at = excluded.closes_at,
        is_closed = false;
$$;

revoke all on function public.set_ground_hours_all_days(uuid, time, time) from public, anon, authenticated;
