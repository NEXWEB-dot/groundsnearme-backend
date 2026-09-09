-- ============================================================================
-- GroundsNearMe — 0021 · finance_overview (private dashboard, one round trip)
-- Superadmin only, enforced inside the function. Returns headline totals plus
-- the three trends the dashboard charts: commission, subscriptions, bookings.
-- ============================================================================

create or replace function public.finance_overview(
  p_months int default 12
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_months int  := least(greatest(coalesce(p_months, 12), 1), 60);
  v_from   date := (date_trunc('month', (now() at time zone 'Asia/Karachi'))
                    - make_interval(months => v_months - 1))::date;
  v_result jsonb;
begin
  if not public.is_superadmin() then
    return jsonb_build_object('ok', false, 'error',
      jsonb_build_object('code', 'FORBIDDEN', 'message', 'Not authorised.'));
  end if;

  select jsonb_build_object(
    'ok', true,
    'window', jsonb_build_object('from', v_from, 'months', v_months),

    'totals', (
      select jsonb_build_object(
        'commission_all_time',   coalesce(sum(cl.commission_amount), 0),
        'commission_collected',  coalesce(sum(cl.commission_amount)
                                   filter (where cl.status = 'collected'), 0),
        'commission_outstanding',coalesce(sum(cl.commission_amount)
                                   filter (where cl.status in ('accrued','invoiced')), 0),
        'commissionable_bookings', count(*)
      )
      from public.commission_ledger cl
      where cl.status <> 'written_off'
    ),

    'subscriptions', (
      select jsonb_build_object(
        'paid_all_time',   coalesce(sum(s.amount) filter (where s.status = 'paid'), 0),
        'unpaid_current',  coalesce(sum(s.amount)
                             filter (where s.status in ('unpaid','overdue')), 0),
        'active_pro_owners', count(distinct s.owner_id)
                               filter (where s.status = 'paid'
                                       and s.cycle_end >= (now() at time zone 'Asia/Karachi')::date)
      )
      from public.owner_subscriptions s
    ),

    'bookings', (
      select jsonb_build_object(
        'total',      count(*),
        'completed',  count(*) filter (where b.status = 'completed'),
        'this_month', count(*) filter (
                        where date_trunc('month', b.booking_date)
                            = date_trunc('month', (now() at time zone 'Asia/Karachi'))),
        'gross_booked_value', coalesce(sum(b.total_amount)
                                filter (where b.status in ('confirmed','completed')), 0)
      )
      from public.bookings b
    ),

    'grounds', (
      select jsonb_build_object(
        'active', count(*) filter (where g.status = 'active'),
        'pending', count(*) filter (where g.status = 'pending'),
        'pro',     count(*) filter (where g.listing_tier = 'pro' and g.status = 'active')
      )
      from public.grounds g
    ),

    'commission_trend', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'month',      m.month,
               'commission', coalesce(v.commission_amount, 0),
               'collected',  coalesce(v.collected_amount, 0),
               'bookings',   coalesce(v.bookings, 0)
             ) order by m.month), '[]'::jsonb)
      from (select generate_series(v_from, date_trunc('month',
                     (now() at time zone 'Asia/Karachi'))::date,
                     interval '1 month')::date as month) m
      left join public.v_monthly_commission v on v.month = m.month
    ),

    'subscription_trend', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'month',  m.month,
               'paid',   coalesce(v.paid_amount, 0),
               'unpaid', coalesce(v.unpaid_amount, 0)
             ) order by m.month), '[]'::jsonb)
      from (select generate_series(v_from, date_trunc('month',
                     (now() at time zone 'Asia/Karachi'))::date,
                     interval '1 month')::date as month) m
      left join public.v_monthly_subscription_revenue v on v.month = m.month
    ),

    'booking_trend', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'month',     m.month,
               'bookings',  coalesce(v.total_bookings, 0),
               'completed', coalesce(v.completed, 0),
               'value',     coalesce(v.gross_booked_value, 0)
             ) order by m.month), '[]'::jsonb)
      from (select generate_series(v_from, date_trunc('month',
                     (now() at time zone 'Asia/Karachi'))::date,
                     interval '1 month')::date as month) m
      left join public.v_monthly_bookings v on v.month = m.month
    ),

    'top_grounds', (
      select coalesce(jsonb_agg(t order by (t->>'commission_amount')::numeric desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'ground_id',         v.ground_id,
                 'ground_name',       v.ground_name,
                 'ground_slug',       v.ground_slug,
                 'area',              v.area,
                 'bookings',          v.bookings,
                 'gross_amount',      v.gross_amount,
                 'commission_amount', v.commission_amount
               ) as t
        from public.v_commission_by_ground v
        order by v.commission_amount desc
        limit 20
      ) s
    )
  ) into v_result;

  return v_result;
end
$$;

revoke all on function public.finance_overview(int) from anon;
grant execute on function public.finance_overview(int) to authenticated;
