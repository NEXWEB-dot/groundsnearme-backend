import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  MAX_IMAGE_BYTES, assertUploadable, buildKey, publicUrl, toKey,
} from '../src/lib/r2.js';

const env = { R2_PUBLIC_BASE_URL: 'https://images.groundsnearme.pk' };

const upload = (type, length) =>
  new Request('https://api.test/v1/admin/grounds/x/images', {
    method: 'POST',
    headers: {
      ...(type ? { 'content-type': type } : {}),
      ...(length ? { 'content-length': String(length) } : {}),
    },
  });

test('assertUploadable accepts the four formats and maps the extension', () => {
  assert.deepEqual(assertUploadable(upload('image/jpeg')), { type: 'image/jpeg', ext: 'jpg' });
  assert.deepEqual(assertUploadable(upload('image/png')), { type: 'image/png', ext: 'png' });
  assert.deepEqual(assertUploadable(upload('image/webp')), { type: 'image/webp', ext: 'webp' });
  assert.deepEqual(assertUploadable(upload('image/avif')), { type: 'image/avif', ext: 'avif' });
  // Parameters and casing are the browser's business, not ours.
  assert.equal(assertUploadable(upload('IMAGE/JPEG; charset=binary')).ext, 'jpg');
});

test('an unsupported type is 415 before any database round trip', () => {
  for (const type of ['image/gif', 'image/svg+xml', 'application/pdf', 'text/html', '']) {
    assert.throws(() => assertUploadable(upload(type)), (err) => {
      assert.equal(err.code, 'UNSUPPORTED_MEDIA_TYPE');
      assert.equal(err.status, 415);
      return true;
    }, `expected ${type || '(none)'} to be rejected`);
  }
});

test('an oversized upload is 413 on the declared length alone', () => {
  assert.throws(() => assertUploadable(upload('image/webp', MAX_IMAGE_BYTES + 1)), (err) => {
    assert.equal(err.code, 'PAYLOAD_TOO_LARGE');
    assert.equal(err.status, 413);
    return true;
  });
  // Exactly at the limit is allowed, and a missing header is not a rejection —
  // the body length is checked again after buffering.
  assert.equal(assertUploadable(upload('image/webp', MAX_IMAGE_BYTES)).ext, 'webp');
  assert.equal(assertUploadable(upload('image/webp')).ext, 'webp');
});

test('buildKey produces a stable prefix and a collision-free leaf', () => {
  const key = buildKey('grounds', 'Star Indoor Cricket!!', 'webp');
  assert.match(key, /^grounds\/star-indoor-cricket\/\d+-[0-9a-f]+\.webp$/);
  assert.notEqual(key, buildKey('grounds', 'Star Indoor Cricket!!', 'webp'));
  assert.match(buildKey('grounds', '', 'jpg'), /^grounds\/unsorted\//);
});

test('toKey reduces a public URL back to the stored key', () => {
  assert.equal(toKey(env, 'https://images.groundsnearme.pk/grounds/a/1.webp'), 'grounds/a/1.webp');
  assert.equal(toKey(env, 'grounds/a/1.webp'), 'grounds/a/1.webp');
  assert.equal(toKey(env, '/grounds/a/1.webp'), 'grounds/a/1.webp');
  assert.equal(toKey(env, 'https://old-cdn.example/grounds/a/1.webp'), 'grounds/a/1.webp');
  assert.equal(toKey(env, ''), null);
});

test('publicUrl round-trips with toKey and tolerates a trailing slash', () => {
  const key = 'grounds/a/1.webp';
  assert.equal(publicUrl(env, key), `${env.R2_PUBLIC_BASE_URL}/${key}`);
  assert.equal(publicUrl({ R2_PUBLIC_BASE_URL: 'https://x.test/' }, key), `https://x.test/${key}`);
  assert.equal(toKey(env, publicUrl(env, key)), key);
});
