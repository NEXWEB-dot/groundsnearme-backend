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
