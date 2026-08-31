import { test } from 'node:test';
import assert from 'node:assert/strict';

import { ApiError, fail, failFromError, json, unwrapRpc } from '../src/lib/http.js';

test('error codes map to the HTTP status the frontend branches on', () => {
  assert.equal(new ApiError('AUTH_REQUIRED', 'x').status, 401);
  assert.equal(new ApiError('FORBIDDEN', 'x').status, 403);
  assert.equal(new ApiError('NOT_FOUND', 'x').status, 404);
  assert.equal(new ApiError('SLOT_TAKEN', 'x').status, 409);
  assert.equal(new ApiError('RATE_LIMITED', 'x').status, 429);
  assert.equal(new ApiError('UPSTREAM_ERROR', 'x').status, 502);
  assert.equal(new ApiError('VALIDATION_ERROR', 'x').status, 400);
  assert.equal(new ApiError('SOMETHING_NEW', 'x').status, 400);
});

test('an explicit status wins over the map', () => {
  assert.equal(new ApiError('DUPLICATE', 'x', { status: 409 }).status, 409);
});

test('fail writes the { error: { code, message } } envelope', async () => {
  const res = fail('SLOT_TAKEN', 'Someone just took this slot. Pick another one.');
  assert.equal(res.status, 409);
  assert.equal(res.headers.get('content-type'), 'application/json; charset=utf-8');
  assert.deepEqual(await res.json(), {
    error: { code: 'SLOT_TAKEN', message: 'Someone just took this slot. Pick another one.' },
  });
});

test('details ride along when present', async () => {
  const res = fail('VALIDATION_ERROR', 'bad', { details: { field: 'start_time' } });
  const body = await res.json();
  assert.deepEqual(body.error.details, { field: 'start_time' });
});

test('an unknown throwable becomes a 500 with no internals leaked', async () => {
  const res = failFromError(new TypeError('cannot read property foo of undefined'));
  assert.equal(res.status, 500);
  const body = await res.json();
  assert.equal(body.error.code, 'INTERNAL_ERROR');
  assert.match(body.error.message, /our side/);
  assert.equal(body.error.message.includes('property foo'), false);
});

test('successful responses are never cached by accident', () => {
  assert.equal(json({ ok: true }).headers.get('cache-control'), 'no-store');
});

test('unwrapRpc turns a failed envelope into the right ApiError', () => {
  assert.throws(
    () => unwrapRpc({ ok: false, error: { code: 'SLOT_TAKEN', message: 'gone' } }),
    (err) => {
      assert.equal(err.code, 'SLOT_TAKEN');
      assert.equal(err.status, 409);
      assert.equal(err.message, 'gone');
      return true;
    },
  );
});

test('unwrapRpc returns the requested key on success', () => {
  const booking = { id: 'b1', booking_ref: 'GNM-2608-ABC123' };
  assert.deepEqual(unwrapRpc({ ok: true, booking }, 'booking'), booking);
  assert.deepEqual(unwrapRpc({ ok: true, booking }).booking, booking);
});

test('an empty RPC response is an upstream error, not a silent null', () => {
  assert.throws(() => unwrapRpc(null), (err) => {
    assert.equal(err.code, 'UPSTREAM_ERROR');
    assert.equal(err.status, 502);
    return true;
  });
});
