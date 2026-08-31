# GroundsNearMe — data model

Postgres on Supabase is the source of truth for everything structured. R2 holds
only image bytes. Nothing in the schema assumes a particular frontend, and nothing
in the frontend is allowed to assume a particular table — the Worker's API contract
sits between them.

24 migrations in `supabase/migrations/`, applied in filename order. They are
idempotent where it is cheap to be (`create table if not exists`,
`create or replace function`), so re-running the folder against an existing project
is safe.

| File | Contains |
| --- | --- |
| `…0001_extensions_enums` | `pgcrypto`, `btree_gist`, `citext`; all enums |
| `…0002_profiles` | `profiles`, role helpers, the signup trigger |
| `…0003_areas_grounds` | `areas`, `grounds`, cover-image sync |
| `…0004_ground_hours` | `ground_hours`, `ground_closures` |
| `…0005_bookings` | `bookings` + the overlap exclusion constraint |
| `…0006_matchmaking` | `open_games`, `open_game_interests` |
| `…0007_monetization` | `owner_subscriptions`, `commission_ledger` |
| `…0008_leads_audit` | `ground_leads`, `audit_log` |
| `…0009`–`…0016` | the RPCs: availability, bookings, search, matchmaking |
| `…0017`–`…0019` | RLS policies: core, bookings/matchmaking, money/internal |
| `…0020`–`…0021` | finance views + `finance_overview()` |
| `…0022_maintenance` | the three housekeeping functions the cron calls |
| `…0023_areas_reference_data` | Karachi areas |
| `…0024_bootstrap_staff` | promotes the first superadmin |

## Extensions

`pgcrypto` (uuid generation), `btree_gist` (the overlap constraint below) and
`citext` (case-insensitive email), all installed into `extensions`, not `public`.

## Enums

15 of them, created in one idempotent pass in `…0001`:

`user_role` (`player`, `owner`, `admin`, `superadmin`) · `ground_status` (`draft`,
`pending`, `active`, `paused`, `rejected`, `archived`) · `ground_type` (`indoor`,
`outdoor`, `both`) · `listing_tier` (`free`, `pro`) · `booking_status` (`pending`,
`confirmed`, `cancelled`, `completed`, `no_show`, `expired`) · `payment_status`
(`unpaid`, `partial`, `paid`, `refunded`) · `booking_source` (`web`, `whatsapp`,
`admin`, `owner`) · `game_status` (`open`, `filled`, `cancelled`, `expired`) ·
`skill_level` (`beginner`, `intermediate`, `advanced`, `any`) · `looking_for`
(`players`, `opposition`) · `interest_status` (`interested`, `accepted`,
`declined`, `withdrawn`) · `subscription_status` (`unpaid`, `paid`, `overdue`,
`waived`, `cancelled`) · `payment_method` (`jazzcash`, `easypaisa`,
`bank_transfer`, `cash`, `other`) · `commission_status` (`accrued`, `invoiced`,
`collected`, `written_off`) · `lead_status` (`new`, `contacted`, `onboarding`,
`listed`, `rejected`).

Enums rather than text plus a check constraint: a typo becomes an error at write
time, and the API's `oneOf()` validators mirror the same lists — when a label is
added here, the matching array in the Worker has to change too or the value is
rejected before it reaches the database.

## Tables

```
auth.users ──1:1──> profiles ──┬──< grounds >──┬──< ground_hours
                               │               ├──< ground_closures
                               │               ├──< bookings >── commission_ledger
                               │               └──< open_games >──< open_game_interests
                               ├──< owner_subscriptions
                               └──< ground_leads (created_by / assigned_to)
areas ──< grounds            audit_log (actor_id → profiles)
```

### `profiles`

One row per `auth.users` row, created by an `after insert` trigger on
`auth.users` — sign-up never needs a second write from the client. Holds `role`,
`full_name`, `handle` (unique, `[a-z0-9_]{3,24}`, stored without the `@`), `email`,
`phone`, `whatsapp_number`, `city`, `avatar_url`, `is_active`.

