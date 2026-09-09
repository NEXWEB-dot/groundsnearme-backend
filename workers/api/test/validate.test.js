import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  bool, clockTime, int, isoDate, oneOf, slugify, str, stringList, uuid, whatsappNumber,
} from '../src/lib/validate.js';

const throwsWith = (fn, code, field) =>
  assert.throws(fn, (err) => {
    assert.equal(err.code, code);
    if (field) assert.equal(err.details?.field, field);
    return true;
  });

test('str trims and enforces bounds', () => {
  assert.equal(str('  Star Indoor  ', 'name'), 'Star Indoor');
  throwsWith(() => str('', 'name'), 'VALIDATION_ERROR', 'name');
  throwsWith(() => str('a'.repeat(501), 'name'), 'VALIDATION_ERROR', 'name');
  assert.equal(str(undefined, 'name', { required: false }), null);
});

test('str rejects non-strings instead of coercing', () => {
  throwsWith(() => str(42, 'name'), 'VALIDATION_ERROR', 'name');
});

test('int accepts numeric strings but not fractions', () => {
  assert.equal(int('2500', 'price'), 2500);
  assert.equal(int(2500, 'price'), 2500);
  throwsWith(() => int('2500.5', 'price'), 'VALIDATION_ERROR', 'price');
  throwsWith(() => int('abc', 'price'), 'VALIDATION_ERROR', 'price');
  throwsWith(() => int(5, 'price', { min: 10 }), 'VALIDATION_ERROR', 'price');
});

test('bool understands the query-string spellings', () => {
  for (const v of [true, 'true', '1', 'yes']) assert.equal(bool(v, 'f'), true);
  for (const v of [false, 'false', '0', 'no']) assert.equal(bool(v, 'f'), false);
  assert.equal(bool(undefined, 'f'), false);
  assert.equal(bool(undefined, 'f', { fallback: true }), true);
  throwsWith(() => bool('maybe', 'f'), 'VALIDATION_ERROR', 'f');
});

test('isoDate rejects impossible calendar dates', () => {
  assert.equal(isoDate('2026-08-29', 'date'), '2026-08-29');
  throwsWith(() => isoDate('2026-02-30', 'date'), 'VALIDATION_ERROR', 'date');
  throwsWith(() => isoDate('29-08-2026', 'date'), 'VALIDATION_ERROR', 'date');
});

test('clockTime normalises HH:MM to HH:MM:SS', () => {
  assert.equal(clockTime('19:00', 'start_time'), '19:00:00');
  assert.equal(clockTime('02:30:00', 'start_time'), '02:30:00');
  throwsWith(() => clockTime('24:00', 'start_time'), 'VALIDATION_ERROR', 'start_time');
  throwsWith(() => clockTime('7pm', 'start_time'), 'VALIDATION_ERROR', 'start_time');
});

test('uuid is checked before it can reach a PostgREST filter', () => {
  const id = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
  assert.equal(uuid(id, 'id'), id);
  throwsWith(() => uuid("' or 1=1--", 'id'), 'VALIDATION_ERROR', 'id');
});

test('oneOf falls back rather than throwing on an absent value', () => {
  assert.equal(oneOf(undefined, 'sort', ['featured', 'rating'], { fallback: 'featured' }), 'featured');
  assert.equal(oneOf('rating', 'sort', ['featured', 'rating']), 'rating');
  throwsWith(() => oneOf('cheapest', 'sort', ['featured', 'rating']), 'VALIDATION_ERROR', 'sort');
});

test('whatsappNumber keeps digits only', () => {
  assert.equal(whatsappNumber('+92 300 0000001', 'whatsapp_number'), '923000000001');
  throwsWith(() => whatsappNumber('12345', 'whatsapp_number'), 'VALIDATION_ERROR', 'whatsapp_number');
});

test('stringList takes CSV or an array and drops blanks', () => {
  assert.deepEqual(stringList('Floodlit, Nets , Parking', 'amenities'), ['Floodlit', 'Nets', 'Parking']);
  assert.deepEqual(stringList(['Nets', '', ' '], 'amenities'), ['Nets']);
  assert.equal(stringList('', 'amenities'), null);
  throwsWith(() => stringList('a'.repeat(41), 'amenities'), 'VALIDATION_ERROR', 'amenities');
});

test('slugify produces something the grounds_slug_format check accepts', () => {
  assert.equal(slugify('KCC Ground — Nazimabad!', 'name'), 'kcc-ground-nazimabad');
  assert.match(slugify('Star Indoor Cricket', 'name'), /^[a-z0-9]+(-[a-z0-9]+)*$/);
  throwsWith(() => slugify('!!!!', 'name'), 'VALIDATION_ERROR', 'name');
});
