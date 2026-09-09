/**
 * Admin: bookings oversight, WhatsApp lead intake, subscription cycles, and the
 * superadmin-only role switch.
 *
 * The lead queue is the internal side of WhatsApp onboarding. It is not a
 * public-facing form — a team member logs what the owner sent, works the lead,
 * and when it converts, links it to the ground they created.
 */

import { ApiError, json, unwrapRpc } from '../lib/http.js';
import { requireStaff, requireSuperadmin } from '../lib/auth.js';
import { sbInsert, sbPatch, sbRpc, sbSelect } from '../lib/supabase.js';
import { priceLabel, shapeBooking, shapeList, whatsappUrl } from '../lib/shape.js';
import { int, isoDate, oneOf, readJson, str, uuid, whatsappNumber } from '../lib/validate.js';
import { karachiToday } from './bookings.js';

const LEAD_STATUSES = ['new', 'contacted', 'onboarding', 'listed', 'rejected'];
const SUB_STATUSES = ['unpaid', 'paid', 'overdue', 'waived', 'cancelled'];
const PAY_METHODS = ['jazzcash', 'easypaisa', 'bank_transfer', 'cash', 'other'];

const page = (q) => ({
  limit: int(q.get('limit'), 'limit', { required: false, min: 1, max: 200 }) ?? 50,
  offset: int(q.get('offset'), 'offset', { required: false, min: 0, max: 100000 }) ?? 0,
});

// ---------------------------------------------------------------------------
// Bookings

export async function listBookings(request, env, { ctx }) {
  await requireStaff(ctx, env);
  const q = new URL(request.url).searchParams;
  const { limit, offset } = page(q);

  const status = oneOf(q.get('status'), 'status',
    ['pending', 'confirmed', 'cancelled', 'completed', 'no_show', 'expired']);
  const groundId = uuid(q.get('ground_id'), 'ground_id', { required: false });
  const from = isoDate(q.get('from'), 'from', { required: false });
  const to = isoDate(q.get('to'), 'to', { required: false });

  let path = 'bookings?select=*,ground:grounds(id,slug,name,cover_image_url)';
  if (status) path += `&status=eq.${status}`;
  if (groundId) path += `&ground_id=eq.${groundId}`;
  if (from) path += `&booking_date=gte.${from}`;
  if (to) path += `&booking_date=lte.${to}`;
  path += `&order=booking_date.desc,start_time.desc&limit=${limit}&offset=${offset}`;

  const rows = await sbSelect(env, path, { token: ctx.token });
  return json(
    shapeList({ items: rows || [], total: (rows || []).length, limit, offset }, (r) =>
      shapeBooking(env, {
        ...r,
        ground: r.ground ? { ...r.ground, cover_image: r.ground.cover_image_url } : null,
      }),
    ),
  );
}

// ---------------------------------------------------------------------------
// WhatsApp lead queue

export async function listLeads(request, env, { ctx }) {
  await requireStaff(ctx, env);
  const q = new URL(request.url).searchParams;
  const { limit, offset } = page(q);
  const status = oneOf(q.get('status'), 'status', LEAD_STATUSES);

  let path = 'ground_leads?select=*&order=created_at.desc';
  if (status) path += `&status=eq.${status}`;
  path += `&limit=${limit}&offset=${offset}`;

  const rows = await sbSelect(env, path, { token: ctx.token });
  const items = (rows || []).map((r) => ({
    ...r,
    whatsapp_url: whatsappUrl(r.whatsapp_number, 'Hi! Following up about listing your ground on GroundsNearMe.'),
    asking_price_label: r.asking_price ? priceLabel(r.asking_price) : null,
  }));
  return json({ items, total: items.length, limit, offset });
}

export async function createLead(request, env, { ctx }) {
  await requireStaff(ctx, env);
  const body = await readJson(request);

  const row = {
    owner_name: str(body.owner_name, 'owner_name', { required: false, max: 120 }),
    whatsapp_number: whatsappNumber(body.whatsapp_number, 'whatsapp_number'),
    phone: str(body.phone, 'phone', { required: false, min: 7, max: 24 }),
    ground_name: str(body.ground_name, 'ground_name', { required: false, max: 160 }),
    area_text: str(body.area_text, 'area_text', { required: false, max: 120 }),
    city: str(body.city, 'city', { required: false, max: 60 }) || 'Karachi',
    asking_price: int(body.asking_price, 'asking_price', { required: false, min: 1, max: 500000 }),
    source: str(body.source, 'source', { required: false, max: 40 }) || 'whatsapp',
    notes: str(body.notes, 'notes', { required: false, max: 4000 }),
    assigned_to: uuid(body.assigned_to, 'assigned_to', { required: false }) || ctx.userId,
    created_by: ctx.userId,
  };

  const saved = await sbInsert(env, 'ground_leads?select=*', row, { token: ctx.token });
  return json({ lead: Array.isArray(saved) ? saved[0] : saved }, { status: 201 });
}

