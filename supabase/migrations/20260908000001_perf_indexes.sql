-- ============================================================================
-- GroundsNearMe — 0026 · Performance Indexes for Production Launch
-- Optimizes query performance, reduces query execution time, and minimizes
-- database CPU/memory footprint under high concurrent load.
-- ============================================================================

-- Fast lookup for Admin Leads CRM by status and chronological recency
create index if not exists ground_leads_status_created_idx
  on public.ground_leads (status, created_at desc);

-- Fast lookup for Ground slot availability & date-range bookings
create index if not exists bookings_ground_date_status_idx
  on public.bookings (ground_id, booking_date, status);

-- Fast lookup for Player bookings history
create index if not exists bookings_player_date_idx
  on public.bookings (player_id, booking_date desc);

-- Fast lookup for Owner subscriptions oversight & monthly billing cycles
create index if not exists owner_subs_status_cycle_idx
  on public.owner_subscriptions (status, cycle_start desc);

-- Fast filtering for active featured and tiered listings
create index if not exists grounds_active_tier_idx
  on public.grounds (status, listing_tier, is_featured)
  where status = 'active';

comment on index public.ground_leads_status_created_idx is
  'Optimizes Admin WhatsApp Leads CRM list queries sorted by recency.';
comment on index public.bookings_ground_date_status_idx is
  'Accelerates slot grid checks and daily booking lookups in owner & player surfaces.';
comment on index public.owner_subs_status_cycle_idx is
  'Accelerates subscription status checks and billing cycle management.';
