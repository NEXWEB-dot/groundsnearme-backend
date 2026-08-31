/**
 * CORS. The public site and both dashboards are separate Cloudflare Pages
 * origins, so the allowlist is config, not a wildcard: `*` would let any site
 * replay a signed-in user's cookies-free bearer requests from their browser.
 */

function allowlist(env) {
  return String(env.ALLOWED_ORIGINS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

export function isAllowedOrigin(origin, env) {
  if (!origin) return false;
  return allowlist(env).includes(origin);
}

export function corsHeaders(request, env) {
  const origin = request.headers.get('origin');
  if (!isAllowedOrigin(origin, env)) return {};
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-credentials': 'false',
    'access-control-expose-headers': 'x-request-id',
    vary: 'origin',
  };
}

export function preflight(request, env) {
  const origin = request.headers.get('origin');
  if (!isAllowedOrigin(origin, env)) {
    return new Response(null, { status: 403 });
  }
  const requested = request.headers.get('access-control-request-headers');
  return new Response(null, {
    status: 204,
    headers: {
      ...corsHeaders(request, env),
      'access-control-allow-methods': 'GET,POST,PATCH,DELETE,OPTIONS',
      'access-control-allow-headers': requested || 'authorization,content-type',
      'access-control-max-age': '86400',
    },
  });
}

/** Copies CORS + security headers onto an already-built response. */
export function withCommonHeaders(response, request, env, requestId) {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(corsHeaders(request, env))) headers.set(k, v);
  headers.set('x-content-type-options', 'nosniff');
  headers.set('referrer-policy', 'strict-origin-when-cross-origin');
  if (requestId) headers.set('x-request-id', requestId);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
