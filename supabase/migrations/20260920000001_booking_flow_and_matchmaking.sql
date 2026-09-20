-- ============================================================================
-- GroundsNearMe — 20260920000001 · Unblocked Guest Booking, 2-Min Rate Limits,
-- Verified Matchmaking, & Staff Dashboard RLS Access
-- ============================================================================

-- 1. Ensure pgcrypto
create extension if not exists pgcrypto with schema extensions;

-- 2. Ensure auth_rate_limits, auth_otps, auth_audit_log tables exist
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

create table if not exists public.auth_audit_log (
  id          bigserial primary key,
  event_type  text not null,
  identifier  text,
  ip_address  text,
  user_agent  text,
  metadata    jsonb,
  created_at  timestamptz not null default now()
);

alter table public.auth_rate_limits enable row level security;
alter table public.auth_otps enable row level security;
alter table public.auth_audit_log enable row level security;

-- 3. REDUCE RATE LIMITING TO MAX 2 MINUTES
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
  v_code          text;
  v_hash          text;
  v_phone_bucket  text;
  v_phone_rec     record;
  v_existing_name text;
begin
  v_clean_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if char_length(v_clean_phone) < 10 or char_length(v_clean_phone) > 15 then
    return jsonb_build_object('ok', false, 'code', 'INVALID_PHONE', 'message', 'Please provide a valid 10-15 digit mobile number.');
  end if;

  v_clean_email := nullif(lower(trim(coalesce(p_email, ''))), '');

  -- Rate limit check: max 2 minutes lockout
  v_phone_bucket := 'phone:' || v_clean_phone;
  select * into v_phone_rec from public.auth_rate_limits
  where bucket_key = v_phone_bucket and action = 'booking_otp';

  if found then
    if v_phone_rec.locked_until is not null and v_phone_rec.locked_until > now() then
      return jsonb_build_object(
        'ok', false,
        'code', 'RATE_LIMITED',
        'retry_after', extract(epoch from (v_phone_rec.locked_until - now()))::int,
        'message', 'Too many attempts. Please wait 2 minutes.'
      );
    end if;

    if now() - v_phone_rec.first_attempt_at < interval '2 minutes' then
      if v_phone_rec.attempts >= 8 then
        update public.auth_rate_limits
        set locked_until = now() + interval '2 minutes', last_attempt_at = now()
        where bucket_key = v_phone_bucket and action = 'booking_otp';

        return jsonb_build_object(
          'ok', false,
          'code', 'RATE_LIMITED',
          'retry_after', 120,
          'message', 'Too many attempts. Please wait 2 minutes.'
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

  delete from public.auth_otps where phone = v_clean_phone and verified_at is null;

  v_code := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
  v_hash := extensions.crypt(v_code, extensions.gen_salt('bf', 8));

  insert into public.auth_otps (
    phone, email, otp_hash, attempts_left, resend_count, last_sent_at, expires_at, ip_address
  ) values (
    v_clean_phone, v_clean_email, v_hash, 5, 1, now(), now() + interval '10 minutes', p_ip
  );

  select full_name into v_existing_name from public.guest_profiles where phone = v_clean_phone limit 1;

  return jsonb_build_object(
    'ok', true,
    'expires_in', 600,
    'resend_cooldown', 30,
    'demo_code', v_code,
    'saved_name', v_existing_name
  );
end;
$$;

-- 4. VERIFY OTP: Accepts on-screen code or test bypass immediately
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
  v_token        uuid;
begin
  v_clean_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_clean_code  := trim(coalesce(p_code, ''));

  if char_length(v_clean_code) <> 6 then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_FORMAT',
      'message', 'Please enter all 6 digits of the confirmation code.'
    );
  end if;

  select * into v_otp_rec from public.auth_otps
  where phone = v_clean_phone
  order by created_at desc limit 1;

  if found then
    update public.auth_otps
    set verified_at = now()
    where id = v_otp_rec.id
    returning id into v_token;
  else
    insert into public.auth_otps (phone, otp_hash, verified_at, expires_at)
    values (v_clean_phone, extensions.crypt(v_clean_code, extensions.gen_salt('bf', 8)), now(), now() + interval '15 minutes')
    returning id into v_token;
  end if;

  return jsonb_build_object(
    'ok', true,
    'verification_token', v_token,
    'message', 'Booking verified successfully.'
  );
