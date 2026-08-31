/**
 * Admin: ground management.
 *
 * This is the only path that creates a ground. There is no public self-serve
 * listing form by design — an owner reaches out on WhatsApp, a team member logs
 * the lead, then enters the details and uploads the photos here.
 *
 * Images are written to R2 and only the *key* is stored on the row, so the
 * public URL is composed at read time and the CDN host can change later without
 * a data migration.
 */

import { ApiError, json } from '../lib/http.js';
import { requireStaff } from '../lib/auth.js';
import { sbInsert, sbMaybeOne, sbPatch, sbSelect } from '../lib/supabase.js';
import { shapeGround, shapeList } from '../lib/shape.js';
import { assertUploadable, deleteImage, putImage, toKey } from '../lib/r2.js';
import {
  bool, int, oneOf, readJson, slugify, str, stringList, uuid, whatsappNumber,
} from '../lib/validate.js';

const ALL_COLS = '*';
const STATUSES = ['draft', 'pending', 'active', 'paused', 'rejected', 'archived'];
const TYPES = ['indoor', 'outdoor', 'both'];

const normalise = (row) =>
  row ? { ...row, cover_image: row.cover_image_url, type: row.ground_type } : row;

export async function listGrounds(request, env, { ctx }) {
  await requireStaff(ctx, env);
  const q = new URL(request.url).searchParams;

  const status = oneOf(q.get('status'), 'status', STATUSES);
  const search = str(q.get('q'), 'q', { required: false, max: 80 });
  const limit = int(q.get('limit'), 'limit', { required: false, min: 1, max: 200 }) ?? 50;
  const offset = int(q.get('offset'), 'offset', { required: false, min: 0, max: 100000 }) ?? 0;

  let path = `grounds?select=${ALL_COLS},area:areas(name,slug)&order=created_at.desc`;
  if (status) path += `&status=eq.${status}`;
  if (search) path += `&name=ilike.*${encodeURIComponent(search)}*`;
  path += `&limit=${limit}&offset=${offset}`;

  const rows = await sbSelect(env, path, { token: ctx.token });
  return json(
    shapeList({ items: rows || [], total: (rows || []).length, limit, offset }, (r) =>
      shapeGround(env, { ...normalise(r), area: r.area?.name || null, area_slug: r.area?.slug || null }),
    ),
  );
}

export async function getGround(request, env, { ctx, params }) {
  await requireStaff(ctx, env);
  const row = await sbMaybeOne(
    env,
    `grounds?select=${ALL_COLS},area:areas(name,slug)&id=eq.${uuid(params.id, 'id')}&limit=1`,
    { token: ctx.token },
  );
  if (!row) throw new ApiError('NOT_FOUND', 'Ground not found.');

  const hours = await sbSelect(
    env,
    `ground_hours?select=day_of_week,opens_at,closes_at,is_closed&ground_id=eq.${row.id}&order=day_of_week.asc`,
    { token: ctx.token },
  );
  return json({
    ground: shapeGround(env, { ...normalise(row), area: row.area?.name || null }),
    hours: hours || [],
  });
}

