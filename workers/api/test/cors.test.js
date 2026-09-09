import { test } from 'node:test';
import assert from 'node:assert/strict';

import { corsHeaders, isAllowedOrigin, preflight, withCommonHeaders } from '../src/lib/cors.js';
import { json } from '../src/lib/http.js';

const env = {
  ALLOWED_ORIGINS: 'https://groundsnearme.pk, https://owner.groundsnearme.pk ,http://localhost:5173',
};

const req = (origin, init = {}) =>
  new Request('https://api.groundsnearme.pk/v1/grounds', {
    headers: origin ? { origin } : {},
    ...init,
  });

test('only listed origins are allowed', () => {
  assert.equal(isAllowedOrigin('https://groundsnearme.pk', env), true);
  assert.equal(isAllowedOrigin('https://owner.groundsnearme.pk', env), true);
  assert.equal(isAllowedOrigin('http://localhost:5173', env), true);
  assert.equal(isAllowedOrigin('https://evil.example', env), false);
  assert.equal(isAllowedOrigin(null, env), false);
});

test('a lookalike origin is not allowed', () => {
  assert.equal(isAllowedOrigin('https://groundsnearme.pk.evil.example', env), false);
  assert.equal(isAllowedOrigin('http://groundsnearme.pk', env), false);
});

test('no wildcard is ever emitted', () => {
  const headers = corsHeaders(req('https://groundsnearme.pk'), env);
  assert.equal(headers['access-control-allow-origin'], 'https://groundsnearme.pk');
  assert.notEqual(headers['access-control-allow-origin'], '*');
  assert.equal(headers.vary, 'origin');
});

test('a disallowed origin gets no CORS headers at all', () => {
  assert.deepEqual(corsHeaders(req('https://evil.example'), env), {});
});

test('preflight is 204 for allowed origins and 403 otherwise', () => {
  const ok = preflight(req('https://groundsnearme.pk', { method: 'OPTIONS' }), env);
  assert.equal(ok.status, 204);
  assert.match(ok.headers.get('access-control-allow-methods'), /PATCH/);

  assert.equal(preflight(req('https://evil.example', { method: 'OPTIONS' }), env).status, 403);
});

test('security headers are added to every response', () => {
  const out = withCommonHeaders(json({ ok: true }), req('https://groundsnearme.pk'), env, 'rid-1');
  assert.equal(out.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(out.headers.get('referrer-policy'), 'strict-origin-when-cross-origin');
  assert.equal(out.headers.get('x-request-id'), 'rid-1');
  assert.equal(out.headers.get('access-control-allow-origin'), 'https://groundsnearme.pk');
});

test('an empty allowlist blocks everything rather than defaulting open', () => {
  assert.equal(isAllowedOrigin('https://groundsnearme.pk', {}), false);
  assert.deepEqual(corsHeaders(req('https://groundsnearme.pk'), {}), {});
});
