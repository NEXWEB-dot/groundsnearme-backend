-- ============================================================================
-- GroundsNearMe — Add booking_ref and booking_id to open_games
-- Enables linking matchmaking games to confirmed ground bookings
-- ============================================================================

alter table public.open_games 
  add column if not exists booking_ref text,
  add column if not exists booking_id uuid references public.bookings(id) on delete set null;

create index if not exists open_games_booking_ref_idx on public.open_games (booking_ref);
create index if not exists open_games_booking_id_idx on public.open_games (booking_id);

-- Reload schema cache in PostgREST
notify pgrst, 'reload schema';
