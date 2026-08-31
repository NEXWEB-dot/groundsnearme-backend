/**
 * Bookings.
 *
 * Creation goes through the create_booking RPC rather than a PostgREST insert,
 * because the RPC re-checks the slot against the availability engine and the
 * GiST exclusion constraint inside one transaction. If two players tap the same
 * 7 PM slot at once, exactly one wins and the other gets SLOT_TAKEN (409) —
 * that is a database guarantee, not a Worker one.
 */

import { ApiError, json, unwrapRpc } from '../lib/http.js';
import { requireUser } from '../lib/auth.js';
import { sbRpc, sbMaybeOne, sbSelect } from '../lib/supabase.js';
import { shapeBooking, shapeList } from '../lib/shape.js';
import { clockTime, int, isoDate, oneOf, readJson, str, uuid } from '../lib/validate.js';
import { enforceRateLimit } from '../lib/ratelimit.js';

/** Enough of the ground for a booking card, nothing owner-private. */
const GROUND_EMBED =
  'ground:grounds(id,slug,name,city,address,whatsapp_number,cover_image_url,area:areas(name,slug))';

const BOOKING_COLS = [
  'id', 'booking_ref', 'ground_id', 'booking_date', 'start_time', 'end_time',
  'duration_minutes', 'status', 'payment_status', 'source', 'price_per_hour',
  'total_amount', 'currency', 'contact_name', 'contact_phone', 'players_expected',
  'notes', 'hold_expires_at', 'confirmed_at', 'cancelled_at', 'cancellation_reason',
  'completed_at', 'created_at',
].join(',');

const select = (extra = '') => `bookings?select=${BOOKING_COLS},${GROUND_EMBED}${extra}`;

/** Nested embeds arrive as an object; flatten area onto the ground. */
function flatten(row) {
  if (!row?.ground) return row;
  const { area, cover_image_url, ...rest } = row.ground;
  return {
    ...row,
    ground: {
      ...rest,
      cover_image: cover_image_url,
      area: area?.name || null,
      area_slug: area?.slug || null,
    },
  };
}

export async function createBooking(request, env, { ctx }) {
  requireUser(ctx);
  await enforceRateLimit(request, env, ctx, { bucket: 'booking', limit: 10, windowSeconds: 300 });

  const body = await readJson(request);
  const payload = unwrapRpc(
    await sbRpc(
      env,
      'create_booking',
      {
        p_ground_id:        uuid(body.ground_id, 'ground_id'),
        p_booking_date:     isoDate(body.booking_date ?? body.date, 'booking_date'),
        p_start_time:       clockTime(body.start_time, 'start_time'),
        p_end_time:         clockTime(body.end_time, 'end_time'),
        p_contact_name:     str(body.contact_name, 'contact_name', { required: false, max: 120 }),
        p_contact_phone:    str(body.contact_phone, 'contact_phone', { required: false, max: 24 }),
        p_notes:            str(body.notes, 'notes', { required: false, max: 1000 }),
        p_players_expected: int(body.players_expected, 'players_expected', {
          required: false, min: 1, max: 40,
        }),
        p_hold_minutes:     int(body.hold_minutes, 'hold_minutes', {
          required: false, min: 5, max: 120,
        }) ?? 30,
      },
      { token: ctx.token },
    ),
    'booking',
  );

  return json({ booking: shapeBooking(env, payload) }, { status: 201 });
}

export async function listMyBookings(request, env, { ctx }) {
  const userId = requireUser(ctx);
  const q = new URL(request.url).searchParams;

  const status = oneOf(q.get('status'), 'status', [
    'pending', 'confirmed', 'cancelled', 'completed', 'no_show', 'expired',
  ]);
  const scope = oneOf(q.get('scope'), 'scope', ['upcoming', 'past', 'all'], { fallback: 'all' });
  const limit = int(q.get('limit'), 'limit', { required: false, min: 1, max: 100 }) ?? 50;
  const offset = int(q.get('offset'), 'offset', { required: false, min: 0, max: 100000 }) ?? 0;
  const today = karachiToday();

  let filter = `&player_id=eq.${userId}`;
  if (status) filter += `&status=eq.${status}`;
  if (scope === 'upcoming') filter += `&booking_date=gte.${today}&order=booking_date.asc,start_time.asc`;
  else if (scope === 'past') filter += `&booking_date=lt.${today}&order=booking_date.desc,start_time.desc`;
  else filter += '&order=booking_date.desc,start_time.desc';
  filter += `&limit=${limit}&offset=${offset}`;

  const rows = await sbSelect(env, select(filter), { token: ctx.token });
  return json(
    shapeList({ items: rows || [], total: (rows || []).length, limit, offset }, (r) =>
      shapeBooking(env, flatten(r)),
    ),
  );
}

export async function getBooking(request, env, { ctx, params }) {
  requireUser(ctx);
  const id = uuid(params.id, 'id');
  // RLS decides visibility: the player who booked, the ground's owner, or staff.
  const row = await sbMaybeOne(env, select(`&id=eq.${id}&limit=1`), { token: ctx.token });
  if (!row) throw new ApiError('NOT_FOUND', 'Booking not found.');
  return json({ booking: shapeBooking(env, flatten(row)) });
}

export async function cancelBooking(request, env, { ctx, params }) {
  requireUser(ctx);
  const body = request.headers.get('content-type') ? await readJson(request) : {};
  const payload = unwrapRpc(
    await sbRpc(
      env,
      'cancel_booking',
      {
        p_booking_id: uuid(params.id, 'id'),
        p_reason: str(body.reason, 'reason', { required: false, max: 400 }),
      },
      { token: ctx.token },
    ),
    'booking',
  );
  return json({ booking: shapeBooking(env, payload) });
}

/**
 * Owner/staff status transitions (confirm, complete, no_show). Players get a
 * FORBIDDEN from the RPC — the player guard trigger only lets them cancel.
 */
export async function setBookingStatus(request, env, { ctx, params }) {
  requireUser(ctx);
  const body = await readJson(request);
  const payload = unwrapRpc(
    await sbRpc(
      env,
      'set_booking_status',
      {
        p_booking_id: uuid(params.id, 'id'),
        p_status: oneOf(body.status, 'status',
          ['pending', 'confirmed', 'cancelled', 'completed', 'no_show', 'expired'],
          { required: true }),
        p_reason: str(body.reason, 'reason', { required: false, max: 400 }),
      },
      { token: ctx.token },
    ),
    'booking',
  );
  return json({ booking: shapeBooking(env, payload) });
}

/** Asia/Karachi is UTC+5 year-round (no DST), so a fixed shift is exact. */
export function karachiToday() {
  return new Date(Date.now() + 5 * 3600 * 1000).toISOString().slice(0, 10);
}