export async function updateLead(request, env, { ctx, params }) {
  await requireStaff(ctx, env);
  const body = await readJson(request);
  const patch = {};

  if ('status' in body) patch.status = oneOf(body.status, 'status', LEAD_STATUSES, { required: true });
  if ('notes' in body) patch.notes = str(body.notes, 'notes', { required: false, max: 4000 });
  if ('assigned_to' in body) patch.assigned_to = uuid(body.assigned_to, 'assigned_to', { required: false });
  if ('created_ground_id' in body) {
    patch.created_ground_id = uuid(body.created_ground_id, 'created_ground_id', { required: false });
  }
  if ('first_contact_at' in body) patch.first_contact_at = new Date().toISOString();

  if (!Object.keys(patch).length) {
    throw new ApiError('VALIDATION_ERROR', 'Nothing to update.', { details: { field: 'body' } });
  }

  const rows = await sbPatch(
    env,
    `ground_leads?id=eq.${uuid(params.id, 'id')}&select=*`,
    patch,
    { token: ctx.token },
  );
  const lead = Array.isArray(rows) ? rows[0] : rows;
  if (!lead) throw new ApiError('NOT_FOUND', 'Lead not found.');
  return json({ lead });
}

// ---------------------------------------------------------------------------
// Subscription cycles
//
// No auto-recurring billing at launch: JazzCash/EasyPaisa have no mature
// mandate flow and local owners rarely hold cards, so each cycle is a row with
// a payment link and a paid/unpaid status a team member flips once the transfer
// lands. `paid_at` is stamped by a trigger, not by this route.

export async function listSubscriptions(request, env, { ctx }) {
  await requireStaff(ctx, env);
  const q = new URL(request.url).searchParams;
  const { limit, offset } = page(q);

  const status = oneOf(q.get('status'), 'status', SUB_STATUSES);
  const ownerId = uuid(q.get('owner_id'), 'owner_id', { required: false });

  let path = 'owner_subscriptions?select=*,ground:grounds(id,slug,name),owner:profiles!owner_subscriptions_owner_id_fkey(id,full_name,whatsapp_number)';
  if (status) path += `&status=eq.${status}`;
  if (ownerId) path += `&owner_id=eq.${ownerId}`;
  path += `&order=cycle_start.desc&limit=${limit}&offset=${offset}`;

  const rows = await sbSelect(env, path, { token: ctx.token });
  const items = (rows || []).map((r) => ({
    ...r,
    amount_label: priceLabel(r.amount, r.currency),
    is_paid: r.status === 'paid' || r.status === 'waived',
    is_overdue: r.status !== 'paid' && r.status !== 'waived' && r.cycle_end < karachiToday(),
    owner_whatsapp_url: whatsappUrl(
      r.owner?.whatsapp_number,
      r.invoice_ref ? `GroundsNearMe invoice ${r.invoice_ref}` : null,
    ),
  }));

  return json({
    items,
    total: items.length,
    limit,
    offset,
    unpaid_total: items.filter((i) => !i.is_paid).reduce((sum, i) => sum + Number(i.amount || 0), 0),
  });
}

export async function createSubscription(request, env, { ctx }) {
  await requireStaff(ctx, env);
  const body = await readJson(request);

  const cycleStart = isoDate(body.cycle_start, 'cycle_start');
  const cycleEnd = isoDate(body.cycle_end ?? monthAfter(cycleStart), 'cycle_end');
  if (cycleEnd <= cycleStart) {
    throw new ApiError('VALIDATION_ERROR', 'cycle_end must be after cycle_start.', {
      details: { field: 'cycle_end' },
    });
  }

  const row = {
    owner_id: uuid(body.owner_id, 'owner_id'),
    ground_id: uuid(body.ground_id, 'ground_id', { required: false }),
    tier: oneOf(body.tier, 'tier', ['free', 'pro'], { fallback: 'pro' }),
    cycle_start: cycleStart,
    cycle_end: cycleEnd,
    amount: int(body.amount, 'amount', { min: 0, max: 1000000 }),
    status: oneOf(body.status, 'status', SUB_STATUSES, { fallback: 'unpaid' }),
    payment_method: oneOf(body.payment_method, 'payment_method', PAY_METHODS),
    payment_link: str(body.payment_link, 'payment_link', { required: false, max: 500 }),
    invoice_ref: str(body.invoice_ref, 'invoice_ref', { required: false, max: 60 }),
    notes: str(body.notes, 'notes', { required: false, max: 2000 }),
    created_by: ctx.userId,
  };

  const saved = await sbInsert(env, 'owner_subscriptions?select=*', row, { token: ctx.token });
  const sub = Array.isArray(saved) ? saved[0] : saved;
  return json({ subscription: { ...sub, amount_label: priceLabel(sub.amount, sub.currency) } }, { status: 201 });
}

