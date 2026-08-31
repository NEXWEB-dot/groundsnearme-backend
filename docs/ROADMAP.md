# GroundsNearMe — build order and status

Tracks the nine-step build order from the scope file against what is actually in this
repository. Updated 30 August 2026.

The Worker has been run. `npm test` passes 62/62,
`tools/check-consistency.sh` passes 10/10, and `wrangler dev` serves the routes
locally — health, CORS, 404/405, the auth and role gates, request validation and the
image upload guards were all exercised against a live instance. There is no Postgres
on this machine (no `psql`, Docker or Supabase CLI), so anything requiring the
database is still unverified. See
[SETUP-RUNBOOK.md](SETUP-RUNBOOK.md#what-has-and-has-not-been-executed).

| # | Step | Status |
| --- | --- | --- |
| 1 | Supabase schema + auth | **written** — 24 migrations |
| 2 | R2 bucket + image pipeline | **written** — Worker side; bucket needs creating |
| 3 | Core API endpoints matching the mock shape | **written** — 45 routes |
| 4 | Connect the frontend's `js/api.js` | **blocked** — needs the other devs |
| 5 | Owner dashboard | **not started** |
| 6 | Admin internal view | **not started** |
| 7 | Private financial dashboard | **not started** |
| 8 | Monthly payment link / invoice tracking | **backend written**, UI not started |
| 9 | Phase 2 | deferred by decision |

## 1 · Supabase schema and auth — written

24 migrations in `supabase/migrations/`, documented in
[DATA-MODEL.md](DATA-MODEL.md). Covers the four roles, grounds, availability,
bookings, matchmaking, monetization, leads and audit; 15 enums; the RPC layer; RLS on
every table; the finance views; and the housekeeping functions.

Two things worth restating because they are the load-bearing decisions:

- **Double-booking is impossible at the database level**, via a GiST exclusion
  constraint on `(ground_id, slot)` for live bookings. Not application logic, not
  polling, not a lock. Two simultaneous requests for the same slot resolve to one
  `201` and one `409 SLOT_TAKEN`.
- **Guard triggers, not just policies.** `tg_grounds_owner_guard()`,
  `tg_bookings_player_guard()` and `tg_profiles_guard()` mean a caller hitting
  PostgREST directly with a valid token still cannot promote their own listing,
  rewrite a booking's price, or change their own role.

Remaining before this is truly done: apply the migrations to a real project, set the
superadmin email in `…0024_bootstrap_staff`, and confirm `bookings_no_overlap`
exists.

## 2 · R2 bucket — Worker side written

`lib/r2.js` plus the three admin image routes, documented in
[R2-IMAGES.md](R2-IMAGES.md). Keys are stored bare in `grounds.images[].url` and the
public URL is composed at read time from `R2_PUBLIC_BASE_URL`, so the CDN host is a
config value rather than data.

Remaining: create `groundsnearme-images`, attach the public custom domain, and put
one real image through the upload path.

## 3 · Core API endpoints — written

45 routes in `workers/api/src/router.js`, documented endpoint by endpoint in
[API-CONTRACT.md](API-CONTRACT.md). Every public read goes through an RPC that
renames columns to the mock data's field names in SQL (`lat`, `lng`, `type`, `tier`,
`cover_image`), so step 4 is a swap and not a translation layer.

Auth is a locally-verified Supabase JWT; requests then run against Supabase with the
caller's own token, so RLS is the authority and the route-level role checks exist to
fail fast with a readable message. CORS is an explicit origin allowlist — never `*`.
Both were verified against a running `wrangler dev`: an `admin` token gets `403` on
`/v1/finance/overview`, a token signed with the wrong secret gets `401`, and a
lookalike origin receives no CORS headers at all.

Remaining: `wrangler dev` against a real Supabase project, then deploy.

## 4 · Connect the frontend — blocked

Not mine to do. The contract has a mock-field → API-field mapping table and a
minimal `js/api.js` client to drop in. What is needed from the other devs is only the
Pages origin, so it can be added to `ALLOWED_ORIGINS`.

The one behaviour that needs stating clearly to whoever does the swap:
`409 SLOT_TAKEN` is a **normal** outcome, not an exception to prevent. The slot grid
is edge-cached for up to 20 seconds, so it is expected to occasionally offer a slot
that has just gone. Handle it by re-fetching availability and showing "someone just
took that slot", not by polling harder.

## 5 · Owner dashboard — not started

