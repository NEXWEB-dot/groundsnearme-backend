# GroundsNearMe — API contract (v1)

The Cloudflare Worker in `workers/api` is the only thing the browser talks to.
Supabase is never called directly from the player site, the owner dashboard or
the admin views: the Worker holds the CORS allowlist, the rate limits and the
role gates, and it shapes rows into the exact fields the mock markup in
`index.html` already renders.

This file is the integration boundary. When the frontend devs replace their mock
data in `js/api.js`, these are the URLs, query strings, request bodies and
response fields to bind to — nothing else is guaranteed to stay stable.

`tools/check-consistency.sh` fails the build if this file and
`workers/api/src/router.js` disagree, so the table below cannot silently rot.

- **Base URL (prod):** `https://api.groundsnearme.pk`
- **Base URL (dev):** `http://127.0.0.1:8787`
- **Version prefix:** every path starts with `/v1`

## Conventions

### Auth

Supabase Auth issues the token; the Worker verifies it and forwards it to
PostgREST so row-level security applies to every read and write.

```
Authorization: Bearer <supabase access_token>
```

No header means anonymous, which is fine for the public reads. A token that is
expired or malformed is `401 AUTH_REQUIRED` — sign in again, do not retry.

Four roles, from `public.profiles.role`:

| Role | Gets |
| --- | --- |
| `player` | public reads, own bookings, matchmaking |
| `owner` | everything a player gets, plus `/v1/owner/*` for their own grounds |
| `admin` | `/v1/admin/*` — all grounds, all bookings, leads, subscriptions |
| `superadmin` | `/v1/finance/*` and role changes. Shayan only. |

Roles are hierarchical in the gates (`owner` routes also accept staff), never
the other way round: an `admin` cannot read `/v1/finance/*`.

### Response envelopes

Success is always a JSON object, never a bare array, so fields can be added
without breaking a consumer:

```json
{ "items": [ … ], "total": 24, "limit": 24, "offset": 0 }
```

```json
{ "ground": { … } }      { "booking": { … } }      { "user": { … } }
```

Failure is always:

```json
{ "error": { "code": "SLOT_TAKEN", "message": "Someone just took this slot. Pick another one.", "details": { "field": "start_time" } } }
```

`message` is user-facing copy — show it. `code` is what you branch on. `details`
is optional and only present for validation errors, where `details.field` names
the offending input so the form can highlight it.

### Error codes

The Worker maps its own guards and the RPCs' `{ok:false,error:{code}}` envelopes
onto the same list. Branch on these:

| Code | HTTP | Means |
| --- | --- | --- |
| `VALIDATION_ERROR` | 400 | bad input; `details.field` names it |
| `AUTH_REQUIRED` | 401 | no token, or expired — send to sign-in |
| `FORBIDDEN` | 403 | signed in, wrong role or not your row |
| `NOT_FOUND` | 404 | no such booking / lead / image |
| `GROUND_NOT_FOUND` | 404 | unknown slug or id |
| `SLOT_TAKEN` | 409 | someone else booked that slot first |
| `NOT_CANCELLABLE` | 409 | already started, completed or cancelled |
| `NOT_EDITABLE` | 409 | that transition is not allowed from this status |
| `GAME_CLOSED` | 409 | open game is full, past or closed |
| `HOST_CANNOT_JOIN` | 409 | you posted this game |
| `RETRY` | 409 | booking-ref collision; resubmit unchanged |
| `PAYLOAD_TOO_LARGE` | 413 | image over 8 MB |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | not jpeg / png / webp / avif |
| `RATE_LIMITED` | 429 | too many writes; back off |
| `METHOD_NOT_ALLOWED` | 405 | path exists, verb does not |
| `UPSTREAM_ERROR` | 502 | Supabase failed or returned nothing |
| `INTERNAL_ERROR` | 500 | bug on our side; nothing leaked |

Booking creation can also return these 400s, each with copy worth showing
verbatim: `GROUND_CLOSED`, `GROUND_NOT_AVAILABLE`, `OUTSIDE_OPENING_HOURS`,
`OUTSIDE_BOOKING_WINDOW`, `SLOT_IN_PAST`, `DATE_IN_PAST`, `INVALID_DURATION`,
`INVALID_TIME_RANGE`.

Anything unlisted defaults to 400, so a new database-side code degrades to "bad
request" rather than a 500.

### CORS, caching and headers

Origins are allowlisted in the `ALLOWED_ORIGINS` var — the public site, the owner
dashboard, the admin host and `localhost:5173` for dev. There is no `*`, ever. A
request from an unlisted origin gets no CORS headers and a preflight from one is
`403`. Add a new host there before deploying a new frontend.

Every response carries `x-content-type-options: nosniff`,
`referrer-policy: strict-origin-when-cross-origin` and an `x-request-id` —
include that id when reporting a bug.