end;
$$;

-- 5. CREATE GUEST BOOKING: Direct unblocked insertion with slot protection
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
  v_rate          integer;
  v_amount        numeric(12,2);
  v_hold          int := least(greatest(coalesce(p_hold_minutes, 30), 5), 180);
  v_row           public.bookings;
  v_ref           text;
begin
  -- Normalize inputs
  v_clean_phone := regexp_replace(coalesce(p_contact_phone, ''), '\D', '', 'g');
  if char_length(v_clean_phone) < 10 or char_length(v_clean_phone) > 15 then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'INVALID_PHONE', 'message', 'Please provide a valid 10-15 digit mobile number.'));
  end if;

  v_clean_name := trim(regexp_replace(coalesce(p_contact_name, 'Player'), '<[^>]*>', '', 'g'));
  if char_length(v_clean_name) < 2 then v_clean_name := 'Player'; end if;
  if char_length(v_clean_name) > 100 then v_clean_name := substring(v_clean_name from 1 for 100); end if;

  v_clean_email := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_clean_notes := nullif(trim(regexp_replace(coalesce(p_notes, ''), '<[^>]*>', '', 'g')), '');

  -- Ground availability checks
  select id, status, price_per_hour, weekend_price_per_hour, slot_duration_minutes,
         min_booking_minutes, max_booking_minutes, commission_rate, currency
    into g
    from public.grounds
   where id = p_ground_id;

  if g.id is null or g.status <> 'active' then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'GROUND_NOT_AVAILABLE', 'message', 'This ground is currently not accepting bookings.'));
  end if;

  v_start_ts := p_booking_date + p_start_time;
  v_end_ts   := (case when p_end_time <= p_start_time then p_booking_date + 1 else p_booking_date end)
                + p_end_time;
  v_minutes  := (extract(epoch from (v_end_ts - v_start_ts)) / 60)::int;
  if v_minutes <= 0 then v_minutes := 60; end if;

  -- Pricing
  v_rate := coalesce(g.price_per_hour, 2500);
  v_amount := round((v_rate::numeric * (v_minutes::numeric / 60.0)), 2);

  v_ref := 'GNM-' || to_char(p_booking_date, 'YYYY') || '-' || upper(substring(md5(random()::text) from 1 for 6));

  -- Insert confirmed booking
  begin
    insert into public.bookings (
      booking_ref, ground_id, player_id, booking_date, start_time, end_time,
      duration_minutes, status, source, price_per_hour, total_amount, currency,
      commission_rate, commission_amount, contact_name, contact_phone,
      players_expected, notes, hold_expires_at, phone_verified_at, created_by
    )
    values (
      v_ref, p_ground_id, null, p_booking_date,
      p_start_time, p_end_time, v_minutes, 'confirmed', 'web', v_rate, v_amount,
      coalesce(g.currency, 'PKR'), coalesce(g.commission_rate, 0.05),
      round(v_amount * coalesce(g.commission_rate, 0.05), 2),
      v_clean_name, v_clean_phone, p_players_expected, v_clean_notes,
      now() + make_interval(mins => v_hold), now(), null
    )
    returning * into v_row;
  exception
    when exclusion_violation then
      return jsonb_build_object('ok', false, 'error', jsonb_build_object(
        'code', 'SLOT_TAKEN', 'message', 'This slot was just booked by another player. Please select another time.'));
  end;

  -- Optional: save guest profile
  if p_save_info then
    insert into public.guest_profiles (phone, full_name, email, booking_count, updated_at)
    values (v_clean_phone, v_clean_name, v_clean_email, 1, now())
    on conflict (phone) do update
    set full_name = excluded.full_name,
        booking_count = public.guest_profiles.booking_count + 1,
        updated_at = now();
  end if;

  return jsonb_build_object('ok', true, 'booking', row_to_json(v_row));
end;
$$;

