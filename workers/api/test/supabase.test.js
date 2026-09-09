import { test } from 'node:test';
import assert from 'node:assert/strict';

import { sbRpc, sbSelect } from '../src/lib/supabase.js';

const env = {
  SUPABASE_URL: 'https://project.supabase.co',
  SUPABASE_ANON_KEY: 'anon-key',
};

/** Swaps global fetch for the call, then restores it. */
async function withFetch(impl, fn) {
  const original = globalThis.fetch;
  globalThis.fetch = impl;
  try {
    return await fn();
  } finally {
    globalThis.fetch = original;
  }
}

const jsonResponse = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

test('a transport failure is a 502, not a 500', async () => {
  await withFetch(
    () => Promise.reject(new TypeError('getaddrinfo ENOTFOUND project.supabase.co')),
    async () => {
      await assert.rejects(sbSelect(env, 'grounds?select=id'), (err) => {
        assert.equal(err.code, 'UPSTREAM_ERROR');
        assert.equal(err.status, 502);
        // The hostname stays in the log, not in the body the browser sees.
        assert.doesNotMatch(err.message, /ENOTFOUND|supabase\.co/);
        return true;
      });
    },
  );
});

test('missing credentials fail before a request is attempted', async () => {
  let called = false;
  await withFetch(
    () => { called = true; return Promise.resolve(jsonResponse([])); },
    async () => {
      await assert.rejects(sbSelect({ SUPABASE_URL: env.SUPABASE_URL }, 'grounds?select=id'), (err) => {
        assert.equal(err.code, 'UPSTREAM_ERROR');
        return true;
      });
    },
  );
  assert.equal(called, false);
});

test('the caller token is what goes to PostgREST, not the anon key', async () => {
  let seen = null;
  await withFetch(
    (url, init) => { seen = { url: String(url), headers: init.headers }; return Promise.resolve(jsonResponse([])); },
    () => sbSelect(env, 'grounds?select=id', { token: 'caller-jwt' }),
  );
  assert.equal(seen.url, 'https://project.supabase.co/rest/v1/grounds?select=id');
  assert.equal(seen.headers.authorization, 'Bearer caller-jwt');
  assert.equal(seen.headers.apikey, 'anon-key');
});

test('an exclusion-constraint violation becomes SLOT_TAKEN 409', async () => {
  await withFetch(
    () => Promise.resolve(jsonResponse({ code: '23P01', message: 'conflicting key value' }, 409)),
    async () => {
      await assert.rejects(sbRpc(env, 'create_booking', {}), (err) => {
        assert.equal(err.code, 'SLOT_TAKEN');
        assert.equal(err.status, 409);
        return true;
      });
    },
  );
});

test('an RLS refusal keeps its status rather than becoming a 400', async () => {
  for (const status of [401, 403]) {
    await withFetch(
      () => Promise.resolve(jsonResponse({ message: 'permission denied for table grounds' }, status)),
      async () => {
        await assert.rejects(sbSelect(env, 'grounds?select=id'), (err) => {
          assert.equal(err.code, 'FORBIDDEN');
          assert.equal(err.status, status);
          return true;
        });
      },
    );
  }
});

test('a database 5xx is surfaced as 502 and a 4xx as 400', async () => {
  await withFetch(
    () => Promise.resolve(jsonResponse({ message: 'boom' }, 503)),
    async () => {
      await assert.rejects(sbSelect(env, 'grounds?select=id'), (err) => {
        assert.equal(err.status, 502);
        return true;
      });
    },
  );
  await withFetch(
    () => Promise.resolve(jsonResponse({ message: 'bad filter' }, 400)),
    async () => {
      await assert.rejects(sbSelect(env, 'grounds?select=id'), (err) => {
        assert.equal(err.status, 400);
        return true;
      });
    },
  );
});
