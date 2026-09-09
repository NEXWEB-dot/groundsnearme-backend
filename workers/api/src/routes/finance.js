/**
 * Private financial dashboard — superadmin only.
 *
 * Gated twice on purpose: RLS restricts commission_ledger and the audit log to
 * superadmin, and finance_overview() re-checks is_superadmin() before it
 * returns a single number. A plain `admin` running the internal dashboard gets a
 * clean 403 here, not a partially-filled P&L.
 *
 * Subscription revenue is kept separate from commission revenue throughout —
 * they are different businesses and mixing them would hide which one is
 * actually working.
 */

import { json, unwrapRpc } from '../lib/http.js';
import { requireSuperadmin } from '../lib/auth.js';
import { sbRpc, sbSelect } from '../lib/supabase.js';
import { priceLabel } from '../lib/shape.js';
import { int, isoDate, oneOf, str } from '../lib/validate.js';

const MONTH_FMT = new Intl.DateTimeFormat('en-GB', { month: 'short', year: 'numeric' });

/** "2026-08-01" → "Aug 2026", so charts can label axes without extra JS. */
function monthLabel(value) {
  const d = new Date(`${String(value).slice(0, 10)}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? String(value) : MONTH_FMT.format(d);
}

const withMonthLabels = (rows) =>
  (Array.isArray(rows) ? rows : []).map((r) => ({ ...r, month_label: monthLabel(r.month) }));

export async function overview(request, env, { ctx }) {
  await requireSuperadmin(ctx, env);
  const q = new URL(request.url).searchParams;

  const payload = unwrapRpc(
    await sbRpc(
      env,
      'finance_overview',
      { p_months: int(q.get('months'), 'months', { required: false, min: 1, max: 36 }) ?? 12 },
      { token: ctx.token },
    ),
  );

  const totals = payload.totals || {};
  const subs = payload.subscriptions || {};

  return json({
    window: payload.window || null,
    totals: {
      ...totals,
      commission_all_time_label: priceLabel(totals.commission_all_time),
      commission_collected_label: priceLabel(totals.commission_collected),
      commission_outstanding_label: priceLabel(totals.commission_outstanding),
    },
    subscriptions: {
      ...subs,
      paid_all_time_label: priceLabel(subs.paid_all_time),
      unpaid_current_label: priceLabel(subs.unpaid_current),
    },
    // Kept apart so the dashboard can show two revenue lines, not one blended one.
    revenue: {
      commission: Number(totals.commission_collected || 0),
      subscriptions: Number(subs.paid_all_time || 0),
      combined:
        Number(totals.commission_collected || 0) + Number(subs.paid_all_time || 0),
      combined_label: priceLabel(
        Number(totals.commission_collected || 0) + Number(subs.paid_all_time || 0),
      ),
    },
    bookings: payload.bookings || {},
    grounds: payload.grounds || {},
    commission_trend: withMonthLabels(payload.commission_trend),
    subscription_trend: withMonthLabels(payload.subscription_trend),
    booking_trend: withMonthLabels(payload.booking_trend),
    top_grounds: (payload.top_grounds || []).map((g) => ({
      ...g,
      gross_label: priceLabel(g.gross_amount),
      commission_label: priceLabel(g.commission_amount),
    })),
  });
}

/** The row-level ledger behind the totals, for reconciliation. */
export async function ledger(request, env, { ctx }) {
  await requireSuperadmin(ctx, env);
  const q = new URL(request.url).searchParams;

  const status = oneOf(q.get('status'), 'status',
    ['accrued', 'invoiced', 'collected', 'written_off']);
  const month = isoDate(q.get('month'), 'month', { required: false });
  const limit = int(q.get('limit'), 'limit', { required: false, min: 1, max: 500 }) ?? 100;
  const offset = int(q.get('offset'), 'offset', { required: false, min: 0, max: 100000 }) ?? 0;

  let path = 'commission_ledger?select=*,ground:grounds(id,slug,name),booking:bookings(booking_ref,booking_date)';
  if (status) path += `&status=eq.${status}`;
  if (month) path += `&earned_month=eq.${month.slice(0, 8)}01`;
  path += `&order=earned_month.desc,created_at.desc&limit=${limit}&offset=${offset}`;

  const rows = await sbSelect(env, path, { token: ctx.token });
  const items = (rows || []).map((r) => ({
    ...r,
    month_label: monthLabel(r.earned_month),
    gross_label: priceLabel(r.gross_amount, r.currency),
    commission_label: priceLabel(r.commission_amount, r.currency),
  }));

  return json({
    items,
    total: items.length,
    limit,
    offset,
    sum_commission: items.reduce((s, i) => s + Number(i.commission_amount || 0), 0),
  });
}

/** Who changed what. Superadmin-read only; nothing can write it over the API. */
export async function auditLog(request, env, { ctx }) {
  await requireSuperadmin(ctx, env);
  const q = new URL(request.url).searchParams;

  const entity = str(q.get('entity'), 'entity', { required: false, max: 60 });
  const limit = int(q.get('limit'), 'limit', { required: false, min: 1, max: 200 }) ?? 100;
  const offset = int(q.get('offset'), 'offset', { required: false, min: 0, max: 100000 }) ?? 0;

  let path = 'audit_log?select=id,actor_id,actor_role,action,entity,entity_id,diff,created_at';
  if (entity) path += `&entity=eq.${encodeURIComponent(entity)}`;
  path += `&order=created_at.desc&limit=${limit}&offset=${offset}`;

  const rows = await sbSelect(env, path, { token: ctx.token });
  return json({ items: rows || [], total: (rows || []).length, limit, offset });
}