Reads are cached at the edge, writes never are:

| Endpoint | `cache-control` |
| --- | --- |
| `/v1/areas` | `public, max-age=600` |
| `/v1/grounds` (list) | `public, max-age=60` |
| `/v1/grounds/:ref` | `public, max-age=30` |
| `/v1/grounds/:ref/availability` | `public, max-age=20` |
| `/v1/matchmaking/games` | `public, max-age=30` |
| everything else | `no-store` |

Availability is 20 seconds stale at worst. That is deliberate: the slot grid is a
hint, and the booking write is the authority. Two players can both see the 7 PM
slot as open, both tap it, and exactly one gets a `201` — the other gets
`409 SLOT_TAKEN`, guaranteed by a Postgres exclusion constraint rather than by
anything in the Worker. **Handle the 409 in the UI; do not try to prevent it by
polling faster.** Re-fetch the availability grid after a 409 and let the player
pick again.

### Rate limits

Applied per user (or per IP when anonymous), fixed window:

| Action | Limit |
| --- | --- |
| `POST /v1/bookings` | 10 per 5 minutes |
| `POST /v1/matchmaking/games` | 5 per hour |
| `POST /v1/matchmaking/games/:id/interest` | 30 per hour |

Over the limit is `429 RATE_LIMITED`. The limiter needs the `RATE_LIMIT` KV
namespace bound; without it the checks are skipped rather than failing closed, so
bind it before launch.

### Pagination

List endpoints take `limit` and `offset` and return them back alongside `total`:

```json
{ "items": [], "total": 137, "limit": 24, "offset": 0 }
```

Defaults: 24 for grounds, 20 for open games, 50 for the dashboards, 100 for the
ledger. Maximum 100 (200 on admin lists, 500 on the ledger).

`total` is exact on `/v1/grounds` and `/v1/matchmaking/games` — the SQL counts
before the limit, so "137 grounds in Karachi" is a real number. On the dashboard
lists it is the length of the page, so paginate with "next" rather than page
numbers there.

### Dates, times, money, images

- **Dates** are `YYYY-MM-DD` in **Asia/Karachi**. Pakistan has no DST, so the
  Worker treats local time as a fixed UTC+5 and `today` never disagrees with the
  player's phone.
- **Times** are 24-hour. Send `"19:00"` or `"19:00:00"`; both are accepted and
  normalised. Reads are less uniform than writes: the public detail and
  availability payloads return `HH:MM` (`"19:00"`), while booking rows come
  straight from PostgREST as `HH:MM:SS` (`"19:00:00"`). Compare with
  `.slice(0, 5)`, or just use the `label` / `slot_label` field. A closing time
  earlier than the opening time means past midnight — `09:00 → 02:00` is a normal
  Karachi day.
- **Money** is an integer number of rupees, never a float. Every amount also
  arrives pre-formatted (`price_label: "PKR 2,500"`) so no two consumers can
  round differently.
- **Images** arrive as absolute URLs on the R2 public host. The database stores
  bare object keys; the URL is composed at read time, so never persist an image
  URL client-side — re-read it.
- **Handles** are returned with the `@` (`"@captain_tariq"`) and accepted with or
  without it.

Anything the SQL layer withheld is absent, not null: `owner_id`,
`internal_notes`, `commission_rate` and the ledger never appear on a public or
player response.

## Endpoint index

45 endpoints. "Auth" is the minimum role; staff always inherit owner routes.

