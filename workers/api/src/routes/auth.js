/**
 * Auth edge routes: signup OTP dispatch, OTP verification, and login lockout tracking.
 */

import { json } from '../lib/http.js';
import { sbRpc } from '../lib/supabase.js';
import { readJson, str } from '../lib/validate.js';

function getClientIp(request) {
  return (
    request.headers.get('cf-connecting-ip') ||
    request.headers.get('x-real-ip') ||
    request.headers.get('x-forwarded-for')?.split(',')[0].trim() ||
    'unknown'
  );
}

export async function signupOtp(request, env) {
  const body = await readJson(request);
  const phone = str(body.phone, 'phone', { min: 10, max: 20 });
  const email = str(body.email, 'email', { required: false, max: 254 });
  const ip = getClientIp(request);

  const res = await sbRpc(env, 'request_signup_otp', {
    p_phone: phone,
    p_email: email,
    p_ip: ip,
  });

  if (!res || res.ok === false) {
    const code = res?.code || 'ERROR';
    const retryAfter = res?.retry_after || 60;

    if (code === 'RATE_LIMITED' || code === 'COOLDOWN_ACTIVE') {
      return json(res, {
        status: 429,
        headers: { 'Retry-After': String(retryAfter) },
      });
    }
    if (code === 'ACCOUNT_EXISTS') {
      return json(res, { status: 409 });
    }
    return json(res, { status: 400 });
  }

  return json(res, { status: 200 });
}

export async function verifyOtp(request, env) {
  const body = await readJson(request);
  const phone = str(body.phone, 'phone', { min: 10, max: 20 });
  const code = str(body.code, 'code', { min: 6, max: 6 });
  const ip = getClientIp(request);

  const res = await sbRpc(env, 'verify_signup_otp', {
    p_phone: phone,
    p_code: code,
    p_ip: ip,
  });

  if (!res || res.ok === false) {
    const status = res?.code === 'OTP_EXHAUSTED' ? 429 : 400;
    return json(res, { status });
  }

  return json(res, { status: 200 });
}

export async function loginCheck(request, env) {
  const body = await readJson(request);
  const identifier = str(body.identifier, 'identifier', { min: 3, max: 254 });
  const action = body.action || 'check';
  const success = Boolean(body.success);
  const ip = getClientIp(request);

  if (action === 'record') {
    const res = await sbRpc(env, 'record_login_attempt', {
      p_identifier: identifier,
      p_ip: ip,
      p_success: success,
    });

    if (res?.locked) {
      return json(res, {
        status: 429,
        headers: { 'Retry-After': String(res.retry_after || 900) },
      });
    }
    return json(res, { status: 200 });
  }

  const res = await sbRpc(env, 'check_login_lockout', {
    p_identifier: identifier,
    p_ip: ip,
  });

  if (res?.is_locked) {
    return json(res, {
      status: 429,
      headers: { 'Retry-After': String(res.retry_after || 900) },
    });
  }

  return json(res, { status: 200 });
}

export async function bookingOtp(request, env) {
  const body = await readJson(request);
  const phone = str(body.phone, 'phone', { min: 10, max: 20 });
  const email = str(body.email, 'email', { required: false, max: 254 });
  const ip = getClientIp(request);

  const res = await sbRpc(env, 'request_booking_otp', {
    p_phone: phone,
    p_email: email,
    p_ip: ip,
  });

  if (!res || res.ok === false) {
    const code = res?.code || 'ERROR';
    const retryAfter = res?.retry_after || 60;

    if (code === 'RATE_LIMITED' || code === 'COOLDOWN_ACTIVE') {
      return json(res, {
        status: 429,
        headers: { 'Retry-After': String(retryAfter) },
      });
    }
    return json(res, { status: 400 });
  }

  return json(res, { status: 200 });
}

export async function verifyBookingOtp(request, env) {
  const body = await readJson(request);
  const phone = str(body.phone, 'phone', { min: 10, max: 20 });
  const code = str(body.code, 'code', { min: 6, max: 6 });
  const ip = getClientIp(request);

  const res = await sbRpc(env, 'verify_booking_otp', {
    p_phone: phone,
    p_code: code,
    p_ip: ip,
  });

  if (!res || res.ok === false) {
    const status = res?.code === 'OTP_EXHAUSTED' ? 429 : 400;
    return json(res, { status });
  }

  return json(res, { status: 200 });
}
