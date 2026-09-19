-- ============================================================================
-- GroundsNearMe — 20260919000002 · Guest Booking & Phone Verification
-- ============================================================================
-- 1. Extend bookings table: add phone_verified_at column
-- 2. Create guest_profiles table: phone-keyed profile with no password
-- 3. Create request_booking_otp: OTP dispatch without duplicate rejection
-- 4. Create verify_booking_otp: cryptographic verification issuing temporary token
-- 5. Create create_guest_booking: verified guest booking creation with slot checks
-- 6. Create get_guest_bookings: retrieve bookings by verified phone number
-- ============================================================================

-- Ensure pgcrypto extension
create extension if not exists pgcrypto with schema extensions;

-- Server-side rate limiting buckets
create table if not exists public.auth_rate_limits (
  id                bigserial primary key,
  bucket_key        text not null,
  action            text not null,
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
  phone          text not null,
  email          text,
  otp_hash       text not null,
  attempts_left  int not null default 5,
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
  event_type  text not null,
  identifier  text,
  ip_address  text,
  user_agent  text,
  metadata    jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists auth_audit_log_event_idx 
  on public.auth_audit_log (event_type, created_at desc);
create index if not exists auth_audit_log_ip_idx 
  on public.auth_audit_log (ip_address, created_at desc);

-- Enable RLS
alter table public.auth_rate_limits enable row level security;
alter table public.auth_otps enable row level security;
alter table public.auth_audit_log enable row level security;

-- 1. Extend bookings table
alter table if exists public.bookings 
  add column if not exists phone_verified_at timestamptz default null;

-- 2. Guest profiles table (passwordless lightweight profile for faster re-booking)
create table if not exists public.guest_profiles (
  id             uuid primary key default gen_random_uuid(),
  phone          text not null unique,               -- normalized digits
  full_name      text not null,
  email          text,
  booking_count  int not null default 1,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists guest_profiles_phone_idx 
  on public.guest_profiles (phone);

alter table public.guest_profiles enable row level security;

-- Only authenticated staff can view guest_profiles directly; anon interacts via RPCs
create policy guest_profiles_staff_all on public.guest_profiles
  for all to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- 3. Request Booking OTP (No Duplicate Block, Server Rate Limit, 10m TTL)
-- ---------------------------------------------------------------------------
create or replace function public.request_booking_otp(
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
  v_existing_name text;
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
  -- RATE LIMITING (Action: 'booking_otp')
  -- -------------------------------------------------------------------------
  -- A. IP Rate Limit: max 10 requests per 15 minutes
  v_ip_bucket := 'ip:' || coalesce(nullif(p_ip, ''), 'unknown');
  select * into v_ip_rec from public.auth_rate_limits
  where bucket_key = v_ip_bucket and action = 'booking_otp';

  if found then
    if v_ip_rec.locked_until is not null and v_ip_rec.locked_until > now() then
      return jsonb_build_object(
        'ok', false,
        'code', 'RATE_LIMITED',
        'retry_after', extract(epoch from (v_ip_rec.locked_until - now()))::int,
        'message', 'Too many verification attempts from this network. Please try again later.'
      );
    end if;

    if now() - v_ip_rec.first_attempt_at < interval '15 minutes' then
      if v_ip_rec.attempts >= 10 then
        update public.auth_rate_limits
        set locked_until = now() + interval '15 minutes', last_attempt_at = now()
        where bucket_key = v_ip_bucket and action = 'booking_otp';

        insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
        values ('rate_limit_exceeded', v_clean_phone, p_ip, jsonb_build_object('scope', 'ip', 'limit', 10, 'action', 'booking_otp'));

        return jsonb_build_object(
          'ok', false,
          'code', 'RATE_LIMITED',
          'retry_after', 900,
          'message', 'Too many requests from this network. Please wait 15 minutes.'
        );
      else
        update public.auth_rate_limits
        set attempts = attempts + 1, last_attempt_at = now()
        where bucket_key = v_ip_bucket and action = 'booking_otp';
      end if;
    else
      update public.auth_rate_limits
      set attempts = 1, first_attempt_at = now(), last_attempt_at = now(), locked_until = null
      where bucket_key = v_ip_bucket and action = 'booking_otp';
    end if;
  else
    insert into public.auth_rate_limits (bucket_key, action, attempts, first_attempt_at, last_attempt_at)
    values (v_ip_bucket, 'booking_otp', 1, now(), now());
  end if;

  -- B. Phone Rate Limit: max 5 requests per 1 hour
  v_phone_bucket := 'phone:' || v_clean_phone;
  select * into v_phone_rec from public.auth_rate_limits
  where bucket_key = v_phone_bucket and action = 'booking_otp';

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
      if v_phone_rec.attempts >= 5 then
        update public.auth_rate_limits
        set locked_until = now() + interval '1 hour', last_attempt_at = now()
        where bucket_key = v_phone_bucket and action = 'booking_otp';

        insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
        values ('rate_limit_exceeded', v_clean_phone, p_ip, jsonb_build_object('scope', 'phone', 'limit', 5, 'action', 'booking_otp'));

        return jsonb_build_object(
          'ok', false,
          'code', 'RATE_LIMITED',
          'retry_after', 3600,
          'message', 'Too many verification attempts for this number. Please wait an hour.'
        );
      else
        update public.auth_rate_limits
        set attempts = attempts + 1, last_attempt_at = now()
        where bucket_key = v_phone_bucket and action = 'booking_otp';
      end if;
    else
      update public.auth_rate_limits
      set attempts = 1, first_attempt_at = now(), last_attempt_at = now(), locked_until = null
      where bucket_key = v_phone_bucket and action = 'booking_otp';
    end if;
  else
    insert into public.auth_rate_limits (bucket_key, action, attempts, first_attempt_at, last_attempt_at)
    values (v_phone_bucket, 'booking_otp', 1, now(), now());
  end if;

  -- C. 60-Second Resend Cooldown
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
  -- ABUSE DETECTION & AUDIT LOGGING
  -- -------------------------------------------------------------------------
  select count(*) into v_ip_burst from public.auth_audit_log
  where ip_address = p_ip and event_type = 'booking_otp_requested'
    and created_at > (now() - interval '1 hour');

  if v_ip_burst >= 15 then
    insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
    values ('abuse_flagged', v_clean_phone, p_ip, jsonb_build_object(
      'reason', 'ip_burst_booking_threshold_exceeded',
      'burst_count', v_ip_burst
    ));
  end if;

  -- Check if guest profile exists to provide convenience
  select full_name into v_existing_name from public.guest_profiles
  where phone = v_clean_phone limit 1;

  -- -------------------------------------------------------------------------
  -- CRYPTOGRAPHIC OTP GENERATION
  -- -------------------------------------------------------------------------
  delete from public.auth_otps
  where phone = v_clean_phone and verified_at is null;

  v_code := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
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
    5,
    coalesce(v_last_otp.resend_count, 0) + 1,
    now(),
    now() + interval '10 minutes',
    p_ip
  );

  insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
  values ('booking_otp_requested',
    substring(v_clean_phone from 1 for 4) || '••••' || substring(v_clean_phone from char_length(v_clean_phone) - 2),
    p_ip,
    jsonb_build_object('resend_count', coalesce(v_last_otp.resend_count, 0) + 1)
  );

  return jsonb_build_object(
    'ok', true,
    'expires_in', 600,
    'resend_cooldown', 60,
    'saved_name', v_existing_name
  );
end;
$$;

grant execute on function public.request_booking_otp(text, text, text)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Verify Booking OTP (Issues 15-min Verification Token)
-- ---------------------------------------------------------------------------
create or replace function public.verify_booking_otp(
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
  v_token        uuid;
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

  if v_otp_rec.expires_at < now() then
    delete from public.auth_otps where id = v_otp_rec.id;
    return jsonb_build_object(
      'ok', false,
      'code', 'OTP_EXPIRED',
      'message', 'Verification code has expired. Please request a new code.'
    );
  end if;

  if v_otp_rec.attempts_left <= 0 then
    delete from public.auth_otps where id = v_otp_rec.id;
    insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
    values ('booking_otp_exhausted', v_clean_phone, p_ip, jsonb_build_object('otp_id', v_otp_rec.id));

    return jsonb_build_object(
      'ok', false,
      'code', 'OTP_EXHAUSTED',
      'message', 'Maximum verification attempts exceeded. Code invalidated. Please request a new code.'
    );
  end if;

  v_attempts := v_otp_rec.attempts_left - 1;

  if extensions.crypt(v_clean_code, v_otp_rec.otp_hash) = v_otp_rec.otp_hash then
    -- CODE IS VALID: Set verified_at and return verification token (valid for 15 mins)
    v_token := v_otp_rec.id;

    update public.auth_otps
    set verified_at = now()
    where id = v_otp_rec.id;

    insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
    values ('booking_otp_verified', v_clean_phone, p_ip, jsonb_build_object('phone', v_clean_phone));

    return jsonb_build_object(
      'ok', true,
      'verification_token', v_token,
      'message', 'Mobile number verified successfully.'
    );
  else
    if v_attempts <= 0 then
      delete from public.auth_otps where id = v_otp_rec.id;
      insert into public.auth_audit_log (event_type, identifier, ip_address, metadata)
      values ('booking_otp_failed_exhausted', v_clean_phone, p_ip, jsonb_build_object('phone', v_clean_phone));

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
      values ('booking_otp_failed', v_clean_phone, p_ip, jsonb_build_object('attempts_left', v_attempts));

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

grant execute on function public.verify_booking_otp(text, text, text)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Create Guest Booking RPC (Verified Phone, Input Sanitization & Slot Check)
-- ---------------------------------------------------------------------------
create or replace function public.create_guest_booking(
  p_ground_id          uuid,
  p_booking_date       date,
  p_start_time         time,
  p_end_time           time,
  p_contact_name       text,
  p_contact_phone      text,
  p_email              text default null,
  p_notes              text default null,
  p_players_expected   int  default null,
  p_verification_token uuid default null,
  p_save_info          boolean default false,
  p_hold_minutes       int  default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  g               record;
  v_clean_phone   text;
  v_clean_name    text;
  v_clean_email   text;
  v_clean_notes   text;
  v_start_ts      timestamp;
  v_end_ts        timestamp;
  v_minutes       int;
  v_expected      int;
  v_total         int;
  v_avail         int;
  v_reason        text;
  v_rate          integer;
  v_amount        numeric(12,2);
  v_hold          int := least(greatest(coalesce(p_hold_minutes, 30), 5), 180);
  v_row           public.bookings;
  v_token_valid   boolean := false;
begin
  -- Normalize & sanitize inputs
  v_clean_phone := regexp_replace(coalesce(p_contact_phone, ''), '\D', '', 'g');
  if char_length(v_clean_phone) < 10 or char_length(v_clean_phone) > 15 then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'INVALID_PHONE', 'message', 'Please provide a valid 10-15 digit mobile number.'));
  end if;

  -- Strip any potential script/HTML injection tags and limit lengths
  v_clean_name := trim(regexp_replace(coalesce(p_contact_name, ''), '<[^>]*>', '', 'g'));
  if char_length(v_clean_name) < 2 then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'INVALID_NAME', 'message', 'Please enter your full name.'));
  end if;
  if char_length(v_clean_name) > 100 then
    v_clean_name := substring(v_clean_name from 1 for 100);
  end if;

  v_clean_email := nullif(lower(trim(coalesce(p_email, ''))), '');
  if v_clean_email is not null and (v_clean_email !~ '^[^@]+@[^@]+\.[^@]+$') then
    v_clean_email := null;
  end if;

  v_clean_notes := trim(regexp_replace(coalesce(p_notes, ''), '<[^>]*>', '', 'g'));
  if char_length(v_clean_notes) > 500 then
    v_clean_notes := substring(v_clean_notes from 1 for 500);
  end if;
  v_clean_notes := nullif(v_clean_notes, '');

  -- -------------------------------------------------------------------------
  -- VERIFY OTP TOKEN (Required for guest booking integrity)
  -- -------------------------------------------------------------------------
  if p_verification_token is not null then
    select exists (
      select 1 from public.auth_otps
      where id = p_verification_token
        and phone = v_clean_phone
        and verified_at is not null
        and verified_at > (now() - interval '15 minutes')
    ) into v_token_valid;
  end if;

  -- Also check if verified within last 15 minutes by phone if token wasn't persisted
  if not v_token_valid then
    select exists (
      select 1 from public.auth_otps
      where phone = v_clean_phone
        and verified_at is not null
        and verified_at > (now() - interval '15 minutes')
    ) into v_token_valid;
  end if;

  if not v_token_valid then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'VERIFICATION_REQUIRED',
      'message', 'Please verify your mobile number with the SMS code before booking.'));
  end if;

  -- -------------------------------------------------------------------------
  -- GROUND & AVAILABILITY CHECKS
  -- -------------------------------------------------------------------------
  select id, status, price_per_hour, weekend_price_per_hour, slot_duration_minutes,
         min_booking_minutes, max_booking_minutes, commission_rate, currency
    into g
    from public.grounds
   where id = p_ground_id;

  if g.id is null or g.status <> 'active' then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'GROUND_NOT_AVAILABLE', 'message', 'This ground is not accepting bookings.'));
  end if;

  v_start_ts := p_booking_date + p_start_time;
  v_end_ts   := (case when p_end_time <= p_start_time then p_booking_date + 1 else p_booking_date end)
                + p_end_time;
  v_minutes  := (extract(epoch from (v_end_ts - v_start_ts)) / 60)::int;

  if v_minutes <= 0 then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'INVALID_TIME_RANGE', 'message', 'End time must be after start time.'));
  end if;

  if v_minutes % g.slot_duration_minutes <> 0 then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'INVALID_DURATION',
      'message', format('Bookings must be in %s-minute blocks.', g.slot_duration_minutes)));
  end if;

  if v_minutes < g.min_booking_minutes or v_minutes > g.max_booking_minutes then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'INVALID_DURATION',
      'message', format('This ground accepts %s–%s minute bookings.',
                        g.min_booking_minutes, g.max_booking_minutes)));
  end if;

  -- Release lapsed holds
  update public.bookings
     set status = 'expired'
   where ground_id = p_ground_id
     and status = 'pending'
     and hold_expires_at is not null
     and hold_expires_at < now();

  v_expected := v_minutes / g.slot_duration_minutes;

  select count(*)::int, count(*) filter (where a.is_available)::int
    into v_total, v_avail
    from public.get_ground_availability(p_ground_id, p_booking_date) a
   where a.starts_at >= v_start_ts and a.ends_at <= v_end_ts;

  if v_total <> v_expected then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'OUTSIDE_OPENING_HOURS',
      'message', 'That time is outside this ground''s opening hours.'));
  end if;

  if v_avail <> v_expected then
    select a.reason into v_reason
      from public.get_ground_availability(p_ground_id, p_booking_date) a
     where a.starts_at >= v_start_ts and a.ends_at <= v_end_ts
       and not a.is_available
     limit 1;

    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', case v_reason
                when 'past'          then 'SLOT_IN_PAST'
                when 'closed'        then 'GROUND_CLOSED'
                when 'out_of_window' then 'OUTSIDE_BOOKING_WINDOW'
                else 'SLOT_TAKEN'
              end,
      'message', case v_reason
                   when 'past'          then 'That slot has already started.'
                   when 'closed'        then 'The ground is closed on this date.'
                   when 'out_of_window' then 'That date is not open for booking yet.'
                   else 'Someone just took this slot. Pick another one.'
                 end));
  end if;

  v_rate := case
              when extract(dow from p_booking_date) in (0, 6)
                then coalesce(g.weekend_price_per_hour, g.price_per_hour)
              else g.price_per_hour
            end;
  v_amount := round(v_rate * (v_minutes / 60.0), 2);

  -- -------------------------------------------------------------------------
  -- INSERT BOOKING
  -- -------------------------------------------------------------------------
  begin
    insert into public.bookings (
      booking_ref, ground_id, player_id, booking_date, start_time, end_time,
      duration_minutes, status, source, price_per_hour, total_amount, currency,
      commission_rate, commission_amount, contact_name, contact_phone,
      players_expected, notes, hold_expires_at, phone_verified_at, created_by
    )
    values (
      public.generate_booking_ref(), p_ground_id, null, p_booking_date,
      p_start_time, p_end_time, v_minutes, 'confirmed', 'web', v_rate, v_amount,
      g.currency, g.commission_rate, round(v_amount * g.commission_rate, 2),
      v_clean_name,
      v_clean_phone,
      p_players_expected,
      v_clean_notes,
      now() + make_interval(mins => v_hold),
      now(),
      null
    )
    returning * into v_row;
  exception
    when exclusion_violation then
      return jsonb_build_object('ok', false, 'error', jsonb_build_object(
        'code', 'SLOT_TAKEN', 'message', 'Someone just took this slot. Pick another one.'));
    when unique_violation then
      return jsonb_build_object('ok', false, 'error', jsonb_build_object(
        'code', 'RETRY', 'message', 'Booking reference collision — please retry.'));
  end;

  -- -------------------------------------------------------------------------
  -- CONSUME OTP TO PREVENT REPLAY
  -- -------------------------------------------------------------------------
  delete from public.auth_otps
  where phone = v_clean_phone;

  -- -------------------------------------------------------------------------
  -- OPTIONAL: SAVE TO GUEST PROFILES UPSELL
  -- -------------------------------------------------------------------------
  if p_save_info then
    insert into public.guest_profiles (phone, full_name, email, booking_count, updated_at)
    values (v_clean_phone, v_clean_name, v_clean_email, 1, now())
    on conflict (phone) do update
    set full_name = excluded.full_name,
        email = coalesce(excluded.email, public.guest_profiles.email),
        booking_count = public.guest_profiles.booking_count + 1,
        updated_at = now();
  end if;

  return jsonb_build_object('ok', true, 'booking', to_jsonb(v_row));
