-- ============================================================================
-- GroundsNearMe — 0003 · areas + grounds
-- Supabase is the source of truth for structured data.
-- Ground images live on Cloudflare R2; only their URLs are stored here.
-- ============================================================================

create table if not exists public.areas (
  id          uuid primary key default gen_random_uuid(),
  city        text not null default 'Karachi',
  name        text not null,
  slug        text not null unique,
  sort_order  int  not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  constraint areas_city_name_unique unique (city, name)
);

create index if not exists areas_city_idx on public.areas (city) where is_active;

comment on table public.areas is
  'Lookup of serviceable areas. Drives the Area filter on the public site.';

-- ---------------------------------------------------------------------------

create table if not exists public.grounds (
  id                       uuid primary key default gen_random_uuid(),
  slug                     text not null unique,
  name                     text not null,
  owner_id                 uuid references public.profiles(id) on delete set null,
  area_id                  uuid references public.areas(id) on delete set null,
  city                     text not null default 'Karachi',
  address                  text,
  latitude                 numeric(9,6),
  longitude                numeric(9,6),
  description              text,
  ground_type              public.ground_type not null default 'outdoor',
  surface                  text,
  pitch_count              int not null default 1 check (pitch_count > 0),

  price_per_hour           integer not null check (price_per_hour > 0),
  weekend_price_per_hour   integer check (weekend_price_per_hour is null or weekend_price_per_hour > 0),
  currency                 char(3) not null default 'PKR',

  whatsapp_number          text,
  phone                    text,
  contact_name             text,

  amenities                text[] not null default '{}',
  images                   jsonb  not null default '[]'::jsonb,
  cover_image_url          text,

  status                   public.ground_status not null default 'pending',
  listing_tier             public.listing_tier  not null default 'free',
  is_featured              boolean not null default false,
  featured_rank            int,
  featured_until           timestamptz,

  -- Commission is 0 at launch (free listings). Set per ground when the
  -- commission model goes live so historical bookings keep their own rate.
  commission_rate          numeric(5,4) not null default 0
                             check (commission_rate >= 0 and commission_rate <= 0.5),

  slot_duration_minutes    int not null default 60
                             check (slot_duration_minutes in (30,60,90,120)),
  min_booking_minutes      int not null default 60 check (min_booking_minutes > 0),
  max_booking_minutes      int not null default 480 check (max_booking_minutes > 0),
  advance_booking_days     int not null default 30 check (advance_booking_days between 1 and 365),

  rating                   numeric(2,1) check (rating is null or rating between 0 and 5),
  review_count             int not null default 0 check (review_count >= 0),

  internal_notes           text,
  created_by               uuid references public.profiles(id) on delete set null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint grounds_whatsapp_format
    check (whatsapp_number is null or whatsapp_number ~ '^[0-9]{10,15}$'),
  constraint grounds_images_is_array
    check (jsonb_typeof(images) = 'array'),
  constraint grounds_booking_window
    check (max_booking_minutes >= min_booking_minutes),
  constraint grounds_slug_format
    check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

comment on table public.grounds is
  'A bookable cricket ground. New rows are created by staff via the admin view '
  'after the owner reaches out on WhatsApp — there is no public self-serve form.';
comment on column public.grounds.images is
  'JSON array of {url, alt, sort} objects. url points at the R2 public bucket.';
comment on column public.grounds.commission_rate is
  'Fraction, e.g. 0.05 = 5%. Snapshotted onto each booking at creation time.';

create index if not exists grounds_status_idx        on public.grounds (status);
create index if not exists grounds_area_idx          on public.grounds (area_id) where status = 'active';
create index if not exists grounds_city_idx          on public.grounds (city)    where status = 'active';
create index if not exists grounds_owner_idx         on public.grounds (owner_id);
create index if not exists grounds_price_idx         on public.grounds (price_per_hour) where status = 'active';
create index if not exists grounds_featured_idx      on public.grounds (is_featured, featured_rank) where status = 'active';
create index if not exists grounds_amenities_gin_idx on public.grounds using gin (amenities);
create index if not exists grounds_name_lower_idx    on public.grounds (lower(name));

drop trigger if exists grounds_set_updated_at on public.grounds;
create trigger grounds_set_updated_at
  before update on public.grounds
  for each row execute function public.tg_set_updated_at();

-- Keep cover_image_url in step with the images array.
create or replace function public.tg_grounds_sync_cover()
returns trigger
language plpgsql
as $$
begin
  if new.cover_image_url is null and jsonb_array_length(coalesce(new.images, '[]'::jsonb)) > 0 then
    new.cover_image_url := new.images -> 0 ->> 'url';
  end if;
  return new;
end
$$;

drop trigger if exists grounds_sync_cover on public.grounds;
create trigger grounds_sync_cover
  before insert or update of images, cover_image_url on public.grounds
  for each row execute function public.tg_grounds_sync_cover();
