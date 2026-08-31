-- ============================================================================
-- GroundsNearMe — 0014 · get_ground (detail page payload)
-- Accepts a slug or a uuid. Returns the ground, its weekly hours, the slot
-- grid for p_date, and upcoming closures — everything the detail page needs.
-- ============================================================================

create or replace function public.get_ground(
  p_ref  text,
  p_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_date  date := coalesce(p_date, (now() at time zone 'Asia/Karachi')::date);
  v_id    uuid;
  v_g     jsonb;
  v_hours jsonb;
  v_slots jsonb;
  v_closed jsonb;
begin
  if p_ref is null or trim(p_ref) = '' then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Ground not found.'));
  end if;

  select g.id into v_id
    from public.grounds g
   where g.status = 'active'
     and (g.slug = lower(trim(p_ref))
          or (p_ref ~ '^[0-9a-fA-F-]{36}$' and g.id = p_ref::uuid))
   limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'NOT_FOUND', 'message', 'Ground not found.'));
  end if;

  select jsonb_build_object(
           'id',                    g.id,
           'slug',                  g.slug,
           'name',                  g.name,
           'area',                  a.name,
           'area_slug',             a.slug,
           'city',                  g.city,
           'address',               g.address,
           'lat',                   g.latitude,
           'lng',                   g.longitude,
           'description',           g.description,
           'type',                  g.ground_type,
           'surface',               g.surface,
           'pitch_count',           g.pitch_count,
           'price_per_hour',        g.price_per_hour,
           'weekend_price_per_hour',g.weekend_price_per_hour,
           'currency',              g.currency,
           'whatsapp_number',       g.whatsapp_number,
           'contact_name',          g.contact_name,
           'amenities',             to_jsonb(g.amenities),
           'images',                g.images,
           'cover_image',           g.cover_image_url,
           'tier',                  g.listing_tier,
           'is_featured',           g.is_featured,
           'rating',                g.rating,
           'review_count',          g.review_count,
           'slot_duration_minutes', g.slot_duration_minutes,
           'min_booking_minutes',   g.min_booking_minutes,
           'max_booking_minutes',   g.max_booking_minutes,
           'advance_booking_days',  g.advance_booking_days
         )
    into v_g
    from public.grounds g
    left join public.areas a on a.id = g.area_id
   where g.id = v_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'day_of_week', h.day_of_week,
           'opens_at',    to_char(h.opens_at,  'HH24:MI'),
           'closes_at',   to_char(h.closes_at, 'HH24:MI'),
           'is_closed',   h.is_closed
         ) order by h.day_of_week), '[]'::jsonb)
    into v_hours
    from public.ground_hours h
   where h.ground_id = v_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'start_time',   to_char(s.slot_start, 'HH24:MI'),
           'end_time',     to_char(s.slot_end,   'HH24:MI'),
           'is_available', s.is_available,
           'reason',       s.reason,
           'price',        s.price
         ) order by s.starts_at), '[]'::jsonb)
    into v_slots
    from public.get_ground_availability(v_id, v_date) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'starts_on', c.starts_on,
           'ends_on',   c.ends_on,
           'reason',    c.reason
         ) order by c.starts_on), '[]'::jsonb)
    into v_closed
    from public.ground_closures c
   where c.ground_id = v_id
     and c.ends_on >= v_date;

  return jsonb_build_object(
    'ok',       true,
    'ground',   v_g,
    'hours',    v_hours,
    'slots',    v_slots,
    'closures', v_closed,
    'date',     v_date
  );
end
$$;

grant execute on function public.get_ground(text, date) to anon, authenticated;