`role` lives here rather than in the JWT so it can be changed without forcing a
re-login. `tg_profiles_guard()` rejects any role change made by someone who is not
a superadmin, so a compromised admin session cannot escalate. `is_active = false`
is a soft ban: the token still verifies, but `roleOf()` in the Worker turns it into
`403 FORBIDDEN`.

Three helpers read this table and are used throughout the RLS policies:
`current_app_role()`, `is_staff()` (admin or superadmin), `is_superadmin()`.

### `areas`

Karachi neighbourhoods — `name`, `slug`, `city`, `sort_order`, `is_active`. Seeded
in `…0023` with the areas the mock UI shows (Gulshan-e-Iqbal, Nazimabad, DHA, PECHS
and the rest). A flat list, not a hierarchy: Karachi does not need one, and a
dropdown that fits on a phone is worth more than a taxonomy.

### `grounds`

The centre of the schema. Identity and content: `slug` (unique, checked against
`^[a-z0-9]+(-[a-z0-9]+)*$`), `name`, `area_id`, `city`, `address`, `latitude`,
`longitude`, `description`, `ground_type`, `surface`, `pitch_count`, `amenities`
(`text[]`, GIN-indexed), `images` (`jsonb`), `cover_image_url`.

Commercial: `owner_id`, `status`, `listing_tier`, `is_featured`, `featured_rank`,
`commission_rate`, `internal_notes`, `created_by`.

Booking rules: `price_per_hour`, `weekend_price_per_hour`, `currency`,
`slot_duration_minutes` (30/60/90/120), `min_booking_minutes`,
`max_booking_minutes` (must be ≥ the minimum), `advance_booking_days` (1–365),
plus `rating` and `review_count` for display.

Four check constraints are worth knowing because the API mirrors them:
`grounds_slug_format`, `grounds_whatsapp_format` (`^[0-9]{10,15}$`, digits only —
which is why `whatsappNumber()` strips everything else), `grounds_images_is_array`
and `grounds_booking_window`.

`commission_rate` defaults to 0 and is capped at 0.5. It is copied onto each
booking at creation time, so raising the platform rate later never rewrites
historical commission.

`tg_grounds_sync_cover()` keeps `cover_image_url` equal to `images -> 0 ->> 'url'`
when it is null, so uploading the first photo sets the cover without a second call.
`tg_grounds_owner_guard()` rejects an owner's attempt to change `status`,
`listing_tier`, `is_featured`, `featured_rank`, `featured_until`,
`commission_rate` or `owner_id` — the API leaves those fields out of the owner
route, and the trigger means a direct PostgREST call cannot get around that.
`tg_grounds_audit_status()` writes a row into `audit_log` on every status change.

### `ground_hours` and `ground_closures`

`ground_hours` is one row per `(ground_id, day_of_week)` — 0 = Sunday — with
`opens_at`, `closes_at`, `is_closed`. A `closes_at` earlier than `opens_at` means
the ground shuts after midnight; the availability function handles the wrap. The
unique key on `(ground_id, day_of_week)` is what lets the owner dashboard replace
the whole week with one upsert.

`ground_closures` is a date range (`starts_on`, `ends_on`, `reason`) for Eid,
tournaments and maintenance. Slots inside a closure still appear in the grid but
come back `is_available: false, reason: 'closed'`.

`set_ground_hours_all_days()` exists for seeding and admin work and is revoked from
`authenticated`, which is why the owner route upserts `ground_hours` directly under
its RLS policy instead of calling it.

### `bookings`

Every column the booking flow needs, plus one generated column that does the heavy
lifting:

```sql
slot tsrange generated always as (
  tsrange((booking_date + start_time),
          ((case when end_time <= start_time then booking_date + 1 else booking_date end) + end_time),
          '[)')
) stored,

constraint bookings_no_overlap exclude using gist (
  ground_id with =,
  slot      with &&
) where (status in ('pending','confirmed'))
```

`slot` is a *naive* `tsrange` in Karachi wall-clock time, not a `tstzrange`. A
generated column has to be immutable, and any timezone conversion is not — but
Pakistan has no DST, so wall-clock arithmetic is exactly right here. The
`case` handles a booking that crosses midnight (23:00 → 01:00 becomes a range
ending on the next date).

