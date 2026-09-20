-- ============================================================================
-- GroundsNearMe — Fix: Slot Release (Idempotent)
-- Run this in Supabase Dashboard → SQL Editor.
-- Ensures release_booking RPC + correct RLS UPDATE/DELETE policies exist.
-- ============================================================================

-- 1. Ensure full table-level privileges so RLS policies can apply
grant select, insert, update, delete on public.bookings to authenticated;
grant select, insert, update, delete on public.bookings to anon;

-- 2. Recreate release_booking RPC (security definer so it bypasses RLS internally)
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
    return jsonb_build_object('ok', true, 'message', 'Already cancelled.',
      'booking', to_jsonb(b));
  end if;

  update public.bookings
     set status             = 'cancelled',
         cancelled_at       = now(),
         cancelled_by       = auth.uid(),
         cancellation_reason = coalesce(nullif(trim(p_reason), ''), 'Cancelled')
   where id = b.id
   returning * into b;

  return jsonb_build_object(
    'ok',      true,
    'message', 'Slot successfully released and reopened.',
    'booking', to_jsonb(b)
  );
end;
$$;

grant execute on function public.release_booking(uuid, text, text)
  to anon, authenticated;

-- 3. Recreate delete_booking RPC (hard delete, staff/owner only)
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
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not authorized to delete this booking.'));
  end if;

  delete from public.bookings where id = p_booking_id;

  return jsonb_build_object('ok', true,
    'message', 'Booking removed and slot released.');
end;
$$;

grant execute on function public.delete_booking(uuid) to authenticated;

-- 4. RLS UPDATE policies for bookings (owner + staff)
drop policy if exists bookings_update_owner on public.bookings;
create policy bookings_update_owner on public.bookings
  for update to authenticated
  using  (public.owns_ground(ground_id))
  with check (public.owns_ground(ground_id));

drop policy if exists bookings_update_staff on public.bookings;
create policy bookings_update_staff on public.bookings
  for update to authenticated
  using  (public.is_staff())
  with check (public.is_staff());

-- 5. RLS DELETE policy for bookings (owner + staff)
drop policy if exists bookings_delete_staff  on public.bookings;
drop policy if exists bookings_delete_owner  on public.bookings;
create policy bookings_delete_staff on public.bookings
  for delete to authenticated
  using (public.is_staff() or public.owns_ground(ground_id));

-- 6. Make sure bookings_select_staff covers anon too (guest lookups use anon key + service role RPC)
drop policy if exists bookings_select_anon on public.bookings;
create policy bookings_select_anon on public.bookings
  for select to anon
  using (false);   -- anon only reads via security-definer RPCs, not direct table

-- Done
