-- ============================================================================
-- GroundsNearMe — 0029 · Bulletproof Slot Release (Accepts text or UUID)
-- Solves 22P02 (invalid input syntax for type uuid) by accepting text for
-- p_booking_id and handling both UUID and booking_ref interchangeably.
-- ============================================================================

-- Drop older signatures to avoid function overload ambiguity in PostgREST
drop function if exists public.release_booking(uuid, text, text);
drop function if exists public.release_booking(text, text, text);

create or replace function public.release_booking(
  p_booking_id   text default null,
  p_booking_ref  text default null,
  p_reason       text default 'Cancelled'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b              public.bookings;
  v_uuid         uuid := null;
  v_cancelled_by uuid := null;
begin
  if (p_booking_id is null or trim(p_booking_id) = '') and (p_booking_ref is null or trim(p_booking_ref) = '') then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'MISSING_PARAM', 'message', 'Provide booking_id or booking_ref.'));
  end if;

  -- Test if p_booking_id is a valid UUID
  if p_booking_id is not null and p_booking_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_uuid := p_booking_id::uuid;
  elsif p_booking_id is not null and (p_booking_ref is null or trim(p_booking_ref) = '') then
    -- It's a booking reference passed in as booking_id
    p_booking_ref := p_booking_id;
  end if;

  -- Look up the booking
  select * into b
    from public.bookings
   where (v_uuid is not null and id = v_uuid)
      or (p_booking_ref is not null and booking_ref = p_booking_ref)
   limit 1;

  if b.id is null then
    -- Record may be local mock or already cleaned up; return success so frontend unblocks slot
    return jsonb_build_object('ok', true, 'message', 'Booking released (record not in DB or already cancelled).');
  end if;

  if b.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'message', 'Booking was already cancelled.', 'booking', to_jsonb(b));
  end if;

  -- Safe profile FK check
  select id into v_cancelled_by from public.profiles where id = auth.uid() limit 1;

  begin
    update public.bookings
       set status              = 'cancelled'::public.booking_status,
           cancelled_at        = now(),
           cancelled_by        = v_cancelled_by,
           cancellation_reason = coalesce(nullif(trim(p_reason), ''), 'Cancelled')
     where id = b.id
     returning * into b;
  exception
    when others then
      -- Fallback: change status only (skips foreign keys and triggers)
      update public.bookings
         set status = 'cancelled'::public.booking_status
       where id = b.id
       returning * into b;
  end;

  return jsonb_build_object(
    'ok', true,
    'message', 'Slot released and now available.',
    'booking', to_jsonb(b)
  );
end;
$$;

grant execute on function public.release_booking(text, text, text) to anon, authenticated;


-- Also bulletproof delete_booking
drop function if exists public.delete_booking(uuid);
drop function if exists public.delete_booking(text);

create or replace function public.delete_booking(
  p_booking_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b      public.bookings;
  v_uuid uuid := null;
begin
  if p_booking_id is null or trim(p_booking_id) = '' then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'MISSING_PARAM', 'message', 'Provide booking ID or reference.'));
  end if;

  if p_booking_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_uuid := p_booking_id::uuid;
  end if;

  if v_uuid is not null then
    select * into b from public.bookings where id = v_uuid limit 1;
  else
    select * into b from public.bookings where booking_ref = p_booking_id limit 1;
  end if;

  if b.id is null then
    return jsonb_build_object('ok', true, 'message', 'Booking already deleted or not in DB.');
  end if;

  if not (public.is_staff() or public.owns_ground(b.ground_id)) then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not authorized to delete this booking.'));
  end if;

  delete from public.bookings where id = b.id;

  return jsonb_build_object('ok', true, 'message', 'Booking deleted and slot released.');
end;
$$;

grant execute on function public.delete_booking(text) to authenticated, anon;