The exclusion constraint is the whole concurrency story. Two requests for the same
slot arriving in the same millisecond do not race: Postgres serialises them and the
loser gets SQLSTATE `23P01`, which `create_booking()` turns into
`{ok:false, error:{code:'SLOT_TAKEN'}}` and the Worker into `409`. No advisory
locks, no polling, no read-then-write window. The `where` clause means cancelled
and expired rows stop blocking the slot automatically.

`player_id` is nullable on purpose: walk-in and WhatsApp bookings entered by an
owner have no account attached, and they still have to block the slot.
`booking_ref` is `GNM-YYMM-XXXXXX` (`generate_booking_ref()`: the Karachi year and
month, then six upper-cased hex characters) and is what a customer reads out over
the phone.

`commission_rate` and `commission_amount` are frozen copies taken at creation.
`hold_expires_at` gives an unconfirmed booking a 30-minute default lease; the cron
sweeps the rest.

Four triggers:

- `tg_set_updated_at()` — shared by every table with an `updated_at`.
- `tg_bookings_stamp_status()` — derives `confirmed_at`, `cancelled_at`,
  `completed_at` from the status change and clears `hold_expires_at` on confirm.
  Timestamps are never client-supplied.
- `tg_bookings_player_guard()` — a player may change `notes`, `contact_name`,
  `contact_phone` and `players_expected`, and may set `status` to `cancelled`.
  Anything else (`booking_date`, `start_time`, `end_time`, `ground_id`,
  `total_amount`, `price_per_hour`, `commission_rate`, `commission_amount`,
  `payment_status`, `player_id`) raises `FIELD_NOT_PLAYER_EDITABLE`; any other
  status raises `PLAYER_CAN_ONLY_CANCEL`. Staff and the ground's owner skip the
  guard entirely.
- `tg_bookings_accrue_commission()` — writes the ledger row when a booking becomes
  `completed`, and writes it off if that booking is later reverted. Zero-rate
  bookings (the launch default) accrue nothing at all.

### `open_games` and `open_game_interests`

Matchmaking is deliberately thin: it is a classified ad, not a league system.
An `open_games` row is either "we need N players" (`looking_for = 'players'`, and
`open_games_needs_count` then requires `players_needed`) or "our team wants
opposition" (`looking_for = 'opposition'`, count optional).

`host_handle` is denormalised from `profiles.handle` so the public list renders
`@handle` without exposing the profiles table to `anon`, and it carries the same
`^[a-z0-9_]{3,24}$` check. `ground_id` and `area_id` are both optional and both
`on delete set null` — a game posted for a ground that is later archived stays
readable. `title` is 6–120 characters, `players_needed` 1–22.

`open_game_interests` is one row per interested player, unique on
`(open_game_id, player_id)`, so tapping "I'm interested" twice is idempotent at the
database level rather than in the UI. Two triggers:

- `tg_interest_not_host()` — a host expressing interest in their own game raises
  `HOST_CANNOT_JOIN_OWN_GAME`, which surfaces as `409 HOST_CANNOT_JOIN`.
- `tg_interest_maybe_fill()` — once accepted interests reach `players_needed`, the
  game flips `open` → `filled` by itself. Games with no count never auto-fill.

Visibility is worth spelling out because the public site depends on it: `anon` can
read `open_games` where `status = 'open'` and nothing at all from
`open_game_interests`. The "N players interested" counter reaches the frontend only
as an aggregate inside `list_open_games()`. A player sees their own interests; a
host sees the interests on their own games.

### `owner_subscriptions`

One row per owner per ground per billing cycle, unique on
`(owner_id, ground_id, cycle_start)`. This is the manual/semi-automated recurring
model: `payment_link` holds the JazzCash / EasyPaisa / bank-transfer link issued for
that cycle, `status` moves `unpaid → paid` (or `waived`, `overdue`, `cancelled`),
and `tg_subscription_stamp_paid()` stamps `paid_at` on the transition so nobody has
to remember to fill it in. `invoice_ref` is unique, `reminder_sent_at` records the
nudge, `cycle_end > cycle_start` is enforced.

