-- ============================================================================
-- GroundsNearMe — 0001 · extensions + enum types
-- Idempotent: safe to re-run.
-- ============================================================================

create extension if not exists pgcrypto   with schema extensions;
create extension if not exists btree_gist  with schema extensions;
create extension if not exists citext      with schema extensions;

-- All enums created in one pass so the file stays declarative.
do $$
declare
  t record;
begin
  for t in
    select * from (values
      ('user_role',          array['player','owner','admin','superadmin']),
      ('ground_status',      array['draft','pending','active','paused','rejected','archived']),
      ('ground_type',        array['indoor','outdoor','both']),
      ('listing_tier',       array['free','pro']),
      ('booking_status',     array['pending','confirmed','cancelled','completed','no_show','expired']),
      ('payment_status',     array['unpaid','partial','paid','refunded']),
      ('booking_source',     array['web','whatsapp','admin','owner']),
      ('game_status',        array['open','filled','cancelled','expired']),
      ('skill_level',        array['beginner','intermediate','advanced','any']),
      ('looking_for',        array['players','opposition']),
      ('interest_status',    array['interested','accepted','declined','withdrawn']),
      ('subscription_status',array['unpaid','paid','overdue','waived','cancelled']),
      ('payment_method',     array['jazzcash','easypaisa','bank_transfer','cash','other']),
      ('commission_status',  array['accrued','invoiced','collected','written_off']),
      ('lead_status',        array['new','contacted','onboarding','listed','rejected'])
    ) as v(name, labels)
  loop
    if not exists (
      select 1 from pg_type
      where typname = t.name and typnamespace = 'public'::regnamespace
    ) then
      execute format(
        'create type public.%I as enum (%s)',
        t.name,
        (select string_agg(quote_literal(l), ',') from unnest(t.labels) as l)
      );
    end if;
  end loop;
end
$$;

-- Shared updated_at trigger function.
create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

comment on function public.tg_set_updated_at() is
  'BEFORE UPDATE trigger: stamps updated_at.';
