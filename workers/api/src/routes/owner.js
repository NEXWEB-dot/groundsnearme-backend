/**
 * Owner dashboard endpoints.
 *
 * Deliberately narrow, matching the launch scope: the owner sees their own
 * ground(s) and listing status, their upcoming bookings and booking history,
 * and their subscription cycles read-only. Owner-facing *analytics* are not in
 * scope for launch, so there is no stats endpoint here.
 *
 * Two things owners cannot do, enforced in the database as well as here:
 * promote their own listing (status / tier / featured / commission columns are
 * blocked by tg_grounds_owner_guard) and mark a subscription cycle paid (they
 * have select but no insert/update on owner_subscriptions).
 */

import { ApiError, json, unwrapRpc } from '../lib/http.js';
import { requireOwner } from '../lib/auth.js';
import { sbDelete, sbInsert, sbMaybeOne, sbPatch, sbRpc, sbSelect } from '../lib/supabase.js';
import { priceLabel, shapeBooking, shapeGround, shapeHours, shapeList } from '../lib/shape.js';
import {
  bool, clockTime, int, isoDate, oneOf, readJson, str, stringList, uuid, whatsappNumber,
} from '../lib/validate.js';
import { karachiToday } from './bookings.js';

/** No internal_notes, no created_by — those are staff columns. */
const GROUND_COLS = [
  'id', 'slug', 'name', 'city', 'address', 'latitude', 'longitude', 'description',
  'ground_type', 'surface', 'pitch_count', 'price_per_hour', 'weekend_price_per_hour',
  'currency', 'whatsapp_number', 'phone', 'contact_name', 'amenities', 'images',
  'cover_image_url', 'status', 'listing_tier', 'is_featured', 'rating', 'review_count',
  'slot_duration_minutes', 'min_booking_minutes', 'max_booking_minutes',
  'advance_booking_days', 'created_at', 'updated_at',
].join(',');

const BOOKING_COLS = [
  'id', 'booking_ref', 'ground_id', 'booking_date', 'start_time', 'end_time',
  'duration_minutes', 'status', 'payment_status', 'source', 'price_per_hour',
  'total_amount', 'currency', 'contact_name', 'contact_phone', 'players_expected',
  'notes', 'hold_expires_at', 'confirmed_at', 'cancelled_at', 'completed_at', 'created_at',
].join(',');

const normalise = (row) => (row ? { ...row, cover_image: row.cover_image_url, type: row.ground_type } : row);

/** The DB check constraint allows exactly these four grid sizes. */
function slotDuration(value) {
  if (value === undefined) return undefined;
  const n = int(value, 'slot_duration_minutes', { min: 30, max: 120 });
  if (![30, 60, 90, 120].includes(n)) {
    throw new ApiError('VALIDATION_ERROR', 'Slot length must be 30, 60, 90 or 120 minutes.', {
      details: { field: 'slot_duration_minutes' },
    });
  }
  return n;
}

export async function myGrounds(request, env, { ctx }) {
  await requireOwner(ctx, env);
  const rows = await sbSelect(
    env,
    `grounds?select=${GROUND_COLS}&owner_id=eq.${ctx.userId}&order=created_at.desc`,
    { token: ctx.token },
  );
  const items = (rows || []).map((r) => shapeGround(env, normalise(r)));
  return json({ items, total: items.length });
}

async function ownedGround(env, ctx, id) {
  const row = await sbMaybeOne(
    env,
    `grounds?select=${GROUND_COLS}&id=eq.${uuid(id, 'id')}&owner_id=eq.${ctx.userId}&limit=1`,
    { token: ctx.token },
  );
  if (!row) throw new ApiError('NOT_FOUND', 'That ground is not on your account.');
  return row;
}

export async function myGround(request, env, { ctx, params }) {
  await requireOwner(ctx, env);
  const row = await ownedGround(env, ctx, params.id);
  const hours = await sbSelect(
    env,
    `ground_hours?select=day_of_week,opens_at,closes_at,is_closed&ground_id=eq.${row.id}&order=day_of_week.asc`,
    { token: ctx.token },
  );
  const closures = await sbSelect(
    env,
    `ground_closures?select=id,starts_on,ends_on,reason&ground_id=eq.${row.id}&ends_on=gte.${karachiToday()}&order=starts_on.asc`,
    { token: ctx.token },
  );
  return json({
    ground: shapeGround(env, normalise(row)),
    hours: (hours || []).map(shapeHours),
    closures: closures || [],
  });
}

/**
 * Operational details only. Anything commercial (status, tier, featured,
 * commission) is absent by design; the trigger would reject it anyway.
 */
