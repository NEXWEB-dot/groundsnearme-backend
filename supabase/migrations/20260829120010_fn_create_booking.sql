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
