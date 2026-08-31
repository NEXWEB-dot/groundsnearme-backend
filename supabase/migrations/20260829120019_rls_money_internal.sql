-- ============================================================================
-- GroundsNearMe — 0019 · RLS: money + internal tables
--   owner_subscriptions : owner sees own cycles; staff manage
--   commission_ledger   : SUPERADMIN ONLY — this is the private P&L
--   ground_leads        : staff only
--   audit_log           : superadmin read only
-- ============================================================================

drop policy if exists subs_select_owner on public.owner_subscriptions;
drop policy if exists subs_staff        on public.owner_subscriptions;

create policy subs_select_owner on public.owner_subscriptions
  for select to authenticated
  using (owner_id = auth.uid());

create policy subs_staff on public.owner_subscriptions
  for all to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- Owners can look but never touch: no owner update/insert policy exists, so
-- flipping a cycle to `paid` is staff-only.

-- ---------------------------------------------------------------------------
-- commission_ledger — deliberately invisible to owners and to non-superadmin
-- staff. The private financial dashboard is the only consumer.
-- ---------------------------------------------------------------------------
drop policy if exists ledger_superadmin on public.commission_ledger;

create policy ledger_superadmin on public.commission_ledger
  for all to authenticated
  using (public.is_superadmin())
  with check (public.is_superadmin());

-- ---------------------------------------------------------------------------
-- ground_leads — internal onboarding queue.
-- ---------------------------------------------------------------------------
drop policy if exists leads_staff on public.ground_leads;

create policy leads_staff on public.ground_leads
  for all to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- audit_log — append-only via public.log_audit(); readable by superadmin.
-- ---------------------------------------------------------------------------
drop policy if exists audit_select_superadmin on public.audit_log;

create policy audit_select_superadmin on public.audit_log
  for select to authenticated
  using (public.is_superadmin());

revoke insert, update, delete on public.audit_log from anon, authenticated;
