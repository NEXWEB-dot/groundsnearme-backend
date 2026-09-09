/**
 * Supabase access-token verification, WebCrypto only (no npm dependency).
 *
 * Supports both signing schemes a Supabase project can be on:
 *   • asymmetric (RS256 / ES256) — public keys fetched from the project's
 *     JWKS endpoint and cached in the isolate
 *   • legacy symmetric (HS256)   — verified with SUPABASE_JWT_SECRET
 *
 * Verification is local, so an expired or forged token is rejected before the
 * request costs a round trip to the database.
 */

const JWKS_TTL_MS = 10 * 60 * 1000;
const jwksCache = new Map(); // url → { keys, fetchedAt }

const b64urlToBytes = (s) => {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + pad;
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
};

const bytesToText = (bytes) => new TextDecoder().decode(bytes);

export function decodeJwt(token) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) return null;
  try {
    return {
      header: JSON.parse(bytesToText(b64urlToBytes(parts[0]))),
      payload: JSON.parse(bytesToText(b64urlToBytes(parts[1]))),
      signature: b64urlToBytes(parts[2]),
      signedData: new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    };
  } catch {
    return null;
  }
}

async function fetchJwks(supabaseUrl) {
  const url = `${supabaseUrl.replace(/\/$/, '')}/auth/v1/.well-known/jwks.json`;
  const hit = jwksCache.get(url);
  if (hit && Date.now() - hit.fetchedAt < JWKS_TTL_MS) return hit.keys;

  const res = await fetch(url, { headers: { accept: 'application/json' } });
  if (!res.ok) throw new Error(`jwks fetch failed: ${res.status}`);
  const body = await res.json();
  const keys = Array.isArray(body.keys) ? body.keys : [];
  jwksCache.set(url, { keys, fetchedAt: Date.now() });
  return keys;
}

const ALG_PARAMS = {
  RS256: { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
  ES256: { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' },
};

async function verifyAsymmetric({ header, signature, signedData }, supabaseUrl) {
  const spec = ALG_PARAMS[header.alg];
  if (!spec) return false;

  const keys = await fetchJwks(supabaseUrl);
  const jwk = keys.find((k) => k.kid === header.kid) || keys[0];
  if (!jwk) return false;

  const importParams =
    header.alg === 'ES256'
      ? { name: 'ECDSA', namedCurve: 'P-256' }
      : { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' };

  const key = await crypto.subtle.importKey('jwk', { ...jwk, ext: true }, importParams, false, [
    'verify',
  ]);

  const verifyParams =
    header.alg === 'ES256' ? { name: 'ECDSA', hash: 'SHA-256' } : { name: 'RSASSA-PKCS1-v1_5' };

  return crypto.subtle.verify(verifyParams, key, signature, signedData);
}

async function verifySymmetric({ signature, signedData }, secret) {
  if (!secret) return false;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  );
  return crypto.subtle.verify('HMAC', key, signature, signedData);
}

/**
 * @returns {Promise<object|null>} the claims when the token is valid, else null
 */
export async function verifySupabaseJwt(token, env) {
  const decoded = decodeJwt(token);
  if (!decoded) return null;

  const { header, payload } = decoded;
  const now = Math.floor(Date.now() / 1000);
  const skew = 30;

  if (!payload.sub) return null;
  if (typeof payload.exp === 'number' && payload.exp + skew < now) return null;
  if (typeof payload.nbf === 'number' && payload.nbf - skew > now) return null;

  const expectedIss = `${String(env.SUPABASE_URL || '').replace(/\/$/, '')}/auth/v1`;
  if (payload.iss && payload.iss !== expectedIss) return null;

  let valid = false;
  try {
    if (header.alg === 'HS256') {
      valid = await verifySymmetric(decoded, env.SUPABASE_JWT_SECRET);
    } else {
      valid = await verifyAsymmetric(decoded, env.SUPABASE_URL);
    }
  } catch {
    return null;
  }

  return valid ? payload : null;
}

export function bearerFrom(request) {
  const raw = request.headers.get('authorization') || '';
  const match = /^Bearer\s+(.+)$/i.exec(raw.trim());
  return match ? match[1].trim() : null;
}
