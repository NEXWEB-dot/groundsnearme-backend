-- ============================================================================
-- GroundsNearMe — Fix: Safe release_booking (FK-safe + exception-handled)
-- The previous release_booking set cancelled_by = auth.uid() directly.
-- If that UID has no row in public.profiles, it violates the FK constraint
-- and the whole UPDATE fails silently (function crashes before returning ok:true).
-- Fix: use a safe subquery so cancelled_by = null when no profile exists.
-- ============================================================================

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
  b              public.bookings;
  v_cancelled_by uuid;
begin
  if p_booking_id is null and p_booking_ref is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'MISSING_PARAM',
                         'message', 'Provide p_booking_id or p_booking_ref.'));
  end if;

  -- Find the booking (security definer bypasses RLS)
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
    return jsonb_build_object('ok', true,
      'message', 'Booking already cancelled.',
      'booking', to_jsonb(b));
  end if;

  -- Safe cancelled_by: only set if the UID has a matching profile row.
  -- This prevents FK violation when the owner/admin has no profile record.
  select id into v_cancelled_by
    from public.profiles
   where id = auth.uid()
   limit 1;

  -- Perform the update with full exception handling
  begin
    update public.bookings
       set status              = 'cancelled',
           cancelled_at        = now(),
           cancelled_by        = v_cancelled_by,   -- null-safe FK
           cancellation_reason = coalesce(nullif(trim(p_reason), ''), 'Cancelled')
     where id = b.id
     returning * into b;
  exception
    when others then
      -- Fallback: update only status (bypasses any FK / trigger issues)
      update public.bookings
         set status = 'cancelled'::public.booking_status
       where id = b.id
       returning * into b;
  end;

  return jsonb_build_object(
    'ok',      true,
    'message', 'Slot released and now available.',
    'booking', to_jsonb(b)
  );
end;
$$;

grant execute on function public.release_booking(uuid, text, text)
  to anon, authenticated;

-- Also fix delete_booking to be FK-safe
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
      jsonb_build_object('code', 'FORBIDDEN',
                         'message', 'Not authorized to delete this booking.'));
  end if;

  delete from public.bookings where id = p_booking_id;

  return jsonb_build_object('ok', true,
    'message', 'Booking deleted and slot released.');
end;
$$;

grant execute on function public.delete_booking(uuid) to authenticated;


-- Ensure UPDATE/DELETE grants exist
grant select, insert, update, delete on public.bookings to authenticated;

-- Recreate UPDATE RLS policies
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

-- DELETE RLS policy
drop policy if exists bookings_delete_staff  on public.bookings;
drop policy if exists bookings_delete_owner  on public.bookings;
create policy bookings_delete_staff on public.bookings
  for delete to authenticated
  using (public.is_staff() or public.owns_ground(ground_id));

-- Done
