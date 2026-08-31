-- ============================================================================
-- GroundsNearMe — 0009 · availability engine
-- Single source of truth for "which slots are open". The public site, the
-- owner dashboard and the booking RPC all go through these two functions.
--
-- Contract: returns one row per bookable slot on p_date, in ground-local
-- (Asia/Karachi) wall-clock time. Zero rows means the ground has no schedule
-- for that weekday at all — render that as "Closed".
-- ============================================================================

create or replace function public.get_ground_availability(
  p_ground_id uuid,
  p_date      date
)
returns table (
  slot_start   time,
  slot_end     time,
  starts_at    timestamp,
  ends_at      timestamp,
  is_available boolean,
  reason       text,
  price        numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  g            record;
  h            record;
  v_now        timestamp := (now() at time zone 'Asia/Karachi');
  v_today      date;
  v_open       timestamp;
  v_close      timestamp;
  v_step       interval;
  v_cur        timestamp;
  v_slot_end   timestamp;
  v_dow        smallint;
  v_rate       integer;
  v_is_weekend boolean;
  v_closed_day boolean;
  v_out_window boolean;
  v_booked     boolean;
begin
  v_today := v_now::date;

  select id, status, price_per_hour, weekend_price_per_hour,
         slot_duration_minutes, advance_booking_days
    into g
    from public.grounds
   where id = p_ground_id;

  if g.id is null or g.status <> 'active' then
    return;
  end if;

  v_dow := extract(dow from p_date)::smallint;

  select * into h
    from public.ground_hours
   where ground_id = p_ground_id and day_of_week = v_dow;

  if h.id is null or h.is_closed then
    return;                                   -- no schedule this weekday
  end if;

  v_is_weekend := v_dow in (0, 6);
  v_rate := case
              when v_is_weekend then coalesce(g.weekend_price_per_hour, g.price_per_hour)
              else g.price_per_hour
            end;

  v_closed_day := exists (
    select 1 from public.ground_closures c
     where c.ground_id = p_ground_id
       and p_date between c.starts_on and c.ends_on
  );

  v_out_window := p_date < v_today
               or p_date > (v_today + g.advance_booking_days);

  v_open  := p_date + h.opens_at;
  v_close := (case when h.closes_at <= h.opens_at then p_date + 1 else p_date end) + h.closes_at;
  v_step  := make_interval(mins => g.slot_duration_minutes);

  v_cur := v_open;
  while v_cur + v_step <= v_close loop
    v_slot_end := v_cur + v_step;

    v_booked := exists (
      select 1
        from public.bookings b
       where b.ground_id = p_ground_id
         and b.status in ('pending','confirmed')
         and (b.status <> 'pending'
              or b.hold_expires_at is null
              or b.hold_expires_at > now())          -- stale holds don't block
         and b.slot && tsrange(v_cur, v_slot_end, '[)')
    );

    slot_start := v_cur::time;
    slot_end   := v_slot_end::time;
    starts_at  := v_cur;
    ends_at    := v_slot_end;
    price      := round(v_rate * (g.slot_duration_minutes / 60.0), 0);

    if v_out_window then
      is_available := false; reason := 'out_of_window';
    elsif v_closed_day then
      is_available := false; reason := 'closed';
    elsif v_cur <= v_now then
      is_available := false; reason := 'past';
    elsif v_booked then
      is_available := false; reason := 'booked';
    else
      is_available := true;  reason := null;
    end if;

    return next;
    v_cur := v_slot_end;
  end loop;

  return;
end
$$;

comment on function public.get_ground_availability(uuid, date) is
  'Slot grid for one ground on one date, Asia/Karachi wall-clock.';

-- ---------------------------------------------------------------------------
-- Cheap "Slots Open" / "Full Today" badge input for list views.
-- ---------------------------------------------------------------------------
create or replace function public.count_open_slots(
  p_ground_id uuid,
  p_date      date
)
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(count(*), 0)::int
    from public.get_ground_availability(p_ground_id, p_date) a
   where a.is_available;
$$;

grant execute on function public.get_ground_availability(uuid, date) to anon, authenticated;
grant execute on function public.count_open_slots(uuid, date)        to anon, authenticated;
