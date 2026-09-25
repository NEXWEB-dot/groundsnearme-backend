-- ============================================================================
-- GroundsNearMe — Fix Bookings Visibility
-- Creates security-definer RPCs to bypass RLS for legitimate reads:
--   get_ground_bookings      → owner portal / owner dashboard
--   get_all_admin_bookings   → admin dashboard
--   get_my_bookings_by_phone → player my-bookings (lookup by phone)
--   get_booked_slots         → public slot availability (anon safe)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. get_ground_bookings — Owner portal: get all bookings for a ground.
--    Verifies caller is the ground owner OR is staff. Returns full booking data.
-- ----------------------------------------------------------------------------
create or replace function public.get_ground_bookings(
  p_ground_id uuid,
  p_limit     int  default 500
)
returns table (
  id                 uuid,
  booking_ref        text,
  ground_id          uuid,
  player_id          uuid,
  booking_date       date,
  start_time         time,
  end_time           time,
  duration_minutes   int,
  status             text,
  payment_status     text,
  source             text,
  price_per_hour     int,
  total_amount       numeric,
  currency           text,
  commission_rate    numeric,
  commission_amount  numeric,
  contact_name       text,
  contact_phone      text,
  notes              text,
  created_at         timestamptz,
  updated_at         timestamptz,
  cancelled_at       timestamptz,
  cancellation_reason text
)
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
  -- Authorization: caller must own the ground OR be staff
  if not (
    public.is_staff()
    or exists (
      select 1 from public.grounds g
       where g.id = p_ground_id
         and g.owner_id = auth.uid()
    )
    -- also allow superadmin by email even if profile row missing
    or lower(coalesce(auth.jwt()->>'email', '')) in ('faisalshayan444@gmail.com', 'shayan@groundsnearme.pk')
  ) then
    raise exception 'FORBIDDEN: You do not have access to this ground''s bookings.' using errcode = 'PGRST301';
  end if;

  return query
    select
      b.id,
      b.booking_ref::text,
      b.ground_id,
      b.player_id,
      b.booking_date,
      b.start_time,
      b.end_time,
      b.duration_minutes,
      b.status::text,
      b.payment_status::text,
      b.source::text,
      b.price_per_hour,
      b.total_amount,
      b.currency::text,
      b.commission_rate,
      b.commission_amount,
      b.contact_name,
      b.contact_phone,
      b.notes,
      b.created_at,
      b.updated_at,
      b.cancelled_at,
      b.cancellation_reason
    from public.bookings b
   where b.ground_id = p_ground_id
   order by b.booking_date desc, b.start_time asc
   limit least(coalesce(p_limit, 500), 1000);
end;
$$;

grant execute on function public.get_ground_bookings(uuid, int) to authenticated;

-- ----------------------------------------------------------------------------
-- 2. get_all_admin_bookings — Admin dashboard: all bookings across all grounds.
--    Staff/superadmin only. Joins ground name for display.
-- ----------------------------------------------------------------------------
create or replace function public.get_all_admin_bookings(
  p_limit  int  default 200,
  p_offset int  default 0
)
returns table (
  id               uuid,
  booking_ref      text,
  ground_id        uuid,
  ground_name      text,
  ground_slug      text,
  booking_date     date,
  start_time       time,
  end_time         time,
  duration_minutes int,
  status           text,
  payment_status   text,
  source           text,
  total_amount     numeric,
  contact_name     text,
  created_at       timestamptz
)
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
  if not (
    public.is_staff()
    or lower(coalesce(auth.jwt()->>'email', '')) in ('faisalshayan444@gmail.com', 'shayan@groundsnearme.pk')
  ) then
    raise exception 'FORBIDDEN: Staff access required.' using errcode = 'PGRST301';
  end if;

  return query
    select
      b.id,
      b.booking_ref::text,
      b.ground_id,
      g.name::text as ground_name,
      g.slug::text as ground_slug,
      b.booking_date,
      b.start_time,
      b.end_time,
      b.duration_minutes,
      b.status::text,
      b.payment_status::text,
      b.source::text,
      b.total_amount,
      b.contact_name,
      b.created_at
    from public.bookings b
    left join public.grounds g on g.id = b.ground_id
   order by b.booking_date desc, b.start_time asc
   limit  least(coalesce(p_limit, 200), 500)
   offset coalesce(p_offset, 0);
end;
$$;

grant execute on function public.get_all_admin_bookings(int, int) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. get_my_bookings_by_phone — Player: fetch own bookings by phone number.
--    No auth required (anon safe). Requires valid 10+ digit phone to match.
-- ----------------------------------------------------------------------------
create or replace function public.get_my_bookings_by_phone(
  p_phone text
)
returns table (
  id           uuid,
  booking_ref  text,
  ground_id    uuid,
  ground_name  text,
  booking_date date,
  start_time   time,
  end_time     time,
  status       text,
  payment_status text,
  total_amount numeric,
  created_at   timestamptz
)
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_clean_phone text;
begin
  v_clean_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if char_length(v_clean_phone) < 10 then
    raise exception 'INVALID_PHONE: Please provide a valid phone number.' using errcode = '22023';
  end if;

  return query
    select
      b.id,
      b.booking_ref::text,
      b.ground_id,
      g.name::text as ground_name,
      b.booking_date,
      b.start_time,
      b.end_time,
      b.status::text,
      b.payment_status::text,
      b.total_amount,
      b.created_at
    from public.bookings b
    left join public.grounds g on g.id = b.ground_id
   where regexp_replace(coalesce(b.contact_phone, ''), '\D', '', 'g') = v_clean_phone
     and b.booking_date >= current_date - interval '90 days'
   order by b.booking_date desc, b.start_time asc
   limit 50;
end;
$$;

grant execute on function public.get_my_bookings_by_phone(text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. get_booked_slots — Public slot availability (cross-browser, no PII).
--    Already defined in migration 20260922000002, but re-create here in case
--    the Supabase dashboard SQL was never run (404 error was confirmed).
-- ----------------------------------------------------------------------------
create or replace function public.get_booked_slots(
  p_ground_id    uuid,
  p_booking_date date
)
returns table (
  start_time time,
  end_time   time,
  status     text
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
    and b.status::text not in ('cancelled', 'expired')
  order by b.start_time;
$$;

grant execute on function public.get_booked_slots(uuid, date) to anon, authenticated;

-- Reload PostgREST schema cache
notify pgrst, 'reload schema';
