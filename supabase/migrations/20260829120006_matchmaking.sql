-- ============================================================================
-- GroundsNearMe — 0006 · matchmaking (open games + interests)
-- ============================================================================

create table if not exists public.open_games (
  id              uuid primary key default gen_random_uuid(),
  host_id         uuid references public.profiles(id) on delete set null,
  host_handle     text not null,
  title           text not null check (char_length(title) between 6 and 120),
  looking_for     public.looking_for not null default 'players',
  skill_level     public.skill_level not null default 'any',
  format          text,
  ground_id       uuid references public.grounds(id) on delete set null,
  area_id         uuid references public.areas(id) on delete set null,
  city            text not null default 'Karachi',
  match_date      date not null,
  start_time      time,
  players_needed  int check (players_needed is null or players_needed between 1 and 22),
  notes           text,
  whatsapp_number text,
  status          public.game_status not null default 'open',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint open_games_whatsapp_format
    check (whatsapp_number is null or whatsapp_number ~ '^[0-9]{10,15}$'),
  constraint open_games_host_handle_format
    check (host_handle ~ '^[a-z0-9_]{3,24}$'),
  constraint open_games_needs_count
    check (looking_for <> 'players' or players_needed is not null)
);

comment on table public.open_games is
  'A player-posted request: "need N players" or "team looking for opposition".';
comment on column public.open_games.host_handle is
  'Denormalised profile handle, rendered as @handle on the public site.';

create index if not exists open_games_status_date_idx
  on public.open_games (status, match_date);
create index if not exists open_games_area_idx  on public.open_games (area_id)  where status = 'open';
create index if not exists open_games_host_idx  on public.open_games (host_id);
create index if not exists open_games_recent_idx on public.open_games (created_at desc);

drop trigger if exists open_games_set_updated_at on public.open_games;
create trigger open_games_set_updated_at
  before update on public.open_games
  for each row execute function public.tg_set_updated_at();

-- ---------------------------------------------------------------------------

create table if not exists public.open_game_interests (
  id            uuid primary key default gen_random_uuid(),
  open_game_id  uuid not null references public.open_games(id) on delete cascade,
  player_id     uuid not null references public.profiles(id) on delete cascade,
  message       text,
  status        public.interest_status not null default 'interested',
  created_at    timestamptz not null default now(),
  constraint open_game_interests_unique unique (open_game_id, player_id)
);

comment on table public.open_game_interests is
  'One row per player expressing interest in an open game. Drives the '
  '"N players expressed interest" counter.';

create index if not exists open_game_interests_game_idx
  on public.open_game_interests (open_game_id);
create index if not exists open_game_interests_player_idx
  on public.open_game_interests (player_id);

-- A host cannot express interest in their own game.
create or replace function public.tg_interest_not_host()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (
    select 1 from public.open_games g
    where g.id = new.open_game_id and g.host_id = new.player_id
  ) then
    raise exception 'HOST_CANNOT_JOIN_OWN_GAME' using errcode = '23514';
  end if;
  return new;
end
$$;

drop trigger if exists interest_not_host on public.open_game_interests;
create trigger interest_not_host
  before insert on public.open_game_interests
  for each row execute function public.tg_interest_not_host();

-- Flip a game to `filled` once enough players are accepted.
create or replace function public.tg_interest_maybe_fill()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_needed  int;
  v_accepted int;
begin
  select players_needed into v_needed
  from public.open_games where id = new.open_game_id;

  if v_needed is null then
    return new;
  end if;

  select count(*) into v_accepted
  from public.open_game_interests
  where open_game_id = new.open_game_id and status = 'accepted';

  if v_accepted >= v_needed then
    update public.open_games
       set status = 'filled'
     where id = new.open_game_id and status = 'open';
  end if;

  return new;
end
$$;

drop trigger if exists interest_maybe_fill on public.open_game_interests;
create trigger interest_maybe_fill
  after insert or update of status on public.open_game_interests
  for each row execute function public.tg_interest_maybe_fill();
