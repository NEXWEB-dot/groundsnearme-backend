-- ============================================================================
-- GroundsNearMe — 0013 · search_grounds
-- One round trip for the public directory: filters, sort, pagination and the
-- per-ground "slots open today" count in a single call.
--   → {"items":[{...}], "total": 137}
-- ============================================================================

create or replace function public.search_grounds(
  p_city       text    default 'Karachi',
  p_area       text    default null,
  p_date       date    default null,
  p_min_price  int     default null,
  p_max_price  int     default null,
  p_type       text    default null,
  p_amenities  text[]  default null,
  p_q          text    default null,
  p_only_open  boolean default false,
  p_sort       text    default 'featured',
  p_limit      int     default 24,
  p_offset     int     default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_date   date := coalesce(p_date, (now() at time zone 'Asia/Karachi')::date);
  v_limit  int  := least(greatest(coalesce(p_limit, 24), 1), 100);
  v_offset int  := greatest(coalesce(p_offset, 0), 0);
  v_sort   text := coalesce(p_sort, 'featured');
  v_items  jsonb;
  v_total  int;
begin
  if v_sort not in ('featured','price_asc','price_desc','rating','newest','name') then
    v_sort := 'featured';
  end if;

  with base as (
    select g.*, a.name as area_name, a.slug as area_slug
      from public.grounds g
      left join public.areas a on a.id = g.area_id
     where g.status = 'active'
       and (p_city      is null or g.city ilike p_city)
       and (p_area      is null or a.slug = lower(p_area) or a.name ilike p_area)
       and (p_min_price is null or g.price_per_hour >= p_min_price)
       and (p_max_price is null or g.price_per_hour <= p_max_price)
       and (p_type      is null
            or g.ground_type::text = p_type
            or (p_type in ('indoor','outdoor') and g.ground_type = 'both'))
       and (p_amenities is null or array_length(p_amenities, 1) is null
            or g.amenities @> p_amenities)
       and (p_q is null or trim(p_q) = ''
            or g.name ilike '%' || p_q || '%'
            or coalesce(g.address, '') ilike '%' || p_q || '%'
            or coalesce(a.name, '')   ilike '%' || p_q || '%')
  ),
  enriched as (
    select b.*, public.count_open_slots(b.id, v_date) as open_slots
      from base b
  ),
  filtered as (
    select * from enriched
     where not coalesce(p_only_open, false) or open_slots > 0
  ),
  page as (
    select count(*) over () as total_count,
           jsonb_build_object(
             'id',                    f.id,
             'slug',                  f.slug,
             'name',                  f.name,
             'area',                  f.area_name,
             'area_slug',             f.area_slug,
             'city',                  f.city,
             'address',               f.address,
             'lat',                   f.latitude,
             'lng',                   f.longitude,
             'type',                  f.ground_type,
             'surface',               f.surface,
             'price_per_hour',        f.price_per_hour,
             'weekend_price_per_hour',f.weekend_price_per_hour,
             'currency',              f.currency,
             'whatsapp_number',       f.whatsapp_number,
             'amenities',             to_jsonb(f.amenities),
             'images',                f.images,
             'cover_image',           f.cover_image_url,
             'tier',                  f.listing_tier,
             'is_featured',           f.is_featured,
             'rating',                f.rating,
             'review_count',          f.review_count,
             'slot_duration_minutes', f.slot_duration_minutes,
             'min_booking_minutes',   f.min_booking_minutes,
             'max_booking_minutes',   f.max_booking_minutes,
             'advance_booking_days',  f.advance_booking_days,
             'open_slots',            f.open_slots,
             'availability_date',     v_date
           ) as item,
           row_number() over (
             order by
               case when v_sort = 'featured' and f.is_featured then 0 else 1 end,
               case v_sort
                 when 'price_asc'  then  f.price_per_hour::numeric
                 when 'price_desc' then -f.price_per_hour::numeric
                 when 'rating'     then -coalesce(f.rating, 0)
                 else null
               end nulls last,
               case v_sort when 'name'   then f.name      else null end nulls last,
               case v_sort when 'newest' then f.created_at else null end desc nulls last,
               f.featured_rank nulls last,
               f.open_slots desc,
               f.name
           ) as ord
      from filtered f
     order by ord
     limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(p.item order by p.ord), '[]'::jsonb),
         coalesce(max(p.total_count), 0)::int
    into v_items, v_total
    from page p;

  return jsonb_build_object(
    'items',  v_items,
    'total',  v_total,
    'limit',  v_limit,
    'offset', v_offset,
    'date',   v_date
  );
end
$$;

grant execute on function public.search_grounds(
  text, text, date, int, int, text, text[], text, boolean, text, int, int
) to anon, authenticated;
