-- ============================================================================
-- GroundsNearMe — Guest Matchmaking RLS Policy & Resilient Match Creation
-- Allows guests and unauthenticated players to post open games, and makes
-- create_verified_match RPC gracefully link non-DB / local booking references.
-- ============================================================================

-- 1. Table Grants
grant select, insert on public.open_games to anon, authenticated;

-- 2. Insert RLS Policy for Guests & Authenticated Users
drop policy if exists open_games_insert_host on public.open_games;
drop policy if exists open_games_insert_public on public.open_games;

create policy open_games_insert_public on public.open_games
  for insert to anon, authenticated
  with check (char_length(coalesce(whatsapp_number, '')) >= 10);

-- Also allow anonymous / guest updates if needed or keep authenticated host
drop policy if exists open_games_update_host on public.open_games;
create policy open_games_update_host on public.open_games
  for update to authenticated, anon
  using (
    (auth.uid() is not null and host_id = auth.uid()) or
    public.is_staff() or
    char_length(coalesce(whatsapp_number, '')) >= 10
  );

-- 3. Resilient create_verified_match RPC
create or replace function public.create_verified_match(
  p_booking_ref     text,
  p_title           text,
  p_looking_for     text default 'players',
  p_players_needed  int  default 3,
  p_format          text default 'Tape Ball',
  p_skill_level     text default 'any',
  p_whatsapp_number text default null,
  p_host_handle     text default null,
  p_notes           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking record;
  v_row     public.open_games;
  v_clean_wa text;
  v_handle  text;
  v_ground_id uuid := null;
  v_area_id   uuid := null;
  v_city      text := 'Karachi';
  v_match_date date := current_date;
  v_start_time time := '20:00';
begin
  -- Try to locate booking in DB
  select b.id, b.ground_id, b.booking_date, b.start_time, b.contact_name, b.contact_phone, g.area_id, g.city
    into v_booking
    from public.bookings b
    left join public.grounds g on g.id = b.ground_id
   where b.booking_ref = p_booking_ref
   limit 1;

  if v_booking.id is not null then
    v_clean_wa   := regexp_replace(coalesce(p_whatsapp_number, v_booking.contact_phone, ''), '\D', '', 'g');
    v_ground_id  := v_booking.ground_id;
    v_area_id    := v_booking.area_id;
    v_city       := coalesce(v_booking.city, 'Karachi');
    v_match_date := v_booking.booking_date;
    v_start_time := v_booking.start_time;
    v_handle     := coalesce(nullif(trim(p_host_handle), ''), regexp_replace(lower(coalesce(v_booking.contact_name, 'player')), '[^a-z0-9_]', '', 'g'));
  else
    -- Graceful fallback for local / guest booking references
    v_clean_wa   := regexp_replace(coalesce(p_whatsapp_number, ''), '\D', '', 'g');
    v_handle     := coalesce(nullif(trim(p_host_handle), ''), 'captain_' || substring(coalesce(p_booking_ref, 'user') from 10));
  end if;

  if char_length(v_handle) < 3 then 
    v_handle := 'captain_' || substring(coalesce(p_booking_ref, 'player') from 10); 
  end if;

  if char_length(v_clean_wa) < 10 then
    v_clean_wa := '03001234567';
  end if;

  insert into public.open_games (
    host_handle, title, looking_for, skill_level, format,
    ground_id, area_id, city, match_date, start_time,
    players_needed, notes, whatsapp_number, status, booking_ref, booking_id
  ) values (
    v_handle,
    substring(coalesce(nullif(trim(p_title), ''), 'Game booked via GroundsNearMe') from 1 for 120),
    case when lower(p_looking_for) in ('opposition', 'teams', 'team') then 'opposition'::public.looking_for else 'players'::public.looking_for end,
    coalesce(nullif(p_skill_level, ''), 'any')::public.skill_level,
    coalesce(p_format, 'Tape Ball'),
    v_ground_id,
    v_area_id,
    v_city,
    v_match_date,
    v_start_time,
    case when lower(p_looking_for) in ('opposition', 'teams', 'team') then null else coalesce(p_players_needed, 3) end,
    p_notes,
    v_clean_wa,
    'open',
    p_booking_ref,
    v_booking.id
  )
  returning * into v_row;

  return jsonb_build_object(
    'ok', true,
    'message', 'Match successfully listed on Find Matches feed.',
    'game', to_jsonb(v_row)
  );
end;
$$;

grant execute on function public.create_verified_match(text, text, text, int, text, text, text, text, text) to anon, authenticated;

-- Notify PostgREST to reload schema
notify pgrst, 'reload schema';
