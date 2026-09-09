/**
 * HTTP helpers. Every response the API produces goes through here, so the
 * envelope stays identical across routes.
 *
 *   success  →  the payload itself (object or {items,total,...})
 *   failure  →  { error: { code, message, details? } }
 */

/** Postgres/RPC error code → HTTP status. Anything unlisted is a 400. */
export const STATUS_BY_CODE = {
  AUTH_REQUIRED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  GROUND_NOT_FOUND: 404,
  SLOT_TAKEN: 409,
  GAME_CLOSED: 409,
  HOST_CANNOT_JOIN: 409,
  NOT_CANCELLABLE: 409,
  NOT_EDITABLE: 409,
  RETRY: 409,
  PAYLOAD_TOO_LARGE: 413,
  UNSUPPORTED_MEDIA_TYPE: 415,
  RATE_LIMITED: 429,
  METHOD_NOT_ALLOWED: 405,
  INTERNAL_ERROR: 500,
  UPSTREAM_ERROR: 502,
};

export class ApiError extends Error {
  constructor(code, message, { status, details } = {}) {
    super(message || code);
    this.code = code;
    this.status = status || STATUS_BY_CODE[code] || 400;
    this.details = details;
  }
}

export function json(body, { status = 200, headers = {} } = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      ...headers,
    },
  });
}

/** Public, cacheable read. Short TTL: availability changes minute to minute. */
export function cached(body, { seconds = 30, status = 200 } = {}) {
  return json(body, {
    status,
    headers: { 'cache-control': `public, max-age=${seconds}, stale-while-revalidate=60` },
  });
}

export function fail(code, message, { status, details } = {}) {
  const resolved = status || STATUS_BY_CODE[code] || 400;
  const body = { error: { code, message: message || code } };
  if (details !== undefined) body.error.details = details;
  return json(body, { status: resolved });
}

export function failFromError(err) {
  if (err instanceof ApiError) {
    return fail(err.code, err.message, { status: err.status, details: err.details });
  }
  return fail('INTERNAL_ERROR', 'Something broke on our side.', { status: 500 });
}

/**
 * Unwraps the {ok, ...} envelope returned by the SQL RPCs. On failure the
 * error code decides the HTTP status, so `SLOT_TAKEN` becomes a real 409.
 */
export function unwrapRpc(payload, key) {
  if (payload && payload.ok === false) {
    const e = payload.error || {};
    throw new ApiError(e.code || 'RPC_ERROR', e.message, { details: e.details });
  }
  if (!payload) throw new ApiError('UPSTREAM_ERROR', 'Empty response from database.');
  return key ? payload[key] : payload;
}

export function noContent() {
  return new Response(null, { status: 204 });
}
