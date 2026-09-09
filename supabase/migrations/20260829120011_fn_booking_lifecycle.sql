-- ============================================================================
-- GroundsNearMe — 0011 · booking lifecycle
--   cancel_booking       : player, ground owner or staff
--   set_booking_status   : ground owner or staff (confirm / complete / no_show)
--   create_manual_booking: owner or staff logging an offline/WhatsApp booking
--                          so it still blocks the slot on the public site
-- ============================================================================

create or replace function public.owns_ground(p_ground_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.grounds g
     where g.id = p_ground_id and g.owner_id = auth.uid()
  );
$$;

-- ---------------------------------------------------------------------------

create or replace function public.cancel_booking(
  p_booking_id uuid,
  p_reason     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b record;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'AUTH_REQUIRED', 'message', 'Sign in first.'));
  end if;

  select * into b from public.bookings where id = p_booking_id;

  if b.id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Booking not found.'));
  end if;

  if not (b.player_id = auth.uid() or public.owns_ground(b.ground_id) or public.is_staff()) then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not your booking.'));
  end if;

  if b.status not in ('pending','confirmed') then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_CANCELLABLE',
        'message', format('This booking is already %s.', b.status)));
  end if;

  update public.bookings
     set status = 'cancelled',
         cancelled_by = auth.uid(),
         cancellation_reason = nullif(trim(coalesce(p_reason, '')), '')
   where id = p_booking_id
   returning * into b;

  return jsonb_build_object('ok', true, 'booking', to_jsonb(b));
end
$$;

-- ---------------------------------------------------------------------------

create or replace function public.set_booking_status(
  p_booking_id uuid,
  p_status     text,
  p_reason     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b       record;
  v_next  public.booking_status;
begin
  if p_status not in ('confirmed','completed','no_show','cancelled') then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'INVALID_STATUS', 'message', 'Unsupported status.'));
  end if;
  v_next := p_status::public.booking_status;

  select * into b from public.bookings where id = p_booking_id;
  if b.id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Booking not found.'));
  end if;

  if not (public.owns_ground(b.ground_id) or public.is_staff()) then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not your ground.'));
  end if;

  if b.status in ('cancelled','expired') and v_next <> 'cancelled' then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_EDITABLE',
        'message', 'Cancelled bookings cannot be revived — create a new one.'));
  end if;

  update public.bookings
     set status = v_next,
         cancellation_reason = case when v_next = 'cancelled'
                                    then nullif(trim(coalesce(p_reason, '')), '')
                                    else cancellation_reason end,
         cancelled_by = case when v_next = 'cancelled' then auth.uid() else cancelled_by end
   where id = p_booking_id
   returning * into b;

  return jsonb_build_object('ok', true, 'booking', to_jsonb(b));
end
$$;

grant execute on function public.owns_ground(uuid)                       to authenticated;
grant execute on function public.cancel_booking(uuid, text)              to authenticated;
grant execute on function public.set_booking_status(uuid, text, text)    to authenticated;
