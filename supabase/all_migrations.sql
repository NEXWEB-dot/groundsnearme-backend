-- ============================================================================
-- FILE: 20260829120001_extensions_enums.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0001 · extensions + enum types
-- Idempotent: safe to re-run.
-- ============================================================================

create extension if not exists pgcrypto   with schema extensions;
create extension if not exists btree_gist  with schema extensions;
create extension if not exists citext      with schema extensions;

-- All enums created in one pass so the file stays declarative.
do $$
declare
  t record;
begin
  for t in
    select * from (values
      ('user_role',          array['player','owner','admin','superadmin']),
      ('ground_status',      array['draft','pending','active','paused','rejected','archived']),
      ('ground_type',        array['indoor','outdoor','both']),
      ('listing_tier',       array['free','pro']),
      ('booking_status',     array['pending','confirmed','cancelled','completed','no_show','expired']),
      ('payment_status',     array['unpaid','partial','paid','refunded']),
      ('booking_source',     array['web','whatsapp','admin','owner']),
      ('game_status',        array['open','filled','cancelled','expired']),
      ('skill_level',        array['beginner','intermediate','advanced','any']),
      ('looking_for',        array['players','opposition']),
      ('interest_status',    array['interested','accepted','declined','withdrawn']),
      ('subscription_status',array['unpaid','paid','overdue','waived','cancelled']),
      ('payment_method',     array['jazzcash','easypaisa','bank_transfer','cash','other']),
      ('commission_status',  array['accrued','invoiced','collected','written_off']),
      ('lead_status',        array['new','contacted','onboarding','listed','rejected'])
    ) as v(name, labels)
  loop
    if not exists (
      select 1 from pg_type
      where typname = t.name and typnamespace = 'public'::regnamespace
    ) then
      execute format(
        'create type public.%I as enum (%s)',
        t.name,
        (select string_agg(quote_literal(l), ',') from unnest(t.labels) as l)
      );
    end if;
  end loop;
end
$$;

-- Shared updated_at trigger function.
create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

comment on function public.tg_set_updated_at() is
  'BEFORE UPDATE trigger: stamps updated_at.';


-- ============================================================================
-- FILE: 20260829120002_profiles.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0002 · profiles + auth wiring + role helpers
-- One profile row per auth.users row. `role` is the app-level role.
-- ============================================================================

create table if not exists public.profiles (
  id                uuid primary key references auth.users(id) on delete cascade,
  role              public.user_role not null default 'player',
  full_name         text,
  handle            extensions.citext unique,
  email             extensions.citext,
  phone             text,
  whatsapp_number   text,
  city              text not null default 'Karachi',
  avatar_url        text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint profiles_handle_format
    check (handle is null or handle ~ '^[a-z0-9_]{3,24}$'),
  constraint profiles_phone_len
    check (phone is null or char_length(phone) between 7 and 24),
  constraint profiles_whatsapp_format
    check (whatsapp_number is null or whatsapp_number ~ '^[0-9]{10,15}$')
);

comment on table public.profiles is
  'App-level user record. role: player | owner | admin | superadmin.';
comment on column public.profiles.whatsapp_number is
  'Digits only, country code first, no + (wa.me format). e.g. 923001234567';

create index if not exists profiles_role_idx on public.profiles (role);

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.tg_set_updated_at();

-- ---------------------------------------------------------------------------
-- Role helpers. SECURITY DEFINER so RLS policies can read `profiles` without
-- recursing into the policies defined on `profiles` itself.
-- ---------------------------------------------------------------------------
create or replace function public.current_app_role()
returns public.user_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.role from public.profiles p where p.id = auth.uid();
$$;

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select p.role in ('admin','superadmin') from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

create or replace function public.is_superadmin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select p.role = 'superadmin' from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

comment on function public.is_superadmin() is
  'True only for the private financial dashboard owner (Shayan).';

-- ---------------------------------------------------------------------------
-- Signup hook. Never lets a signup self-assign a staff role: only player or
-- owner can come from client-supplied metadata.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_raw    text;
  v_handle text;
begin
  v_raw := coalesce(
    nullif(new.raw_user_meta_data->>'account_type', ''),
    nullif(new.raw_app_meta_data->>'gnm_role', ''),
    'player'
  );
  if v_raw not in ('player','owner') then
    v_raw := 'player';
  end if;

  v_handle := nullif(lower(new.raw_user_meta_data->>'handle'), '');
  if v_handle is not null then
    if v_handle !~ '^[a-z0-9_]{3,24}$'
       or exists (select 1 from public.profiles p where p.handle = v_handle::extensions.citext)
    then
      v_handle := null;  -- never block signup on a taken/invalid handle
    end if;
  end if;

  insert into public.profiles (
    id, role, full_name, handle, email, phone, whatsapp_number
  )
  values (
    new.id,
    v_raw::public.user_role,
    nullif(new.raw_user_meta_data->>'full_name', ''),
    v_handle::extensions.citext,
    new.email::extensions.citext,
    coalesce(nullif(new.phone, ''), nullif(new.raw_user_meta_data->>'phone', '')),
    nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'whatsapp_number', ''), '[^0-9]', '', 'g'), '')
  )
  on conflict (id) do nothing;

  return new;
end
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Only a superadmin may change someone's role (service_role/psql bypasses).
create or replace function public.tg_profiles_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.role is distinct from old.role then
    if auth.uid() is not null and not public.is_superadmin() then
      raise exception 'ROLE_CHANGE_FORBIDDEN' using errcode = '42501';
    end if;
  end if;
  new.id := old.id;
  return new;
end
$$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard
  before update on public.profiles
  for each row execute function public.tg_profiles_guard();


-- ============================================================================
-- FILE: 20260829120003_areas_grounds.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0003 · areas + grounds
-- Supabase is the source of truth for structured data.
-- Ground images live on Cloudflare R2; only their URLs are stored here.
-- ============================================================================

create table if not exists public.areas (
  id          uuid primary key default gen_random_uuid(),
  city        text not null default 'Karachi',
  name        text not null,
  slug        text not null unique,
  sort_order  int  not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  constraint areas_city_name_unique unique (city, name)
);

create index if not exists areas_city_idx on public.areas (city) where is_active;

comment on table public.areas is
  'Lookup of serviceable areas. Drives the Area filter on the public site.';

-- ---------------------------------------------------------------------------