export async function updateMyGround(request, env, { ctx, params }) {
  await requireOwner(ctx, env);
  const row = await ownedGround(env, ctx, params.id);
  const body = await readJson(request);
  const patch = {};

  const put = (key, value) => { if (key in body) patch[key] = value; };

  put('description', str(body.description, 'description', { required: false, max: 4000 }));
  put('address', str(body.address, 'address', { required: false, max: 300 }));
  put('surface', str(body.surface, 'surface', { required: false, max: 60 }));
  put('contact_name', str(body.contact_name, 'contact_name', { required: false, max: 120 }));
  put('phone', str(body.phone, 'phone', { required: false, min: 7, max: 24 }));
  put('whatsapp_number', whatsappNumber(body.whatsapp_number, 'whatsapp_number', { required: false }));
  put('pitch_count', int(body.pitch_count, 'pitch_count', { required: false, min: 1, max: 20 }));
  put('price_per_hour', int(body.price_per_hour, 'price_per_hour', { required: false, min: 100, max: 500000 }));
  put('weekend_price_per_hour', int(body.weekend_price_per_hour, 'weekend_price_per_hour', {
    required: false, min: 100, max: 500000,
  }));
  put('amenities', stringList(body.amenities, 'amenities', { max: 20 }) || []);
  put('slot_duration_minutes', slotDuration(body.slot_duration_minutes));
  put('min_booking_minutes', int(body.min_booking_minutes, 'min_booking_minutes', {
    required: false, min: 30, max: 480,
  }));
  put('max_booking_minutes', int(body.max_booking_minutes, 'max_booking_minutes', {
    required: false, min: 30, max: 720,
  }));
  put('advance_booking_days', int(body.advance_booking_days, 'advance_booking_days', {
    required: false, min: 1, max: 365,
  }));

  for (const k of Object.keys(patch)) if (patch[k] === undefined) delete patch[k];
  if (!Object.keys(patch).length) {
    throw new ApiError('VALIDATION_ERROR', 'Nothing to update.', { details: { field: 'body' } });
  }

  const rows = await sbPatch(env, `grounds?id=eq.${row.id}&select=${GROUND_COLS}`, patch, {
    token: ctx.token,
  });
  const updated = Array.isArray(rows) ? rows[0] : rows;
  return json({ ground: shapeGround(env, normalise(updated)) });
}

/** Replaces the whole week in one upsert so the grid can never half-save. */
export async function setMyHours(request, env, { ctx, params }) {
  await requireOwner(ctx, env);
  const row = await ownedGround(env, ctx, params.id);
  const body = await readJson(request);

  if (!Array.isArray(body.hours) || !body.hours.length) {
    throw new ApiError('VALIDATION_ERROR', 'Send an array of hours.', { details: { field: 'hours' } });
  }
  if (body.hours.length > 7) {
    throw new ApiError('VALIDATION_ERROR', 'At most seven days.', { details: { field: 'hours' } });
  }

  const seen = new Set();
  const rows = body.hours.map((h, i) => {
    const dow = int(h?.day_of_week, `hours[${i}].day_of_week`, { min: 0, max: 6 });
    if (seen.has(dow)) {
      throw new ApiError('VALIDATION_ERROR', `Day ${dow} is listed twice.`, {
        details: { field: `hours[${i}].day_of_week` },
      });
    }
    seen.add(dow);
    const closed = bool(h?.is_closed, `hours[${i}].is_closed`);
    return {
      ground_id: row.id,
      day_of_week: dow,
      // A closed day still needs times to satisfy NOT NULL; they are ignored.
      opens_at: clockTime(h?.opens_at ?? (closed ? '00:00' : undefined), `hours[${i}].opens_at`),
      closes_at: clockTime(h?.closes_at ?? (closed ? '00:00' : undefined), `hours[${i}].closes_at`),
      is_closed: closed,
    };
  });

  const saved = await sbInsert(
    env,
    'ground_hours?on_conflict=ground_id,day_of_week&select=day_of_week,opens_at,closes_at,is_closed',
    rows,
    { token: ctx.token, prefer: 'return=representation,resolution=merge-duplicates' },
  );
  return json({ hours: (saved || []).map(shapeHours) });
}

export async function addMyClosure(request, env, { ctx, params }) {
  await requireOwner(ctx, env);
  const row = await ownedGround(env, ctx, params.id);
  const body = await readJson(request);

  const starts = isoDate(body.starts_on, 'starts_on');
  const ends = isoDate(body.ends_on ?? body.starts_on, 'ends_on');
  if (ends < starts) {
    throw new ApiError('VALIDATION_ERROR', 'ends_on cannot be before starts_on.', {
      details: { field: 'ends_on' },
    });
  }

  const saved = await sbInsert(
    env,
    'ground_closures?select=id,starts_on,ends_on,reason',
    {
      ground_id: row.id,
      starts_on: starts,
      ends_on: ends,
      reason: str(body.reason, 'reason', { required: false, max: 200 }),
      created_by: ctx.userId,
    },
    { token: ctx.token },
  );
  return json({ closure: Array.isArray(saved) ? saved[0] : saved }, { status: 201 });
}

