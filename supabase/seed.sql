-- ============================================================================
-- GroundsNearMe — development seed
-- Mirrors the three grounds already hard-coded in index.html so the frontend
-- gets identical data when it swaps mock arrays for real fetches.
--
--   supabase db reset          (local: applies migrations, then this file)
--   psql "$DB_URL" -f supabase/seed.sql   (remote dev project)
--
-- Safe to re-run. No auth users are created here — sign up through Auth.
-- ============================================================================

insert into public.grounds (
  slug, name, area_id, city, address, ground_type, surface,
  price_per_hour, weekend_price_per_hour, whatsapp_number, contact_name,
  amenities, status, listing_tier, is_featured, featured_rank,
  slot_duration_minutes, rating, review_count, description
)
select
  v.slug, v.name, a.id, 'Karachi', v.address, v.gtype::public.ground_type, v.surface,
  v.price, v.weekend_price, v.wa, v.contact,
  v.amenities, 'active'::public.ground_status, 'free'::public.listing_tier,
  v.featured, v.rank, 60, v.rating, v.reviews, v.descr
from (values
  ('star-indoor-cricket', 'Star Indoor Cricket', 'gulshan-e-iqbal',
   'Block 13-D, Gulshan-e-Iqbal', 'indoor', 'Matting',
   2500, 3000, '920000000001', 'Imran',
   array['Floodlit','Nets','Parking'], true, 1, 4.6, 23,
   'Covered indoor arena with two matting pitches and full floodlighting. Popular for evening T10s.'),
  ('champions-arena', 'Champions Arena', 'dha-defence',
   'Khayaban-e-Rahat, DHA Phase 6', 'indoor', 'Astro turf',
   3200, 3800, '920000000002', 'Bilal',
   array['AC Indoor','Nets','Scorer'], true, 2, 4.8, 41,
   'Air-conditioned indoor ground with a scorer on request. Premium surface, corporate-league regular.'),
  ('kcc-ground-nazimabad', 'KCC Ground Nazimabad', 'nazimabad',
   'Block 3, Nazimabad', 'outdoor', 'Turf',
   1800, 2200, '920000000003', 'Rashid',
   array['Open Air','Floodlit','Dressing Room'], false, null, 4.3, 17,
   'Full-size open-air turf ground with floodlights and a dressing room. Books out fast on weekends.')
) as v(slug, name, area_slug, address, gtype, surface, price, weekend_price,
       wa, contact, amenities, featured, rank, rating, reviews, descr)
left join public.areas a on a.slug = v.area_slug
on conflict (slug) do nothing;

-- Opening hours: 09:00 → 02:00 (closes after midnight) every day.
select public.set_ground_hours_all_days(id, time '09:00', time '02:00')
  from public.grounds
 where slug in ('star-indoor-cricket', 'champions-arena', 'kcc-ground-nazimabad');

-- ---------------------------------------------------------------------------
-- Make KCC read as "Full Today" and put a couple of bookings on the others,
-- so the availability grid and the badges have something to show.
-- ---------------------------------------------------------------------------
do $$
declare
  v_kcc   uuid;
  v_star  uuid;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  s       record;
begin
  select id into v_kcc  from public.grounds where slug = 'kcc-ground-nazimabad';
  select id into v_star from public.grounds where slug = 'star-indoor-cricket';

  if v_kcc is not null then
    for s in
      select a.slot_start, a.slot_end, a.price
        from public.get_ground_availability(v_kcc, v_today) a
       where a.is_available
    loop
      insert into public.bookings (
        booking_ref, ground_id, player_id, booking_date, start_time, end_time,
        duration_minutes, status, source, price_per_hour, total_amount,
        commission_rate, commission_amount, contact_name, notes, confirmed_at
      )
      values (
        public.generate_booking_ref(), v_kcc, null, v_today, s.slot_start, s.slot_end,
        60, 'confirmed', 'whatsapp', 1800, s.price, 0, 0,
        'Seed booking', 'Seeded so this ground reads as Full Today', now()
      )
      on conflict do nothing;
    end loop;
  end if;

  if v_star is not null then
    insert into public.bookings (
      booking_ref, ground_id, player_id, booking_date, start_time, end_time,
      duration_minutes, status, source, price_per_hour, total_amount,
      commission_rate, commission_amount, contact_name, confirmed_at
    )
    values
      (public.generate_booking_ref(), v_star, null, v_today + 1, time '19:00', time '20:00',
       60, 'confirmed', 'whatsapp', 2500, 2500, 0, 0, 'Tariq', now()),
      (public.generate_booking_ref(), v_star, null, v_today + 1, time '20:00', time '21:00',
       60, 'confirmed', 'whatsapp', 2500, 2500, 0, 0, 'Tariq', now())
    on conflict do nothing;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Matchmaking feed (the two cards on the homepage). host_id stays null until
-- real accounts exist; host_handle is what the UI renders.
-- ---------------------------------------------------------------------------
insert into public.open_games (
  host_id, host_handle, title, looking_for, skill_level, format,
  ground_id, area_id, match_date, start_time, players_needed, status
)
select
  null, v.handle, v.title, v.looking::public.looking_for, v.skill::public.skill_level,
  v.format, g.id, a.id,
  (now() at time zone 'Asia/Karachi')::date + v.day_offset, v.start_time, v.needed, 'open'
from (values
  ('captain_tariq', 'Need 3 players — Saturday 7PM, Star Indoor', 'players',
   'intermediate', 'Indoor T10', 'star-indoor-cricket', 'gulshan-e-iqbal', 2, time '19:00', 3),
  ('nazim_eleven', 'Full team looking for opposition — Sunday morning', 'opposition',
   'advanced', 'Hard ball 20 overs', null, 'north-nazimabad', 3, time '08:00', null)
) as v(handle, title, looking, skill, format, ground_slug, area_slug, day_offset, start_time, needed)
left join public.grounds g on g.slug = v.ground_slug
left join public.areas   a on a.slug = v.area_slug
where not exists (
  select 1 from public.open_games og where og.title = v.title
);