create table if not exists public.grounds (
  id                       uuid primary key default gen_random_uuid(),
  slug                     text not null unique,
  name                     text not null,
  owner_id                 uuid references public.profiles(id) on delete set null,
  area_id                  uuid references public.areas(id) on delete set null,
  city                     text not null default 'Karachi',
  address                  text,
  latitude                 numeric(9,6),
  longitude                numeric(9,6),
  description              text,
  ground_type              public.ground_type not null default 'outdoor',
  surface                  text,
  pitch_count              int not null default 1 check (pitch_count > 0),

  price_per_hour           integer not null check (price_per_hour > 0),
  weekend_price_per_hour   integer check (weekend_price_per_hour is null or weekend_price_per_hour > 0),
  currency                 char(3) not null default 'PKR',

  whatsapp_number          text,
  phone                    text,
  contact_name             text,

  amenities                text[] not null default '{}',
  images                   jsonb  not null default '[]'::jsonb,
  cover_image_url          text,

  status                   public.ground_status not null default 'pending',
  listing_tier             public.listing_tier  not null default 'free',
  is_featured              boolean not null default false,
  featured_rank            int,
  featured_until           timestamptz,

  -- Commission is 0 at launch (free listings). Set per ground when the
  -- commission model goes live so historical bookings keep their own rate.
  commission_rate          numeric(5,4) not null default 0
                             check (commission_rate >= 0 and commission_rate <= 0.5),

  slot_duration_minutes    int not null default 60
                             check (slot_duration_minutes in (30,60,90,120)),
  min_booking_minutes      int not null default 60 check (min_booking_minutes > 0),
  max_booking_minutes      int not null default 480 check (max_booking_minutes > 0),
  advance_booking_days     int not null default 30 check (advance_booking_days between 1 and 365),

  rating                   numeric(2,1) check (rating is null or rating between 0 and 5),
  review_count             int not null default 0 check (review_count >= 0),

  internal_notes           text,
  created_by               uuid references public.profiles(id) on delete set null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint grounds_whatsapp_format
    check (whatsapp_number is null or whatsapp_number ~ '^[0-9]{10,15}$'),
  constraint grounds_images_is_array
    check (jsonb_typeof(images) = 'array'),
  constraint grounds_booking_window
    check (max_booking_minutes >= min_booking_minutes),
  constraint grounds_slug_format
    check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

comment on table public.grounds is
  'A bookable cricket ground. New rows are created by staff via the admin view '
  'after the owner reaches out on WhatsApp — there is no public self-serve form.';
comment on column public.grounds.images is
  'JSON array of {url, alt, sort} objects. url points at the R2 public bucket.';
comment on column public.grounds.commission_rate is
  'Fraction, e.g. 0.05 = 5%. Snapshotted onto each booking at creation time.';

create index if not exists grounds_status_idx        on public.grounds (status);
create index if not exists grounds_area_idx          on public.grounds (area_id) where status = 'active';
create index if not exists grounds_city_idx          on public.grounds (city)    where status = 'active';
create index if not exists grounds_owner_idx         on public.grounds (owner_id);
create index if not exists grounds_price_idx         on public.grounds (price_per_hour) where status = 'active';
create index if not exists grounds_featured_idx      on public.grounds (is_featured, featured_rank) where status = 'active';
create index if not exists grounds_amenities_gin_idx on public.grounds using gin (amenities);
create index if not exists grounds_name_lower_idx    on public.grounds (lower(name));

drop trigger if exists grounds_set_updated_at on public.grounds;
create trigger grounds_set_updated_at
  before update on public.grounds
  for each row execute function public.tg_set_updated_at();

-- Keep cover_image_url in step with the images array.
create or replace function public.tg_grounds_sync_cover()
returns trigger
language plpgsql
as $$
begin
  if new.cover_image_url is null and jsonb_array_length(coalesce(new.images, '[]'::jsonb)) > 0 then
    new.cover_image_url := new.images -> 0 ->> 'url';
  end if;
  return new;
end
$$;

drop trigger if exists grounds_sync_cover on public.grounds;
create trigger grounds_sync_cover
  before insert or update of images, cover_image_url on public.grounds
  for each row execute function public.tg_grounds_sync_cover();


-- ============================================================================
-- FILE: 20260829120004_ground_hours.sql
-- ============================================================================

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


-- ============================================================================
-- FILE: 20260829120005_bookings.sql
-- ============================================================================

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


-- ============================================================================
-- FILE: 20260829120006_matchmaking.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0006 · matchmaking (open games + interests)
-- ============================================================================

create table if not exists public.open_games (
  id              uuid primary key default gen_random_uuid(),
  host_id         uuid references public.profiles(id) on delete set null,
  host_handle     text not null,
  title           text not null check (char_length(title) between 6 and 120),
  looking_for     public.looking_for not null default 'players',
  skill_level     public.skill_level not null default 'any',
  format          text,
  ground_id       uuid references public.grounds(id) on delete set null,
  area_id         uuid references public.areas(id) on delete set null,
  city            text not null default 'Karachi',
  match_date      date not null,
  start_time      time,
  players_needed  int check (players_needed is null or players_needed between 1 and 22),
  notes           text,
  whatsapp_number text,
  status          public.game_status not null default 'open',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint open_games_whatsapp_format
    check (whatsapp_number is null or whatsapp_number ~ '^[0-9]{10,15}$'),
  constraint open_games_host_handle_format
    check (host_handle ~ '^[a-z0-9_]{3,24}$'),
  constraint open_games_needs_count
    check (looking_for <> 'players' or players_needed is not null)
);

comment on table public.open_games is
  'A player-posted request: "need N players" or "team looking for opposition".';
comment on column public.open_games.host_handle is
  'Denormalised profile handle, rendered as @handle on the public site.';

create index if not exists open_games_status_date_idx
  on public.open_games (status, match_date);
create index if not exists open_games_area_idx  on public.open_games (area_id)  where status = 'open';
create index if not exists open_games_host_idx  on public.open_games (host_id);
create index if not exists open_games_recent_idx on public.open_games (created_at desc);

drop trigger if exists open_games_set_updated_at on public.open_games;
create trigger open_games_set_updated_at
  before update on public.open_games
  for each row execute function public.tg_set_updated_at();

-- ---------------------------------------------------------------------------

create table if not exists public.open_game_interests (
  id            uuid primary key default gen_random_uuid(),
  open_game_id  uuid not null references public.open_games(id) on delete cascade,
  player_id     uuid not null references public.profiles(id) on delete cascade,
  message       text,
  status        public.interest_status not null default 'interested',
  created_at    timestamptz not null default now(),
  constraint open_game_interests_unique unique (open_game_id, player_id)
);

comment on table public.open_game_interests is
  'One row per player expressing interest in an open game. Drives the '
  '"N players expressed interest" counter.';

create index if not exists open_game_interests_game_idx
  on public.open_game_interests (open_game_id);
create index if not exists open_game_interests_player_idx
  on public.open_game_interests (player_id);

-- A host cannot express interest in their own game.
create or replace function public.tg_interest_not_host()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (
    select 1 from public.open_games g
    where g.id = new.open_game_id and g.host_id = new.player_id
  ) then
    raise exception 'HOST_CANNOT_JOIN_OWN_GAME' using errcode = '23514';
  end if;
  return new;
end
$$;

drop trigger if exists interest_not_host on public.open_game_interests;
create trigger interest_not_host
  before insert on public.open_game_interests
  for each row execute function public.tg_interest_not_host();

-- Flip a game to `filled` once enough players are accepted.
create or replace function public.tg_interest_maybe_fill()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_needed  int;
  v_accepted int;
begin
  select players_needed into v_needed
  from public.open_games where id = new.open_game_id;

  if v_needed is null then
    return new;
  end if;

  select count(*) into v_accepted
  from public.open_game_interests
  where open_game_id = new.open_game_id and status = 'accepted';

  if v_accepted >= v_needed then
    update public.open_games
       set status = 'filled'
     where id = new.open_game_id and status = 'open';
  end if;

  return new;
end
$$;

drop trigger if exists interest_maybe_fill on public.open_game_interests;
create trigger interest_maybe_fill
  after insert or update of status on public.open_game_interests
  for each row execute function public.tg_interest_maybe_fill();


-- ============================================================================
-- FILE: 20260829120007_monetization.sql
-- ============================================================================

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


-- ============================================================================
-- FILE: 20260829120008_leads_audit.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0008 · WhatsApp owner-onboarding intake + audit log
-- Owners message the WhatsApp deep link on the public site; staff log the
-- conversation here, then create the ground from the admin view.
-- ============================================================================

create table if not exists public.ground_leads (
  id                uuid primary key default gen_random_uuid(),
  owner_name        text,
  whatsapp_number   text not null,
  phone             text,
  ground_name       text,
  area_text         text,
  city              text not null default 'Karachi',
  asking_price      integer check (asking_price is null or asking_price > 0),
  source            text not null default 'whatsapp',
  status            public.lead_status not null default 'new',
  notes             text,
  assigned_to       uuid references public.profiles(id) on delete set null,
  created_ground_id uuid references public.grounds(id) on delete set null,
  first_contact_at  timestamptz,
  created_by        uuid references public.profiles(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint ground_leads_whatsapp_format
    check (whatsapp_number ~ '^[0-9]{10,15}$')
);

comment on table public.ground_leads is
  'Manual intake queue for owner onboarding. Internal only — never public.';

create index if not exists ground_leads_status_idx on public.ground_leads (status, created_at desc);
create index if not exists ground_leads_wa_idx     on public.ground_leads (whatsapp_number);

drop trigger if exists ground_leads_set_updated_at on public.ground_leads;
create trigger ground_leads_set_updated_at
  before update on public.ground_leads
  for each row execute function public.tg_set_updated_at();

-- ---------------------------------------------------------------------------

create table if not exists public.audit_log (
  id          bigserial primary key,
  actor_id    uuid references public.profiles(id) on delete set null,
  actor_role  public.user_role,
  action      text not null,
  entity      text not null,
  entity_id   text,
  diff        jsonb,
  created_at  timestamptz not null default now()
);

comment on table public.audit_log is
  'Append-only trail for staff actions (ground created/approved, status flips).';

create index if not exists audit_log_entity_idx on public.audit_log (entity, entity_id, created_at desc);
create index if not exists audit_log_actor_idx  on public.audit_log (actor_id, created_at desc);

create or replace function public.log_audit(
  p_action    text,
  p_entity    text,
  p_entity_id text,
  p_diff      jsonb default null
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.audit_log (actor_id, actor_role, action, entity, entity_id, diff)
  values (auth.uid(), public.current_app_role(), p_action, p_entity, p_entity_id, p_diff);
$$;

-- Track every ground status transition automatically.
create or replace function public.tg_grounds_audit_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    perform public.log_audit('ground.created', 'grounds', new.id::text,
      jsonb_build_object('status', new.status, 'name', new.name));
  elsif new.status is distinct from old.status then
    perform public.log_audit('ground.status_changed', 'grounds', new.id::text,
      jsonb_build_object('from', old.status, 'to', new.status));
  end if;
  return null;
end
$$;

drop trigger if exists grounds_audit_status on public.grounds;
create trigger grounds_audit_status
  after insert or update of status on public.grounds
  for each row execute function public.tg_grounds_audit_status();


-- ============================================================================
-- FILE: 20260829120009_fn_availability.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0009 · availability engine
-- Single source of truth for "which slots are open". The public site, the
-- owner dashboard and the booking RPC all go through these two functions.
--
-- Contract: returns one row per bookable slot on p_date, in ground-local
-- (Asia/Karachi) wall-clock time. Zero rows means the ground has no schedule
-- for that weekday at all — render that as "Closed".
-- ============================================================================

create or replace function public.get_ground_availability(
  p_ground_id uuid,
  p_date      date
)
returns table (
  slot_start   time,
  slot_end     time,
  starts_at    timestamp,
  ends_at      timestamp,
  is_available boolean,
  reason       text,
  price        numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  g            record;
  h            record;
  v_now        timestamp := (now() at time zone 'Asia/Karachi');
  v_today      date;
  v_open       timestamp;
  v_close      timestamp;
  v_step       interval;
  v_cur        timestamp;
  v_slot_end   timestamp;
  v_dow        smallint;
  v_rate       integer;
  v_is_weekend boolean;
  v_closed_day boolean;
  v_out_window boolean;
  v_booked     boolean;
begin
  v_today := v_now::date;

  select id, status, price_per_hour, weekend_price_per_hour,
         slot_duration_minutes, advance_booking_days
    into g
    from public.grounds
   where id = p_ground_id;

  if g.id is null or g.status <> 'active' then
    return;
  end if;

  v_dow := extract(dow from p_date)::smallint;

  select * into h
    from public.ground_hours
   where ground_id = p_ground_id and day_of_week = v_dow;

  if h.id is null or h.is_closed then
    return;                                   -- no schedule this weekday
  end if;

  v_is_weekend := v_dow in (0, 6);
  v_rate := case
              when v_is_weekend then coalesce(g.weekend_price_per_hour, g.price_per_hour)
              else g.price_per_hour
            end;

  v_closed_day := exists (
    select 1 from public.ground_closures c
     where c.ground_id = p_ground_id
       and p_date between c.starts_on and c.ends_on
  );

  v_out_window := p_date < v_today
               or p_date > (v_today + g.advance_booking_days);

  v_open  := p_date + h.opens_at;
  v_close := (case when h.closes_at <= h.opens_at then p_date + 1 else p_date end) + h.closes_at;
  v_step  := make_interval(mins => g.slot_duration_minutes);

  v_cur := v_open;
  while v_cur + v_step <= v_close loop
    v_slot_end := v_cur + v_step;

    v_booked := exists (
      select 1
        from public.bookings b
       where b.ground_id = p_ground_id
         and b.status in ('pending','confirmed')
         and (b.status <> 'pending'
              or b.hold_expires_at is null
              or b.hold_expires_at > now())          -- stale holds don't block
         and b.slot && tsrange(v_cur, v_slot_end, '[)')
    );

    slot_start := v_cur::time;
    slot_end   := v_slot_end::time;
    starts_at  := v_cur;
    ends_at    := v_slot_end;
    price      := round(v_rate * (g.slot_duration_minutes / 60.0), 0);

    if v_out_window then
      is_available := false; reason := 'out_of_window';
    elsif v_closed_day then
      is_available := false; reason := 'closed';
    elsif v_cur <= v_now then
      is_available := false; reason := 'past';
    elsif v_booked then
      is_available := false; reason := 'booked';
    else
      is_available := true;  reason := null;
    end if;

    return next;
    v_cur := v_slot_end;
  end loop;

  return;
end
$$;

comment on function public.get_ground_availability(uuid, date) is
  'Slot grid for one ground on one date, Asia/Karachi wall-clock.';

-- ---------------------------------------------------------------------------
-- Cheap "Slots Open" / "Full Today" badge input for list views.
-- ---------------------------------------------------------------------------
create or replace function public.count_open_slots(
  p_ground_id uuid,
  p_date      date
)
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(count(*), 0)::int
    from public.get_ground_availability(p_ground_id, p_date) a
   where a.is_available;
$$;

grant execute on function public.get_ground_availability(uuid, date) to anon, authenticated;
grant execute on function public.count_open_slots(uuid, date)        to anon, authenticated;


-- ============================================================================
-- FILE: 20260829120010_fn_create_booking.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0010 · create_booking
-- Returns a JSON envelope (never raises) so the Worker can map failures to
-- precise HTTP status codes without depending on PostgREST error translation:
--   {"ok":true,  "booking": {...}}
--   {"ok":false, "error": {"code":"SLOT_TAKEN","message":"..."}}
-- ============================================================================

create or replace function public.create_booking(
  p_ground_id        uuid,
  p_booking_date     date,
  p_start_time       time,
  p_end_time         time,
  p_contact_name     text default null,
  p_contact_phone    text default null,
  p_notes            text default null,
  p_players_expected int  default null,
  p_hold_minutes     int  default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  g          record;
  v_player   uuid := auth.uid();
  v_start_ts timestamp;
  v_end_ts   timestamp;
  v_minutes  int;
  v_expected int;
  v_total    int;
  v_avail    int;
  v_reason   text;
  v_rate     integer;
  v_amount   numeric(12,2);
  v_hold     int := least(greatest(coalesce(p_hold_minutes, 30), 5), 180);
  v_row      public.bookings;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'AUTH_REQUIRED', 'message', 'Sign in to book a slot.'));
  end if;

  select id, status, price_per_hour, weekend_price_per_hour, slot_duration_minutes,
         min_booking_minutes, max_booking_minutes, commission_rate, currency
    into g
    from public.grounds
   where id = p_ground_id;

  if g.id is null or g.status <> 'active' then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'GROUND_NOT_AVAILABLE', 'message', 'This ground is not accepting bookings.'));
  end if;

  v_start_ts := p_booking_date + p_start_time;
  v_end_ts   := (case when p_end_time <= p_start_time then p_booking_date + 1 else p_booking_date end)
                + p_end_time;
  v_minutes  := (extract(epoch from (v_end_ts - v_start_ts)) / 60)::int;

  if v_minutes <= 0 then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'INVALID_TIME_RANGE', 'message', 'End time must be after start time.'));
  end if;

  if v_minutes % g.slot_duration_minutes <> 0 then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'INVALID_DURATION',
      'message', format('Bookings must be in %s-minute blocks.', g.slot_duration_minutes)));
  end if;

  if v_minutes < g.min_booking_minutes or v_minutes > g.max_booking_minutes then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'INVALID_DURATION',
      'message', format('This ground accepts %s–%s minute bookings.',
                        g.min_booking_minutes, g.max_booking_minutes)));
  end if;

  -- Release holds that have lapsed so they neither block the grid nor the
  -- exclusion constraint below.
  update public.bookings
     set status = 'expired'
   where ground_id = p_ground_id
     and status = 'pending'
     and hold_expires_at is not null
     and hold_expires_at < now();

  v_expected := v_minutes / g.slot_duration_minutes;

  select count(*)::int, count(*) filter (where a.is_available)::int
    into v_total, v_avail
    from public.get_ground_availability(p_ground_id, p_booking_date) a
   where a.starts_at >= v_start_ts and a.ends_at <= v_end_ts;

  if v_total <> v_expected then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'OUTSIDE_OPENING_HOURS',
      'message', 'That time is outside this ground''s opening hours.'));
  end if;

  if v_avail <> v_expected then
    select a.reason into v_reason
      from public.get_ground_availability(p_ground_id, p_booking_date) a
     where a.starts_at >= v_start_ts and a.ends_at <= v_end_ts
       and not a.is_available
     limit 1;

    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', case v_reason
                when 'past'          then 'SLOT_IN_PAST'
                when 'closed'        then 'GROUND_CLOSED'
                when 'out_of_window' then 'OUTSIDE_BOOKING_WINDOW'
                else 'SLOT_TAKEN'
              end,
      'message', case v_reason
                   when 'past'          then 'That slot has already started.'
                   when 'closed'        then 'The ground is closed on this date.'
                   when 'out_of_window' then 'That date is not open for booking yet.'
                   else 'Someone just took this slot. Pick another one.'
                 end));
  end if;

  v_rate := case
              when extract(dow from p_booking_date) in (0, 6)
                then coalesce(g.weekend_price_per_hour, g.price_per_hour)
              else g.price_per_hour
            end;
  v_amount := round(v_rate * (v_minutes / 60.0), 2);

  begin
    insert into public.bookings (
      booking_ref, ground_id, player_id, booking_date, start_time, end_time,
      duration_minutes, status, source, price_per_hour, total_amount, currency,
      commission_rate, commission_amount, contact_name, contact_phone,
      players_expected, notes, hold_expires_at, created_by
    )
    values (
      public.generate_booking_ref(), p_ground_id, v_player, p_booking_date,
      p_start_time, p_end_time, v_minutes, 'pending', 'web', v_rate, v_amount,
      g.currency, g.commission_rate, round(v_amount * g.commission_rate, 2),
      nullif(trim(coalesce(p_contact_name, '')), ''),
      nullif(trim(coalesce(p_contact_phone, '')), ''),
      p_players_expected,
      nullif(trim(coalesce(p_notes, '')), ''),
      now() + make_interval(mins => v_hold),
      v_player
    )
    returning * into v_row;
  exception
    when exclusion_violation then
      return jsonb_build_object('ok', false, 'error', jsonb_build_object(
        'code', 'SLOT_TAKEN', 'message', 'Someone just took this slot. Pick another one.'));
    when unique_violation then
      return jsonb_build_object('ok', false, 'error', jsonb_build_object(
        'code', 'RETRY', 'message', 'Booking reference collision — please retry.'));
  end;

  return jsonb_build_object('ok', true, 'booking', to_jsonb(v_row));
