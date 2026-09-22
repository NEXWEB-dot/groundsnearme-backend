-- ============================================================================
-- GroundsNearMe — get_booked_slots RPC
-- Allows anon/guest users to fetch booked slot times for a specific ground+date
-- WITHOUT exposing any PII (name, phone, etc.)
-- This is the ONLY way anon should read booking data (security definer bypasses RLS)
-- ============================================================================

create or replace function public.get_booked_slots(
  p_ground_id   uuid,
  p_booking_date date
)
returns table (
  start_time  time,
  end_time    time,
  status      text
)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select
    b.start_time,
    b.end_time,
    b.status::text
  from public.bookings b
  where b.ground_id    = p_ground_id
    and b.booking_date = p_booking_date
    and b.status not in ('cancelled', 'expired', 'rejected')
  order by b.start_time;
$$;

grant execute on function public.get_booked_slots(uuid, date) to anon, authenticated;

-- Notify PostgREST to reload schema
notify pgrst, 'reload schema';
