/**
 * The signed-in user's own profile.
 *
 * `role` is returned so the dashboards can pick a landing page, but it is not
 * writable here — role changes are gated to superadmin by a trigger, and this
 * route does not even forward the field.
 */

import { ApiError, json } from '../lib/http.js';
import { requireUser, roleOf } from '../lib/auth.js';
import { sbMaybeOne, sbPatch } from '../lib/supabase.js';
import { readJson, str, whatsappNumber } from '../lib/validate.js';

const COLS = 'id,role,full_name,handle,email,phone,whatsapp_number,city,avatar_url,is_active,created_at';

export async function getMe(request, env, { ctx }) {
  const userId = requireUser(ctx);
  const profile = await sbMaybeOne(env, `profiles?select=${COLS}&id=eq.${userId}&limit=1`, {
    token: ctx.token,
  });
  if (!profile) throw new ApiError('NOT_FOUND', 'Profile not found.');

  return json({
    user: {
      ...profile,
      handle: profile.handle ? `@${profile.handle}` : null,
      role: await roleOf(ctx, env),
    },
  });
}

export async function updateMe(request, env, { ctx }) {
  const userId = requireUser(ctx);
  const body = await readJson(request);

  const patch = {};
  if ('full_name' in body) patch.full_name = str(body.full_name, 'full_name', { required: false, max: 120 });
  if ('handle' in body) patch.handle = handle(body.handle);
  if ('phone' in body) patch.phone = str(body.phone, 'phone', { required: false, min: 7, max: 24 });
  if ('whatsapp_number' in body) {
    patch.whatsapp_number = whatsappNumber(body.whatsapp_number, 'whatsapp_number', { required: false });
  }
  if ('city' in body) patch.city = str(body.city, 'city', { required: false, max: 60 }) || 'Karachi';

  if (!Object.keys(patch).length) {
    throw new ApiError('VALIDATION_ERROR', 'Nothing to update.', { details: { field: 'body' } });
  }

  const rows = await sbPatch(env, `profiles?id=eq.${userId}&select=${COLS}`, patch, {
    token: ctx.token,
  });
  const updated = Array.isArray(rows) ? rows[0] : rows;
  return json({ user: { ...updated, handle: updated?.handle ? `@${updated.handle}` : null } });
}

/** Stored bare; rendered with the @ prefix. Matches the DB check constraint. */
function handle(value) {
  if (value === null || value === undefined || value === '') return null;
  const clean = String(value).trim().replace(/^@/, '').toLowerCase();
  if (!/^[a-z0-9_]{3,24}$/.test(clean)) {
    throw new ApiError(
      'VALIDATION_ERROR',
      'Handle must be 3–24 characters: letters, numbers or underscore.',
      { details: { field: 'handle' } },
    );
  }
  return clean;
}