end
$$;

grant execute on function public.create_booking(uuid, date, time, time, text, text, text, int, int)
  to authenticated;


-- ============================================================================
-- FILE: 20260829120011_fn_booking_lifecycle.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0011 · booking lifecycle
--   cancel_booking       : player, ground owner or staff
--   set_booking_status   : ground owner or staff (confirm / complete / no_show)
--   create_manual_booking: owner or staff logging an offline/WhatsApp booking
--                          so it still blocks the slot on the public site
-- ============================================================================

create or replace function public.owns_ground(p_ground_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.grounds g
     where g.id = p_ground_id and g.owner_id = auth.uid()
  );
$$;

-- ---------------------------------------------------------------------------

create or replace function public.cancel_booking(
  p_booking_id uuid,
  p_reason     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b record;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'AUTH_REQUIRED', 'message', 'Sign in first.'));
  end if;

  select * into b from public.bookings where id = p_booking_id;

  if b.id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Booking not found.'));
  end if;

  if not (b.player_id = auth.uid() or public.owns_ground(b.ground_id) or public.is_staff()) then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not your booking.'));
  end if;

  if b.status not in ('pending','confirmed') then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_CANCELLABLE',
        'message', format('This booking is already %s.', b.status)));
  end if;

  update public.bookings
     set status = 'cancelled',
         cancelled_by = auth.uid(),
         cancellation_reason = nullif(trim(coalesce(p_reason, '')), '')
   where id = p_booking_id
   returning * into b;

  return jsonb_build_object('ok', true, 'booking', to_jsonb(b));
end
$$;

-- ---------------------------------------------------------------------------