/** Fields a staff member may set. Slug is derived from the name if omitted. */
function groundFields(body, { creating }) {
  const out = {};
  const put = (key, value) => {
    if (creating || key in body) {
      if (value !== undefined) out[key] = value;
    }
  };

  put('name', str(body.name, 'name', { required: creating, min: 2, max: 160 }));
  put('city', str(body.city, 'city', { required: false, max: 60 }) || (creating ? 'Karachi' : undefined));
  put('area_id', uuid(body.area_id, 'area_id', { required: false }));
  put('owner_id', uuid(body.owner_id, 'owner_id', { required: false }));
  put('address', str(body.address, 'address', { required: false, max: 300 }));
  put('description', str(body.description, 'description', { required: false, max: 4000 }));
  put('ground_type', oneOf(body.ground_type ?? body.type, 'ground_type', TYPES,
    { fallback: creating ? 'outdoor' : undefined }));
  put('surface', str(body.surface, 'surface', { required: false, max: 60 }));
  put('pitch_count', int(body.pitch_count, 'pitch_count', { required: false, min: 1, max: 20 }));
  put('price_per_hour', int(body.price_per_hour, 'price_per_hour',
    { required: creating, min: 100, max: 500000 }));
  put('weekend_price_per_hour', int(body.weekend_price_per_hour, 'weekend_price_per_hour',
    { required: false, min: 100, max: 500000 }));
  put('whatsapp_number', whatsappNumber(body.whatsapp_number, 'whatsapp_number', { required: false }));
  put('phone', str(body.phone, 'phone', { required: false, min: 7, max: 24 }));
  put('contact_name', str(body.contact_name, 'contact_name', { required: false, max: 120 }));
  put('amenities', stringList(body.amenities, 'amenities', { max: 20 }) || (creating ? [] : undefined));
  put('internal_notes', str(body.internal_notes, 'internal_notes', { required: false, max: 4000 }));

  // Commercial levers — staff only. Owners are blocked from these by trigger.
  put('status', oneOf(body.status, 'status', STATUSES, { fallback: creating ? 'pending' : undefined }));
  put('listing_tier', oneOf(body.listing_tier, 'listing_tier', ['free', 'pro'],
    { fallback: creating ? 'free' : undefined }));
  if ('is_featured' in body) out.is_featured = bool(body.is_featured, 'is_featured');
  if ('featured_rank' in body) {
    out.featured_rank = int(body.featured_rank, 'featured_rank', { required: false, min: 1, max: 999 });
  }
  if ('commission_rate' in body) out.commission_rate = commissionRate(body.commission_rate);

  put('slot_duration_minutes', slotDuration(body.slot_duration_minutes));
  put('min_booking_minutes', int(body.min_booking_minutes, 'min_booking_minutes',
    { required: false, min: 30, max: 480 }));
  put('max_booking_minutes', int(body.max_booking_minutes, 'max_booking_minutes',
    { required: false, min: 30, max: 720 }));
  put('advance_booking_days', int(body.advance_booking_days, 'advance_booking_days',
    { required: false, min: 1, max: 365 }));

  return out;
}

function commissionRate(value) {
  if (value === null || value === undefined || value === '') return 0;
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0 || n > 0.5) {
    throw new ApiError('VALIDATION_ERROR', 'Commission rate must be between 0 and 0.5.', {
      details: { field: 'commission_rate' },
    });
  }
  return Math.round(n * 10000) / 10000;
}

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

export { groundFields, normalise, ALL_COLS, STATUSES };

export async function createGround(request, env, { ctx }) {
  await requireStaff(ctx, env);
  const body = await readJson(request);
  const fields = groundFields(body, { creating: true });

  fields.slug = body.slug ? slugify(body.slug, 'slug') : slugify(fields.name, 'name');
  fields.created_by = ctx.userId;

  const rows = await sbInsert(env, `grounds?select=${ALL_COLS}`, fields, { token: ctx.token });
  const created = Array.isArray(rows) ? rows[0] : rows;

  // Default Mon–Sun hours so the ground is bookable the moment it goes active.
  const opens = body.opens_at || '09:00:00';
  const closes = body.closes_at || '02:00:00';
  await sbInsert(
    env,
    'ground_hours?on_conflict=ground_id,day_of_week',
    [0, 1, 2, 3, 4, 5, 6].map((d) => ({
      ground_id: created.id, day_of_week: d, opens_at: opens, closes_at: closes,
    })),
    { token: ctx.token, prefer: 'return=minimal,resolution=merge-duplicates' },
  );

  return json({ ground: shapeGround(env, normalise(created)) }, { status: 201 });
}

export async function updateGround(request, env, { ctx, params }) {
  await requireStaff(ctx, env);
  const id = uuid(params.id, 'id');
  const body = await readJson(request);
  const fields = groundFields(body, { creating: false });
  if (body.slug) fields.slug = slugify(body.slug, 'slug');

  if (!Object.keys(fields).length) {
    throw new ApiError('VALIDATION_ERROR', 'Nothing to update.', { details: { field: 'body' } });
  }

  const rows = await sbPatch(env, `grounds?id=eq.${id}&select=${ALL_COLS}`, fields, {
    token: ctx.token,
  });
  const updated = Array.isArray(rows) ? rows[0] : rows;
  if (!updated) throw new ApiError('NOT_FOUND', 'Ground not found.');
  return json({ ground: shapeGround(env, normalise(updated)) });
}

/**
 * Raw binary upload: the browser PUTs the file bytes with the image's own
 * content-type. No multipart parsing, no base64 inflation — one request per
 * image, which is also what makes a progress bar easy in the admin UI.
 *
 *   POST /v1/admin/grounds/:id/images?alt=Main%20pitch
 */
