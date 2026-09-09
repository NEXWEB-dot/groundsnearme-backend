-- ============================================================================
-- GroundsNearMe — 0027 · Slot Release & Lifecycle Integrity
-- Ensures cancelled or removed bookings immediately release their slot so it
-- becomes available again for players and turf owners.
-- Fixes type casting in create_manual_booking and adds missing RLS insert/delete.
-- ============================================================================

-- 1. Fix create_manual_booking type cast for status column
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
  v_status   public.booking_status;
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
  v_status := case when p_confirmed then 'confirmed'::public.booking_status else 'pending'::public.booking_status end;

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

  -- Release holds that have lapsed
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
      v_status,
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
end;
$$;

grant execute on function public.create_manual_booking(
  uuid, date, time, time, text, text, text, text, boolean
) to authenticated;


-- 2. release_booking RPC (Universal slot cancellation & release)
-- Can be called by booking reference or UUID. Instantly frees up the slot.
create or replace function public.release_booking(
  p_booking_id   uuid default null,
  p_booking_ref  text default null,
  p_reason       text default 'Cancelled'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b public.bookings;
begin
  if p_booking_id is null and p_booking_ref is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'MISSING_PARAM', 'message', 'Provide booking_id or booking_ref.'));
  end if;

  select * into b
    from public.bookings
   where (p_booking_id is not null and id = p_booking_id)
      or (p_booking_ref is not null and booking_ref = p_booking_ref)
   limit 1;

  if b.id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Booking not found.'));
  end if;

  if b.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'message', 'Already cancelled.', 'booking', to_jsonb(b));
  end if;

  update public.bookings
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = auth.uid(),
         cancellation_reason = coalesce(nullif(trim(p_reason), ''), 'Cancelled')
   where id = b.id
   returning * into b;

  perform public.log_audit('booking.cancelled', 'bookings', b.id::text,
    jsonb_build_object('ground_id', b.ground_id, 'ref', b.booking_ref, 'reason', p_reason));

  return jsonb_build_object('ok', true, 'message', 'Slot successfully released and reopened.', 'booking', to_jsonb(b));
end;
$$;

grant execute on function public.release_booking(uuid, text, text) to anon, authenticated;


-- 3. delete_booking RPC (Hard deletion by staff or ground owner)
create or replace function public.delete_booking(
  p_booking_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b public.bookings;
begin
  select * into b from public.bookings where id = p_booking_id;
  if b.id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Booking not found.'));
  end if;

  if not (public.is_staff() or public.owns_ground(b.ground_id)) then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not authorized to delete booking.'));
  end if;

  delete from public.bookings where id = p_booking_id;

  perform public.log_audit('booking.deleted', 'bookings', p_booking_id::text,
    jsonb_build_object('ground_id', b.ground_id, 'ref', b.booking_ref));

  return jsonb_build_object('ok', true, 'message', 'Booking removed and slot released.');
end;
$$;

grant execute on function public.delete_booking(uuid) to authenticated;


-- 4. RLS Policy additions for staff/owner direct access
drop policy if exists bookings_insert_staff on public.bookings;
create policy bookings_insert_staff on public.bookings
  for insert to authenticated
  with check (public.is_staff() or public.owns_ground(ground_id));

drop policy if exists bookings_delete_staff on public.bookings;
create policy bookings_delete_staff on public.bookings
  for delete to authenticated
  using (public.is_staff() or public.owns_ground(ground_id));

grant delete on public.bookings to authenticated;