create or replace function public.set_booking_status(
  p_booking_id uuid,
  p_status     text,
  p_reason     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b       record;
  v_next  public.booking_status;
begin
  if p_status not in ('confirmed','completed','no_show','cancelled') then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'INVALID_STATUS', 'message', 'Unsupported status.'));
  end if;
  v_next := p_status::public.booking_status;

  select * into b from public.bookings where id = p_booking_id;
  if b.id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Booking not found.'));
  end if;

  if not (public.owns_ground(b.ground_id) or public.is_staff()) then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not your ground.'));
  end if;

  if b.status in ('cancelled','expired') and v_next <> 'cancelled' then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_EDITABLE',
        'message', 'Cancelled bookings cannot be revived — create a new one.'));
  end if;

  update public.bookings
     set status = v_next,
         cancellation_reason = case when v_next = 'cancelled'
                                    then nullif(trim(coalesce(p_reason, '')), '')
                                    else cancellation_reason end,
         cancelled_by = case when v_next = 'cancelled' then auth.uid() else cancelled_by end
   where id = p_booking_id
   returning * into b;

  return jsonb_build_object('ok', true, 'booking', to_jsonb(b));
end
$$;

grant execute on function public.owns_ground(uuid)                       to authenticated;
grant execute on function public.cancel_booking(uuid, text)              to authenticated;
grant execute on function public.set_booking_status(uuid, text, text)    to authenticated;


-- ============================================================================
-- FILE: 20260829120012_fn_manual_booking.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0012 · create_manual_booking
-- Owners and staff log walk-in / WhatsApp bookings here so the slot stops
-- showing as open on the public site. No player account required.
-- ============================================================================

create or replace function public.create_manual_booking(
  p_ground_id      uuid,
  p_booking_date   date,
  p_start_time     time,
  p_end_time       time,
  p_contact_name   text default null,
  p_contact_phone  text default null,
  p_notes          text default null,
  p_source         text default 'whatsapp',
  p_confirmed      boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  g          record;
  v_start_ts timestamp;
  v_end_ts   timestamp;
  v_minutes  int;
  v_rate     integer;
  v_amount   numeric(12,2);
  v_source   public.booking_source;
  v_row      public.bookings;
begin
  if not (public.owns_ground(p_ground_id) or public.is_staff()) then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not your ground.'));
  end if;

  if p_source not in ('web','whatsapp','admin','owner') then
    p_source := 'whatsapp';
  end if;
  v_source := p_source::public.booking_source;

  select id, status, price_per_hour, weekend_price_per_hour, commission_rate, currency
    into g
    from public.grounds
   where id = p_ground_id;

  if g.id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'GROUND_NOT_FOUND', 'message', 'Ground not found.'));
  end if;

  v_start_ts := p_booking_date + p_start_time;
  v_end_ts   := (case when p_end_time <= p_start_time then p_booking_date + 1 else p_booking_date end)
                + p_end_time;
  v_minutes  := (extract(epoch from (v_end_ts - v_start_ts)) / 60)::int;

  if v_minutes <= 0 then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'INVALID_TIME_RANGE', 'message', 'End time must be after start time.'));
  end if;

  -- Staff/owners are trusted to book outside the published grid (private
  -- hires, tournaments), so opening hours are not enforced here — but the
  -- overlap constraint still is.
  update public.bookings
     set status = 'expired'
   where ground_id = p_ground_id
     and status = 'pending'
     and hold_expires_at is not null
     and hold_expires_at < now();

  v_rate := case
              when extract(dow from p_booking_date) in (0, 6)
                then coalesce(g.weekend_price_per_hour, g.price_per_hour)
              else g.price_per_hour
            end;
  v_amount := round(v_rate * (v_minutes / 60.0), 2);

  begin
    insert into public.bookings (
      booking_ref, ground_id, player_id, booking_date, start_time, end_time,
      duration_minutes, status, source, price_per_hour, total_amount, currency,
      commission_rate, commission_amount, contact_name, contact_phone, notes,
      confirmed_at, created_by
    )
    values (
      public.generate_booking_ref(), p_ground_id, null, p_booking_date,
      p_start_time, p_end_time, v_minutes,
      case when p_confirmed then 'confirmed' else 'pending' end,
      v_source, v_rate, v_amount, g.currency,
      g.commission_rate, round(v_amount * g.commission_rate, 2),
      nullif(trim(coalesce(p_contact_name, '')), ''),
      nullif(trim(coalesce(p_contact_phone, '')), ''),
      nullif(trim(coalesce(p_notes, '')), ''),
      case when p_confirmed then now() else null end,
      auth.uid()
    )
    returning * into v_row;
  exception
    when exclusion_violation then
      return jsonb_build_object('ok', false, 'error', jsonb_build_object(
        'code', 'SLOT_TAKEN', 'message', 'That slot already has a live booking.'));
  end;

  perform public.log_audit('booking.manual_created', 'bookings', v_row.id::text,
    jsonb_build_object('ground_id', p_ground_id, 'ref', v_row.booking_ref, 'source', v_source));

  return jsonb_build_object('ok', true, 'booking', to_jsonb(v_row));
end
$$;

grant execute on function public.create_manual_booking(
  uuid, date, time, time, text, text, text, text, boolean
) to authenticated;


-- ============================================================================
-- FILE: 20260829120013_fn_search_grounds.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0013 · search_grounds
-- One round trip for the public directory: filters, sort, pagination and the
-- per-ground "slots open today" count in a single call.
--   → {"items":[{...}], "total": 137}
-- ============================================================================

create or replace function public.search_grounds(
  p_city       text    default 'Karachi',
  p_area       text    default null,
  p_date       date    default null,
  p_min_price  int     default null,
  p_max_price  int     default null,
  p_type       text    default null,
  p_amenities  text[]  default null,
  p_q          text    default null,
  p_only_open  boolean default false,
  p_sort       text    default 'featured',
  p_limit      int     default 24,
  p_offset     int     default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_date   date := coalesce(p_date, (now() at time zone 'Asia/Karachi')::date);
  v_limit  int  := least(greatest(coalesce(p_limit, 24), 1), 100);
  v_offset int  := greatest(coalesce(p_offset, 0), 0);
  v_sort   text := coalesce(p_sort, 'featured');
  v_items  jsonb;
  v_total  int;
begin
  if v_sort not in ('featured','price_asc','price_desc','rating','newest','name') then
    v_sort := 'featured';
  end if;

  with base as (
    select g.*, a.name as area_name, a.slug as area_slug
      from public.grounds g
      left join public.areas a on a.id = g.area_id
     where g.status = 'active'
       and (p_city      is null or g.city ilike p_city)
       and (p_area      is null or a.slug = lower(p_area) or a.name ilike p_area)
       and (p_min_price is null or g.price_per_hour >= p_min_price)
       and (p_max_price is null or g.price_per_hour <= p_max_price)
       and (p_type      is null
            or g.ground_type::text = p_type
            or (p_type in ('indoor','outdoor') and g.ground_type = 'both'))
       and (p_amenities is null or array_length(p_amenities, 1) is null
            or g.amenities @> p_amenities)
       and (p_q is null or trim(p_q) = ''
            or g.name ilike '%' || p_q || '%'
            or coalesce(g.address, '') ilike '%' || p_q || '%'
            or coalesce(a.name, '')   ilike '%' || p_q || '%')
  ),
  enriched as (
    select b.*, public.count_open_slots(b.id, v_date) as open_slots
      from base b
  ),
  filtered as (
    select * from enriched
     where not coalesce(p_only_open, false) or open_slots > 0
  ),
  page as (
    select count(*) over () as total_count,
           jsonb_build_object(
             'id',                    f.id,
             'slug',                  f.slug,
             'name',                  f.name,
             'area',                  f.area_name,
             'area_slug',             f.area_slug,
             'city',                  f.city,
             'address',               f.address,
             'lat',                   f.latitude,
             'lng',                   f.longitude,
             'type',                  f.ground_type,
             'surface',               f.surface,
             'price_per_hour',        f.price_per_hour,
             'weekend_price_per_hour',f.weekend_price_per_hour,
             'currency',              f.currency,
             'whatsapp_number',       f.whatsapp_number,
             'amenities',             to_jsonb(f.amenities),
             'images',                f.images,
             'cover_image',           f.cover_image_url,
             'tier',                  f.listing_tier,
             'is_featured',           f.is_featured,
             'rating',                f.rating,
             'review_count',          f.review_count,
             'slot_duration_minutes', f.slot_duration_minutes,
             'min_booking_minutes',   f.min_booking_minutes,
             'max_booking_minutes',   f.max_booking_minutes,
             'advance_booking_days',  f.advance_booking_days,
             'open_slots',            f.open_slots,
             'availability_date',     v_date
           ) as item,
           row_number() over (
             order by
               case when v_sort = 'featured' and f.is_featured then 0 else 1 end,
               case v_sort
                 when 'price_asc'  then  f.price_per_hour::numeric
                 when 'price_desc' then -f.price_per_hour::numeric
                 when 'rating'     then -coalesce(f.rating, 0)
                 else null
               end nulls last,
               case v_sort when 'name'   then f.name      else null end nulls last,
               case v_sort when 'newest' then f.created_at else null end desc nulls last,
               f.featured_rank nulls last,
               f.open_slots desc,
               f.name
           ) as ord
      from filtered f
     order by ord
     limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(p.item order by p.ord), '[]'::jsonb),
         coalesce(max(p.total_count), 0)::int
    into v_items, v_total
    from page p;

  return jsonb_build_object(
    'items',  v_items,
    'total',  v_total,
    'limit',  v_limit,
    'offset', v_offset,
    'date',   v_date
  );
end
$$;

grant execute on function public.search_grounds(
  text, text, date, int, int, text, text[], text, boolean, text, int, int
) to anon, authenticated;


-- ============================================================================
-- FILE: 20260829120014_fn_get_ground.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0014 · get_ground (detail page payload)
-- Accepts a slug or a uuid. Returns the ground, its weekly hours, the slot
-- grid for p_date, and upcoming closures — everything the detail page needs.
-- ============================================================================

create or replace function public.get_ground(
  p_ref  text,
  p_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_date  date := coalesce(p_date, (now() at time zone 'Asia/Karachi')::date);
  v_id    uuid;
  v_g     jsonb;
  v_hours jsonb;
  v_slots jsonb;
  v_closed jsonb;
begin
  if p_ref is null or trim(p_ref) = '' then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Ground not found.'));
  end if;

  select g.id into v_id
    from public.grounds g
   where g.status = 'active'
     and (g.slug = lower(trim(p_ref))
          or (p_ref ~ '^[0-9a-fA-F-]{36}$' and g.id = p_ref::uuid))
   limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Ground not found.'));
  end if;

  select jsonb_build_object(
           'id',                    g.id,
           'slug',                  g.slug,
           'name',                  g.name,
           'area',                  a.name,
           'area_slug',             a.slug,
           'city',                  g.city,
           'address',               g.address,
           'lat',                   g.latitude,
           'lng',                   g.longitude,
           'description',           g.description,
           'type',                  g.ground_type,
           'surface',               g.surface,
           'pitch_count',           g.pitch_count,
           'price_per_hour',        g.price_per_hour,
           'weekend_price_per_hour',g.weekend_price_per_hour,
           'currency',              g.currency,
           'whatsapp_number',       g.whatsapp_number,
           'contact_name',          g.contact_name,
           'amenities',             to_jsonb(g.amenities),
           'images',                g.images,
           'cover_image',           g.cover_image_url,
           'tier',                  g.listing_tier,
           'is_featured',           g.is_featured,
           'rating',                g.rating,
           'review_count',          g.review_count,
           'slot_duration_minutes', g.slot_duration_minutes,
           'min_booking_minutes',   g.min_booking_minutes,
           'max_booking_minutes',   g.max_booking_minutes,
           'advance_booking_days',  g.advance_booking_days
         )
    into v_g
    from public.grounds g
    left join public.areas a on a.id = g.area_id
   where g.id = v_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'day_of_week', h.day_of_week,
           'opens_at',    to_char(h.opens_at,  'HH24:MI'),
           'closes_at',   to_char(h.closes_at, 'HH24:MI'),
           'is_closed',   h.is_closed
         ) order by h.day_of_week), '[]'::jsonb)
    into v_hours
    from public.ground_hours h
   where h.ground_id = v_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'start_time',   to_char(s.slot_start, 'HH24:MI'),
           'end_time',     to_char(s.slot_end,   'HH24:MI'),
           'is_available', s.is_available,
           'reason',       s.reason,
           'price',        s.price
         ) order by s.starts_at), '[]'::jsonb)
    into v_slots
    from public.get_ground_availability(v_id, v_date) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'starts_on', c.starts_on,
           'ends_on',   c.ends_on,
           'reason',    c.reason
         ) order by c.starts_on), '[]'::jsonb)
    into v_closed
    from public.ground_closures c
   where c.ground_id = v_id
     and c.ends_on >= v_date;

  return jsonb_build_object(
    'ok',       true,
    'ground',   v_g,
    'hours',    v_hours,
    'slots',    v_slots,
    'closures', v_closed,
    'date',     v_date
  );