| Endpoint | Auth | What it does |
| --- | --- | --- |
| `GET /v1/health` | — | liveness + whether Supabase and R2 are configured |
| `GET /v1/areas` | — | Karachi areas for the filter dropdown |
| `GET /v1/grounds` | — | the directory: search, filter, sort, paginate |
| `GET /v1/grounds/:ref/availability` | — | slot grid for one ground on one date |
| `GET /v1/grounds/:ref` | — | one ground by slug or id, with hours and slots |
| `GET /v1/matchmaking/games` | — | open-games feed |
| `GET /v1/me` | player | own profile + role, for choosing a landing page |
| `PATCH /v1/me` | player | edit own name, handle, phone, WhatsApp, city |
| `POST /v1/bookings` | player | book a slot — the only path that can 409 |
| `GET /v1/bookings/mine` | player | own bookings, `scope=upcoming\|past\|all` |
| `GET /v1/bookings/:id` | player | one booking (player, its owner, or staff) |
| `POST /v1/bookings/:id/cancel` | player | cancel own booking, optional reason |
| `PATCH /v1/bookings/:id/status` | owner | confirm / complete / no-show |
| `POST /v1/matchmaking/games` | player | post "need 3 players" |
| `POST /v1/matchmaking/games/:id/interest` | player | put your hand up; returns host's WhatsApp |
| `PATCH /v1/matchmaking/interests/:id` | player | host accepts or declines someone |
| `GET /v1/owner/grounds` | owner | own ground(s) + listing status |
| `GET /v1/owner/grounds/:id` | owner | one own ground with hours and closures |
| `PATCH /v1/owner/grounds/:id` | owner | edit operational fields only |
| `PUT /v1/owner/grounds/:id/hours` | owner | replace the weekly opening hours |
| `POST /v1/owner/grounds/:id/closures` | owner | block out a date range |
| `DELETE /v1/owner/grounds/:id/closures/:closureId` | owner | remove a closure |
| `GET /v1/owner/bookings` | owner | bookings across own grounds |
| `POST /v1/owner/bookings` | owner | log a walk-in / WhatsApp booking |
| `GET /v1/owner/subscriptions` | owner | own billing cycles, read-only |
| `GET /v1/admin/grounds` | admin | every ground, any status |
| `POST /v1/admin/grounds` | admin | create a ground (the only way one exists) |
| `GET /v1/admin/grounds/:id` | admin | full row incl. internal notes |
| `PATCH /v1/admin/grounds/:id` | admin | edit anything, incl. status and tier |
| `POST /v1/admin/grounds/:id/images` | admin | upload one image to R2 |
| `PATCH /v1/admin/grounds/:id/images` | admin | reorder / retitle / set cover |
| `DELETE /v1/admin/grounds/:id/images` | admin | remove one image |
| `GET /v1/admin/bookings` | admin | all bookings, filterable by date and ground |
| `GET /v1/admin/leads` | admin | WhatsApp onboarding queue |
| `POST /v1/admin/leads` | admin | log an owner who messaged us |
| `PATCH /v1/admin/leads/:id` | admin | work the lead; link the ground it became |
| `GET /v1/admin/subscriptions` | admin | billing cycles, paid/unpaid/overdue |
| `POST /v1/admin/subscriptions` | admin | open one cycle by hand |
| `POST /v1/admin/subscriptions/open-cycle` | admin | open this month for every pro ground |
| `PATCH /v1/admin/subscriptions/:id` | admin | mark paid, attach a payment link |
| `GET /v1/admin/users` | admin | people, filterable by role |
| `PATCH /v1/admin/users/:id/role` | superadmin | change someone's role |
| `GET /v1/finance/overview` | superadmin | commission, subscriptions, trends |
| `GET /v1/finance/ledger` | superadmin | row-level commission ledger |
| `GET /v1/finance/audit` | superadmin | who changed what |

## Public reads

### `GET /v1/grounds`

The directory. One round trip: filtering, sorting, the per-ground open-slot count
and the total all happen in SQL.

| Query | Type | Default | Notes |
| --- | --- | --- | --- |
| `city` | string | `Karachi` | |
| `area` | string | — | area name or slug |
| `date` | `YYYY-MM-DD` | today | which day the slot count is for |
| `min_price`, `max_price` | int | — | rupees per hour |
| `type` | `indoor` \| `outdoor` \| `both` | — | |
| `amenities` | CSV | — | e.g. `Floodlit,Nets,Parking`; matches all |
| `q` | string | — | free text over name, area and address |
| `only_open` | bool | `false` | drop grounds with no free slot on `date` |
| `sort` | see below | `featured` | |
| `limit`, `offset` | int | `24`, `0` | |

`sort` accepts `featured`, `price_asc`, `price_desc`, `rating`, `newest`, `name`.
Anything else is a `VALIDATION_ERROR` rather than a silent fallback. `featured`
puts paid placement first, then rating — it is the only sort that is not purely
mechanical, which is what the pro tier will eventually sell.

Only `status = 'active'` grounds are ever returned here.

```json
{
  "items": [
    {
      "id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
      "slug": "star-indoor-cricket",
      "name": "Star Indoor Cricket",
      "area": "Gulshan-e-Iqbal",
      "area_slug": "gulshan-e-iqbal",
      "city": "Karachi",
      "location_label": "Gulshan-e-Iqbal, Karachi",
      "type": "indoor",
      "tier": "free",
      "price_per_hour": 2500,
      "currency": "PKR",
      "price_label": "PKR 2,500",
      "weekend_price_label": "PKR 3,000",
      "rating": 4.8,
      "review_count": 42,
      "amenities": ["Floodlit", "Nets", "Parking"],
      "cover_image": "https://images.groundsnearme.pk/grounds/star-indoor/1-a.webp",
      "images": [{ "url": "https://images.groundsnearme.pk/grounds/star-indoor/1-a.webp", "alt": null, "sort": 0 }],
      "open_slots": 4,
      "availability_date": "2026-08-29",
      "slots_status": "open",
      "availability_badge": "Slots Open",
      "is_featured": true,
      "whatsapp_number": "920000000001",
      "whatsapp_url": "https://wa.me/920000000001?text=Hi%2C%20I'd%20like%20to%20book%20Star%20Indoor%20Cricket%20via%20GroundsNearMe."
    }
  ],
  "total": 137, "limit": 24, "offset": 0, "date": "2026-08-29"
}
```

