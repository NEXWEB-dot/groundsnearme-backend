import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  availabilityBadge, imageUrl, priceLabel, shapeGround, shapeGroundDetail,
  shapeImages, shapeList, shapeOpenGame, to12h, whatsappUrl,
} from '../src/lib/shape.js';

const env = { R2_PUBLIC_BASE_URL: 'https://images.groundsnearme.pk' };

test('priceLabel matches the card text on the public site', () => {
  assert.equal(priceLabel(2500), 'PKR 2,500');
  assert.equal(priceLabel(3200), 'PKR 3,200');
  assert.equal(priceLabel(1800), 'PKR 1,800');
  assert.equal(priceLabel(950), 'PKR 950');
  assert.equal(priceLabel(1250000), 'PKR 1,250,000');
  assert.equal(priceLabel(null), null);
});

test('imageUrl resolves R2 keys and leaves absolute URLs alone', () => {
  assert.equal(
    imageUrl(env, 'grounds/star-indoor/1-a.webp'),
    'https://images.groundsnearme.pk/grounds/star-indoor/1-a.webp',
  );
  assert.equal(imageUrl(env, 'https://cdn.example/x.jpg'), 'https://cdn.example/x.jpg');
  assert.equal(imageUrl({}, 'a/b.jpg'), '/a/b.jpg');
  assert.equal(imageUrl(env, null), null);
});

test('shapeImages sorts by sort and tolerates bare strings', () => {
  // A bare string has no `sort`, so it falls back to its array index (1 here).
  // The object's explicit sort must be distinct from that, or the comparison is
  // a tie and the assertion below would only be testing sort stability.
  const out = shapeImages(env, [
    { url: 'g/b.jpg', sort: 2, alt: 'B' },
    'g/a.jpg',
  ]);
  assert.deepEqual(out.map((i) => i.url), [
    'https://images.groundsnearme.pk/g/a.jpg',
    'https://images.groundsnearme.pk/g/b.jpg',
  ]);
  assert.equal(out[1].alt, 'B');
});

test('whatsappUrl builds a wa.me link and skips junk numbers', () => {
  assert.equal(whatsappUrl('920000000001'), 'https://wa.me/920000000001');
  assert.match(whatsappUrl('92 000 0000001', 'hi there'), /^https:\/\/wa\.me\/920000000001\?text=hi%20there$/);
  assert.equal(whatsappUrl('123'), null);
});

test('availabilityBadge reproduces the mock badges', () => {
  assert.deepEqual(availabilityBadge(4), { slots_status: 'open', availability_badge: 'Slots Open' });
  assert.deepEqual(availabilityBadge(0), { slots_status: 'full', availability_badge: 'Full Today' });
  assert.deepEqual(availabilityBadge(null), { slots_status: 'unknown', availability_badge: null });
});

test('an absent number stays absent instead of coercing to zero', () => {
  // Number(null) and Number('') are both 0, which would print "PKR 0" for a
  // ground with no weekend price and badge every ground "Full Today" whenever a
  // query did not ask for open_slots.
  assert.equal(priceLabel(null), null);
  assert.equal(priceLabel(undefined), null);
  assert.equal(priceLabel(''), null);
  assert.equal(priceLabel(0), 'PKR 0');

  for (const empty of [null, undefined, '']) {
    assert.deepEqual(availabilityBadge(empty), {
      slots_status: 'unknown',
      availability_badge: null,
    });
  }
  assert.deepEqual(availabilityBadge(0), { slots_status: 'full', availability_badge: 'Full Today' });
});

test('to12h converts the 24h grid to the label the UI shows', () => {
  assert.equal(to12h('19:00'), '7:00 PM');
  assert.equal(to12h('00:30'), '12:30 AM');
  assert.equal(to12h('12:00'), '12:00 PM');
  assert.equal(to12h(null), null);
});

