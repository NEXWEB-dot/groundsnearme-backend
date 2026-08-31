/**
 * R2 media handling.
 *
 * Images live in R2 (binding `IMAGES`), never in Supabase Storage: the site is
 * already on Cloudflare Pages + Workers, so same-platform delivery is faster,
 * and Supabase's free-tier storage quota stays reserved for structured data.
 * Supabase remains the source of truth — the R2 *key* is what gets written into
 * grounds.images, and the public URL is composed at read time from
 * R2_PUBLIC_BASE_URL so the CDN host can change without a data migration.
 *
 * Uploads are staff-only (see routes/admin.js). There is no public upload path
 * because grounds are only ever added through the admin view.
 */

import { ApiError } from './http.js';

const ALLOWED = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/avif': 'avif',
};

export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

const rand = () => crypto.randomUUID().split('-')[0];

/** grounds/<slug>/<epoch>-<rand>.<ext> — stable prefix, collision-free leaf. */
export function buildKey(prefix, slug, ext) {
  const safeSlug = String(slug || 'unsorted')
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60) || 'unsorted';
  return `${prefix}/${safeSlug}/${Date.now()}-${rand()}.${ext}`;
}

function bucket(env) {
  if (!env.IMAGES) {
    throw new ApiError('UPSTREAM_ERROR', 'Image storage is not configured for this environment.');
  }
  return env.IMAGES;
}

/**
 * Header-only gate: content-type and declared length. Cheap enough to run
 * before the database round trip, so a wrong file type is rejected without
 * costing a query. Returns the extension the type maps to.
 */
export function assertUploadable(request) {
  const type = (request.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  const ext = ALLOWED[type];
  if (!ext) {
    throw new ApiError(
      'UNSUPPORTED_MEDIA_TYPE',
      'Upload a JPEG, PNG, WebP or AVIF image.',
      { details: { received: type || null, allowed: Object.keys(ALLOWED) } },
    );
  }

  const declared = Number(request.headers.get('content-length') || 0);
  if (declared && declared > MAX_IMAGE_BYTES) {
    throw new ApiError('PAYLOAD_TOO_LARGE', 'Images must be under 8 MB.');
  }

  return { type, ext };
}

/**
 * Accepts a raw binary body (content-type header decides the extension) and
 * returns { key, url, size, content_type }.
 */
export async function putImage(env, request, { slug, prefix = 'grounds' } = {}) {
  const { type, ext } = assertUploadable(request);

  const body = await request.arrayBuffer();
  if (!body.byteLength) {
    throw new ApiError('VALIDATION_ERROR', 'The upload was empty.', { details: { field: 'body' } });
  }
  if (body.byteLength > MAX_IMAGE_BYTES) {
    throw new ApiError('PAYLOAD_TOO_LARGE', 'Images must be under 8 MB.');
  }

  const key = buildKey(prefix, slug, ext);
  await bucket(env).put(key, body, {
    httpMetadata: {
      contentType: type,
      cacheControl: 'public, max-age=31536000, immutable',
    },
  });

  return { key, url: publicUrl(env, key), size: body.byteLength, content_type: type };
}

export function publicUrl(env, key) {
  const base = String(env.R2_PUBLIC_BASE_URL || '').replace(/\/+$/, '');
  return base ? `${base}/${String(key).replace(/^\/+/, '')}` : `/${key}`;
}

/**
 * Deletes by key. A full URL is accepted too and reduced back to its key, so
 * the admin UI can hand over whatever it has on the row.
 */
export async function deleteImage(env, keyOrUrl) {
  const key = toKey(env, keyOrUrl);
  if (!key) throw new ApiError('VALIDATION_ERROR', 'A key is required.', { details: { field: 'key' } });
  await bucket(env).delete(key);
  return { key, deleted: true };
}

export function toKey(env, keyOrUrl) {
  const s = String(keyOrUrl || '').trim();
  if (!s) return null;
  const base = String(env.R2_PUBLIC_BASE_URL || '').replace(/\/+$/, '');
  if (base && s.startsWith(`${base}/`)) return s.slice(base.length + 1);
  if (/^https?:\/\//i.test(s)) {
    try {
      return new URL(s).pathname.replace(/^\/+/, '');
    } catch {
      return null;
    }
  }
  return s.replace(/^\/+/, '');
}
