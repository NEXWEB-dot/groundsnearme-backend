-- ============================================================================
-- GroundsNearMe — 0024 · bootstrap staff accounts
--
-- Roles cannot be self-assigned at signup (see handle_new_user), so the first
-- superadmin has to be promoted here, once, by hand.
--
-- HOW TO USE
--   1. Sign up normally through Supabase Auth with the account that should own
--      the private financial dashboard.
--   2. Edit the email below, then run this file (Supabase SQL editor or
--      `supabase db push`).
--   3. Verify:  select id, role from public.profiles where role <> 'player';
--
-- Re-running is safe. If the email does not exist yet the statement is a no-op
-- and prints a notice.
-- ============================================================================

do $$
declare
  -- ▼▼▼ EDIT THIS ▼▼▼
  v_superadmin_email text := 'shayan@groundsnearme.pk';
  -- ▲▲▲ EDIT THIS ▲▲▲
  v_id uuid;
begin
  select u.id into v_id
    from auth.users u
   where lower(u.email) = lower(v_superadmin_email)
   limit 1;

  if v_id is null then
    raise notice 'bootstrap: no auth user for % — sign up first, then re-run.', v_superadmin_email;
    return;
  end if;

  insert into public.profiles (id, role, email)
  values (v_id, 'superadmin', v_superadmin_email::extensions.citext)
  on conflict (id) do update set role = 'superadmin';

  raise notice 'bootstrap: % promoted to superadmin (%).', v_superadmin_email, v_id;
end
$$;

-- ---------------------------------------------------------------------------
-- Promoting additional staff later (admin, not superadmin):
--
--   update public.profiles
--      set role = 'admin'
--    where id = (select id from auth.users where email = 'teammate@example.com');
--
-- Note: `admin` can manage grounds, bookings and onboarding leads but CANNOT
-- read commission_ledger or call finance_overview(). Only `superadmin` can.
-- ---------------------------------------------------------------------------
