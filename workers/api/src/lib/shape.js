/**
 * DB row → API DTO.
 *
 * The frontend cards in index.html render "PKR 2,500", a wa.me link and a
 * "Slots Open" / "Full Today" badge. Formatting those in one place here — not
 * in each dashboard and not in the public site's JS — keeps the three
 * consumers from drifting apart, and means a copy change is one edit.
 *
 * Rule: never invent fields the database did not return, and never pass
 * through fields the SQL layer deliberately withheld (owner_id, internal
 * notes). The RPCs already build their item objects explicitly; this layer
 * only decorates.
 */

const ABSOLUTE_RE = /^https?:\/\//i;

/**
 * `Number(null)` and `Number('')` are both 0, which would turn a missing price
 * into "PKR 0" and a missing slot count into "Full Today". Absent has to stay
 * absent, so reject the empty values before coercing.
 */
function numOrNull(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

/** R2 keys are stored bare in `grounds.images` so the CDN host can change. */
export function imageUrl(env, value) {
  if (!value) return null;
  const s = String(value).trim();
  if (!s) return null;
  if (ABSOLUTE_RE.test(s)) return s;
  const base = String(env.R2_PUBLIC_BASE_URL || '').replace(/\/+$/, '');
  const key = s.replace(/^\/+/, '');
  return base ? `${base}/${key}` : `/${key}`;
}

export function shapeImages(env, images) {
  if (!Array.isArray(images)) return [];
  return images
    .map((img, i) => {
      const raw = typeof img === 'string' ? { url: img } : img || {};
      const url = imageUrl(env, raw.url || raw.key);
      if (!url) return null;
      return {
        url,
        alt: raw.alt || null,
        sort: Number.isFinite(raw.sort) ? raw.sort : i,
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.sort - b.sort);
}

/** "PKR 2,500" — grouped the way the mock cards show it. */
export function priceLabel(amount, currency = 'PKR') {
  const n = numOrNull(amount);
  if (n === null) return null;
  const grouped = Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${currency || 'PKR'} ${grouped}`;
}

export function whatsappUrl(number, text) {
  const digits = String(number || '').replace(/[^0-9]/g, '');
  if (digits.length < 10) return null;
  const q = text ? `?text=${encodeURIComponent(text)}` : '';
  return `https://wa.me/${digits}${q}`;
}

/**
 * The badge on the ground card. `open_slots` comes from count_open_slots(),
 * which returns 0 both for "every slot taken" and for "closed today" — the
 * detail payload's `hours` disambiguates, the list payload cannot, so the list
 * badge stays the same "Full Today" the mock used.
 *
 * A null count means the query did not ask for one — that is `unknown` with no
 * badge, never "Full Today", so a list route that omits `open_slots` cannot
 * silently tell every player the city is booked out.
 */
export function availabilityBadge(openSlots) {
  const n = numOrNull(openSlots);
  if (n === null) return { slots_status: 'unknown', availability_badge: null };
  if (n > 0) return { slots_status: 'open', availability_badge: 'Slots Open' };
  return { slots_status: 'full', availability_badge: 'Full Today' };
}

export function shapeGround(env, row) {
  if (!row) return null;
  const images = shapeImages(env, row.images);
  const cover = imageUrl(env, row.cover_image) || images[0]?.url || null;
  return {
    ...row,
    images,
    cover_image: cover,
    price_label: priceLabel(row.price_per_hour, row.currency),
    weekend_price_label: row.weekend_price_per_hour
      ? priceLabel(row.weekend_price_per_hour, row.currency)
      : null,
    whatsapp_url: whatsappUrl(
      row.whatsapp_number,
      row.name ? `Hi, I'd like to book ${row.name} via GroundsNearMe.` : null,
    ),
    location_label: [row.area, row.city].filter(Boolean).join(', ') || null,
    ...availabilityBadge(row.open_slots),
  };
}

/** get_ground() returns {ground, hours, slots, closures, date}. */
export function shapeGroundDetail(env, payload) {
  if (!payload) return null;
  const openCount = Array.isArray(payload.slots)
    ? payload.slots.filter((s) => s.is_available).length
    : 0;
  const closedToday =
    Array.isArray(payload.slots) && payload.slots.length === 0;

  return {
    ground: {
      ...shapeGround(env, payload.ground),
      open_slots: openCount,
      ...(closedToday
        ? { slots_status: 'closed', availability_badge: 'Closed Today' }
        : availabilityBadge(openCount)),
    },
    hours: Array.isArray(payload.hours) ? payload.hours.map(shapeHours) : [],
    slots: Array.isArray(payload.slots) ? payload.slots.map(shapeSlot) : [],
    closures: Array.isArray(payload.closures) ? payload.closures : [],
    date: payload.date || null,
  };
}

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

export function shapeHours(row) {
  if (!row) return null;
  return {
    ...row,
    day_name: DAY_NAMES[Number(row.day_of_week)] || null,
    label: row.is_closed ? 'Closed' : `${row.opens_at} – ${row.closes_at}`,
  };
}

/** 24h "19:00" → "7:00 PM", which is how the mock labels slots. */
export function to12h(hhmm) {
  const m = /^(\d{1,2}):(\d{2})/.exec(String(hhmm || ''));
  if (!m) return null;
  const h = Number(m[1]);
  const suffix = h >= 12 ? 'PM' : 'AM';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${m[2]} ${suffix}`;
}

export function shapeSlot(row) {
  if (!row) return null;
  return {
    ...row,
    label: `${to12h(row.start_time)} – ${to12h(row.end_time)}`,
    price_label: priceLabel(row.price),
  };
}

export function shapeBooking(env, row) {
  if (!row) return null;
  const ground = row.ground ? shapeGround(env, row.ground) : null;
  return {
    ...row,
    ground,
    slot_label: row.start_time ? `${to12h(row.start_time)} – ${to12h(row.end_time)}` : null,
    amount_label: priceLabel(row.total_amount, row.currency),
    is_upcoming: upcoming(row),
  };
}

function upcoming(row) {
  if (!row.booking_date) return null;
  const end = `${row.booking_date}T${(row.end_time || '00:00:00').slice(0, 8)}`;
  // Wall-clock Asia/Karachi = UTC+5, no DST, so a fixed offset is exact.
  const ts = Date.parse(`${end}+05:00`);
  return Number.isFinite(ts) ? ts > Date.now() : null;
}

export function shapeOpenGame(env, row) {
  if (!row) return null;
  return {
    ...row,
    handle: row.host_handle ? `@${String(row.host_handle).replace(/^@/, '')}` : null,
    ground: row.ground
      ? { ...row.ground, cover_image: imageUrl(env, row.ground.cover_image) }
      : null,
    when_label: [row.match_date, to12h(row.start_time)].filter(Boolean).join(' · ') || null,
    interest_label:
      Number(row.interest_count) > 0
        ? `${row.interest_count} player${Number(row.interest_count) === 1 ? '' : 's'} expressed interest`
        : 'No interest yet',
    whatsapp_url: whatsappUrl(row.whatsapp_number, row.title ? `Re: ${row.title}` : null),
  };
}

/** Applies a shaper to the {items,total,limit,offset,...} envelope. */
export function shapeList(payload, mapper) {
  const items = Array.isArray(payload?.items) ? payload.items.map(mapper).filter(Boolean) : [];
  return {
    items,
    total: Number(payload?.total ?? items.length),
    limit: payload?.limit ?? null,
    offset: payload?.offset ?? null,
    ...(payload?.date ? { date: payload.date } : {}),
  };
}