test('shapeGround decorates without dropping database fields', () => {
  const row = {
    id: 'g1', slug: 'star-indoor-cricket', name: 'Star Indoor Cricket',
    area: 'Gulshan-e-Iqbal', city: 'Karachi', price_per_hour: 2500, currency: 'PKR',
    whatsapp_number: '920000000001', amenities: ['Floodlit', 'Nets', 'Parking'],
    images: [{ url: 'grounds/star/1.webp', sort: 0 }], cover_image: null, open_slots: 4,
  };
  const out = shapeGround(env, row);

  assert.equal(out.price_label, 'PKR 2,500');
  assert.equal(out.availability_badge, 'Slots Open');
  assert.equal(out.location_label, 'Gulshan-e-Iqbal, Karachi');
  assert.equal(out.cover_image, 'https://images.groundsnearme.pk/grounds/star/1.webp');
  assert.match(out.whatsapp_url, /^https:\/\/wa\.me\/920000000001\?text=/);
  assert.deepEqual(out.amenities, ['Floodlit', 'Nets', 'Parking']);
  assert.equal(out.slug, 'star-indoor-cricket');
});

test('a weekday with no rows reads as Closed Today, not Full Today', () => {
  const out = shapeGroundDetail(env, {
    ground: { id: 'g1', name: 'KCC', price_per_hour: 1800 },
    hours: [{ day_of_week: 5, opens_at: '09:00', closes_at: '02:00', is_closed: true }],
    slots: [],
    closures: [],
    date: '2026-08-29',
  });

  assert.equal(out.ground.availability_badge, 'Closed Today');
  assert.equal(out.ground.slots_status, 'closed');
  assert.equal(out.hours[0].label, 'Closed');
  assert.equal(out.hours[0].day_name, 'Friday');
});

test('a fully-booked day reads as Full Today', () => {
  const out = shapeGroundDetail(env, {
    ground: { id: 'g1', name: 'KCC', price_per_hour: 1800 },
    hours: [],
    slots: [
      { start_time: '19:00', end_time: '20:00', is_available: false, reason: 'booked', price: 1800 },
    ],
    closures: [],
    date: '2026-08-29',
  });

  assert.equal(out.ground.availability_badge, 'Full Today');
  assert.equal(out.slots[0].label, '7:00 PM – 8:00 PM');
  assert.equal(out.slots[0].price_label, 'PKR 1,800');
});

test('shapeOpenGame prefixes the handle and counts interest', () => {
  const out = shapeOpenGame(env, {
    id: 'og1', title: 'Need 3 players — Saturday 7PM, Star Indoor',
    host_handle: 'captain_tariq', match_date: '2026-09-05', start_time: '19:00',
    interest_count: 4, whatsapp_number: '920000000001',
    ground: { id: 'g1', name: 'Star Indoor', cover_image: 'grounds/star/1.webp' },
  });

  assert.equal(out.handle, '@captain_tariq');
  assert.equal(out.interest_label, '4 players expressed interest');
  assert.equal(out.when_label, '2026-09-05 · 7:00 PM');
  assert.equal(out.ground.cover_image, 'https://images.groundsnearme.pk/grounds/star/1.webp');
});

test('shapeOpenGame singularises one interest and handles none', () => {
  assert.equal(shapeOpenGame(env, { interest_count: 1 }).interest_label, '1 player expressed interest');
  assert.equal(shapeOpenGame(env, { interest_count: 0 }).interest_label, 'No interest yet');
});

test('shapeList keeps the envelope the frontend paginates on', () => {
  const out = shapeList({ items: [{ n: 1 }, { n: 2 }], total: 137, limit: 24, offset: 0, date: '2026-08-29' },
    (r) => ({ ...r, doubled: r.n * 2 }));
  assert.equal(out.total, 137);
  assert.equal(out.limit, 24);
  assert.equal(out.date, '2026-08-29');
  assert.deepEqual(out.items.map((i) => i.doubled), [2, 4]);
});

test('shapeList survives a missing items array', () => {
  const out = shapeList(null, (r) => r);
  assert.deepEqual(out.items, []);
  assert.equal(out.total, 0);
});