`slots_status` / `availability_badge` are the badge on the card, computed once
server-side so the public site, the owner dashboard and the admin table never
disagree:

| `slots_status` | `availability_badge` | When |
| --- | --- | --- |
| `open` | `Slots Open` | at least one free slot on `date` |
| `full` | `Full Today` | open, but every slot taken |
| `closed` | `Closed Today` | closed that weekday, or a closure covers it |
| `unknown` | `null` | no date was resolved (rare) |

The list endpoint cannot tell `full` from `closed` — its count is just a number —
so a closed ground reads as `Full Today` in the grid and as `Closed Today` on the
detail page, which is where `hours` is available to disambiguate.

### `GET /v1/grounds/:ref`

`:ref` is the slug (`star-indoor-cricket`) or the uuid. Prefer the slug: it is
what the URL bar should show. `?date=YYYY-MM-DD` picks the day, default today.
`404 GROUND_NOT_FOUND` for an unknown or non-active ground.

```json
{
  "ground": { "…": "every field from the list, plus", "description": "…", "address": "…",
              "lat": 24.92, "lng": 67.09, "surface": "Astro", "pitch_count": 2,
              "contact_name": "Tariq", "slot_duration_minutes": 60, "advance_booking_days": 30 },
  "hours": [
    { "day_of_week": 1, "day_name": "Monday", "opens_at": "09:00", "closes_at": "02:00", "is_closed": false, "label": "09:00 – 02:00" }
  ],
  "slots": [
    { "start_time": "19:00", "end_time": "20:00", "is_available": true, "reason": null, "price": 2500, "label": "7:00 PM – 8:00 PM", "price_label": "PKR 2,500" }
  ],
  "closures": [{ "starts_on": "2026-09-06", "ends_on": "2026-09-07", "reason": "Tournament" }],
  "date": "2026-08-29"
}
```

Coordinates are `lat` / `lng`, the ground type is `type`, and the listing tier is
`tier` — the SQL renames them on the way out, so bind to these and not to the
column names.

`day_of_week` is 0 = Sunday. `slots` is empty on a closed day — that is the
signal, not a flag. `reason` on an unavailable slot is one of exactly four values:
`booked`, `closed` (a `ground_closures` date range covers the day), `past` (already
started today) or `out_of_window` (outside `advance_booking_days`). Show it as the
tooltip rather than inventing copy.

### `GET /v1/grounds/:ref/availability`

The slot grid alone, for the date picker — same data, ~90% smaller payload, and
it 404s on a stale slug exactly like the detail route.

```json
{ "ground": { "id": "…", "slug": "star-indoor-cricket", "name": "Star Indoor Cricket" },
  "date": "2026-08-30", "slots": [ … ], "open_slots": 4, "is_closed": false }
```

### `GET /v1/areas`

`{ "items": [{ "id": "…", "name": "Gulshan-e-Iqbal", "slug": "gulshan-e-iqbal", "city": "Karachi", "sort_order": 10 }], "total": 12 }`

## Bookings

### `POST /v1/bookings`

Requires a token. The one endpoint where concurrency is real.

```json
{
  "ground_id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
  "booking_date": "2026-08-30",
  "start_time": "19:00",
  "end_time": "20:00",
  "contact_name": "Tariq",
  "contact_phone": "03001234567",
  "players_expected": 12,
  "notes": "Bringing our own bats",
  "hold_minutes": 30
}
```

`ground_id`, `booking_date`, `start_time`, `end_time` are required; the rest are
optional. `date` is accepted as an alias for `booking_date`. `hold_minutes` is
5–120, default 30.

`201` on success:

```json
{ "booking": {
  "id": "…", "booking_ref": "GNM-2608-ABC123", "status": "pending",
  "payment_status": "unpaid", "booking_date": "2026-08-30",
  "start_time": "19:00:00", "end_time": "20:00:00", "duration_minutes": 60,
  "price_per_hour": 2500, "total_amount": 2500, "currency": "PKR",
  "amount_label": "PKR 2,500", "slot_label": "7:00 PM – 8:00 PM",
  "is_upcoming": true, "hold_expires_at": "2026-08-29T14:30:00Z",
  "ground": { "id": "…", "slug": "star-indoor-cricket", "name": "Star Indoor Cricket", "whatsapp_number": "920000000001" }
} }
```

New bookings are `pending` with a hold, not confirmed. Show the owner's WhatsApp
link and the `booking_ref` on the confirmation screen — that reference is what
the owner will ask for. A hold that is never confirmed is swept to `expired` by
the cron; the slot frees itself.