end
$$;

grant execute on function public.get_ground(text, date) to anon, authenticated;


-- ============================================================================
-- FILE: 20260829120015_fn_matchmaking.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0015 · matchmaking functions
--   list_open_games  : public feed with interest counts
--   create_open_game : authenticated players post a game
--   express_interest : "Join Game" button
-- ============================================================================

create or replace function public.list_open_games(
  p_city        text default 'Karachi',
  p_area        text default null,
  p_skill       text default null,
  p_looking_for text default null,
  p_from_date   date default null,
  p_limit       int  default 20,
  p_offset      int  default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_from   date := coalesce(p_from_date, (now() at time zone 'Asia/Karachi')::date);
  v_limit  int  := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset int  := greatest(coalesce(p_offset, 0), 0);
  v_items  jsonb;
  v_total  int;
begin
  with page as (
    select count(*) over () as total_count,
           jsonb_build_object(
             'id',             og.id,
             'title',          og.title,
             'host_handle',    og.host_handle,
             'looking_for',    og.looking_for,
             'skill_level',    og.skill_level,
             'format',         og.format,
             'area',           a.name,
             'area_slug',      a.slug,
             'city',           og.city,
             'match_date',     og.match_date,
             'start_time',     to_char(og.start_time, 'HH24:MI'),
             'players_needed', og.players_needed,
             'notes',          og.notes,
             'status',         og.status,
             'interest_count', (
               select count(*) from public.open_game_interests i
                where i.open_game_id = og.id and i.status <> 'withdrawn'
             ),
             'ground', case when g.id is null then null else jsonb_build_object(
                            'id', g.id, 'slug', g.slug, 'name', g.name,
                            'cover_image', g.cover_image_url) end,
             'whatsapp_number', og.whatsapp_number,
             'created_at',      og.created_at
           ) as item,
           row_number() over (order by og.match_date asc, og.created_at desc) as ord
      from public.open_games og
      left join public.areas   a on a.id = og.area_id
      left join public.grounds g on g.id = og.ground_id and g.status = 'active'
     where og.status = 'open'
       and og.match_date >= v_from
       and (p_city        is null or og.city ilike p_city)
       and (p_area        is null or a.slug = lower(p_area) or a.name ilike p_area)
       and (p_skill       is null or og.skill_level::text in (p_skill, 'any'))
       and (p_looking_for is null or og.looking_for::text = p_looking_for)
     order by ord
     limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(p.item order by p.ord), '[]'::jsonb),
         coalesce(max(p.total_count), 0)::int
    into v_items, v_total
    from page p;

  return jsonb_build_object('items', v_items, 'total', v_total,
                            'limit', v_limit, 'offset', v_offset);
end
$$;

-- ---------------------------------------------------------------------------

create or replace function public.create_open_game(
  p_title          text,
  p_match_date     date,
  p_looking_for    text default 'players',
  p_skill_level    text default 'any',
  p_players_needed int  default null,
  p_start_time     time default null,
  p_format         text default null,
  p_ground_id      uuid default null,
  p_area_id        uuid default null,
  p_notes          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user   uuid := auth.uid();
  v_handle text;
  v_wa     text;
  v_row    public.open_games;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'AUTH_REQUIRED', 'message', 'Sign in to post a game.'));
  end if;

  if p_looking_for not in ('players','opposition') then p_looking_for := 'players'; end if;
  if p_skill_level not in ('beginner','intermediate','advanced','any') then p_skill_level := 'any'; end if;

  if p_looking_for = 'players' and coalesce(p_players_needed, 0) < 1 then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'PLAYERS_NEEDED_REQUIRED',
        'message', 'Say how many players you need.'));
  end if;

  if p_match_date < (now() at time zone 'Asia/Karachi')::date then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'DATE_IN_PAST', 'message', 'Pick a future date.'));
  end if;

  select coalesce(pr.handle::text, 'player_' || substr(v_user::text, 1, 6)), pr.whatsapp_number
    into v_handle, v_wa
    from public.profiles pr where pr.id = v_user;

  -- Rate limit: 5 open games per player per rolling day.
  if (select count(*) from public.open_games
       where host_id = v_user and created_at > now() - interval '1 day') >= 5 then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'RATE_LIMITED', 'message', 'Too many posts today.'));
  end if;

  insert into public.open_games (
    host_id, host_handle, title, looking_for, skill_level, format, ground_id,
    area_id, match_date, start_time, players_needed, notes, whatsapp_number
  )
  values (
    v_user, v_handle, trim(p_title), p_looking_for::public.looking_for,
    p_skill_level::public.skill_level, nullif(trim(coalesce(p_format, '')), ''),
    p_ground_id, p_area_id, p_match_date, p_start_time, p_players_needed,
    nullif(trim(coalesce(p_notes, '')), ''), v_wa
  )
  returning * into v_row;

  return jsonb_build_object('ok', true, 'game', to_jsonb(v_row));
end
$$;

grant execute on function public.list_open_games(text, text, text, text, date, int, int)
  to anon, authenticated;
grant execute on function public.create_open_game(
  text, date, text, text, int, time, text, uuid, uuid, text
) to authenticated;


-- ============================================================================
-- FILE: 20260829120016_fn_interest.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0016 · matchmaking interest ("Join Game")
-- ============================================================================

create or replace function public.express_interest(
  p_open_game_id uuid,
  p_message      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  g      record;
  v_row  public.open_game_interests;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'AUTH_REQUIRED', 'message', 'Sign in to join a game.'));
  end if;

  select id, host_id, status, whatsapp_number
    into g
    from public.open_games
   where id = p_open_game_id;

  if g.id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'That game no longer exists.'));
  end if;

  if g.status <> 'open' then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'GAME_CLOSED',
        'message', format('This game is already %s.', g.status)));
  end if;

  if g.host_id = v_user then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'HOST_CANNOT_JOIN', 'message', 'This is your own game.'));
  end if;

  insert into public.open_game_interests as ogi (open_game_id, player_id, message)
  values (p_open_game_id, v_user, nullif(trim(coalesce(p_message, '')), ''))
  on conflict (open_game_id, player_id) do update
    set status  = 'interested',
        message = coalesce(excluded.message, ogi.message)
  returning * into v_row;

  return jsonb_build_object(
    'ok', true,
    'interest', to_jsonb(v_row),
    -- Handed back so the frontend can open the WhatsApp thread immediately.
    'host_whatsapp_number', g.whatsapp_number,
    'interest_count', (
      select count(*) from public.open_game_interests i
       where i.open_game_id = p_open_game_id and i.status <> 'withdrawn'
    )
  );