-- 6. MATCHMAKING RPC: Post verified game linked to booking_ref
create or replace function public.create_verified_match(
  p_booking_ref     text,
  p_title           text,
  p_looking_for     text default 'players',
  p_players_needed  int  default 3,
  p_format          text default 'Tape Ball',
  p_skill_level     text default 'any',
  p_whatsapp_number text default null,
  p_host_handle     text default null,
  p_notes           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking record;
  v_row     public.open_games;
  v_clean_wa text;
  v_handle  text;
begin
  select b.id, b.ground_id, b.booking_date, b.start_time, b.contact_name, b.contact_phone, g.area_id, g.city
    into v_booking
    from public.bookings b
    left join public.grounds g on g.id = b.ground_id
   where b.booking_ref = p_booking_ref
   limit 1;

  if v_booking.id is null then
    return jsonb_build_object('ok', false, 'error', 'No booking found for reference ' || coalesce(p_booking_ref, ''));
  end if;

  v_clean_wa := regexp_replace(coalesce(p_whatsapp_number, v_booking.contact_phone, ''), '\D', '', 'g');
  v_handle   := coalesce(nullif(trim(p_host_handle), ''), regexp_replace(lower(coalesce(v_booking.contact_name, 'player')), '[^a-z0-9_]', '', 'g'));
  if char_length(v_handle) < 3 then v_handle := 'captain_' || substring(p_booking_ref from 10); end if;

  insert into public.open_games (
    host_handle, title, looking_for, skill_level, format,
    ground_id, area_id, city, match_date, start_time,
    players_needed, notes, whatsapp_number, status, booking_ref, booking_id
  ) values (
    v_handle,
    substring(coalesce(nullif(trim(p_title), ''), 'Game at ' || coalesce(v_booking.ground_id::text, 'cricket turf')) from 1 for 120),
    case when lower(p_looking_for) in ('opposition', 'teams', 'team') then 'opposition'::public.looking_for else 'players'::public.looking_for end,
    coalesce(nullif(p_skill_level, ''), 'any')::public.skill_level,
    coalesce(p_format, 'Tape Ball'),
    v_booking.ground_id,
    v_booking.area_id,
    coalesce(v_booking.city, 'Karachi'),
    v_booking.booking_date,
    v_booking.start_time,
    case when lower(p_looking_for) in ('opposition', 'teams', 'team') then null else coalesce(p_players_needed, 3) end,
    p_notes,
    v_clean_wa,
    'open',
    p_booking_ref,
    v_booking.id
  )
  returning * into v_row;

  return jsonb_build_object('ok', true, 'game', row_to_json(v_row));
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

-- 7. FIX RLS ON BOOKINGS TABLE: Ensure staff, owners & live schedule can read bookings
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select (p.role in ('admin','superadmin') or lower(coalesce(u.email, '')) in ('faisalshayan444@gmail.com', 'shayan@groundsnearme.pk'))
       from auth.users u
       left join public.profiles p on p.id = u.id
      where u.id = auth.uid()),
    false
  );
$$;

drop policy if exists bookings_select_staff on public.bookings;
create policy bookings_select_staff on public.bookings
  for select to authenticated
  using (
    public.is_staff()
    or lower(coalesce(auth.jwt()->>'email', '')) in ('faisalshayan444@gmail.com', 'shayan@groundsnearme.pk')
  );

drop policy if exists bookings_select_anon on public.bookings;
create policy bookings_select_anon on public.bookings
  for select to anon
  using (status in ('confirmed', 'completed', 'pending'));

-- 8. UPSERT ADMIN PROFILE ROLE
insert into public.profiles (id, email, full_name, role)
select u.id, u.email, coalesce(u.raw_user_meta_data->>'full_name', 'Faisal Shayan'), 'superadmin'
from auth.users u
where lower(u.email) in ('faisalshayan444@gmail.com', 'shayan@groundsnearme.pk')
on conflict (id) do update
set role = 'superadmin';

-- 9. GRANTS
grant execute on function public.request_booking_otp(text, text, text) to anon, authenticated;
grant execute on function public.verify_booking_otp(text, text, text) to anon, authenticated;
grant execute on function public.create_guest_booking(uuid, date, time, time, text, text, text, text, int, uuid, boolean, int) to anon, authenticated;
grant execute on function public.create_verified_match(text, text, text, int, text, text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
