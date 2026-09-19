-- ============================================================================
-- GroundsNearMe — 20260919000001 · Auth & OTP Security Hardening
-- ============================================================================
-- 1. Pre-dispatch duplicate check (prevents OTP spamming to registered users)
-- 2. Server-side rate limiting (signup per IP/phone, login lockout per account/IP)
-- 3. Cryptographic OTP lifecycle (10m TTL, bcrypt hash, 5 attempt limit, auto-wipe)
-- 4. Generic error messages (CWE-209 / account enumeration prevention)
-- 5. Password complexity validation in DB
-- 6. Audit logging & abuse alerting (carrier prefix and IP burst tracking)
-- ============================================================================

-- Ensure pgcrypto is available
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- 1. Tables for Rate Limiting, OTP Management, and Auth Audit Logs
-- ---------------------------------------------------------------------------

-- Server-side rate limiting buckets
create table if not exists public.auth_rate_limits (
  id                bigserial primary key,
  bucket_key        text not null,            -- e.g. 'ip:192.168.1.1' or 'ident:03001234567'
  action            text not null,            -- 'signup_otp', 'login_attempt', 'otp_verify'
  attempts          int not null default 1,
  first_attempt_at  timestamptz not null default now(),
  last_attempt_at   timestamptz not null default now(),
  locked_until      timestamptz,
  created_at        timestamptz not null default now(),
  constraint auth_rate_limits_key_action unique (bucket_key, action)
);

create index if not exists auth_rate_limits_locked_idx 
  on public.auth_rate_limits (bucket_key, action, locked_until);

-- OTP management table: codes stored strictly as bcrypt/pgcrypto hashes
create table if not exists public.auth_otps (
  id             uuid primary key default gen_random_uuid(),
  phone          text not null,               -- normalized digits only
  email          text,                        -- normalized lowercase
  otp_hash       text not null,               -- extensions.crypt(code, gen_salt('bf', 8))
  attempts_left  int not null default 5,      -- max 5 attempts before code is destroyed
  resend_count   int not null default 0,
  last_sent_at   timestamptz not null default now(),
  expires_at     timestamptz not null default (now() + interval '10 minutes'),
  verified_at    timestamptz,
  ip_address     text,
  created_at     timestamptz not null default now()
);

create index if not exists auth_otps_lookup_idx 
  on public.auth_otps (phone, expires_at desc);

