-- ============================================================================
-- GroundsNearMe — 0022 · maintenance jobs
-- Called from the Worker's scheduled (cron) handler, and optionally from
-- pg_cron if it is enabled on the project.
-- ============================================================================

create or replace function public.expire_stale_bookings()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count int;
begin
  with expired as (
    update public.bookings
       set status = 'expired'
     where status = 'pending'
       and hold_expires_at is not null
       and hold_expires_at < now()
    returning 1
  )
  select count(*) into v_count from expired;

  return coalesce(v_count, 0);
end
$$;

comment on function public.expire_stale_bookings() is
  'Releases pending slots whose hold lapsed. Idempotent.';

-- ---------------------------------------------------------------------------

create or replace function public.expire_past_open_games()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count int;
begin
  with expired as (
    update public.open_games
       set status = 'expired'
     where status = 'open'
       and match_date < (now() at time zone 'Asia/Karachi')::date
    returning 1
  )
  select count(*) into v_count from expired;

  return coalesce(v_count, 0);
end
$$;

-- ---------------------------------------------------------------------------
-- Mark yesterday's confirmed bookings as completed so commission accrues.
-- ---------------------------------------------------------------------------

create or replace function public.complete_finished_bookings()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count int;
  v_now   timestamp := (now() at time zone 'Asia/Karachi');
begin
  with done as (
    update public.bookings b
       set status = 'completed'
     where b.status = 'confirmed'
       and upper(b.slot) < v_now
    returning 1
  )
  select count(*) into v_count from done;

  return coalesce(v_count, 0);
end
$$;

comment on function public.complete_finished_bookings() is
  'Confirmed bookings whose slot has ended become completed, which is what '
  'triggers commission accrual.';

-- ---------------------------------------------------------------------------
-- Roll a monthly premium invoice row for every pro-tier owner. Manual /
-- semi-automated billing: this creates the unpaid cycle, a human sends the
-- JazzCash / EasyPaisa link, then the row is flipped to paid.
-- ---------------------------------------------------------------------------

create or replace function public.open_subscription_cycle(
  p_month  date default null,
  p_amount numeric default 2000
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Karachi')::date))::date;
  v_end   date := (v_start + interval '1 month')::date;
  v_made  int;
begin
  if not public.is_staff() then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not authorised.'));
  end if;

  with created as (
    insert into public.owner_subscriptions (
      owner_id, ground_id, tier, cycle_start, cycle_end, amount, status, created_by
    )
    select g.owner_id, g.id, 'pro', v_start, v_end, p_amount, 'unpaid', auth.uid()
      from public.grounds g
     where g.listing_tier = 'pro'
       and g.status = 'active'
       and g.owner_id is not null
    on conflict (owner_id, ground_id, cycle_start) do nothing
    returning 1
  )
  select count(*) into v_made from created;

  return jsonb_build_object('ok', true, 'cycles_created', coalesce(v_made, 0),
                            'cycle_start', v_start, 'cycle_end', v_end);
end
$$;

revoke all on function public.expire_stale_bookings()        from anon, authenticated;
revoke all on function public.expire_past_open_games()       from anon, authenticated;
revoke all on function public.complete_finished_bookings()   from anon, authenticated;
grant  execute on function public.open_subscription_cycle(date, numeric) to authenticated;
