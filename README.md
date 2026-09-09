# GroundsNearMe — Backend

This is the **backend-only** repository for GroundsNearMe — Pakistan's first cricket ground booking platform.

The frontend (public homepage) lives in the sibling `groundsnearme/` folder.

```
groundsnearmebackend/
├── workers/api/        Cloudflare Worker — 45 routes in front of Supabase + R2
├── supabase/           Postgres schema (24 migrations) and dev seed data
├── tools/              Static cross-artefact consistency checks (10/10 passing)
└── docs/               Technical documentation
```

## Quick Start

```bash
cd workers/api && npm install && npm test
```

62 unit tests. Then follow [docs/SETUP-RUNBOOK.md](docs/SETUP-RUNBOOK.md).

```bash
bash tools/check-consistency.sh
```

10 static checks across migrations, Worker, and API contract.

## Roles

| Role | Sees |
| --- | --- |
| `player` | own bookings, own matchmaking posts |
| `owner` | own grounds, bookings, subscription cycles |
| `admin` | all grounds, bookings, leads, subscriptions, users |
| `superadmin` | everything + finance ledger |

## Admin Dashboard

The admin **API** routes (`/v1/admin/*`) are fully implemented. The admin **HTML dashboard** is the next item to build — see [docs/ROADMAP.md](docs/ROADMAP.md).
