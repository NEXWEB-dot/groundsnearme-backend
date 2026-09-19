-- ============================================================================
-- GroundsNearMe — 0028 · Server-Side Admin Role Verification RPC
-- Protects admin endpoints from client-side spoofing by verifying role in profiles table.
-- ============================================================================

create or replace function public.check_admin_role()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id  uuid := auth.uid();
  v_role     text;
  v_email    text;
  v_is_staff boolean := false;
  v_is_super boolean := false;
begin
  if v_user_id is null then
    return jsonb_build_object(
      'authenticated', false,
      'is_staff', false,
      'is_superadmin', false,
      'role', null,
      'error', 'Not authenticated'
    );
  end if;

  select p.role::text, coalesce(p.email::text, u.email)
    into v_role, v_email
    from auth.users u
    left join public.profiles p on p.id = u.id
   where u.id = v_user_id;

  if v_role in ('admin', 'superadmin') then
    v_is_staff := true;
  end if;

  -- Superadmin check
  if v_role = 'superadmin' or lower(coalesce(v_email, '')) in ('faisalshayan444@gmail.com', 'shayan@groundsnearme.pk') then
    v_is_super := true;
    v_is_staff := true;
  end if;

  return jsonb_build_object(
    'authenticated', true,
    'is_staff', v_is_staff,
    'is_superadmin', v_is_super,
    'role', coalesce(v_role, 'player'),
    'user_id', v_user_id,
    'email', v_email
  );
end;
$$;

grant execute on function public.check_admin_role() to authenticated;
grant execute on function public.is_staff() to authenticated;
grant execute on function public.is_superadmin() to authenticated;
