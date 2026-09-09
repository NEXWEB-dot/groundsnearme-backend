-- ============================================================================
-- GroundsNearMe — 0020 · finance views (private dashboard inputs)
-- security_invoker = on, so the caller's RLS applies: commission rows are
-- visible to superadmin only, which makes these views superadmin-only too.
-- ============================================================================

create or replace view public.v_monthly_commission
  with (security_invoker = on) as
select
  cl.earned_month                                                    as month,
  count(*)                                                           as bookings,
  sum(cl.gross_amount)                                               as gross_amount,
  sum(cl.commission_amount)                                          as commission_amount,
  sum(cl.commission_amount) filter (where cl.status = 'collected')    as collected_amount,
  sum(cl.commission_amount) filter (where cl.status in ('accrued','invoiced')) as outstanding_amount
from public.commission_ledger cl
where cl.status <> 'written_off'
group by cl.earned_month;

comment on view public.v_monthly_commission is
  'Commission earned per month. Superadmin only (RLS on commission_ledger).';

-- ---------------------------------------------------------------------------

create or replace view public.v_commission_by_ground
  with (security_invoker = on) as
select
  cl.ground_id,
  g.name                                as ground_name,
  g.slug                                as ground_slug,
  a.name                                as area,
  count(*)                              as bookings,
  sum(cl.gross_amount)                  as gross_amount,
  sum(cl.commission_amount)             as commission_amount,
  max(cl.earned_month)                  as last_earned_month
from public.commission_ledger cl
join public.grounds g on g.id = cl.ground_id
left join public.areas a on a.id = g.area_id
where cl.status <> 'written_off'
group by cl.ground_id, g.name, g.slug, a.name;

comment on view public.v_commission_by_ground is
  'Which venues generate the most commission. Superadmin only.';

-- ---------------------------------------------------------------------------

create or replace view public.v_monthly_subscription_revenue
  with (security_invoker = on) as
select
  date_trunc('month', s.cycle_start)::date                     as month,
  count(*)                                                     as cycles,
  count(*) filter (where s.status = 'paid')                    as paid_cycles,
  count(*) filter (where s.status in ('unpaid','overdue'))      as unpaid_cycles,
  sum(s.amount) filter (where s.status = 'paid')               as paid_amount,
  sum(s.amount) filter (where s.status in ('unpaid','overdue')) as unpaid_amount
from public.owner_subscriptions s
group by date_trunc('month', s.cycle_start);

comment on view public.v_monthly_subscription_revenue is
  'Premium-tier revenue, tracked separately from commission revenue.';

-- ---------------------------------------------------------------------------
-- Booking volume drives commission, so it is tracked in its own right.
-- Visible to staff (bookings RLS), which includes superadmin.
-- ---------------------------------------------------------------------------

create or replace view public.v_monthly_bookings
  with (security_invoker = on) as
select
  date_trunc('month', b.booking_date)::date                          as month,
  count(*)                                                           as total_bookings,
  count(*) filter (where b.status = 'completed')                     as completed,
  count(*) filter (where b.status = 'confirmed')                     as confirmed,
  count(*) filter (where b.status in ('cancelled','expired'))         as cancelled,
  count(distinct b.ground_id)                                        as active_grounds,
  count(distinct b.player_id)                                        as unique_players,
  sum(b.total_amount) filter (where b.status in ('confirmed','completed')) as gross_booked_value
from public.bookings b
group by date_trunc('month', b.booking_date);

comment on view public.v_monthly_bookings is
  'Platform-wide booking volume per month.';

grant select on public.v_monthly_commission            to authenticated;
grant select on public.v_commission_by_ground          to authenticated;
grant select on public.v_monthly_subscription_revenue  to authenticated;
grant select on public.v_monthly_bookings              to authenticated;