Backend is complete and deliberately narrow: `GET /v1/owner/grounds`,
`/v1/owner/grounds/:id` (with hours and closures), `PATCH` for operational fields,
hours upsert, closures add/delete, `GET /v1/owner/bookings`,
`POST /v1/owner/bookings/manual`, `GET /v1/owner/subscriptions`.

Two absences are decisions, not gaps: there is **no owner analytics endpoint**
(explicitly out of scope for launch), and owners **cannot** touch `status`,
`listing_tier`, `is_featured`, `featured_rank`, `featured_until`, `commission_rate`
or `owner_id` — blocked in the route and again by trigger.

UI is vanilla HTML/CSS/JS on Cloudflare Pages, matching
[DESIGN-TOKENS.md](DESIGN-TOKENS.md). Screens needed: my ground(s) + listing status,
upcoming bookings, booking history, the weekly hours grid, closures, and
subscriptions read-only.

## 6 · Admin internal view — not started

Backend complete: grounds list/detail/create/update, the three image routes, leads,
bookings across all grounds, booking status changes, subscription cycles, and
`open-cycle`.

`POST /v1/admin/grounds` is the **only** path that creates a ground. There is no
public self-serve listing form, by design — an owner messages WhatsApp, a team member
logs the lead in `ground_leads`, then enters the details and uploads photos here.

## 7 · Private financial dashboard — not started

`GET /v1/finance/overview` is written and gated twice: `requireSuperadmin()` in the
route, and `is_superadmin()` **inside** `finance_overview()` so the gate does not
depend on the route guard being wired correctly. An `admin` token gets `403` — checked
against a running instance, not just read. That is the point of having two staff roles.

One call returns everything the five requested views need: monthly commission,
monthly revenue trend, per-ground breakdown (top 20), subscription revenue tracked
separately from commission, and platform-wide booking volume per month. Trends are
gap-filled, so a quiet month is a zero rather than a hole the chart interpolates.

Clarity over decoration, per the brief: tabular numbers, honest zeros, no sparkline
where a figure will do.

## 8 · Payment links and paid/unpaid tracking — backend written

`owner_subscriptions` is one row per owner per ground per cycle, with
`payment_link`, `invoice_ref`, `status` and a trigger that stamps `paid_at` on the
transition. `open_subscription_cycle(month, amount)` opens the month's unpaid rows
for every active pro-tier ground, idempotently.

No auto-recurring billing, and no card gateway. JazzCash and EasyPaisa do not offer
mature recurring billing here, and Stripe assumes cards local owners largely do not
have — so the launch model is a link per cycle and a paid/unpaid flag. The table is
shaped so adopting a gateway later means adding columns, not rewriting the model.

Owners have `select` and no `insert` or `update` policy at all, so "the owner cannot
mark their own cycle paid" is a database fact.

UI remaining: the staff screen to issue a link and flip a cycle.

## 9 · Phase 2 — deferred

Deliberately not built:

- **Owner-facing analytics.** Out of scope for launch.
- **Public pro-tier launch.** Ship free-only, gather traction data, then pitch pro on
  visibility and priority placement. The plumbing exists — `listing_tier`,
  `is_featured`, `featured_rank`, `featured_until` and the subscription table are all
  in place — so this is a pricing decision, not an engineering one.
- **True auto-recurring billing.** Revisit at scale.
- **Supabase tier upgrade.** Free is correct for the Karachi launch. Revisit when
  ground count and traffic actually grow.
- **Image transforms.** No resizing or format conversion; because the row stores a
  key rather than a URL, adding a transform later does not touch the database.
- **An orphaned-object reaper for R2.** Deletes update the row before the bucket, so
  a failed bucket delete leaves a harmless orphan. At this scale a periodic manual
  sweep is cheaper to run than to build.
- **Reviews.** `rating` and `review_count` are display-only columns with no table
  behind them.
- **Notifications.** No email or WhatsApp automation. `reminder_sent_at` exists to
  record a manual nudge.

## Next actions, in order

1. Create the Supabase project; apply the 24 migrations; run the seed on dev only.
2. Set the superadmin email in `…0024` and promote the account.
3. Create the R2 bucket and attach the public domain.
4. Fill `wrangler.toml` vars, set the two secrets, deploy.
5. Verify with the curls in [SETUP-RUNBOOK.md](SETUP-RUNBOOK.md#verification) —
   including two concurrent bookings for one slot, and an `admin` token against
   `/v1/finance/overview` expecting `403`.
6. Hand [API-CONTRACT.md](API-CONTRACT.md) to the frontend devs and add their Pages
   origin to `ALLOWED_ORIGINS`.
7. Build the owner dashboard (step 5), then the admin view (step 6), then the finance
   dashboard (step 7).