end
$$;

-- ---------------------------------------------------------------------------

create or replace function public.set_interest_status(
  p_interest_id uuid,
  p_status      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  i      record;
  v_host uuid;
begin
  if p_status not in ('interested','accepted','declined','withdrawn') then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'INVALID_STATUS', 'message', 'Unsupported status.'));
  end if;

  select ogi.*, og.host_id into i
    from public.open_game_interests ogi
    join public.open_games og on og.id = ogi.open_game_id
   where ogi.id = p_interest_id;

  if i.id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Not found.'));
  end if;

  v_host := i.host_id;

  -- Host may accept/decline; the player may only withdraw their own interest.
  if p_status = 'withdrawn' then
    if i.player_id <> v_user then
      return jsonb_build_object('ok', false, 'error',
        jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not yours.'));
    end if;
  elsif v_host is distinct from v_user and not public.is_staff() then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Only the host can do that.'));
  end if;

  update public.open_game_interests
     set status = p_status::public.interest_status
   where id = p_interest_id;

  return jsonb_build_object('ok', true, 'id', p_interest_id, 'status', p_status);
end
$$;

grant execute on function public.express_interest(uuid, text)     to authenticated;
grant execute on function public.set_interest_status(uuid, text)  to authenticated;


-- ============================================================================
-- FILE: 20260829120017_rls_core.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0017 · RLS: enable everywhere + grants + directory policies
-- Rule of thumb: every table gets RLS on, and anything not explicitly allowed
-- is denied. Public read is limited to active grounds and open games.
-- ============================================================================

alter table public.profiles            enable row level security;
alter table public.areas               enable row level security;
alter table public.grounds             enable row level security;
alter table public.ground_hours        enable row level security;
alter table public.ground_closures     enable row level security;
alter table public.bookings            enable row level security;
alter table public.open_games          enable row level security;
alter table public.open_game_interests enable row level security;
alter table public.owner_subscriptions enable row level security;
alter table public.commission_ledger   enable row level security;
alter table public.ground_leads        enable row level security;
alter table public.audit_log           enable row level security;

-- Table privileges (RLS narrows these further, row by row).
grant usage on schema public to anon, authenticated;

grant select on public.areas               to anon, authenticated;
grant select on public.grounds             to anon, authenticated;
grant select on public.ground_hours        to anon, authenticated;
grant select on public.ground_closures     to anon, authenticated;
grant select on public.open_games          to anon, authenticated;
grant select on public.open_game_interests to anon, authenticated;

grant select, update           on public.profiles            to authenticated;
grant select, insert, update   on public.bookings            to authenticated;
grant select, insert, update   on public.open_games          to authenticated;
grant select, insert, update, delete on public.open_game_interests to authenticated;
grant select, insert, update   on public.grounds             to authenticated;
grant select, insert, update, delete on public.ground_hours    to authenticated;
grant select, insert, update, delete on public.ground_closures to authenticated;
grant select, insert, update   on public.owner_subscriptions to authenticated;
grant select                   on public.commission_ledger   to authenticated;
grant select, insert, update   on public.ground_leads        to authenticated;
grant select                   on public.audit_log           to authenticated;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select_self  on public.profiles;
drop policy if exists profiles_select_staff on public.profiles;
drop policy if exists profiles_update_self  on public.profiles;

create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = auth.uid());

create policy profiles_select_staff on public.profiles
  for select to authenticated
  using (public.is_staff());

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- areas — public read, staff write
-- ---------------------------------------------------------------------------
drop policy if exists areas_select_public on public.areas;
create policy areas_select_public on public.areas
  for select to anon, authenticated
  using (is_active or public.is_staff());

-- ---------------------------------------------------------------------------
-- grounds
--   public          : active listings only
--   owner           : own listings, any status; may edit a safe subset
--   staff/superadmin: everything
-- ---------------------------------------------------------------------------
drop policy if exists grounds_select_public on public.grounds;
drop policy if exists grounds_select_owner  on public.grounds;
drop policy if exists grounds_select_staff  on public.grounds;
drop policy if exists grounds_update_owner  on public.grounds;
drop policy if exists grounds_write_staff   on public.grounds;

create policy grounds_select_public on public.grounds
  for select to anon, authenticated
  using (status = 'active');

create policy grounds_select_owner on public.grounds
  for select to authenticated
  using (owner_id = auth.uid());

create policy grounds_select_staff on public.grounds
  for select to authenticated
  using (public.is_staff());

create policy grounds_update_owner on public.grounds
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy grounds_write_staff on public.grounds
  for all to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- Owners must not be able to promote their own listing or change its billing
-- terms; those columns are staff-only even on their own row.
create or replace function public.tg_grounds_owner_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or public.is_staff() then
    return new;
  end if;

  if new.status          is distinct from old.status
     or new.listing_tier is distinct from old.listing_tier
     or new.is_featured  is distinct from old.is_featured
     or new.featured_rank is distinct from old.featured_rank
     or new.featured_until is distinct from old.featured_until
     or new.commission_rate is distinct from old.commission_rate
     or new.owner_id     is distinct from old.owner_id
  then
    raise exception 'FIELD_NOT_OWNER_EDITABLE' using errcode = '42501';
  end if;

  return new;
end
$$;

drop trigger if exists grounds_owner_guard on public.grounds;
create trigger grounds_owner_guard
  before update on public.grounds
  for each row execute function public.tg_grounds_owner_guard();

-- ---------------------------------------------------------------------------
-- ground_hours / ground_closures — public read for active grounds,
-- owner+staff write.
-- ---------------------------------------------------------------------------
drop policy if exists ground_hours_select_public on public.ground_hours;
drop policy if exists ground_hours_write_owner   on public.ground_hours;
drop policy if exists ground_hours_write_staff   on public.ground_hours;

create policy ground_hours_select_public on public.ground_hours
  for select to anon, authenticated
  using (exists (select 1 from public.grounds g
                  where g.id = ground_id and g.status = 'active'));

create policy ground_hours_write_owner on public.ground_hours
  for all to authenticated
  using (public.owns_ground(ground_id))
  with check (public.owns_ground(ground_id));

create policy ground_hours_write_staff on public.ground_hours
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists ground_closures_select_public on public.ground_closures;
drop policy if exists ground_closures_write_owner   on public.ground_closures;
drop policy if exists ground_closures_write_staff   on public.ground_closures;

create policy ground_closures_select_public on public.ground_closures
  for select to anon, authenticated
  using (exists (select 1 from public.grounds g
                  where g.id = ground_id and g.status = 'active'));

create policy ground_closures_write_owner on public.ground_closures
  for all to authenticated
  using (public.owns_ground(ground_id))
  with check (public.owns_ground(ground_id));

create policy ground_closures_write_staff on public.ground_closures
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());


-- ============================================================================
-- FILE: 20260829120018_rls_bookings_matchmaking.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0018 · RLS: bookings + matchmaking
--   player : own bookings only
--   owner  : bookings on their own grounds
--   staff  : everything
-- Writes normally go through the SECURITY DEFINER RPCs; these policies are the
-- backstop for anything that talks to PostgREST directly.
-- ============================================================================

drop policy if exists bookings_select_own    on public.bookings;
drop policy if exists bookings_select_owner  on public.bookings;
drop policy if exists bookings_select_staff  on public.bookings;
drop policy if exists bookings_insert_own    on public.bookings;
drop policy if exists bookings_update_own    on public.bookings;
drop policy if exists bookings_update_owner  on public.bookings;
drop policy if exists bookings_update_staff  on public.bookings;

create policy bookings_select_own on public.bookings
  for select to authenticated
  using (player_id = auth.uid());

create policy bookings_select_owner on public.bookings
  for select to authenticated
  using (public.owns_ground(ground_id));

create policy bookings_select_staff on public.bookings
  for select to authenticated
  using (public.is_staff());

create policy bookings_insert_own on public.bookings
  for insert to authenticated
  with check (
    player_id = auth.uid()
    and exists (select 1 from public.grounds g
                 where g.id = ground_id and g.status = 'active')
  );

create policy bookings_update_own on public.bookings
  for update to authenticated
  using (player_id = auth.uid())
  with check (player_id = auth.uid());

create policy bookings_update_owner on public.bookings
  for update to authenticated
  using (public.owns_ground(ground_id))
  with check (public.owns_ground(ground_id));

create policy bookings_update_staff on public.bookings
  for update to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- A player may only cancel — never re-price, move, or confirm their own slot.
create or replace function public.tg_bookings_player_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null
     or public.is_staff()
     or public.owns_ground(new.ground_id)
  then
    return new;
  end if;

  if new.booking_date     is distinct from old.booking_date
     or new.start_time    is distinct from old.start_time
     or new.end_time      is distinct from old.end_time
     or new.ground_id     is distinct from old.ground_id
     or new.total_amount  is distinct from old.total_amount
     or new.price_per_hour is distinct from old.price_per_hour
     or new.commission_rate is distinct from old.commission_rate
     or new.commission_amount is distinct from old.commission_amount
     or new.payment_status is distinct from old.payment_status
     or new.player_id     is distinct from old.player_id
  then
    raise exception 'FIELD_NOT_PLAYER_EDITABLE' using errcode = '42501';
  end if;

  if new.status is distinct from old.status and new.status <> 'cancelled' then
    raise exception 'PLAYER_CAN_ONLY_CANCEL' using errcode = '42501';
  end if;

  return new;
