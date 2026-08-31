/**
 * Input validation. Every value that reaches SQL passes through here first, so
 * shape errors come back as a clean 400 with the offending field named rather
 * than as a Postgres constraint message.
 */

import { ApiError } from './http.js';

const bad = (field, message) =>
  new ApiError('VALIDATION_ERROR', message, { details: { field } });

export async function readJson(request, { maxBytes = 64 * 1024 } = {}) {
  const type = request.headers.get('content-type') || '';
  if (!type.includes('application/json')) {
    throw new ApiError('UNSUPPORTED_MEDIA_TYPE', 'Send application/json.');
  }
  const text = await request.text();
  if (text.length > maxBytes) {
    throw new ApiError('PAYLOAD_TOO_LARGE', 'Request body is too large.');
  }
  if (!text.trim()) return {};
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw bad('body', 'Body must be a JSON object.');
    }
    return parsed;
  } catch (err) {
    if (err instanceof ApiError) throw err;
    throw bad('body', 'Body is not valid JSON.');
  }
}

export function str(value, field, { min = 1, max = 500, required = true, trim = true } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw bad(field, `${field} is required.`);
    return null;
  }
  if (typeof value !== 'string') throw bad(field, `${field} must be text.`);
  const out = trim ? value.trim() : value;
  if (out.length < min) throw bad(field, `${field} must be at least ${min} characters.`);
  if (out.length > max) throw bad(field, `${field} must be at most ${max} characters.`);
  return out;
}

export function int(value, field, { min = -2147483648, max = 2147483647, required = true } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw bad(field, `${field} is required.`);
    return null;
  }
  const n = typeof value === 'number' ? value : Number(String(value).trim());
  if (!Number.isFinite(n) || !Number.isInteger(n)) throw bad(field, `${field} must be a whole number.`);
  if (n < min || n > max) throw bad(field, `${field} must be between ${min} and ${max}.`);
  return n;
}

export function bool(value, field, { required = false, fallback = false } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw bad(field, `${field} is required.`);
    return fallback;
  }
  if (typeof value === 'boolean') return value;
  const s = String(value).toLowerCase();
  if (['true', '1', 'yes'].includes(s)) return true;
  if (['false', '0', 'no'].includes(s)) return false;
  throw bad(field, `${field} must be true or false.`);
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
export function isoDate(value, field, { required = true } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw bad(field, `${field} is required.`);
    return null;
  }
  const s = String(value).trim();
  if (!DATE_RE.test(s)) throw bad(field, `${field} must be YYYY-MM-DD.`);
  const d = new Date(`${s}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || !d.toISOString().startsWith(s)) {
    throw bad(field, `${field} is not a real date.`);
  }
  return s;
}

const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)(:[0-5]\d)?$/;
export function clockTime(value, field, { required = true } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw bad(field, `${field} is required.`);
    return null;
  }
  const s = String(value).trim();
  if (!TIME_RE.test(s)) throw bad(field, `${field} must be HH:MM (24-hour).`);
  return s.length === 5 ? `${s}:00` : s;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function uuid(value, field, { required = true } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw bad(field, `${field} is required.`);
    return null;
  }
  const s = String(value).trim();
  if (!UUID_RE.test(s)) throw bad(field, `${field} must be a UUID.`);
  return s;
}

export function oneOf(value, field, allowed, { required = false, fallback = null } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw bad(field, `${field} is required.`);
    return fallback;
  }
  const s = String(value).trim();
  if (!allowed.includes(s)) {
    throw bad(field, `${field} must be one of: ${allowed.join(', ')}.`);
  }
  return s;
}

/** wa.me format: digits only, country code first, no plus. */
export function whatsappNumber(value, field, { required = true } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw bad(field, `${field} is required.`);
    return null;
  }
  const digits = String(value).replace(/[^0-9]/g, '');
  if (digits.length < 10 || digits.length > 15) {
    throw bad(field, `${field} must be 10–15 digits including the country code.`);
  }
  return digits;
}

export function stringList(value, field, { max = 20, maxLen = 40 } = {}) {
  if (value === undefined || value === null || value === '') return null;
  const arr = Array.isArray(value) ? value : String(value).split(',');
  const out = arr.map((v) => String(v).trim()).filter(Boolean);
  if (out.length > max) throw bad(field, `${field} accepts at most ${max} values.`);
  for (const v of out) {
    if (v.length > maxLen) throw bad(field, `Each ${field} value must be under ${maxLen} chars.`);
  }
  return out.length ? out : null;
}

export function slugify(value, field) {
  const base = str(value, field, { min: 2, max: 120 })
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);
  if (!base) throw bad(field, `${field} could not be turned into a slug.`);
  return base;
}