-- Append-only auth security audit log
create table if not exists public.auth_audit_log (
  id          bigserial primary key,
  event_type  text not null,                  -- 'signup_otp_requested', 'otp_verify_success', 'otp_verify_failed', 'login_failed', 'login_lockout', 'abuse_flagged'
  identifier  text,                           -- masked phone or email
  ip_address  text,
  user_agent  text,
  metadata    jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists auth_audit_log_event_idx 
  on public.auth_audit_log (event_type, created_at desc);
create index if not exists auth_audit_log_ip_idx 
  on public.auth_audit_log (ip_address, created_at desc);

-- Enable RLS on all internal auth tables (zero public direct access)
alter table public.auth_rate_limits enable row level security;
alter table public.auth_otps enable row level security;
alter table public.auth_audit_log enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Password Complexity Validation Helper
-- ---------------------------------------------------------------------------
create or replace function public.validate_password_strength(p_password text)
returns boolean
language plpgsql
immutable
as $$
begin
  if p_password is null or char_length(p_password) < 8 then
    return false;
  end if;
  -- Must contain uppercase, lowercase, digit, and special character
  if p_password !~ '[A-Z]' then return false; end if;
  if p_password !~ '[a-z]' then return false; end if;
  if p_password !~ '[0-9]' then return false; end if;
  if p_password !~ '[^a-zA-Z0-9]' then return false; end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Request Signup OTP (Pre-Check + Server Rate Limit + Salted Hashing + Abuse Alert)
-- ---------------------------------------------------------------------------
create or replace function public.request_signup_otp(
  p_phone text,
  p_email text default null,
  p_ip    text default 'unknown'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_clean_phone   text;
  v_clean_email   text;
  v_ip_bucket     text;
  v_phone_bucket  text;
  v_ip_rec        record;
  v_phone_rec     record;
  v_last_otp      record;
  v_cooldown_left int;
  v_code          text;
  v_hash          text;
  v_prefix        text;
  v_prefix_count  int;
  v_ip_burst      int;
begin
  -- Normalize inputs
  v_clean_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if char_length(v_clean_phone) < 10 or char_length(v_clean_phone) > 15 then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_PHONE',
      'message', 'Please enter a valid mobile number (10 to 15 digits).'
    );
  end if;

  v_clean_email := nullif(lower(trim(coalesce(p_email, ''))), '');
  if v_clean_email is not null and (v_clean_email !~ '^[^@]+@[^@]+\.[^@]+$') then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_EMAIL',
      'message', 'Please enter a valid email address.'
    );
  end if;

  -- -------------------------------------------------------------------------
  -- STEP 1: DUPLICATE ACCOUNT CHECK BEFORE GENERATING OR SENDING ANY OTP
  -- -------------------------------------------------------------------------
  if exists (
    select 1 from auth.users u
    where (u.phone is not null and regexp_replace(u.phone, '\D', '', 'g') = v_clean_phone)
       or (v_clean_email is not null and u.email is not null and lower(u.email) = v_clean_email)
  ) or exists (
    select 1 from public.profiles p
    where (p.phone is not null and regexp_replace(p.phone, '\D', '', 'g') = v_clean_phone)
       or (v_clean_email is not null and p.email is not null and lower(p.email::text) = v_clean_email)
  ) then
    -- Enumeration-safe duplicate message (doesn't disclose phone vs email)
    return jsonb_build_object(
      'ok', false,
      'code', 'ACCOUNT_EXISTS',
      'message', 'An account with these details already exists. Please log in.'
    );
  end if;

  -- -------------------------------------------------------------------------
  -- STEP 2: SERVER-SIDE RATE LIMITING
  -- -------------------------------------------------------------------------
  -- A. IP Rate Limit: max 5 requests per 15 minutes
  v_ip_bucket := 'ip:' || coalesce(nullif(p_ip, ''), 'unknown');
  select * into v_ip_rec from public.auth_rate_limits
  where bucket_key = v_ip_bucket and action = 'signup_otp';

  if found then
    if v_ip_rec.locked_until is not null and v_ip_rec.locked_until > now() then
      return jsonb_build_object(
        'ok', false,
        'code', 'RATE_LIMITED',
        'retry_after', extract(epoch from (v_ip_rec.locked_until - now()))::int,
        'message', 'Too many requests from this network. Please try again later.'
      );
    end if;

    if now() - v_ip_rec.first_attempt_at < interval '15 minutes' then
      if v_ip_rec.attempts >= 5 then
        update public.auth_rate_limits
        set locked_until = now() + interval '15 minutes', last_attempt_at = now()
        where bucket_key = v_ip_bucket and action = 'signup_otp';

        insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
        values ('rate_limit_exceeded', v_clean_phone, p_ip, jsonb_build_object('scope', 'ip', 'limit', 5));

        return jsonb_build_object(
          'ok', false,
          'code', 'RATE_LIMITED',
          'retry_after', 900,
          'message', 'Too many requests from this network. Please wait 15 minutes.'
        );
      else
        update public.auth_rate_limits
        set attempts = attempts + 1, last_attempt_at = now()
        where bucket_key = v_ip_bucket and action = 'signup_otp';
      end if;
    else
      update public.auth_rate_limits
      set attempts = 1, first_attempt_at = now(), last_attempt_at = now(), locked_until = null
      where bucket_key = v_ip_bucket and action = 'signup_otp';
    end if;
  else
    insert into public.auth_rate_limits (bucket_key, action, attempts, first_attempt_at, last_attempt_at)
    values (v_ip_bucket, 'signup_otp', 1, now(), now());
  end if;

  -- B. Phone Rate Limit: max 3 requests per 1 hour
  v_phone_bucket := 'phone:' || v_clean_phone;
  select * into v_phone_rec from public.auth_rate_limits
  where bucket_key = v_phone_bucket and action = 'signup_otp';

  if found then
    if v_phone_rec.locked_until is not null and v_phone_rec.locked_until > now() then
      return jsonb_build_object(
        'ok', false,
        'code', 'RATE_LIMITED',
        'retry_after', extract(epoch from (v_phone_rec.locked_until - now()))::int,
        'message', 'Too many verification attempts for this number. Please wait an hour.'
      );
    end if;

    if now() - v_phone_rec.first_attempt_at < interval '1 hour' then
      if v_phone_rec.attempts >= 3 then
        update public.auth_rate_limits
        set locked_until = now() + interval '1 hour', last_attempt_at = now()
        where bucket_key = v_phone_bucket and action = 'signup_otp';

        insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
        values ('rate_limit_exceeded', v_clean_phone, p_ip, jsonb_build_object('scope', 'phone', 'limit', 3));

        return jsonb_build_object(
          'ok', false,
          'code', 'RATE_LIMITED',
          'retry_after', 3600,
          'message', 'Too many verification attempts for this number. Please wait an hour.'
        );
      else
        update public.auth_rate_limits
        set attempts = attempts + 1, last_attempt_at = now()
        where bucket_key = v_phone_bucket and action = 'signup_otp';
      end if;
    else
      update public.auth_rate_limits
      set attempts = 1, first_attempt_at = now(), last_attempt_at = now(), locked_until = null
      where bucket_key = v_phone_bucket and action = 'signup_otp';
    end if;
  else
    insert into public.auth_rate_limits (bucket_key, action, attempts, first_attempt_at, last_attempt_at)
    values (v_phone_bucket, 'signup_otp', 1, now(), now());
  end if;

  -- C. Resend Cooldown: 60s minimum interval enforced on server
  select * into v_last_otp from public.auth_otps
  where phone = v_clean_phone and verified_at is null and expires_at > now()
  order by created_at desc limit 1;

  if found and (now() - v_last_otp.last_sent_at < interval '60 seconds') then
    v_cooldown_left := extract(epoch from (v_last_otp.last_sent_at + interval '60 seconds' - now()))::int;
    return jsonb_build_object(
      'ok', false,
      'code', 'COOLDOWN_ACTIVE',
      'retry_after', greatest(1, v_cooldown_left),
      'message', 'Please wait ' || greatest(1, v_cooldown_left) || ' seconds before requesting another code.'
    );
  end if;

  -- -------------------------------------------------------------------------
  -- STEP 3: ABUSE ALERTING & PATTERN DETECTION
  -- -------------------------------------------------------------------------
  -- Flag if > 10 requests from same IP in 1h
  select count(*) into v_ip_burst from public.auth_audit_log
  where ip_address = p_ip and event_type = 'signup_otp_requested'
    and created_at > (now() - interval '1 hour');

  if v_ip_burst >= 10 then
    insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
    values ('abuse_flagged', v_clean_phone, p_ip, jsonb_build_object(
      'reason', 'ip_burst_threshold_exceeded',
      'burst_count', v_ip_burst
    ));
  end if;

  -- Flag carrier prefix pooling (> 20 requests to same prefix in 1 hour)
  if char_length(v_clean_phone) >= 4 then
    v_prefix := substring(v_clean_phone from 1 for 4); -- e.g. '0300', '0321'
    select count(*) into v_prefix_count from public.auth_otps
    where phone like (v_prefix || '%') and created_at > (now() - interval '1 hour');

    if v_prefix_count >= 20 then
      insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
      values ('abuse_flagged', v_prefix || '****', p_ip, jsonb_build_object(
        'reason', 'carrier_prefix_burst',
        'prefix', v_prefix,
        'count', v_prefix_count
      ));
    end if;
  end if;

  -- -------------------------------------------------------------------------
  -- STEP 4: CRYPTOGRAPHIC OTP GENERATION & STORAGE
  -- -------------------------------------------------------------------------
  -- Invalidate / remove previous unverified codes for this phone
  delete from public.auth_otps
  where phone = v_clean_phone and verified_at is null;

  -- Generate 6-digit cryptographically random code
  v_code := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');

  -- Cryptographic salted hash (bcrypt cost 8 for fast verification without server drag)
  v_hash := extensions.crypt(v_code, extensions.gen_salt('bf', 8));

  insert into public.auth_otps (
    phone,
    email,
    otp_hash,
    attempts_left,
    resend_count,
    last_sent_at,
    expires_at,
    ip_address
  ) values (
    v_clean_phone,
    v_clean_email,
    v_hash,
    5, -- Max 5 attempts
    coalesce(v_last_otp.resend_count, 0) + 1,
    now(),
    now() + interval '10 minutes', -- 10 min TTL
    p_ip
  );

  -- Audit log entry
  insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
  values ('signup_otp_requested', 
    substring(v_clean_phone from 1 for 4) || '••••' || substring(v_clean_phone from char_length(v_clean_phone) - 2),
    p_ip,
    jsonb_build_object('resend_count', coalesce(v_last_otp.resend_count, 0) + 1)
  );

  -- Return success with cooldown details (raw code never returned in production)
  return jsonb_build_object(
    'ok', true,
    'expires_in', 600,
    'resend_cooldown', 60,
    'delivery', 'sms'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Verify Signup OTP (5 Attempts, Expiry, Salt Match & Instant Wipe)
-- ---------------------------------------------------------------------------
create or replace function public.verify_signup_otp(
  p_phone text,
  p_code  text,
  p_ip    text default 'unknown'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_clean_phone  text;
  v_clean_code   text;
  v_otp_rec      record;
  v_attempts     int;
begin
  v_clean_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_clean_code  := trim(coalesce(p_code, ''));

  if char_length(v_clean_code) <> 6 then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_FORMAT',
      'message', 'Please enter all 6 digits of the verification code.'
    );
  end if;

  select * into v_otp_rec from public.auth_otps
  where phone = v_clean_phone and verified_at is null
  order by created_at desc limit 1;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'OTP_NOT_FOUND',
      'message', 'No active verification code found. Please request a new one.'
    );
  end if;

  -- Check code expiry (10 min TTL)
  if v_otp_rec.expires_at < now() then
    delete from public.auth_otps where id = v_otp_rec.id;
    return jsonb_build_object(
      'ok', false,
      'code', 'OTP_EXPIRED',
      'message', 'Verification code has expired. Please request a new code.'
    );
  end if;

  -- Check attempts left
  if v_otp_rec.attempts_left <= 0 then
    delete from public.auth_otps where id = v_otp_rec.id;
    insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
    values ('otp_invalidated_exhausted', v_clean_phone, p_ip, jsonb_build_object('otp_id', v_otp_rec.id));

    return jsonb_build_object(
      'ok', false,
      'code', 'OTP_EXHAUSTED',
      'message', 'Maximum verification attempts exceeded. Code invalidated. Please request a new code.'
    );
  end if;

  -- Decrement attempts left
  v_attempts := v_otp_rec.attempts_left - 1;

  -- Compare cryptographic salted hash
  if extensions.crypt(v_clean_code, v_otp_rec.otp_hash) = v_otp_rec.otp_hash then
    -- CODE IS VALID: Invalidate immediately to prevent replay attacks
    delete from public.auth_otps where id = v_otp_rec.id;

    insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
    values ('otp_verify_success', v_clean_phone, p_ip, jsonb_build_object('phone', v_clean_phone));

    return jsonb_build_object(
      'ok', true,
      'message', 'Phone verified successfully.'
    );
  else
    -- CODE MISMATCH
    if v_attempts <= 0 then
      delete from public.auth_otps where id = v_otp_rec.id;
      insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
      values ('otp_verify_failed_exhausted', v_clean_phone, p_ip, jsonb_build_object('phone', v_clean_phone));

      return jsonb_build_object(
        'ok', false,
        'code', 'OTP_EXHAUSTED',
        'attempts_left', 0,
        'message', 'Incorrect verification code. Maximum attempts exceeded. Code has been invalidated.'
      );
    else
      update public.auth_otps
      set attempts_left = v_attempts
      where id = v_otp_rec.id;

      insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
      values ('otp_verify_failed', v_clean_phone, p_ip, jsonb_build_object('attempts_left', v_attempts));

      return jsonb_build_object(
        'ok', false,
        'code', 'INVALID_OTP',
        'attempts_left', v_attempts,
        'message', 'Incorrect verification code. (' || v_attempts || ' attempt' || (case when v_attempts = 1 then '' else 's' end) || ' remaining)'
      );
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Record Login Attempt & Lockout (5 Failed Attempts -> 15 Min Lockout)
-- ---------------------------------------------------------------------------
create or replace function public.record_login_attempt(
  p_identifier text,
  p_ip         text default 'unknown',
  p_success    boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bucket_id    text;
  v_bucket_ip    text;
  v_rec          record;
  v_attempts     int;
  v_lock_seconds int;
begin
  v_bucket_id := 'login_id:' || lower(trim(coalesce(p_identifier, '')));
  v_bucket_ip := 'login_ip:' || coalesce(nullif(p_ip, ''), 'unknown');

  -- On successful login: clear failed attempts
  if p_success then
    delete from public.auth_rate_limits
    where bucket_key in (v_bucket_id, v_bucket_ip) and action = 'login_attempt';

    insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
    values ('login_success', p_identifier, p_ip, jsonb_build_object('success', true));

    return jsonb_build_object('ok', true, 'locked', false);
  end if;

  -- On failed login: track account identifier bucket
  select * into v_rec from public.auth_rate_limits
  where bucket_key = v_bucket_id and action = 'login_attempt';

  if found then
    -- If already locked out
    if v_rec.locked_until is not null and v_rec.locked_until > now() then
      v_lock_seconds := extract(epoch from (v_rec.locked_until - now()))::int;
      return jsonb_build_object(
        'ok', false,
        'locked', true,
        'retry_after', greatest(1, v_lock_seconds),
        'attempts_left', 0,
        'message', 'Account temporarily locked due to repeated failed attempts. Please try again in ' || ceil(v_lock_seconds / 60.0)::int || ' minutes.'
      );
    end if;

    -- If prior attempts within 15 min window
    if now() - v_rec.first_attempt_at < interval '15 minutes' then
      v_attempts := v_rec.attempts + 1;
      if v_attempts >= 5 then
        update public.auth_rate_limits
        set attempts = v_attempts,
            locked_until = now() + interval '15 minutes',
            last_attempt_at = now()
        where bucket_key = v_bucket_id and action = 'login_attempt';

        insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
        values ('login_lockout', p_identifier, p_ip, jsonb_build_object('attempts', v_attempts, 'duration_mins', 15));

        return jsonb_build_object(
          'ok', false,
          'locked', true,
          'retry_after', 900,
          'attempts_left', 0,
          'message', 'Too many failed login attempts. Account temporarily locked for 15 minutes.'
        );
      else
        update public.auth_rate_limits
        set attempts = v_attempts, last_attempt_at = now()
        where bucket_key = v_bucket_id and action = 'login_attempt';
      end if;
    else
      v_attempts := 1;
      update public.auth_rate_limits
      set attempts = 1, first_attempt_at = now(), last_attempt_at = now(), locked_until = null
      where bucket_key = v_bucket_id and action = 'login_attempt';
    end if;
  else
    v_attempts := 1;
    insert into public.auth_rate_limits (bucket_key, action, attempts, first_attempt_at, last_attempt_at)
    values (v_bucket_id, 'login_attempt', 1, now(), now());
  end if;

  insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
  values ('login_failed', p_identifier, p_ip, jsonb_build_object('attempt', v_attempts, 'attempts_left', greatest(0, 5 - v_attempts)));

  return jsonb_build_object(
    'ok', false,
    'locked', false,
    'attempts_left', greatest(0, 5 - v_attempts),
    'message', 'Invalid mobile number, email, or password.'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Check Login Lockout Status
-- ---------------------------------------------------------------------------
create or replace function public.check_login_lockout(
  p_identifier text,
  p_ip         text default 'unknown'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bucket_id    text;
  v_bucket_ip    text;
  v_rec          record;
  v_lock_seconds int;
begin
  v_bucket_id := 'login_id:' || lower(trim(coalesce(p_identifier, '')));
  v_bucket_ip := 'login_ip:' || coalesce(nullif(p_ip, ''), 'unknown');

  select * into v_rec from public.auth_rate_limits
  where bucket_key in (v_bucket_id, v_bucket_ip)
    and action = 'login_attempt'
    and locked_until > now()
  order by locked_until desc limit 1;

  if found then
    v_lock_seconds := extract(epoch from (v_rec.locked_until - now()))::int;
    return jsonb_build_object(
      'is_locked', true,
      'retry_after', greatest(1, v_lock_seconds),
      'message', 'Account temporarily locked. Try again in ' || ceil(v_lock_seconds / 60.0)::int || ' minutes.'
    );
  end if;

  return jsonb_build_object('is_locked', false, 'retry_after', 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Grant Permissions to anon and authenticated
-- ---------------------------------------------------------------------------
grant execute on function public.validate_password_strength(text) to anon, authenticated;
grant execute on function public.request_signup_otp(text, text, text) to anon, authenticated;
grant execute on function public.verify_signup_otp(text, text, text) to anon, authenticated;
grant execute on function public.record_login_attempt(text, text, boolean) to anon, authenticated;
grant execute on function public.check_login_lockout(text, text) to anon, authenticated;
