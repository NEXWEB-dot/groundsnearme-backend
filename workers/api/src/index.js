/**
 * Worker entry point.
 *
 *   fetch     — the API, behind a CORS allowlist and a JWT check
 *   scheduled — housekeeping every 10 minutes (see crons in wrangler.toml)
 *
 * Auth model, restated because it is the thing most likely to be broken by a
 * later change: browser requests are executed against Supabase with the
 * caller's own access token, so Postgres RLS is the authority on what they can
 * read and write. The role checks in the route handlers exist to fail fast with
 * a friendly message, never as the only gate. The service-role key is used only
 * by the scheduled handler below.
 */

import { buildContext } from './lib/auth.js';
import { preflight, withCommonHeaders } from './lib/cors.js';
import { fail, failFromError, json } from './lib/http.js';
import { sbRpc } from './lib/supabase.js';
import { buildRouter } from './router.js';

const router = buildRouter();

export default {
  async fetch(request, env, workerCtx) {
    const requestId = crypto.randomUUID();
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return preflight(request, env);
    }

    let response;
    try {
      response = await handle(request, env, url, workerCtx);
    } catch (err) {
      if (!(err && err.code)) {
        console.error('unhandled', requestId, err?.stack || String(err));
      }
      response = failFromError(err);
    }

    return withCommonHeaders(response, request, env, requestId);
  },

  /**
   * Housekeeping. Runs with the service-role key because it acts on rows that
   * belong to no one in particular: holds that lapsed, games whose date passed,
   * bookings that finished (which is what accrues commission).
   */
  async scheduled(event, env, workerCtx) {
    workerCtx.waitUntil(housekeeping(env));
  },
};

async function handle(request, env, url, workerCtx) {
  if (url.pathname === '/' || url.pathname === '/v1') {
    return json({
      service: 'groundsnearme-api',
      docs: 'See docs/API-CONTRACT.md',
      health: '/v1/health',
    });
  }

  const match = router.find(request.method, url.pathname);

  if (!match) {
    return fail('NOT_FOUND', `No route for ${request.method} ${url.pathname}`);
  }
  if (match.allowed) {
    return fail('METHOD_NOT_ALLOWED', `Use ${match.allowed.join(', ')} on this path.`, {
      status: 405,
    });
  }

  // Verified locally: a forged or expired token never reaches the database.
  const ctx = await buildContext(request, env);
  return match.handler(request, env, { ctx, params: match.params, workerCtx });
}

export async function housekeeping(env) {
  const jobs = [
    ['expire_stale_bookings', {}],
    ['expire_past_open_games', {}],
    ['complete_finished_bookings', {}],
  ];

  const results = [];
  for (const [fn, args] of jobs) {
    try {
      const out = await sbRpc(env, fn, args, { serviceRole: true });
      results.push({ fn, ok: true, out });
    } catch (err) {
      // One failing job must not stop the others.
      console.error('housekeeping failed', fn, err?.message || String(err));
      results.push({ fn, ok: false, error: err?.message || String(err) });
    }
  }
  console.log('housekeeping', JSON.stringify(results));
  return results;
}
