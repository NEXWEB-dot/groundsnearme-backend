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