No card-on-file, no webhook, no auto-charge — that is a scale decision, not an
oversight, and the table is shaped so switching to a gateway later means adding
columns rather than rewriting the model. Owners have `select` and nothing else:
flipping a cycle to paid is staff work.

### `commission_ledger`

One row per commissionable booking, `unique (booking_id)`, so the accrual trigger
is safe to fire twice. `earned_month` is forced to the first of the month by
`commission_earned_month_is_first_of_month`, which is what makes the monthly
rollups a plain `group by` with no date juggling. `gross_amount`,
`commission_rate` and `commission_amount` are copies, not joins — a rate change or
a ground rename never rewrites history. `status` walks `accrued → invoiced →
collected`, or `written_off` if the booking is reverted.

Readable by superadmin only. That single RLS policy is what makes the four finance
views superadmin-only for free, because they are all `security_invoker = on`.

### `ground_leads`

The WhatsApp intake queue, and the reason there is no public listing form. An owner
messages the deep link on the public site; a team member records `owner_name`,
`whatsapp_number` (digits only, 10–15), `ground_name`, `area_text` as free text
(the area may not exist as a row yet), `asking_price`, `notes`, then moves `status`
through `new → contacted → onboarding → listed` (or `rejected`).
`created_ground_id` links the lead to the ground it became, which is how the funnel
is measured later. Internal only — no policy grants `anon` anything here.

### `audit_log`

Append-only, `bigserial`, `(actor_id, actor_role, action, entity, entity_id, diff)`.
`log_audit()` is `security definer` and fills the actor from `auth.uid()` and
`current_app_role()`, so a caller cannot claim to be someone else.
`tg_grounds_audit_status()` uses it to record `ground.created` and
`ground.status_changed` (with a `{from, to}` diff) automatically — the two events
that matter when a listing goes live or gets pulled.

## Functions

Anything that has to be atomic, or that needs to read a table the caller cannot see,
is a `security definer` function rather than Worker logic. The Worker validates and
shapes; the database decides.

Everything that can fail for a *business* reason returns a jsonb envelope instead of
raising:

```json
{ "ok": true,  "booking": { … } }
{ "ok": false, "error": { "code": "SLOT_TAKEN", "message": "Someone just took this slot. Pick another one." } }
```

That is not defensive politeness — PostgREST maps a raised exception to an HTTP
status by SQLSTATE, and the mapping is too coarse to distinguish "already
cancelled" from "not your booking". `unwrapRpc()` in the Worker reads the envelope
and looks the code up in `STATUS_BY_CODE`, so every failure gets the right status.

### Availability

| Function | Returns | Granted to |
| --- | --- | --- |
| `get_ground_availability(ground_id, date)` | one row per slot: `slot_start`, `slot_end`, `starts_at`, `ends_at`, `is_available`, `reason`, `price` | `anon`, `authenticated` |
| `count_open_slots(ground_id, date)` | `int` — available slots only | `anon`, `authenticated` |

The single source of truth for "is this bookable". The public site, the owner
dashboard and `create_booking()` all go through it, so there is no second
implementation to drift. It returns **zero rows** when the ground is not `active`,
has no `ground_hours` row for that weekday, or that row is `is_closed` — the
frontend reads an empty grid as *Closed Today*.

The walk is `opens_at` → `closes_at` in `slot_duration_minutes` steps, stopping when
a whole step no longer fits, so a 30-minute tail on a 60-minute grid is never
offered. `closes_at <= opens_at` extends the window past midnight. Weekend pricing
(`dow in (0,6)`) falls back to `price_per_hour` when
`weekend_price_per_hour` is null, and `price` is per slot, not per hour.

Precedence for `reason` is fixed: `out_of_window` → `closed` → `past` → `booked`.
A pending booking whose `hold_expires_at` has lapsed does **not** block a slot, so an
abandoned checkout frees the grid before the cron gets to it.

`count_open_slots()` is the badge input for list views. It cannot distinguish "full"
from "closed" — both are 0 — which is why the list endpoint's badge collapses them
and only the detail endpoint can tell them apart.

### Bookings

