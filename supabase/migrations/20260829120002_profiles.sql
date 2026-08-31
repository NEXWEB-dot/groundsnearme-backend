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