Statuses: `pending → confirmed → completed`, with `cancelled`, `no_show` and
`expired` as terminals. A player can only ever move a booking to `cancelled`;
attempting anything else is `403 PLAYER_CAN_ONLY_CANCEL`.

### `GET /v1/bookings/mine`

`?scope=upcoming|past|all` (default `all`), `?status=…`, `?limit`, `?offset`.
Returns the `{items,total,limit,offset}` envelope of the same booking objects.
`upcoming` sorts ascending by date, the others descending — the order the two
tabs of "My bookings" want.

### `GET /v1/bookings/:id`

Visible to the player who booked it, the owner of that ground, or staff. Anyone
else gets `404`, not `403` — a stranger's booking id should not be confirmable by
poking at the API.

### `POST /v1/bookings/:id/cancel`

Body is optional: `{ "reason": "Rain" }`. Returns the updated booking.
`409 NOT_CANCELLABLE` if it has already started, completed or been cancelled.

### `PATCH /v1/bookings/:id/status`

Owner/staff only. `{ "status": "confirmed" }`, or `completed`, `no_show`,
`cancelled` with an optional `reason`. This is the button on the owner dashboard's
booking row. Marking a booking `completed` is what accrues commission into the
ledger, so it is not cosmetic.

## Matchmaking

### `GET /v1/matchmaking/games`

Public. `?city`, `?area`, `?skill=beginner|intermediate|advanced|any`,
`?looking_for=players|opposition`, `?from_date`, `?limit` (20), `?offset`.

```json
{ "items": [{
  "id": "…", "title": "Need 3 players — Saturday 7PM, Star Indoor",
  "handle": "@captain_tariq", "match_date": "2026-09-05", "start_time": "19:00:00",
  "when_label": "2026-09-05 · 7:00 PM", "looking_for": "players",
  "skill_level": "intermediate", "players_needed": 3, "format": "T10",
  "interest_count": 4, "interest_label": "4 players expressed interest",
  "ground": { "id": "…", "name": "Star Indoor", "cover_image": "https://images.groundsnearme.pk/…" }
}], "total": 18, "limit": 20, "offset": 0 }
```

The host's phone number is **not** in the feed — it is returned only to someone
who has actually expressed interest. `interest_label` is pre-singularised
(`"1 player expressed interest"`, `"No interest yet"`).

### `POST /v1/matchmaking/games`

```json
{ "title": "Need 3 players — Saturday 7PM, Star Indoor", "match_date": "2026-09-05",
  "looking_for": "players", "skill_level": "intermediate", "players_needed": 3,
  "start_time": "19:00", "format": "T10", "ground_id": "…", "area_id": "…", "notes": "…" }
```

`title` (6–120 chars) and `match_date` are required; `players_needed` is required
when `looking_for` is `players`. `201 { "game": { … } }`. Five per hour.

### `POST /v1/matchmaking/games/:id/interest`

Optional `{ "message": "I keep wicket" }`. `201` with the host's contact, which is
the whole point of the feature:

```json
{ "interest": { "id": "…", "status": "interested" }, "interest_count": 5,
  "host_whatsapp_number": "920000000001",
  "host_whatsapp_url": "https://wa.me/920000000001?text=Hi!%20I'm%20interested%20in%20your%20game%20on%20GroundsNearMe." }
```

`409 HOST_CANNOT_JOIN` on your own game, `409 GAME_CLOSED` once it is full or past.

### `PATCH /v1/matchmaking/interests/:id`

Host-side triage: `{ "status": "accepted" }` — also `declined`, `interested`,
`withdrawn`. Returns `{ "id", "status" }`.

## Own profile

### `GET /v1/me`

```json
{ "user": { "id": "…", "role": "owner", "full_name": "Tariq", "handle": "@captain_tariq",
  "email": "…", "phone": "…", "whatsapp_number": "920000000001", "city": "Karachi",
  "avatar_url": null, "is_active": true, "created_at": "…" } }
```

Use `role` to route: `player` → the public site, `owner` → the owner dashboard,
`admin`/`superadmin` → the internal views. Do not trust it for authorisation; the
API re-checks on every call.

### `PATCH /v1/me`

`full_name`, `handle`, `phone`, `whatsapp_number`, `city`. Only keys present in the
body are touched. `role` is ignored if sent — role changes go through
`PATCH /v1/admin/users/:id/role` and are superadmin-only. A handle must be 3–24
characters of `a–z`, `0–9` or `_`.

## Owner dashboard

Scope for launch: the ground(s), the bookings, the billing status. No owner-facing
analytics — that is Phase 2 and there is deliberately no endpoint for it, so the
dashboard cannot quietly grow one.

### `GET /v1/owner/grounds` · `GET /v1/owner/grounds/:id`