/** First of the next month — the default cycle length. */
function monthAfter(date) {
  const [y, m] = date.split('-').map(Number);
  const nextY = m === 12 ? y + 1 : y;
  const nextM = m === 12 ? 1 : m + 1;
  return `${nextY}-${String(nextM).padStart(2, '0')}-01`;
}

/** Marking a cycle paid is the one write that actually matters here. */
export async function updateSubscription(request, env, { ctx, params }) {
  await requireStaff(ctx, env);
  const body = await readJson(request);
  const patch = {};

  if ('status' in body) patch.status = oneOf(body.status, 'status', SUB_STATUSES, { required: true });
  if ('payment_method' in body) {
    patch.payment_method = oneOf(body.payment_method, 'payment_method', PAY_METHODS);
  }
  if ('payment_link' in body) {
    patch.payment_link = str(body.payment_link, 'payment_link', { required: false, max: 500 });
  }
  if ('invoice_ref' in body) {
    patch.invoice_ref = str(body.invoice_ref, 'invoice_ref', { required: false, max: 60 });
  }
  if ('amount' in body) patch.amount = int(body.amount, 'amount', { min: 0, max: 1000000 });
  if ('notes' in body) patch.notes = str(body.notes, 'notes', { required: false, max: 2000 });
  if (body.reminder_sent === true) patch.reminder_sent_at = new Date().toISOString();

  if (!Object.keys(patch).length) {
    throw new ApiError('VALIDATION_ERROR', 'Nothing to update.', { details: { field: 'body' } });
  }

  const rows = await sbPatch(
    env,
    `owner_subscriptions?id=eq.${uuid(params.id, 'id')}&select=*`,
    patch,
    { token: ctx.token },
  );
  const sub = Array.isArray(rows) ? rows[0] : rows;
  if (!sub) throw new ApiError('NOT_FOUND', 'Subscription cycle not found.');
  return json({ subscription: { ...sub, amount_label: priceLabel(sub.amount, sub.currency) } });
}

/**
 * Opens this month's unpaid cycle for every active pro ground.
 *
 * Kicked off by a staff member rather than the cron: open_subscription_cycle()
 * checks is_staff(), and the scheduled job runs with the service-role key where
 * auth.uid() is null. Semi-automated is the intent anyway — someone still has to
 * send the JazzCash / EasyPaisa link afterwards.
 */
export async function openSubscriptionCycle(request, env, { ctx }) {
  await requireStaff(ctx, env);
  const body = request.headers.get('content-type') ? await readJson(request) : {};
  const payload = unwrapRpc(
    await sbRpc(
      env,
      'open_subscription_cycle',
      {
        p_month: isoDate(body.month, 'month', { required: false }),
        p_amount: int(body.amount, 'amount', { required: false, min: 0, max: 1000000 }) ?? 2000,
      },
      { token: ctx.token },
    ),
  );
  return json({
    cycles_created: payload.cycles_created,
    cycle_start: payload.cycle_start,
    cycle_end: payload.cycle_end,
  }, { status: 201 });
}

// ---------------------------------------------------------------------------
// People
export async function listUsers(request, env, { ctx }) {
  await requireStaff(ctx, env);
  const q = new URL(request.url).searchParams;
  const { limit, offset } = page(q);
  const role = oneOf(q.get('role'), 'role', ['player', 'owner', 'admin', 'superadmin']);

  let path = 'profiles?select=id,role,full_name,handle,email,phone,whatsapp_number,city,is_active,created_at';
  if (role) path += `&role=eq.${role}`;
  path += `&order=created_at.desc&limit=${limit}&offset=${offset}`;

  const rows = await sbSelect(env, path, { token: ctx.token });
  const items = (rows || []).map((r) => ({ ...r, handle: r.handle ? `@${r.handle}` : null }));
  return json({ items, total: items.length, limit, offset });
}

/**
 * Superadmin only — the profiles guard trigger rejects a role change from
 * anyone else, so a plain admin cannot mint another admin.
 */
export async function setUserRole(request, env, { ctx, params }) {
  await requireSuperadmin(ctx, env);
  const body = await readJson(request);
  const rows = await sbPatch(
    env,
    `profiles?id=eq.${uuid(params.id, 'id')}&select=id,role,full_name,is_active`,
    {
      role: oneOf(body.role, 'role', ['player', 'owner', 'admin', 'superadmin'], { required: true }),
    },
    { token: ctx.token },
  );
  const user = Array.isArray(rows) ? rows[0] : rows;
  if (!user) throw new ApiError('NOT_FOUND', 'User not found.');
  return json({ user });
}
