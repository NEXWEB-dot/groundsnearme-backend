-- ============================================================================
-- GroundsNearMe — 0028 · Admin Owner Onboarding & Credentials Management
-- Provides an RPC function for staff to onboard turf owners, create/update their
-- auth credentials, assign their ground, set future commission rates, and log
-- an audit trail of access grants.
-- ============================================================================

create or replace function public.admin_onboard_owner(
  p_ground_id        uuid,
  p_owner_name       text,
  p_whatsapp         text,
  p_email            text,
  p_password         text,
  p_commission_rate  numeric default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id     uuid;
  v_ground_name text;
  v_clean_wa    text;
  v_clean_email text;
  v_comm        numeric(5,4);
begin
  -- 1. Security check: Only staff (admin or superadmin) may onboard owners
  if not public.is_staff() then
    return jsonb_build_object(
      'ok', false,
      'error', 'Unauthorized: Only staff members can onboard turf owners.'
    );
  end if;

  -- 2. Verify ground
  select name into v_ground_name from public.grounds where id = p_ground_id;
  if v_ground_name is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'Ground not found.'
    );
  end if;

  v_clean_email := lower(trim(p_email));
  if v_clean_email is null or v_clean_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' then
    return jsonb_build_object(
      'ok', false,
      'error', 'Valid email address is required.'
    );
  end if;

  if length(p_password) < 6 then
    return jsonb_build_object(
      'ok', false,
      'error', 'Password must be at least 6 characters.'
    );
  end if;

  v_clean_wa := regexp_replace(coalesce(p_whatsapp, ''), '[^0-9]', '', 'g');
  if v_clean_wa like '03%' and length(v_clean_wa) = 11 then
    v_clean_wa := '92' || substr(v_clean_wa, 2);
  elsif v_clean_wa like '0092%' then
    v_clean_wa := substr(v_clean_wa, 3);
  end if;

  v_comm := coalesce(p_commission_rate, 0);
  if v_comm < 0 or v_comm > 0.5 then
    v_comm := 0;
  end if;

  -- 3. Upsert user in auth.users
  select id into v_user_id from auth.users where lower(email) = v_clean_email;

  if v_user_id is null then
    v_user_id := gen_random_uuid();
    insert into auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at
    ) values (
      '00000000-0000-0000-0000-000000000000',
      v_user_id,
      'authenticated',
      'authenticated',
      v_clean_email,
      crypt(p_password, gen_salt('bf')),
      now(),
      jsonb_build_object('provider', 'email', 'providers', array['email']),
      jsonb_build_object(
        'full_name', p_owner_name,
        'whatsapp_number', v_clean_wa,
        'account_type', 'owner'
      ),
      now(),
      now()
    );
  else
    -- Update existing user credentials and ensure email is confirmed
    update auth.users
       set encrypted_password = crypt(p_password, gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()),
           raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
             'full_name', p_owner_name,
             'whatsapp_number', v_clean_wa,
             'account_type', 'owner'
           ),
           updated_at = now()
     where id = v_user_id;
  end if;

  -- 4. Upsert public.profiles
  insert into public.profiles (
    id, role, full_name, email, whatsapp_number, is_active
  ) values (
    v_user_id,
    'owner',
    p_owner_name,
    v_clean_email::extensions.citext,
    nullif(v_clean_wa, ''),
    true
  )
  on conflict (id) do update
    set role = 'owner',
        full_name = coalesce(excluded.full_name, profiles.full_name),
        whatsapp_number = coalesce(excluded.whatsapp_number, profiles.whatsapp_number),
        is_active = true,
        updated_at = now();

  -- 5. Link Ground to this owner and save commission rate
  update public.grounds
     set owner_id = v_user_id,
         commission_rate = v_comm,
         contact_name = coalesce(p_owner_name, contact_name),
         whatsapp_number = coalesce(nullif(v_clean_wa, ''), whatsapp_number),
         updated_at = now()
   where id = p_ground_id;

  -- 6. Record in audit trail
  insert into public.audit_log (
    actor_id, actor_role, action, entity, entity_id, diff
  ) values (
    auth.uid(),
    public.current_app_role(),
    'onboard_owner',
    'grounds',
    p_ground_id::text,
    jsonb_build_object(
      'owner_id', v_user_id,
      'owner_name', p_owner_name,
      'email', v_clean_email,
      'whatsapp', v_clean_wa,
      'ground_name', v_ground_name,
      'commission_rate', v_comm
    )
  );

  return jsonb_build_object(
    'ok', true,
    'owner_id', v_user_id,
    'ground_id', p_ground_id,
    'ground_name', v_ground_name,
    'owner_name', p_owner_name,
    'email', v_clean_email,
    'whatsapp_number', v_clean_wa,
    'commission_rate', v_comm,
    'created_at', now()
  );
exception
  when others then
    return jsonb_build_object(
      'ok', false,
      'error', SQLERRM
    );
end;
$$;

-- Grant execution to authenticated staff
grant execute on function public.admin_onboard_owner(uuid, text, text, text, text, numeric) to authenticated, anon;
