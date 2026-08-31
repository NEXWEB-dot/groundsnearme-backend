# supabase/

Postgres is the source of truth for everything structured. R2 holds image bytes and
nothing else.

```
migrations/   24 files, applied in filename order
seed.sql      development data mirroring the frontend's mock objects
```

Full schema documentation: [../docs/DATA-MODEL.md](../docs/DATA-MODEL.md).
Setup steps: [../docs/SETUP-RUNBOOK.md](../docs/SETUP-RUNBOOK.md).

## Applying

```bash
supabase link --project-ref YOUR_PROJECT_REF && supabase db push
```

Without the CLI, paste each file into the SQL editor in filename order. The files are
idempotent wherever that is cheap — `create table if not exists`,
`create or replace function`, `drop trigger if exists` before `create trigger` — so
re-running the whole folder against an existing project is safe.

Order matters on a fresh project: `…0001` installs the extensions and enums that
everything else depends on, `…0005` needs `btree_gist` visible on the search path,
and each `rls_*` file needs the tables it protects.

## Layout

| Files | Contents |
| --- | --- |
| `0001`–`0008` | extensions, enums, tables, triggers |
| `0009`–`0016` | RPCs: availability, bookings, search, matchmaking |
| `0017`–`0019` | RLS policies: core, bookings/matchmaking, money/internal |
| `0020`–`0021` | finance views and `finance_overview()` |
| `0022` | the housekeeping functions the Worker's cron calls |
| `0023` | Karachi areas reference data |
| `0024` | promotes the first superadmin — **edit the email before running** |

## Two things to know before changing anything

**The exclusion constraint is the double-booking guarantee.**
`bookings_no_overlap` on `(ground_id, slot)` for `status in ('pending','confirmed')`.
Not application logic. If a migration ever needs to drop or recreate it, that is the
riskiest line in the folder — the window while it is absent is a window where two
players can book the same slot.

**Guard triggers are the real authority, not the RLS policies alone.**
`tg_grounds_owner_guard()` blocks an owner from touching commercial columns,
`tg_bookings_player_guard()` restricts a player to notes/contact fields plus
cancelling, and `tg_profiles_guard()` gates role changes to superadmin. They hold
even for a caller hitting PostgREST directly with a valid token, which is why the
Worker's route-level checks can afford to be friendly error messages rather than
security.

## Seed

`seed.sql` inserts the same grounds, prices and WhatsApp numbers the frontend's mock
data uses, so a local site looks like the mock-up. Development and staging only.

```bash
supabase db reset   # drops, re-runs migrations, then seed.sql
```

`tools/check-consistency.sh` check 8 asserts the seed still mirrors `index.html`. If
a mock price changes on the frontend, that check fails until the seed matches — which
is the point of having it.

## Adding a migration

Timestamp-prefixed, `YYYYMMDDHHMMSS_short_name.sql`, so filename order is apply
order. Three habits worth keeping:

- Guard everything (`if not exists`, `or replace`) so the folder stays re-runnable.
- Set `search_path` explicitly in any `security definer` function; every existing one
  uses `set search_path = public, pg_temp`.
- When adding an enum label, update the matching `oneOf()` array in the Worker in the
  same change. The validator rejects unknown values before they reach the database,
  so a new label that only exists in SQL is unreachable through the API.