end
$$;

drop trigger if exists bookings_player_guard on public.bookings;
create trigger bookings_player_guard
  before update on public.bookings
  for each row execute function public.tg_bookings_player_guard();

-- ---------------------------------------------------------------------------
-- open_games — anyone can read open games; hosts manage their own.
-- ---------------------------------------------------------------------------
drop policy if exists open_games_select_public on public.open_games;
drop policy if exists open_games_select_host   on public.open_games;
drop policy if exists open_games_insert_host   on public.open_games;
drop policy if exists open_games_update_host   on public.open_games;
drop policy if exists open_games_staff         on public.open_games;

create policy open_games_select_public on public.open_games
  for select to anon, authenticated
  using (status = 'open');

create policy open_games_select_host on public.open_games
  for select to authenticated
  using (host_id = auth.uid());

create policy open_games_insert_host on public.open_games
  for insert to authenticated
  with check (host_id = auth.uid());

create policy open_games_update_host on public.open_games
  for update to authenticated
  using (host_id = auth.uid())
  with check (host_id = auth.uid());

create policy open_games_staff on public.open_games
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- open_game_interests
--   public : nothing (only the aggregate count, exposed via list_open_games)
--   player : own rows
--   host   : rows on their own games
-- ---------------------------------------------------------------------------
drop policy if exists interests_select_self  on public.open_game_interests;
drop policy if exists interests_select_host  on public.open_game_interests;
drop policy if exists interests_insert_self  on public.open_game_interests;
drop policy if exists interests_update_self  on public.open_game_interests;
drop policy if exists interests_update_host  on public.open_game_interests;
drop policy if exists interests_delete_self  on public.open_game_interests;

create policy interests_select_self on public.open_game_interests
  for select to authenticated
  using (player_id = auth.uid());

create policy interests_select_host on public.open_game_interests
  for select to authenticated
  using (exists (select 1 from public.open_games g
                  where g.id = open_game_id and g.host_id = auth.uid())
         or public.is_staff());

create policy interests_insert_self on public.open_game_interests
  for insert to authenticated
  with check (player_id = auth.uid());

create policy interests_update_self on public.open_game_interests
  for update to authenticated
  using (player_id = auth.uid()) with check (player_id = auth.uid());

create policy interests_update_host on public.open_game_interests
  for update to authenticated
  using (exists (select 1 from public.open_games g
                  where g.id = open_game_id and g.host_id = auth.uid()));

create policy interests_delete_self on public.open_game_interests
  for delete to authenticated
  using (player_id = auth.uid());


-- ============================================================================
-- FILE: 20260829120019_rls_money_internal.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0019 · RLS: money + internal tables
--   owner_subscriptions : owner sees own cycles; staff manage
--   commission_ledger   : SUPERADMIN ONLY — this is the private P&L
--   ground_leads        : staff only
--   audit_log           : superadmin read only
-- ============================================================================

drop policy if exists subs_select_owner on public.owner_subscriptions;
drop policy if exists subs_staff        on public.owner_subscriptions;

create policy subs_select_owner on public.owner_subscriptions
  for select to authenticated
  using (owner_id = auth.uid());

create policy subs_staff on public.owner_subscriptions
  for all to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- Owners can look but never touch: no owner update/insert policy exists, so
-- flipping a cycle to `paid` is staff-only.

-- ---------------------------------------------------------------------------
-- commission_ledger — deliberately invisible to owners and to non-superadmin
-- staff. The private financial dashboard is the only consumer.
-- ---------------------------------------------------------------------------
drop policy if exists ledger_superadmin on public.commission_ledger;

create policy ledger_superadmin on public.commission_ledger
  for all to authenticated
  using (public.is_superadmin())
  with check (public.is_superadmin());

-- ---------------------------------------------------------------------------
-- ground_leads — internal onboarding queue.
-- ---------------------------------------------------------------------------
drop policy if exists leads_staff on public.ground_leads;

create policy leads_staff on public.ground_leads
  for all to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- audit_log — append-only via public.log_audit(); readable by superadmin.
-- ---------------------------------------------------------------------------
drop policy if exists audit_select_superadmin on public.audit_log;

create policy audit_select_superadmin on public.audit_log
  for select to authenticated
  using (public.is_superadmin());

revoke insert, update, delete on public.audit_log from anon, authenticated;


-- ============================================================================
-- FILE: 20260829120020_finance_views.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0020 · finance views (private dashboard inputs)
-- security_invoker = on, so the caller's RLS applies: commission rows are
-- visible to superadmin only, which makes these views superadmin-only too.
-- ============================================================================

create or replace view public.v_monthly_commission
  with (security_invoker = on) as
select
  cl.earned_month                                                    as month,
  count(*)                                                           as bookings,
  sum(cl.gross_amount)                                               as gross_amount,
  sum(cl.commission_amount)                                          as commission_amount,
  sum(cl.commission_amount) filter (where cl.status = 'collected')    as collected_amount,
  sum(cl.commission_amount) filter (where cl.status in ('accrued','invoiced')) as outstanding_amount
from public.commission_ledger cl
where cl.status <> 'written_off'
group by cl.earned_month;

comment on view public.v_monthly_commission is
  'Commission earned per month. Superadmin only (RLS on commission_ledger).';

-- ---------------------------------------------------------------------------

create or replace view public.v_commission_by_ground
  with (security_invoker = on) as
select
  cl.ground_id,
  g.name                                as ground_name,
  g.slug                                as ground_slug,
  a.name                                as area,
  count(*)                              as bookings,
  sum(cl.gross_amount)                  as gross_amount,
  sum(cl.commission_amount)             as commission_amount,
  max(cl.earned_month)                  as last_earned_month
from public.commission_ledger cl
join public.grounds g on g.id = cl.ground_id
left join public.areas a on a.id = g.area_id
where cl.status <> 'written_off'
group by cl.ground_id, g.name, g.slug, a.name;

comment on view public.v_commission_by_ground is
  'Which venues generate the most commission. Superadmin only.';

-- ---------------------------------------------------------------------------

create or replace view public.v_monthly_subscription_revenue
  with (security_invoker = on) as
select
  date_trunc('month', s.cycle_start)::date                     as month,
  count(*)                                                     as cycles,
  count(*) filter (where s.status = 'paid')                    as paid_cycles,
  count(*) filter (where s.status in ('unpaid','overdue'))      as unpaid_cycles,
  sum(s.amount) filter (where s.status = 'paid')               as paid_amount,
  sum(s.amount) filter (where s.status in ('unpaid','overdue')) as unpaid_amount
from public.owner_subscriptions s
group by date_trunc('month', s.cycle_start);

comment on view public.v_monthly_subscription_revenue is
  'Premium-tier revenue, tracked separately from commission revenue.';

-- ---------------------------------------------------------------------------
-- Booking volume drives commission, so it is tracked in its own right.
-- Visible to staff (bookings RLS), which includes superadmin.
-- ---------------------------------------------------------------------------

create or replace view public.v_monthly_bookings
  with (security_invoker = on) as
select
  date_trunc('month', b.booking_date)::date                          as month,
  count(*)                                                           as total_bookings,
  count(*) filter (where b.status = 'completed')                     as completed,
  count(*) filter (where b.status = 'confirmed')                     as confirmed,
  count(*) filter (where b.status in ('cancelled','expired'))         as cancelled,
  count(distinct b.ground_id)                                        as active_grounds,
  count(distinct b.player_id)                                        as unique_players,
  sum(b.total_amount) filter (where b.status in ('confirmed','completed')) as gross_booked_value
from public.bookings b
group by date_trunc('month', b.booking_date);

comment on view public.v_monthly_bookings is
  'Platform-wide booking volume per month.';

grant select on public.v_monthly_commission            to authenticated;
grant select on public.v_commission_by_ground          to authenticated;
grant select on public.v_monthly_subscription_revenue  to authenticated;
grant select on public.v_monthly_bookings              to authenticated;


-- ============================================================================
-- FILE: 20260829120021_fn_finance_overview.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0021 · finance_overview (private dashboard, one round trip)
-- Superadmin only, enforced inside the function. Returns headline totals plus
-- the three trends the dashboard charts: commission, subscriptions, bookings.
-- ============================================================================

