/**
 * Public reads — no auth required.
 *
 * These are the four calls the player-facing site needs to replace its mock
 * data: the area filter list, the directory, one ground, and that ground's slot
 * grid for a date. Each is one round trip; the SQL layer does the joins and the
 * per-ground open-slot count so the browser never has to fan out.
 */

import { cached, unwrapRpc } from '../lib/http.js';
import { sbRpc, sbSelect } from '../lib/supabase.js';
import { shapeGround, shapeGroundDetail, shapeList, shapeSlot } from '../lib/shape.js';
import { int, isoDate, oneOf, str, stringList, bool } from '../lib/validate.js';

const SORTS = ['featured', 'price_asc', 'price_desc', 'rating', 'newest', 'name'];
const TYPES = ['indoor', 'outdoor', 'both'];

export async function health(request, env) {
  return cached(
    {
      ok: true,
      service: 'groundsnearme-api',
      version: '1',
      time: new Date().toISOString(),
      supabase_configured: Boolean(env.SUPABASE_URL && env.SUPABASE_ANON_KEY),
      images_configured: Boolean(env.IMAGES),
    },
    { seconds: 5 },
  );
}

export async function listAreas(request, env) {
  const rows = await sbSelect(
    env,
    'areas?select=id,name,slug,city,sort_order&is_active=eq.true&order=sort_order.asc,name.asc',
  );
  return cached({ items: rows || [], total: (rows || []).length }, { seconds: 600 });
}

export async function listGrounds(request, env) {
  const q = new URL(request.url).searchParams;

  const payload = await sbRpc(env, 'search_grounds', {
    p_city:      str(q.get('city'), 'city', { required: false, max: 60 }) || 'Karachi',
    p_area:      str(q.get('area'), 'area', { required: false, max: 60 }),
    p_date:      isoDate(q.get('date'), 'date', { required: false }),
    p_min_price: int(q.get('min_price'), 'min_price', { required: false, min: 0, max: 1000000 }),
    p_max_price: int(q.get('max_price'), 'max_price', { required: false, min: 0, max: 1000000 }),
    p_type:      oneOf(q.get('type'), 'type', TYPES),
    p_amenities: stringList(q.get('amenities'), 'amenities', { max: 12 }),
    p_q:         str(q.get('q'), 'q', { required: false, max: 80 }),
    p_only_open: bool(q.get('only_open'), 'only_open'),
    p_sort:      oneOf(q.get('sort'), 'sort', SORTS, { fallback: 'featured' }),
    p_limit:     int(q.get('limit'), 'limit', { required: false, min: 1, max: 100 }) ?? 24,
    p_offset:    int(q.get('offset'), 'offset', { required: false, min: 0, max: 100000 }) ?? 0,
  });

  return cached(shapeList(payload, (row) => shapeGround(env, row)), { seconds: 60 });
}

export async function getGround(request, env, { params }) {
  const q = new URL(request.url).searchParams;
  const payload = unwrapRpc(
    await sbRpc(env, 'get_ground', {
      p_ref: str(params.ref, 'ref', { max: 120 }),
      p_date: isoDate(q.get('date'), 'date', { required: false }),
    }),
  );
  return cached(shapeGroundDetail(env, payload), { seconds: 30 });
}

/**
 * The slot grid on its own, for the date-picker on the detail page. Served from
 * get_ground so a stale slug still 404s the same way the detail route does.
 */
export async function getAvailability(request, env, { params }) {
  const q = new URL(request.url).searchParams;
  const payload = unwrapRpc(
    await sbRpc(env, 'get_ground', {
      p_ref: str(params.ref, 'ref', { max: 120 }),
      p_date: isoDate(q.get('date'), 'date', { required: false }),
    }),
  );

  const slots = Array.isArray(payload.slots) ? payload.slots.map(shapeSlot) : [];
  return cached(
    {
      ground: { id: payload.ground?.id, slug: payload.ground?.slug, name: payload.ground?.name },
      date: payload.date,
      slots,
      open_slots: slots.filter((s) => s.is_available).length,
      is_closed: slots.length === 0,
    },
    { seconds: 20 },
  );
}
