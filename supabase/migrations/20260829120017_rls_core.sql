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
