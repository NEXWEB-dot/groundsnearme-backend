# GroundsNearMe — Product Requirements Document (PRD)

**Document Version:** 1.0.0  
**Status:** Ready for Production Launch  
**Target Market:** Karachi, Pakistan (Expanding to Lahore & Islamabad)  
**Primary Domain:** `groundsnearme.pk`  

---

## 1. Executive Summary & Vision

### 1.1 Product Vision
**GroundsNearMe** is Pakistan's premier online sports venue booking and slot management platform. It solves the fragmentation and friction in urban recreational sports by providing real-time turf slot availability, instant WhatsApp booking coordination, transparent hourly rates, and automated ground management for venue owners.

### 1.2 The Problem
* **For Players:** Finding an open cricket turf slot in Karachi currently requires calling 5 to 10 different venue managers on WhatsApp or phone, dealing with outdated paper registers, and risking double-booking when arriving at the venue.
* **For Turf Owners:** Venue owners rely on memory, notebooks, and scattered WhatsApp chats, resulting in accidental double-bookings, unclaimed no-shows, unpaid slots, and zero digital visibility to new corporate or recreational teams.

### 1.3 The Solution
A unified, low-latency, mobile-first web platform connecting players directly with floodlit turfs and indoor arenas across Karachi. Powered by a PostgreSQL concurrency engine that guarantees **zero double-bookings** and **instant slot release** when reservations are cancelled.

---

## 2. Target Personas & Stakeholders

| Persona | Role | Primary Goals | Key Pain Points Solved |
| :--- | :--- | :--- | :--- |
| **Hamza (Player / Team Captain)** | Books weekend and late-night tape-ball matches for his 11-player squad. | Check live slot openings across Gulshan, Johar, and DHA in 30 seconds; book without calling. | No more calling 8 different grounds to find an open 10 PM slot on Friday night. |
| **Tariq (Turf Owner / Manager)** | Manages 2 floodlit synthetic turf pitches in Gulshan-e-Iqbal. | Block maintenance hours, log walk-in bookings, prevent overlapping bookings, and track revenue. | Replaces paper notebooks; eliminates double-booking disputes; automatically syncs offline and online bookings. |
| **Shayan (Platform Operations / Admin)** | Manages inbound WhatsApp leads, lists new turfs, monitors revenue, and oversees platform health. | Rapidly onboard venue owners from WhatsApp, convert leads to listed grounds, monitor city-wide GMV. | Structured CRM pipeline from inbound WhatsApp message to active verified ground listing. |

---

## 3. Recommended Production Technology Stack

To ensure maximum uptime, zero quota exhaustion, instant mobile load times, and bank-grade data integrity in Pakistan, the platform utilizes a modern serverless edge stack:

```
┌────────────────────────────────────────────────────────┐
│             Player, Owner & Admin Surfaces             │
│        (HTML5, Modern CSS Tokens, Phosphor Icons)       │
└───────────────┬────────────────────────┬───────────────┘
                │                        │
       Static Assets / CDN      REST / Real-time Queries
                │                        │
┌───────────────▼────────┐      ┌────────▼───────────────┐
│     Cloudflare Pages   │      │   Supabase PostgreSQL  │
│  (Global Edge Caching, │      │ (PostgREST API + Auth  │
│    Zero Server Cost)   │      │   + GiST Exclusion)    │
└────────────────────────┘      └────────┬───────────────┘
                                         │
                                Images / Media
                                         │
                                ┌────────▼───────────────┐
                                │     Cloudflare R2      │
                                │   (Zero Egress Fee     │
                                │    Image CDN Bucket)   │
                                └────────────────────────┘
```

* **Frontend:** Clean Vanilla JavaScript (ES2022+), CSS Custom Properties (`DESIGN-TOKENS.md`), Phosphor Icons Web. Zero heavy framework overhead ensures sub-second First Contentful Paint (FCP) on mobile 4G across Karachi.
* **Database & Auth:** Supabase PostgreSQL with `btree_gist`, `citext`, and `pgcrypto`. Built-in Row Level Security (RLS) and JWT auth.
* **Edge Routing & Housekeeping:** Cloudflare Workers with cron triggers for hold expiry, slot cleanup, and rate-limiting.
* **Image Delivery:** Cloudflare R2 object storage with public custom domain `images.groundsnearme.pk` for zero-egress cost photo hosting.

---

## 4. Functional Specifications & Core Modules

### 4.1 Real-Time Slot Availability & Instant Slot Release Engine
* **Double-Booking Guarantee:** The database enforces an exclusion constraint using GiST on `(ground_id, slot tsrange)` for all bookings with `status in ('pending', 'confirmed')`. Overlapping bookings are mathematically impossible at the database engine level.
* **Instant Slot Release on Cancellation:**
  * When a booking is cancelled by a player, owner, or staff administrator, its status transitions to `'cancelled'`.
  * Because cancelled rows are excluded from the GiST constraint, the slot is **instantly freed** in the database engine.
  * The availability RPC `get_ground_availability` and the client `LiveSlotStore` immediately reflect the slot as `'available'`.
  * Turf owners can click **"Release Slot"** directly on any booked card in the Owner Schedule Grid to reopen that hour in 1 click.
* **Hard Deletion Support:** Staff and verified owners have permission via `rpc/delete_booking` to permanently delete accidental booking records, reopening the slot immediately.