| Function | Caller | Envelope |
| --- | --- | --- |
| `create_booking(ground, date, start, end, contact_name, contact_phone, notes, players_expected, hold_minutes)` | any signed-in player | `booking` |
| `cancel_booking(booking_id, reason)` | player, ground owner or staff | `booking` |
| `set_booking_status(booking_id, status, reason)` | ground owner or staff | `booking` |
| `create_manual_booking(ground, date, start, end, contact_name, contact_phone, notes, source, confirmed)` | ground owner or staff | `booking` |
| `owns_ground(ground_id)` | helper, used by policies and the RPCs above | `boolean` |

`create_booking()` runs the checks in a deliberate order and returns the first
failure: `AUTH_REQUIRED`, `GROUND_NOT_AVAILABLE` (missing or not `active`),
`INVALID_TIME_RANGE`, `INVALID_DURATION` (not a whole number of slots, or outside
`min`/`max_booking_minutes`), `OUTSIDE_OPENING_HOURS` (the requested span does not
line up with the grid at all), then whichever of `SLOT_IN_PAST`, `GROUND_CLOSED`,
`OUTSIDE_BOOKING_WINDOW` or `SLOT_TAKEN` the unavailable slot's `reason` maps to.

It expires lapsed holds on that ground before checking, computes the price itself
from `price_per_hour` / `weekend_price_per_hour` — the client never sends an
amount — freezes `commission_rate` and `commission_amount` onto the row, and inserts
as `pending` with `hold_expires_at = now() + hold_minutes` (default 30, clamped to
5–180).

Then the important part: the insert is wrapped in its own `begin … exception` block.
`exclusion_violation` becomes `SLOT_TAKEN` and `unique_violation` (a `booking_ref`
collision) becomes `RETRY`. Everything before that block is advisory; *this* is the
guarantee. Two players tapping the same slot simultaneously both pass the
availability read and one of them loses here.

`cancel_booking()` allows the player, the ground's owner or staff, and only from
`pending` or `confirmed` — anything else is `NOT_CANCELLABLE`. It records
`cancelled_by` and `cancellation_reason`; `cancelled_at` is stamped by the trigger.

`set_booking_status()` accepts `confirmed`, `completed`, `no_show` or `cancelled`
(anything else is `INVALID_STATUS`) and refuses to revive a `cancelled` or `expired`
booking with `NOT_EDITABLE` — the slot may well have been resold by then, so the
correct move is a new booking, not a resurrection.

`create_manual_booking()` is the walk-in path. It skips the opening-hours check
because the owner knows their own exceptions, and it inserts with a null
`player_id`, but it goes through the same table and therefore the same exclusion
constraint — an offline booking blocks the public slot grid immediately.

### Public reads

| Function | Returns | Granted to |
| --- | --- | --- |
| `search_grounds(city, area, date, min_price, max_price, type, amenities, q, only_open, sort, limit, offset)` | `{items, total, limit, offset, date}` | `anon`, `authenticated` |
| `get_ground(ref, date)` | `{ok, ground, hours, slots, closures, date}` | `anon`, `authenticated` |

Both return a jsonb document rather than a rowset, which is what lets them hand the
frontend the *exact* object shape the mock data used — the field renames
(`latitude` → `lat`, `longitude` → `lng`, `ground_type` → `type`,
`listing_tier` → `tier`, `cover_image_url` → `cover_image`) happen here, once, in
SQL, and neither the Worker nor `js/api.js` has to translate.

`search_grounds()` only ever sees `status = 'active'` grounds. `area` matches either
the slug or the name, so a URL can carry either. `type` treats a `both` ground as
matching `indoor` *and* `outdoor`. `amenities` is a containment test (`@>`) against
the GIN index — every requested amenity must be present. `q` is a case-insensitive
substring over name, address and area name. `only_open` filters on
`count_open_slots(...) > 0` for `date`, defaulting to today in Karachi.

`sort` accepts `featured`, `price_asc`, `price_desc`, `rating`, `newest` or `name`,
and an unrecognised value silently falls back to `featured` rather than erroring —
a bad query string should not break the search page. Featured grounds float to the
top under `featured` only; every sort then breaks ties by `featured_rank`, then most
open slots, then name, so the ordering is stable across pages. `limit` is clamped to
1–100. `total` comes from a window function over the filtered set, so pagination
knows the real count.

