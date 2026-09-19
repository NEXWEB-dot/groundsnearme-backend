-- ============================================================================
-- GroundsNearMe — 0029 · Matchmaking Booking Guard
-- Enforces that open games / matchmaking posts must be linked to a verified,
-- confirmed ground booking to eliminate spam and fake match posts.
-- ============================================================================

-- 1. Add booking linkage columns to open_games
alter table public.open_games
  add column if not exists booking_ref text,
  add column if not exists booking_id uuid references public.bookings(id) on delete set null;

create index if not exists open_games_booking_ref_idx on public.open_games(booking_ref);
create index if not exists open_games_booking_id_idx on public.open_games(booking_id);

-- 2. Update create_open_game RPC to require and verify booking
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
  p_notes          text default null,
  p_booking_ref    text default null,
  p_booking_id     uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user      uuid := auth.uid();
  v_handle    text;
  v_wa        text;
  v_booking   record;
  v_ground_id uuid := p_ground_id;
  v_area_id   uuid := p_area_id;
  v_row       public.open_games;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'AUTH_REQUIRED', 'message', 'Sign in to post a game.'));
  end if;

  -- 1. Verification of confirmed booking
  if p_booking_id is not null or p_booking_ref is not null then
    select b.id, b.booking_ref, b.ground_id, b.booking_date, b.start_time, b.status, g.area_id
      into v_booking
      from public.bookings b
      left join public.grounds g on g.id = b.ground_id
     where (p_booking_id is not null and b.id = p_booking_id)
        or (p_booking_ref is not null and b.booking_ref = p_booking_ref)
     limit 1;

    if v_booking.id is null then
      return jsonb_build_object('ok', false, 'error',
        jsonb_build_object('code', 'INVALID_BOOKING', 'message', 'Specified booking was not found.'));
    end if;

    if v_booking.status in ('cancelled', 'expired') then
      return jsonb_build_object('ok', false, 'error',
        jsonb_build_object('code', 'BOOKING_INACTIVE', 'message', 'Match cannot be posted for a cancelled or expired booking.'));
    end if;

    -- Pre-fill / lock ground and area from the verified booking
    v_ground_id  := v_booking.ground_id;
    p_match_date := v_booking.booking_date;
    if p_start_time is null then
      p_start_time := v_booking.start_time;
    end if;
    if v_booking.area_id is not null then
      v_area_id := v_booking.area_id;
    end if;
  else
    -- Without booking ref or id, reject match post
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'BOOKING_REQUIRED', 'message', 'Match postings are exclusively available for confirmed ground bookings. Please book a ground slot first.'));
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

  -- Rate limit: 5 open games per player per rolling day
  if (select count(*) from public.open_games
       where host_id = v_user and created_at > now() - interval '1 day') >= 5 then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'RATE_LIMITED', 'message', 'Too many posts today.'));
  end if;

  insert into public.open_games (
    host_id, host_handle, title, looking_for, skill_level, format, ground_id,
    area_id, match_date, start_time, players_needed, notes, whatsapp_number,
    booking_ref, booking_id
  )
  values (
    v_user, v_handle, trim(p_title), p_looking_for::public.looking_for,
    p_skill_level::public.skill_level, nullif(trim(coalesce(p_format, '')), ''),
    v_ground_id, v_area_id, p_match_date, p_start_time, p_players_needed,
    nullif(trim(coalesce(p_notes, '')), ''), v_wa,
    v_booking.booking_ref, v_booking.id
  )
  returning * into v_row;

  return jsonb_build_object('ok', true, 'game', to_jsonb(v_row));
end;
$$;

grant execute on function public.create_open_game(
  text, date, text, text, int, time, text, uuid, uuid, text, text, uuid
) to authenticated;