export async function deleteMyClosure(request, env, { ctx, params }) {
  await requireOwner(ctx, env);
  await ownedGround(env, ctx, params.id);
  await sbDelete(
    env,
    `ground_closures?id=eq.${uuid(params.closureId, 'closureId')}&ground_id=eq.${params.id}`,
    { token: ctx.token },
  );
  return json({ deleted: true });
}

export async function myBookings(request, env, { ctx }) {
  await requireOwner(ctx, env);
  const q = new URL(request.url).searchParams;

  const scope = oneOf(q.get('scope'), 'scope', ['upcoming', 'past', 'all'], { fallback: 'upcoming' });
  const status = oneOf(q.get('status'), 'status',
    ['pending', 'confirmed', 'cancelled', 'completed', 'no_show', 'expired']);
  const groundId = uuid(q.get('ground_id'), 'ground_id', { required: false });
  const limit = int(q.get('limit'), 'limit', { required: false, min: 1, max: 100 }) ?? 50;
  const offset = int(q.get('offset'), 'offset', { required: false, min: 0, max: 100000 }) ?? 0;
  const today = karachiToday();

  // RLS already restricts these rows to grounds this owner owns.
  let path = `bookings?select=${BOOKING_COLS},ground:grounds!inner(id,slug,name,cover_image_url,whatsapp_number)`;
  if (groundId) path += `&ground_id=eq.${groundId}`;
  if (status) path += `&status=eq.${status}`;
  if (scope === 'upcoming') path += `&booking_date=gte.${today}&order=booking_date.asc,start_time.asc`;
  else if (scope === 'past') path += `&booking_date=lt.${today}&order=booking_date.desc,start_time.desc`;
  else path += '&order=booking_date.desc,start_time.desc';
  path += `&limit=${limit}&offset=${offset}`;

  const rows = await sbSelect(env, path, { token: ctx.token });
  return json(
    shapeList({ items: rows || [], total: (rows || []).length, limit, offset }, (r) =>
      shapeBooking(env, { ...r, ground: r.ground ? { ...r.ground, cover_image: r.ground.cover_image_url } : null }),
    ),
  );
}

/**
 * Walk-in and WhatsApp bookings the owner took offline. Skips opening-hours
 * checks on purpose — the owner knows their own exceptions — but the exclusion
 * constraint still stops it colliding with a web booking.
 */
export async function createManualBooking(request, env, { ctx }) {
  await requireOwner(ctx, env);
  const body = await readJson(request);

  const payload = unwrapRpc(
    await sbRpc(
      env,
      'create_manual_booking',
      {
        p_ground_id:     uuid(body.ground_id, 'ground_id'),
        p_booking_date:  isoDate(body.booking_date ?? body.date, 'booking_date'),
        p_start_time:    clockTime(body.start_time, 'start_time'),
        p_end_time:      clockTime(body.end_time, 'end_time'),
        p_contact_name:  str(body.contact_name, 'contact_name', { required: false, max: 120 }),
        p_contact_phone: str(body.contact_phone, 'contact_phone', { required: false, max: 24 }),
        p_notes:         str(body.notes, 'notes', { required: false, max: 1000 }),
        p_source:        oneOf(body.source, 'source', ['whatsapp', 'admin', 'owner', 'web'],
          { fallback: 'whatsapp' }),
        p_confirmed:     bool(body.confirmed, 'confirmed', { fallback: true }),
      },
      { token: ctx.token },
    ),
    'booking',
  );
  return json({ booking: shapeBooking(env, payload) }, { status: 201 });
}

/**
 * Read-only. Marking a cycle paid is staff work — the owner pays by JazzCash,
 * EasyPaisa or bank transfer against `payment_link` and the team flips it.
 */
export async function mySubscriptions(request, env, { ctx }) {
  await requireOwner(ctx, env);
  const rows = await sbSelect(
    env,
    'owner_subscriptions?select=id,ground_id,tier,cycle_start,cycle_end,amount,currency,status,payment_method,payment_link,invoice_ref,paid_at' +
      `&owner_id=eq.${ctx.userId}&order=cycle_start.desc&limit=36`,
    { token: ctx.token },
  );
  const items = (rows || []).map((r) => ({
    ...r,
    amount_label: priceLabel(r.amount, r.currency),
    is_paid: r.status === 'paid' || r.status === 'waived',
  }));
  return json({ items, total: items.length, unpaid: items.filter((i) => !i.is_paid).length });
}
