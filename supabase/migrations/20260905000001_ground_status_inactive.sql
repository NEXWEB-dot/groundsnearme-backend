-- ============================================================================
-- GroundsNearMe — 0025 · ground_status inactive value
-- Adds 'inactive' to ground_status enum so grounds can be marked inactive
-- without deletion, and ensures consistency across admin and owner portals.
-- ============================================================================

-- Add 'inactive' to ground_status enum if not present.
alter type public.ground_status add value if not exists 'inactive';

-- Re-assert owns_ground to ensure it checks owner_id cleanly
create or replace function public.owns_ground(p_ground_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.grounds g
     where g.id = p_ground_id and g.owner_id = auth.uid()
  );
$$;

grant execute on function public.owns_ground(uuid) to authenticated;
