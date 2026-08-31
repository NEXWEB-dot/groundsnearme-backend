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