### 4.2 Public Discovery & Player Booking Flow (`groundsnearme.pk`)
* **Area & Surface Filtering:** Filter by major Karachi districts (Gulshan, DHA, Clifton, Johar, Nazimabad, North Nazimabad, Malir, PECHS) and surface type (Astro Turf, Natural Grass, Matting, Indoor AC).
* **Live Dynamic Cards:** Each card displays verified hourly rate, weekend rate, amenities (Floodlights, Nets, Dressing Room, Parking, AC), and high-res pitch photos.
* **Direct WhatsApp Quick Chat:** Generates a deep link formatted as `https://wa.me/923XXXXXXXXX?text=...` with pre-filled match and slot details.
* **Resilient Offline Fallback:** If offline or cold-starting, seamlessly falls back to cached `MOCK_GROUNDS` data so the site never shows a blank screen.

### 4.3 Ground Owner Operations Portal (`owner.groundsnearme.pk`)
* **Owner Authentication:** Session-based login using Supabase Auth with scoped access to their own venues (`owns_ground` RLS policy).
* **Interactive Slot Schedule Grid:** 24-hour visual schedule with color-coded badges:
  * **Green (Available):** Open for player booking or 1-click walk-in reservation.
  * **Amber / Black (Booked):** Displays player name, booking reference, payment badge, and a **"Release Slot"** button.
* **Maintenance & Blackouts:** Ability to block entire date ranges for pitch rolling, rainy season, or maintenance (`ground_closures`).
* **Commercial Rate Controls:** Edit standard hourly rate, weekend surge rate, manager contact name, and turf surface.

### 4.4 Admin & Operations Console (`admin.groundsnearme.pk`)
* **WhatsApp Leads CRM:**
  * Dedicated intake queue for ground owners reaching out via WhatsApp.
  * Pipeline tracking: `New` &rarr; `Contacted` &rarr; `Onboarding` &rarr; `Listed` &rarr; `Rejected`.
  * 1-Click **"Convert to Ground"**: Automatically creates an active ground profile pre-filled with the owner's name, phone, asking rate, and matched Karachi area.
* **Bookings Oversight:** Global table of all bookings across all venues in the city with date and ground filtering, status flipping, cancellation reason logging, and hard deletion.
* **Grounds Directory Management:** Publish new turfs, edit existing details, update status (`active`, `pending`, `inactive`, `paused`, `archived`), and assign listing tiers (`free` vs `pro`).
* **Subscription Management:** Monthly billing cycle creation for Pro tier grounds (`rpc/open_subscription_cycle`) with invoice reference and payment status tracking.

---

## 5. Security & Data Protection Architecture

* **Zero Plaintext Secrets:** No `service_role` keys exist in browser code. All client transactions execute through authenticated JWT tokens or restricted anonymous public read endpoints.
* **Row-Level Security (RLS) Matrix:**
  * `public.grounds`: Public read for `status = 'active'`; write restricted to verified staff or owning manager.
  * `public.bookings`: Public read restricted to non-confidential slot timings; write/cancel restricted to staff, ground owner, or booking creator.
  * `public.ground_leads`: Visible only to staff (`public.is_staff()`).
  * `public.commission_ledger`: Visible only to superadmin (`public.is_superadmin()`).
* **Input Validation & Sanitization:** All numbers normalized to Pakistan E.164 without plus (`923XXXXXXXXX`); UUIDs regex-validated; booking references verified against `^GNM-[0-9]{4}-[A-Z0-9]{6}$`.

---

## 6. Non-Functional & Quota Optimization Requirements

* **Supabase Quota Preservation:**
  * All `select` queries must specify precise columns (`select=id,slug,name...`). `select=*` on `grounds` is strictly prohibited on list views to prevent downloading large JSON image arrays.
  * Egress payload reduced by >80% to operate safely within the 2 GB/month free-tier bandwidth limit.
* **Performance Indexes:**
  * `ground_leads (status, created_at desc)`
  * `bookings (ground_id, booking_date, status)`
  * `bookings (player_id, booking_date desc)`
  * `owner_subscriptions (status, cycle_start desc)`
  * `grounds (status, listing_tier, is_featured)`
* **Latency Benchmarks:**
  * Slot availability lookup: `< 80ms`
  * Booking confirmation: `< 150ms`
  * Mobile page load: `< 1.2s` over 4G

---

## 7. Release Roadmap & Launch Criteria

### Phase 1: Karachi Launch (Immediate)
- [x] WhatsApp Lead CRM operational with status pipeline and 1-click conversion.
- [x] Concurrency-safe double-booking prevention engine active.
- [x] Instant slot release on cancellation verified across Admin, Owner, and Player surfaces.
- [x] Owner Portal with Live Schedule Grid, Walk-in Booking, and 1-click Release Slot.
- [x] Mobile-optimized public discovery site with verified WhatsApp deep links.

### Phase 2: Player Accounts & Online Payments (Q4 2026)
- [ ] JazzCash / EasyPaisa / Raast payment gateway integration for slot deposits.
- [ ] SMS / WhatsApp Automated OTP notifications for booking confirmations.
- [ ] Verified Player Reviews and pitch condition ratings.

### Phase 3: Regional Expansion (2027)
- [ ] Expansion to Lahore (Gulberg, DHA, Model Town) and Islamabad/Rawalpindi.
- [ ] Tournament brackets and corporate league management portal.
