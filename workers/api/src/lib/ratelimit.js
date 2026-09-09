/**
 * Fixed-window rate limiting, KV-optional.
 *
 * The RATE_LIMIT KV namespace is commented out in wrangler.toml, so on a fresh
 * checkout this module is a no-op and nothing breaks. Bind the namespace and
 * every guarded route starts enforcing without a code change.
 *
 * Fixed windows are cheap and coarse: a caller can burst at a window boundary.
 * That is an acceptable trade for write-abuse protection on a Karachi launch;
 * the real double-booking guarantee lives in the database exclusion constraint,
 * not here.
 */

import { ApiError } from './http.js';

const clientKey = (request, ctx) =>
  ctx?.userId || request.headers.get('cf-connecting-ip') || 'anonymous';

/**
 * @returns {Promise<{limited: boolean, remaining: number}>}
 */
export async function rateLimit(request, env, ctx, { bucket, limit = 20, windowSeconds = 60 } = {}) {
  const kv = env.RATE_LIMIT;
  if (!kv) return { limited: false, remaining: limit };

  const window = Math.floor(Date.now() / 1000 / windowSeconds);
  const key = `rl:${bucket}:${clientKey(request, ctx)}:${window}`;

  let count = 0;
  try {
    count = Number((await kv.get(key)) || 0);
  } catch {
    return { limited: false, remaining: limit }; // never fail a request on KV trouble
  }

  if (count >= limit) return { limited: true, remaining: 0 };

  try {
    await kv.put(key, String(count + 1), { expirationTtl: Math.max(windowSeconds, 60) });
  } catch {
    /* best effort */
  }
  return { limited: false, remaining: Math.max(limit - count - 1, 0) };
}

/** Throws RATE_LIMITED (429) instead of returning a flag. */
export async function enforceRateLimit(request, env, ctx, opts) {
  const { limited } = await rateLimit(request, env, ctx, opts);
  if (limited) {
    throw new ApiError('RATE_LIMITED', 'Too many requests. Wait a minute and try again.');
  }
}