`get_ground()` takes a slug *or* a uuid (36-char hex form) in the same parameter,
and is the only read that returns the full detail payload in one round trip: the
ground, all seven `hours` rows, the `slots` grid for `date`, and upcoming
`closures`. It emits times as `HH:MM`, unlike a raw PostgREST `time` column which
comes back `HH:MM:SS`. An unknown or non-active ref returns the `NOT_FOUND`
envelope, which the Worker turns into `404 GROUND_NOT_FOUND`.

### Matchmaking

| Function | Caller | Notes |
| --- | --- | --- |
| `list_open_games(city, area, skill, looking_for, from_date, limit, offset)` | `anon` | only `status = 'open'`, plus the interest count |
| `create_open_game(title, match_date, looking_for, skill_level, players_needed, start_time, format, ground_id, area_id, notes)` | signed-in player | stamps `host_id` and `host_handle` from the caller's profile |
| `express_interest(open_game_id, message)` | signed-in player | `GAME_CLOSED`, `HOST_CANNOT_JOIN` |
| `set_interest_status(interest_id, status)` | the game's host | `accepted` / `declined`; may flip the game to `filled` |

`list_open_games()` is the only way the interest *count* reaches the public site —
the rows themselves are invisible to `anon` by policy, so the aggregate is computed
inside the function. `create_open_game()` reads the handle from `profiles` rather
than trusting the client, which is what keeps `host_handle` honest despite being
denormalised; a player with no handle set gets `player_` plus the first six
characters of their id, so posting never blocks on profile completeness. It also
carries its own rate limit — five open games per host per rolling day, counted in
SQL — which is a backstop for the Worker's 5-per-hour KV limiter rather than a
duplicate of it: if `RATE_LIMIT` is unbound the KV check is skipped, and this one
still holds. Its other rejections are `PLAYERS_NEEDED_REQUIRED` and `DATE_IN_PAST`,
and out-of-range `looking_for` / `skill_level` values fall back to `players` / `any`
instead of erroring.

### Finance

`finance_overview(months = 12)` is the private dashboard in one call. It checks
`is_superadmin()` **inside** the function and returns a `FORBIDDEN` envelope
otherwise, so the gate does not depend on the Worker's route guard being wired
correctly — two independent locks on the same door. Trends are gap-filled with
`generate_series`, so a month with no bookings is a zero rather than a missing point
the chart has to interpolate. `top_grounds` is capped at 20.

### Maintenance

Four housekeeping functions, called from the Worker's `scheduled` handler (and safe
to wire to `pg_cron` instead if it is ever enabled). The first three are revoked
from both `anon` and `authenticated` — only the service-role key can run them.

| Function | Does | Returns |
| --- | --- | --- |
| `expire_stale_bookings()` | `pending` → `expired` once `hold_expires_at` has passed | count |
| `expire_past_open_games()` | `open` → `expired` once `match_date` is yesterday in Karachi | count |
| `complete_finished_bookings()` | `confirmed` → `completed` once `upper(slot)` is in the past | count |
| `open_subscription_cycle(month, amount = 2000)` | one `unpaid` row per active pro-tier ground for that month | `{ok, cycles_created, cycle_start, cycle_end}` |

All four are idempotent. `complete_finished_bookings()` is the one that matters
commercially: completing a booking is what fires
`tg_bookings_accrue_commission()`, so commission is a consequence of the cron
running, not of anyone remembering to click something.

`open_subscription_cycle()` is `is_staff()`-gated inside the function, upserts on
`(owner_id, ground_id, cycle_start)` so running it twice in a month creates nothing
the second time, and defaults to the current Karachi month. It is the *only*
subscription automation at launch: it opens the cycle, a human sends the JazzCash /
EasyPaisa / bank-transfer link, and staff flip the row to `paid`. With no grounds on
`pro` at launch it correctly creates zero rows.

## Row-level security