export async function uploadImage(request, env, { ctx, params }) {
  await requireStaff(ctx, env);
  const id = uuid(params.id, 'id');
  const q = new URL(request.url).searchParams;

  // Reject a wrong file type or an oversized body on the headers alone, before
  // spending a query on the ground lookup.
  assertUploadable(request);

  const ground = await sbMaybeOne(env, `grounds?select=id,slug,images&id=eq.${id}&limit=1`, {
    token: ctx.token,
  });
  if (!ground) throw new ApiError('NOT_FOUND', 'Ground not found.');

  const existing = Array.isArray(ground.images) ? ground.images : [];
  if (existing.length >= 12) {
    throw new ApiError('VALIDATION_ERROR', 'A ground can hold at most 12 images.', {
      details: { field: 'images' },
    });
  }

  const stored = await putImage(env, request, { slug: ground.slug });
  const entry = {
    url: stored.key, // key, not URL — resolved at read time
    alt: str(q.get('alt'), 'alt', { required: false, max: 160 }),
    sort: existing.length,
  };

  const rows = await sbPatch(
    env,
    `grounds?id=eq.${id}&select=id,images,cover_image_url`,
    { images: [...existing, entry] },
    { token: ctx.token },
  );
  const row = Array.isArray(rows) ? rows[0] : rows;

  return json(
    { image: { ...entry, url: stored.url, key: stored.key, size: stored.size },
      images: row?.images || [], cover_image: row?.cover_image_url || null },
    { status: 201 },
  );
}

/** Reorder, retitle, or pick the cover. Keys must already be on the row. */
export async function reorderImages(request, env, { ctx, params }) {
  await requireStaff(ctx, env);
  const id = uuid(params.id, 'id');
  const body = await readJson(request);

  const ground = await sbMaybeOne(env, `grounds?select=id,images&id=eq.${id}&limit=1`, {
    token: ctx.token,
  });
  if (!ground) throw new ApiError('NOT_FOUND', 'Ground not found.');

  const known = new Map(
    (Array.isArray(ground.images) ? ground.images : []).map((img) => [toKey(env, img.url), img]),
  );

  if (!Array.isArray(body.images)) {
    throw new ApiError('VALIDATION_ERROR', 'Send an array of images.', {
      details: { field: 'images' },
    });
  }

  const next = body.images.map((img, i) => {
    const key = toKey(env, img?.key ?? img?.url);
    if (!key || !known.has(key)) {
      throw new ApiError('VALIDATION_ERROR', 'That image is not on this ground.', {
        details: { field: `images[${i}]` },
      });
    }
    return { url: key, alt: img.alt ?? known.get(key).alt ?? null, sort: i };
  });

  const patch = { images: next };
  // Nulling the cover lets the sync trigger re-pick images[0].
  patch.cover_image_url = next.length ? next[0].url : null;

  const rows = await sbPatch(env, `grounds?id=eq.${id}&select=id,images,cover_image_url`, patch, {
    token: ctx.token,
  });
  const row = Array.isArray(rows) ? rows[0] : rows;
  return json({ images: row?.images || [], cover_image: row?.cover_image_url || null });
}

/**
 * Removes the image from the row first, then from R2. That order matters: if the
 * bucket delete fails we are left with an orphaned object (harmless, cheap)
 * rather than a row pointing at a 404.
 */
export async function removeImage(request, env, { ctx, params }) {
  await requireStaff(ctx, env);
  const id = uuid(params.id, 'id');
  const body = await readJson(request);
  const key = toKey(env, body.key ?? body.url);
  if (!key) {
    throw new ApiError('VALIDATION_ERROR', 'Send the image key.', { details: { field: 'key' } });
  }

  const ground = await sbMaybeOne(env, `grounds?select=id,images,cover_image_url&id=eq.${id}&limit=1`, {
    token: ctx.token,
  });
  if (!ground) throw new ApiError('NOT_FOUND', 'Ground not found.');

  const existing = Array.isArray(ground.images) ? ground.images : [];
  const next = existing
    .filter((img) => toKey(env, img.url) !== key)
    .map((img, i) => ({ ...img, sort: i }));

  if (next.length === existing.length) {
    throw new ApiError('NOT_FOUND', 'That image is not on this ground.');
  }

  const coverGone = toKey(env, ground.cover_image_url) === key;
  await sbPatch(
    env,
    `grounds?id=eq.${id}&select=id`,
    { images: next, ...(coverGone ? { cover_image_url: next[0]?.url || null } : {}) },
    { token: ctx.token, prefer: 'return=minimal' },
  );

  await deleteImage(env, key);
  return json({ deleted: true, key, images: next });
}