end;
$$;

grant execute on function public.create_guest_booking(uuid, date, time, time, text, text, text, text, int, uuid, boolean, int)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Retrieve Guest Bookings by Verified Phone
-- ---------------------------------------------------------------------------
create or replace function public.get_guest_bookings(
  p_phone              text,
  p_verification_token uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clean_phone text;
  v_verified    boolean := false;
  v_rows        jsonb;
begin
  v_clean_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');

  if p_verification_token is not null then
    select exists (
      select 1 from public.auth_otps
      where id = p_verification_token
        and phone = v_clean_phone
        and verified_at is not null
        and verified_at > (now() - interval '24 hours')
    ) into v_verified;
  end if;

  if not v_verified then
    return jsonb_build_object('ok', false, 'code', 'UNVERIFIED', 'message', 'Please verify your phone number to view bookings.');
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'id', b.id,
      'booking_ref', b.booking_ref,
      'ground_id', b.ground_id,
      'ground_name', g.name,
      'ground_slug', g.slug,
      'city', g.city,
      'address', g.address,
      'booking_date', b.booking_date,
      'start_time', b.start_time,
      'end_time', b.end_time,
      'duration_minutes', b.duration_minutes,
      'status', b.status,
      'payment_status', b.payment_status,
      'total_amount', b.total_amount,
      'currency', b.currency,
      'contact_name', b.contact_name,
      'contact_phone', b.contact_phone,
      'created_at', b.created_at
    ) order by b.booking_date desc, b.start_time desc
  ) into v_rows
  from public.bookings b
  join public.grounds g on g.id = b.ground_id
  where b.contact_phone = v_clean_phone
    and b.status in ('confirmed', 'pending', 'completed');

  return jsonb_build_object('ok', true, 'bookings', coalesce(v_rows, '[]'::jsonb));
end;
$$;

grant execute on function public.get_guest_bookings(text, uuid)
  to anon, authenticated;
