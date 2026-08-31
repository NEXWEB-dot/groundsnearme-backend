import { test } from 'node:test';
import assert from 'node:assert/strict';

import { Router, compile, matchSegments } from '../src/lib/router.js';

test('compile splits literals and params', () => {
  assert.deepEqual(compile('/v1/grounds/:ref/availability'), [
    { literal: 'v1' },
    { literal: 'grounds' },
    { param: 'ref' },
    { literal: 'availability' },
  ]);
});

test('matchSegments requires an exact segment count', () => {
  const c = compile('/v1/grounds/:ref');
  assert.deepEqual(matchSegments(c, ['v1', 'grounds', 'star-indoor']), { ref: 'star-indoor' });
  assert.equal(matchSegments(c, ['v1', 'grounds']), null);
  assert.equal(matchSegments(c, ['v1', 'grounds', 'a', 'b']), null);
});

test('params are percent-decoded', () => {
  const c = compile('/v1/areas/:name');
  assert.deepEqual(matchSegments(c, ['v1', 'areas', 'DHA%20Phase%206']), { name: 'DHA Phase 6' });
});

test('a malformed escape does not match rather than throwing', () => {
  const c = compile('/v1/areas/:name');
  assert.equal(matchSegments(c, ['v1', 'areas', '%E0%A4%A']), null);
});

test('literal routes win over params when registered first', () => {
  const r = new Router()
    .get('/v1/bookings/mine', () => 'mine')
    .get('/v1/bookings/:id', () => 'one');

  assert.equal(r.find('GET', '/v1/bookings/mine').handler(), 'mine');

  const single = r.find('GET', '/v1/bookings/7f1e');
  assert.equal(single.handler(), 'one');
  assert.deepEqual(single.params, { id: '7f1e' });
});

test('a known path with the wrong method reports the allowed set', () => {
  const r = new Router()
    .get('/v1/me', () => 'get')
    .patch('/v1/me', () => 'patch');

  assert.deepEqual(r.find('DELETE', '/v1/me'), { allowed: ['GET', 'PATCH'] });
});

test('an unknown path returns null', () => {
  const r = new Router().get('/v1/me', () => 'get');
  assert.equal(r.find('GET', '/v1/nope'), null);
});

test('trailing and duplicate slashes are ignored', () => {
  const r = new Router().get('/v1/health', () => 'ok');
  assert.equal(r.find('GET', '/v1/health/').handler(), 'ok');
  assert.equal(r.find('GET', '//v1//health').handler(), 'ok');
});

test('method matching is case-insensitive', () => {
  const r = new Router().add('get', '/v1/health', () => 'ok');
  assert.equal(r.find('GET', '/v1/health').handler(), 'ok');
});
