-- ============================================================================
-- GroundsNearMe — 0023 · reference data: Karachi areas
-- Reference data, not seed data: these rows are needed in production.
-- ============================================================================

insert into public.areas (city, name, slug, sort_order) values
  ('Karachi', 'Gulshan-e-Iqbal',    'gulshan-e-iqbal',    10),
  ('Karachi', 'Gulistan-e-Johar',   'gulistan-e-johar',   20),
  ('Karachi', 'DHA / Defence',      'dha-defence',        30),
  ('Karachi', 'Clifton',            'clifton',            40),
  ('Karachi', 'Nazimabad',          'nazimabad',          50),
  ('Karachi', 'North Nazimabad',    'north-nazimabad',    60),
  ('Karachi', 'Federal B Area',     'federal-b-area',     70),
  ('Karachi', 'PECHS',              'pechs',              80),
  ('Karachi', 'Scheme 33',          'scheme-33',          90),
  ('Karachi', 'Malir',              'malir',             100),
  ('Karachi', 'Korangi',            'korangi',           110),
  ('Karachi', 'Saddar',             'saddar',            120),
  ('Karachi', 'Shah Faisal',        'shah-faisal',       130),
  ('Karachi', 'Surjani / Gadap',    'surjani-gadap',     140)
on conflict (slug) do nothing;