`{ items, total }` of the owner's grounds; the single form adds `hours` and the
upcoming `closures`. `status` and `listing_tier` are visible (that is the "listing
status" the dashboard shows) but not writable here.

### `PATCH /v1/owner/grounds/:id`

Operational fields only: `description`, `address`, `surface`, `contact_name`,
`phone`, `whatsapp_number`, `pitch_count`, `price_per_hour`,
`weekend_price_per_hour`, `amenities`, `slot_duration_minutes` (30/60/90/120),
`min_booking_minutes`, `max_booking_minutes`, `advance_booking_days`.

`status`, `listing_tier`, `is_featured`, `featured_rank` and `commission_rate` are
not in that list. Sending them changes nothing here, and a direct PostgREST write
is rejected by a trigger — an owner cannot promote their own listing.

### `PUT /v1/owner/grounds/:id/hours`

Replaces the week in a single upsert, so the grid can never half-save:

```json
{ "hours": [ { "day_of_week": 1, "opens_at": "09:00", "closes_at": "02:00", "is_closed": false },
             { "day_of_week": 5, "is_closed": true } ] }
```

1–7 entries, no duplicate `day_of_week`. A closed day may omit the times.

### `POST /v1/owner/grounds/:id/closures` · `DELETE …/closures/:closureId`

`{ "starts_on": "2026-09-06", "ends_on": "2026-09-07", "reason": "Tournament" }` —
`ends_on` defaults to `starts_on` for a single day. Slots inside a closure come
back `is_available: false, reason: "closed"`.

### `GET /v1/owner/bookings`

`?scope=upcoming|past|all` (default `upcoming`), `?status`, `?ground_id`, `?limit`,
`?offset`. Upcoming bookings and history are the same endpoint, two scopes.

### `POST /v1/owner/bookings`

Walk-ins and WhatsApp bookings the owner took offline, so the grid reflects
reality:

```json
{ "ground_id": "…", "booking_date": "2026-08-30", "start_time": "20:00",
  "end_time": "21:00", "contact_name": "Walk-in", "contact_phone": "0300…",
  "source": "whatsapp", "confirmed": true }
```

Opening-hours checks are skipped — the owner knows their own exceptions — but the
exclusion constraint still applies, so this can return `409 SLOT_TAKEN` against a
web booking. `source` is `whatsapp` (default), `admin`, `owner` or `web`.

### `GET /v1/owner/subscriptions`

Read-only, last 36 cycles:

```json
{ "items": [{ "id": "…", "tier": "pro", "cycle_start": "2026-08-01", "cycle_end": "2026-09-01",
  "amount": 2000, "amount_label": "PKR 2,000", "status": "unpaid", "is_paid": false,
  "payment_method": "jazzcash", "payment_link": "https://…", "invoice_ref": "GNM-INV-0042",
  "paid_at": null }], "total": 3, "unpaid": 1 }
```

An owner cannot mark their own cycle paid — they pay via `payment_link` and a team
member flips the status once the transfer lands.

## Admin (internal)

### Grounds

`POST /v1/admin/grounds` is the only way a ground comes into existence. There is
no public self-serve listing form, by design: an owner messages us on WhatsApp, a
team member logs the lead, then types the details in here.

```json
{ "name": "Star Indoor Cricket", "area_id": "…", "owner_id": "…", "address": "…",
  "ground_type": "indoor", "price_per_hour": 2500, "whatsapp_number": "920000000001",
  "amenities": ["Floodlit", "Nets", "Parking"], "status": "pending",
  "listing_tier": "free", "commission_rate": 0.1, "internal_notes": "Lead from 12 Aug" }
```

`name` and `price_per_hour` are required. `slug` is derived from the name unless
sent. Creation seeds Mon–Sun `09:00 → 02:00` hours (override with `opens_at` /
`closes_at`) so the ground is bookable the moment it goes `active`. Status flow is
`draft → pending → active`, with `paused`, `rejected`, `archived`.

`PATCH /v1/admin/grounds/:id` takes the same fields plus `is_featured` and
`featured_rank`. `commission_rate` is a fraction, 0–0.5.

### Images

`POST /v1/admin/grounds/:id/images?alt=Main%20pitch` — a **raw binary** PUT-style
body, not multipart:

```js
await fetch(`${API}/v1/admin/grounds/${id}/images?alt=${encodeURIComponent(alt)}`, {
  method: 'POST',
  headers: { authorization: `Bearer ${token}`, 'content-type': file.type },
  body: file,
});
```

One request per file, so a progress bar is trivial and nothing is base64-inflated.
`jpeg`, `png`, `webp`, `avif`; 8 MB max; 12 images per ground. `201`:

```json
{ "image": { "url": "https://images.groundsnearme.pk/grounds/star-indoor/1724…-a1b2.webp",
             "key": "grounds/star-indoor/1724…-a1b2.webp", "alt": "Main pitch", "sort": 0, "size": 184320 },
  "images": [ … ], "cover_image": "grounds/star-indoor/1724…-a1b2.webp" }
```

The database row stores the **key**; the public URL is composed at read time from
`R2_PUBLIC_BASE_URL`. That is why moving the CDN host later is a config change, not
a data migration.

`PATCH /v1/admin/grounds/:id/images` with `{ "images": [{ "key": "…", "alt": "…" }, …] }`
reorders, retitles and sets the cover in one call — `images[0]` becomes the cover.
Every key must already be on that row.

`DELETE /v1/admin/grounds/:id/images` with `{ "key": "…" }` removes it from the row
first, then from the bucket. If the bucket delete fails you get an orphaned object
rather than a row pointing at a 404.

### Bookings oversight

`GET /v1/admin/bookings` — `?status`, `?ground_id`, `?from`, `?to`, `?limit` (50,
max 200), `?offset`. Full rows, newest first.

### WhatsApp lead queue

`GET/POST /v1/admin/leads`, `PATCH /v1/admin/leads/:id`. Internal only — this is
the inbox side of WhatsApp onboarding, never a public form.

`POST` needs `whatsapp_number`; `owner_name`, `ground_name`, `area_text`, `city`,
`asking_price`, `source`, `notes`, `assigned_to` are optional. Each item comes back
with a ready `whatsapp_url` so a team member can reply in one click.

`PATCH` moves `status` through `new → contacted → onboarding → listed` (or
`rejected`), and takes `created_ground_id` to link the ground the lead became.
Send `{ "first_contact_at": true }` to stamp the first reply.

### Subscription cycles

No auto-recurring billing at launch. JazzCash and EasyPaisa have no mature mandate
flow and local owners rarely hold cards, so a "subscription" is a row per month
with a payment link and a status a human flips. Revisit true recurring billing when
the volume justifies the integration work.

`GET /v1/admin/subscriptions` — `?status=unpaid|paid|overdue|waived|cancelled`,
`?owner_id`, `?limit`, `?offset`. Each item adds `is_paid`, `is_overdue`,
`amount_label` and `owner_whatsapp_url`; the envelope adds `unpaid_total` in rupees
so the dashboard can show one number for what is outstanding.

`POST /v1/admin/subscriptions` opens one cycle by hand:

```json
{ "owner_id": "…", "ground_id": "…", "tier": "pro", "cycle_start": "2026-09-01",
  "cycle_end": "2026-10-01", "amount": 2000, "payment_method": "jazzcash",
  "payment_link": "https://…", "invoice_ref": "GNM-INV-0042" }
```

`cycle_end` defaults to the first of the next month. `POST /v1/admin/subscriptions/open-cycle`
does the whole batch — `{ "month": "2026-09-01", "amount": 2000 }`, both optional —
and returns `{ "cycles_created": 7, "cycle_start", "cycle_end" }`. It is a button,
not a cron job: the cron runs with the service-role key where `auth.uid()` is null
and the RPC requires staff, and someone has to send the payment links anyway.

`PATCH /v1/admin/subscriptions/:id` is where money gets recorded: `status`,
`payment_method`, `payment_link`, `invoice_ref`, `amount`, `notes`, and
`{ "reminder_sent": true }` to stamp `reminder_sent_at`. `paid_at` is set by a
trigger when the status becomes `paid` — do not send it.

### People

`GET /v1/admin/users` — `?role=player|owner|admin|superadmin`, `?limit`, `?offset`.

`PATCH /v1/admin/users/:id/role` — `{ "role": "owner" }`. **Superadmin only**, so a
plain admin cannot mint another admin. A trigger enforces the same rule at the
database level.

## Private finance (superadmin only)

Shayan's dashboard. Gated three times over: `requireSuperadmin` in the Worker,
`is_superadmin()` inside `finance_overview()`, and RLS on `commission_ledger` and
`audit_log`. A plain `admin` hitting these gets a clean `403` — not a
partially-filled P&L.

### `GET /v1/finance/overview`

`?months=12` (1–36) sets the trend window.

```json
{
  "window": { "from": "2025-09-01", "months": 12 },
  "totals": { "commission_all_time": 184500, "commission_collected": 152000,
              "commission_outstanding": 32500, "commissionable_bookings": 1240,
              "commission_all_time_label": "PKR 184,500",
              "commission_collected_label": "PKR 152,000",
              "commission_outstanding_label": "PKR 32,500" },
  "subscriptions": { "paid_all_time": 46000, "unpaid_current": 8000, "active_pro_owners": 7,
                     "paid_all_time_label": "PKR 46,000", "unpaid_current_label": "PKR 8,000" },
  "revenue": { "commission": 152000, "subscriptions": 46000, "combined": 198000,
               "combined_label": "PKR 198,000" },
  "bookings": { "total": 1610, "completed": 1240, "this_month": 96, "gross_booked_value": 3120000 },
  "grounds": { "active": 42, "pending": 5, "pro": 7 },
  "commission_trend":   [{ "month": "2026-08-01", "month_label": "Aug 2026", "commission": 21400, "collected": 18000, "bookings": 96 }],
  "subscription_trend": [{ "month": "2026-08-01", "month_label": "Aug 2026", "paid": 14000, "unpaid": 4000 }],
  "booking_trend":      [{ "month": "2026-08-01", "month_label": "Aug 2026", "bookings": 96, "completed": 88, "value": 214000 }],
  "top_grounds": [{ "ground_id": "…", "ground_name": "Star Indoor Cricket",
                    "ground_slug": "star-indoor-cricket", "area": "Gulshan-e-Iqbal",
                    "bookings": 41, "gross_amount": 102500, "commission_amount": 10250,
                    "gross_label": "PKR 102,500", "commission_label": "PKR 10,250" }]
}
```

Every trend array is gap-filled: a month with no activity is present with zeros, so
a chart never has to interpolate and the x-axis is always `months` long. `top_grounds`
is capped at 20, sorted by commission.

Commission revenue and subscription revenue stay in separate blocks all the way
through — they are different businesses, and blending them would hide which one is
actually working. `revenue.combined` exists for the one headline number that wants
it. `month_label` is pre-formatted (`"Aug 2026"`) so a chart can label its axis
without extra date code.

### `GET /v1/finance/ledger`

`?status=accrued|invoiced|collected|written_off`, `?month=2026-08-01`, `?limit` (100,
max 500), `?offset`. Row-level commission behind the totals, for reconciliation.
Each row carries `month_label`, `gross_label`, `commission_label` and the embedded
ground and booking ref; the envelope carries `sum_commission` for the page.

### `GET /v1/finance/audit`

`?entity=grounds`, `?limit`, `?offset`. `{ id, actor_id, actor_role, action, entity,
entity_id, diff, created_at }`. Read-only — nothing can write it over the API.

## Swapping the mock data in `js/api.js`

The response fields were chosen to match what `index.html` already renders, so the
swap should be a change of data source, not a change of markup.

| What the mock card shows | Field to bind |
| --- | --- |
| `PKR 2,500` | `price_label` |
| `Gulshan-e-Iqbal, Karachi` | `location_label` |
| `Slots Open` / `Full Today` | `availability_badge` (+ `slots_status` for the colour) |
| `7:00 PM – 8:00 PM` | `slot.label` |
| the WhatsApp button | `whatsapp_url` (already includes the prefilled message) |
| `@captain_tariq` | `handle` |
| `4 players expressed interest` | `interest_label` |
| the card photo | `cover_image` (absolute URL, ready for `<img src>`) |

Nothing needs client-side formatting. If a label is missing it is `null` — render
the fallback, do not compute a replacement, or the three consumers drift.

A minimal client:

```js
const API = 'https://api.groundsnearme.pk';

async function call(path, { method = 'GET', body, token } = {}) {
  const res = await fetch(API + path, {
    method,
    headers: {
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  const data = await res.json().catch(() => null);
  if (!res.ok) {
    const err = new Error(data?.error?.message || 'Something went wrong.');
    err.code = data?.error?.code || 'INTERNAL_ERROR';
    err.status = res.status;
    err.field = data?.error?.details?.field || null;
    throw err;   // show err.message; branch on err.code
  }
  return data;
}

export const getGrounds = (params) => call(`/v1/grounds?${new URLSearchParams(params)}`);
export const getGround = (slug, date) => call(`/v1/grounds/${slug}${date ? `?date=${date}` : ''}`);
export const getAvailability = (slug, date) => call(`/v1/grounds/${slug}/availability?date=${date}`);
export const createBooking = (payload, token) => call('/v1/bookings', { method: 'POST', body: payload, token });
export const getOpenGames = (params) => call(`/v1/matchmaking/games?${new URLSearchParams(params)}`);
```

Three rules worth keeping in the client:

1. **Never call Supabase directly from the browser.** The anon key would work, but
   it bypasses the rate limits and the shaping, and it hard-codes the DB schema
   into the frontend.
2. **Treat `409 SLOT_TAKEN` as a normal outcome**, not an error state — re-fetch
   availability and let the player pick again.
3. **Re-read image URLs**; never persist them. The database stores keys.

## Not in this contract, on purpose

- No public ground-listing form. Grounds are created only by staff via
  `POST /v1/admin/grounds`, after a WhatsApp conversation.
- No owner analytics endpoint. Phase 2.
- No pro-tier signup or checkout. The tier exists in the schema so placement can be
  sold later; nothing surfaces it publicly at launch.
- No card payments and no auto-recurring billing. Monthly cycles are rows with a
  payment link and a paid/unpaid status.
- No push or email notifications. WhatsApp links are the notification layer.