create or replace function public.finance_overview(
  p_months int default 12
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_months int  := least(greatest(coalesce(p_months, 12), 1), 60);
  v_from   date := (date_trunc('month', (now() at time zone 'Asia/Karachi'))
                    - make_interval(months => v_months - 1))::date;
  v_result jsonb;
begin
  if not public.is_superadmin() then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not authorised.'));
  end if;

  select jsonb_build_object(
    'ok', true,
    'window', jsonb_build_object('from', v_from, 'months', v_months),

    'totals', (
      select jsonb_build_object(
        'commission_all_time',   coalesce(sum(cl.commission_amount), 0),
        'commission_collected',  coalesce(sum(cl.commission_amount)
                                   filter (where cl.status = 'collected'), 0),
        'commission_outstanding',coalesce(sum(cl.commission_amount)
                                   filter (where cl.status in ('accrued','invoiced')), 0),
        'commissionable_bookings', count(*)
      )
      from public.commission_ledger cl
      where cl.status <> 'written_off'
    ),

    'subscriptions', (
      select jsonb_build_object(
        'paid_all_time',   coalesce(sum(s.amount) filter (where s.status = 'paid'), 0),
        'unpaid_current',  coalesce(sum(s.amount)
                             filter (where s.status in ('unpaid','overdue')), 0),
        'active_pro_owners', count(distinct s.owner_id)
                               filter (where s.status = 'paid'
                                       and s.cycle_end >= (now() at time zone 'Asia/Karachi')::date)
      )
      from public.owner_subscriptions s
    ),

    'bookings', (
      select jsonb_build_object(
        'total',      count(*),
        'completed',  count(*) filter (where b.status = 'completed'),
        'this_month', count(*) filter (
                        where date_trunc('month', b.booking_date)
                            = date_trunc('month', (now() at time zone 'Asia/Karachi'))),
        'gross_booked_value', coalesce(sum(b.total_amount)
                                filter (where b.status in ('confirmed','completed')), 0)
      )
      from public.bookings b
    ),

    'grounds', (
      select jsonb_build_object(
        'active', count(*) filter (where g.status = 'active'),
        'pending', count(*) filter (where g.status = 'pending'),
        'pro',     count(*) filter (where g.listing_tier = 'pro' and g.status = 'active')
      )
      from public.grounds g
    ),

    'commission_trend', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'month',      m.month,
               'commission', coalesce(v.commission_amount, 0),
               'collected',  coalesce(v.collected_amount, 0),
               'bookings',   coalesce(v.bookings, 0)
             ) order by m.month), '[]'::jsonb)
      from (select generate_series(v_from, date_trunc('month',
                     (now() at time zone 'Asia/Karachi'))::date,
                     interval '1 month')::date as month) m
      left join public.v_monthly_commission v on v.month = m.month
    ),

    'subscription_trend', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'month',  m.month,
               'paid',   coalesce(v.paid_amount, 0),
               'unpaid', coalesce(v.unpaid_amount, 0)
             ) order by m.month), '[]'::jsonb)
      from (select generate_series(v_from, date_trunc('month',
                     (now() at time zone 'Asia/Karachi'))::date,
                     interval '1 month')::date as month) m
      left join public.v_monthly_subscription_revenue v on v.month = m.month
    ),

    'booking_trend', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'month',     m.month,
               'bookings',  coalesce(v.total_bookings, 0),
               'completed', coalesce(v.completed, 0),
               'value',     coalesce(v.gross_booked_value, 0)
             ) order by m.month), '[]'::jsonb)
      from (select generate_series(v_from, date_trunc('month',
                     (now() at time zone 'Asia/Karachi'))::date,
                     interval '1 month')::date as month) m
      left join public.v_monthly_bookings v on v.month = m.month
    ),

    'top_grounds', (
      select coalesce(jsonb_agg(t order by (t->>'commission_amount')::numeric desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'ground_id',         v.ground_id,
                 'ground_name',       v.ground_name,
                 'ground_slug',       v.ground_slug,
                 'area',              v.area,
                 'bookings',          v.bookings,
                 'gross_amount',      v.gross_amount,
                 'commission_amount', v.commission_amount
               ) as t
        from public.v_commission_by_ground v
        order by v.commission_amount desc
        limit 20
      ) s
    )
  ) into v_result;

  return v_result;
end
$$;

revoke all on function public.finance_overview(int) from anon;
grant execute on function public.finance_overview(int) to authenticated;


-- ============================================================================
-- FILE: 20260829120022_maintenance.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0022 · maintenance jobs
-- Called from the Worker's scheduled (cron) handler, and optionally from
-- pg_cron if it is enabled on the project.
-- ============================================================================

create or replace function public.expire_stale_bookings()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count int;
begin
  with expired as (
    update public.bookings
       set status = 'expired'
     where status = 'pending'
       and hold_expires_at is not null
       and hold_expires_at < now()
    returning 1
  )
  select count(*) into v_count from expired;

  return coalesce(v_count, 0);
end
$$;

comment on function public.expire_stale_bookings() is
  'Releases pending slots whose hold lapsed. Idempotent.';

-- ---------------------------------------------------------------------------

create or replace function public.expire_past_open_games()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count int;
begin
  with expired as (
    update public.open_games
       set status = 'expired'
     where status = 'open'
       and match_date < (now() at time zone 'Asia/Karachi')::date
    returning 1
  )
  select count(*) into v_count from expired;

  return coalesce(v_count, 0);
end
$$;

-- ---------------------------------------------------------------------------
-- Mark yesterday's confirmed bookings as completed so commission accrues.
-- ---------------------------------------------------------------------------

create or replace function public.complete_finished_bookings()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count int;
  v_now   timestamp := (now() at time zone 'Asia/Karachi');
begin
  with done as (
    update public.bookings b
       set status = 'completed'
     where b.status = 'confirmed'
       and upper(b.slot) < v_now
    returning 1
  )
  select count(*) into v_count from done;

  return coalesce(v_count, 0);
end
$$;

comment on function public.complete_finished_bookings() is
  'Confirmed bookings whose slot has ended become completed, which is what '
  'triggers commission accrual.';

-- ---------------------------------------------------------------------------
-- Roll a monthly premium invoice row for every pro-tier owner. Manual /
-- semi-automated billing: this creates the unpaid cycle, a human sends the
-- JazzCash / EasyPaisa link, then the row is flipped to paid.
-- ---------------------------------------------------------------------------

create or replace function public.open_subscription_cycle(
  p_month  date default null,
  p_amount numeric default 2000
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Karachi')::date))::date;
  v_end   date := (v_start + interval '1 month')::date;
  v_made  int;
begin
  if not public.is_staff() then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not authorised.'));
  end if;

  with created as (
    insert into public.owner_subscriptions (
      owner_id, ground_id, tier, cycle_start, cycle_end, amount, status, created_by
    )
    select g.owner_id, g.id, 'pro', v_start, v_end, p_amount, 'unpaid', auth.uid()
      from public.grounds g
     where g.listing_tier = 'pro'
       and g.status = 'active'
       and g.owner_id is not null
    on conflict (owner_id, ground_id, cycle_start) do nothing
    returning 1
  )
  select count(*) into v_made from created;

  return jsonb_build_object('ok', true, 'cycles_created', coalesce(v_made, 0),
                            'cycle_start', v_start, 'cycle_end', v_end);
end
$$;

revoke all on function public.expire_stale_bookings()        from anon, authenticated;
revoke all on function public.expire_past_open_games()       from anon, authenticated;
revoke all on function public.complete_finished_bookings()   from anon, authenticated;
grant  execute on function public.open_subscription_cycle(date, numeric) to authenticated;


-- ============================================================================
-- FILE: 20260829120023_areas_reference_data.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0023 · reference data: Karachi areas
-- Reference data, not seed data: these rows are needed in production.
-- ============================================================================

insert into public.areas (city, name, slug, sort_order) values
  ('Karachi', 'Gulshan-e-Iqbal',    'gulshan-e-iqbal',    10),
  ('Karachi', 'Gulistan-e-Johar',   'gulistan-e-johar',   20),
  ('Karachi', 'DHA / Defence',      'dha-defence',        30),
  ('Karachi', 'Clifton',            'clifton',            40),
  ('Karachi', 'Nazimabad',          'nazimabad',          50),
  ('Karachi', 'North Nazimabad',    'north-nazimabad',    60),
  ('Karachi', 'Federal B Area',     'federal-b-area',     70),
  ('Karachi', 'PECHS',              'pechs',              80),
  ('Karachi', 'Scheme 33',          'scheme-33',          90),
  ('Karachi', 'Malir',              'malir',             100),
  ('Karachi', 'Korangi',            'korangi',           110),
  ('Karachi', 'Saddar',             'saddar',            120),
  ('Karachi', 'Shah Faisal',        'shah-faisal',       130),
  ('Karachi', 'Surjani / Gadap',    'surjani-gadap',     140)
on conflict (slug) do nothing;


-- ============================================================================
-- FILE: 20260829120024_bootstrap_staff.sql
-- ============================================================================

-- ============================================================================
-- GroundsNearMe — 0024 · bootstrap staff accounts
--
-- Roles cannot be self-assigned at signup (see handle_new_user), so the first
-- superadmin has to be promoted here, once, by hand.
--
-- HOW TO USE
--   1. Sign up normally through Supabase Auth with the account that should own
--      the private financial dashboard.
--   2. Edit the email below, then run this file (Supabase SQL editor or
--      `supabase db push`).
--   3. Verify:  select id, role from public.profiles where role <> 'player';
--
-- Re-running is safe. If the email does not exist yet the statement is a no-op
-- and prints a notice.
-- ============================================================================

do $$
declare
  -- ▼▼▼ EDIT THIS ▼▼▼
  v_superadmin_email text := 'shayan@groundsnearme.pk';
  -- ▲▲▲ EDIT THIS ▲▲▲
  v_id uuid;
begin
  select u.id into v_id
    from auth.users u
   where lower(u.email) = lower(v_superadmin_email)
   limit 1;

  if v_id is null then
    raise notice 'bootstrap: no auth user for % — sign up first, then re-run.', v_superadmin_email;
    return;
  end if;

  insert into public.profiles (id, role, email)
  values (v_id, 'superadmin', v_superadmin_email::extensions.citext)
  on conflict (id) do update set role = 'superadmin';

  raise notice 'bootstrap: % promoted to superadmin (%).', v_superadmin_email, v_id;
end
$$;

-- ---------------------------------------------------------------------------
-- Promoting additional staff later (admin, not superadmin):
--
--   update public.profiles
--      set role = 'admin'
--    where id = (select id from auth.users where email = 'teammate@example.com');
--
-- Note: `admin` can manage grounds, bookings and onboarding leads but CANNOT
-- read commission_ledger or call finance_overview(). Only `superadmin` can.
-- ---------------------------------------------------------------------------


