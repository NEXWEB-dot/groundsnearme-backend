/**
 * Minimal Supabase (PostgREST) client for the Worker.
 *
 * Design rule: every request carries the CALLER'S access token, so row-level
 * security in Postgres is the authority on what they can see. The Worker's own
 * role checks are a fast-fail convenience, never the only gate. The
 * service-role key is used in exactly two places — the scheduled housekeeping
 * job and the role lookup — and never on behalf of a browser request.
 */

import { ApiError } from './http.js';

const restBase = (env) => `${String(env.SUPABASE_URL || '').replace(/\/$/, '')}/rest/v1`;

function headers(env, token, extra = {}) {
  const anon = env.SUPABASE_ANON_KEY;
  return {
    apikey: anon,
    authorization: `Bearer ${token || anon}`,
    'content-type': 'application/json',
    accept: 'application/json',
    ...extra,
  };
}

async function send(env, { method, path, token, body, prefer, serviceRole = false }) {
  const key = serviceRole ? env.SUPABASE_SERVICE_ROLE_KEY : env.SUPABASE_ANON_KEY;
  if (!key) throw new ApiError('UPSTREAM_ERROR', 'Supabase credentials are not configured.');

  const extra = prefer ? { prefer } : {};
  const auth = serviceRole
    ? { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json', ...extra }
    : headers(env, token, extra);

  // A fetch that throws is a transport failure — DNS, TLS, connection refused,
  // Supabase down. That is not "something broke on our side", and reporting it
  // as a 500 makes an outage indistinguishable from a Worker bug in the logs.
  let res;
  try {
    res = await fetch(`${restBase(env)}/${path}`, {
      method,
      headers: auth,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (cause) {
    // The reason goes to the log, not to the caller — a transport error message
    // carries hostnames and internal detail the browser has no use for.
    console.error('supabase transport failure', method, path, cause?.message);
    throw new ApiError('UPSTREAM_ERROR', 'The database is unreachable. Try again shortly.', {
      status: 502,
    });
  }

  const text = await res.text();
  const parsed = text ? safeJson(text) : null;

  if (!res.ok) {
    // PostgREST returns { code, message, details, hint }.
    const pg = parsed && typeof parsed === 'object' ? parsed : {};
    if (res.status === 401 || res.status === 403) {
      throw new ApiError('FORBIDDEN', pg.message || 'Not permitted.', { status: res.status });
    }
    if (res.status === 404) {
      throw new ApiError('NOT_FOUND', pg.message || 'Not found.');
    }
    if (pg.code === '23P01') {
      throw new ApiError('SLOT_TAKEN', 'Someone just took this slot. Pick another one.');
    }
    if (pg.code === '23505') {
      throw new ApiError('DUPLICATE', pg.message || 'Already exists.', { status: 409 });
    }
    throw new ApiError('UPSTREAM_ERROR', pg.message || `Database error (${res.status}).`, {
      status: res.status >= 500 ? 502 : 400,
      details: pg.details || undefined,
    });
  }

  return parsed;
}

function safeJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

export const sbSelect = (env, path, opts = {}) =>
  send(env, { method: 'GET', path, ...opts });

export const sbInsert = (env, table, body, opts = {}) =>
  send(env, {
    method: 'POST',
    path: table,
    body,
    prefer: 'return=representation',
    ...opts,
  });

export const sbPatch = (env, path, body, opts = {}) =>
  send(env, {
    method: 'PATCH',
    path,
    body,
    prefer: 'return=representation',
    ...opts,
  });

export const sbDelete = (env, path, opts = {}) =>
  send(env, { method: 'DELETE', path, ...opts });

/** Calls a Postgres function. All of ours return a jsonb envelope. */
export const sbRpc = (env, fn, args = {}, opts = {}) =>
  send(env, { method: 'POST', path: `rpc/${fn}`, body: args, ...opts });

/** Single row or null, without PostgREST's 406 on empty results. */
export async function sbMaybeOne(env, path, opts = {}) {
  const rows = await sbSelect(env, path, opts);
  return Array.isArray(rows) ? rows[0] || null : rows;
}