RLS is enabled on every table in `public`. The rule of thumb: `anon` can read
active listings and open games and nothing else; a signed-in user can read and edit
their own rows; an owner's reach is defined by `owns_ground()`; staff see
operations; only superadmin sees money.

| Table | `anon` | player | owner | staff | superadmin |
| --- | --- | --- | --- | --- | --- |
| `areas` | active only | active | active | all | all |
| `grounds` | `status = 'active'` | active | own (read + limited update) | all, full write | all |
| `ground_hours`, `ground_closures` | active grounds | read | own, full write | full write | full write |
| `bookings` | — | own | own grounds' | all | all |
| `open_games` | `status = 'open'` | own + open | — | all | all |
| `open_game_interests` | — | own | — | as host / staff | all |
| `owner_subscriptions` | — | — | own, **read-only** | full write | full write |
| `commission_ledger` | — | — | — | — | **only** |
| `ground_leads` | — | — | — | full write | full write |
| `audit_log` | — | — | — | — | read |
| `profiles` | — | own | own | read all | read all |

Two of those rows are load-bearing for the scope of this project.
`commission_ledger` has exactly one policy — `ledger_superadmin` — so the private
P&L is invisible to other admins by construction, not by a hidden route.
`owner_subscriptions` has a `select` policy for owners and no `insert` or `update`
policy at all, which is what makes "the owner cannot mark themselves paid" a
database fact rather than a UI convention.

Writes go through the RPCs almost everywhere, but the policies are written as if
they did not: `bookings_insert_own` and the guard triggers hold even for a caller
hitting PostgREST directly with a valid user token.

## Finance views

Four views, all `security_invoker = on`, which is the whole trick: they inherit the
caller's RLS instead of the view owner's, so the `commission_ledger` policy makes
three of them superadmin-only without a single extra grant.

| View | Grain | Columns |
| --- | --- | --- |
| `v_monthly_commission` | month | `bookings`, `gross_amount`, `commission_amount`, `collected_amount`, `outstanding_amount` |
| `v_commission_by_ground` | ground | `ground_name`, `ground_slug`, `area`, `bookings`, `gross_amount`, `commission_amount`, `last_earned_month` |
| `v_monthly_subscription_revenue` | month | `cycles`, `paid_cycles`, `unpaid_cycles`, `paid_amount`, `unpaid_amount` |
| `v_monthly_bookings` | month | `total_bookings`, `completed`, `confirmed`, `cancelled`, `active_grounds`, `unique_players`, `gross_booked_value` |

`written_off` rows are excluded from both commission views, so a reverted booking
leaves the totals rather than distorting them. Subscription revenue is deliberately
a separate view from commission — the brief asks for premium revenue tracked apart
from commission revenue, and keeping them unjoined means one can be zero at launch
without the other's chart breaking. `v_monthly_bookings` is staff-visible because it
reads `bookings`, not the ledger; it carries no money the ledger would have hidden
beyond booked value.

`finance_overview()` composes all four into one payload so the dashboard makes a
single request. Query the views directly only for ad-hoc work.

## Seed and bootstrap

`…0023_areas_reference_data` inserts 14 Karachi areas — Gulshan-e-Iqbal,
Gulistan-e-Johar, DHA / Defence, Clifton, Nazimabad, North Nazimabad, Federal B
Area, PECHS, Scheme 33, Malir, Korangi, Saddar, Shah Faisal, Surjani / Gadap —
upserted on `slug`, so re-running it is safe and editing a name in place is a
one-line change.

`…0024_bootstrap_staff` is the one migration that needs a human decision. There is
no way to create the first superadmin through the API — every staff-granting path is
itself staff-gated — so the chicken-and-egg is broken here: sign up through the
normal flow with the address in `v_superadmin_email`, then run this file. If the
`auth.users` row does not exist yet it raises a notice and changes nothing, so the
order does not have to be right the first time. The file also carries the one-line
`update` for promoting a teammate to `admin` later, with the reminder that `admin`
is deliberately *not* enough to read `commission_ledger` or call
`finance_overview()`.

Change the email before running it against a real project. Everything else in
`supabase/migrations/` is environment-agnostic.
