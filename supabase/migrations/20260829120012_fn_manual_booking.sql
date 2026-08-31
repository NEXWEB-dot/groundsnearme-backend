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
