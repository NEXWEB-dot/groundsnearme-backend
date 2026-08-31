# GroundsNearMe — images on R2

Ground photos live in a Cloudflare R2 bucket, not in Supabase Storage. Two reasons,
both practical: the site is already on Cloudflare Pages + Workers, so serving media
from the same platform avoids a second vendor in the request path, and Supabase's
free-tier storage quota stays reserved for structured data — which is the thing that
would actually hurt to run out of.

Supabase remains the source of truth. R2 holds bytes and nothing else: no metadata,
no ordering, no alt text. All of that is a `jsonb` array on the ground row.

## The one rule

**The database stores the object key, never the URL.**

```jsonc
// grounds.images
[
  { "url": "grounds/gulshan-cricket-arena/1756512000000-a1b2c3d4.webp", "alt": "Main pitch", "sort": 0 },
  { "url": "grounds/gulshan-cricket-arena/1756512055000-e5f6a7b8.webp", "alt": null,        "sort": 1 }
]
```

The field is called `url` for historical reasons and because the frontend's mock data
called it that — but what it contains is a key. The public URL is composed at read
time by `imageUrl()` in `lib/shape.js`:

```
R2_PUBLIC_BASE_URL + '/' + key
```

Which means changing CDN host, moving to a custom domain, or putting a transform in
front is an environment-variable change. No data migration, no backfill, no
find-and-replace across a `jsonb` column. `imageUrl()` also passes an absolute URL
straight through untouched, so a seeded row pointing at a stock photo still works
and there is no need for a "is this a key or a URL" flag anywhere.

Going the other way, `toKey()` accepts a bare key, a full public URL, or any
absolute URL and reduces it back to a key — so the admin UI can send whatever it
happens to have on the row when reordering or deleting.

## Key layout

```
grounds/<ground-slug>/<epoch-ms>-<8-hex>.<ext>
```

Built by `buildKey()`. The slug is re-sanitised on the way in (lowercased,
non-`[a-z0-9-]` collapsed to `-`, trimmed, capped at 60 characters, falling back to
`unsorted`) — the ground table already enforces a slug format, but a key builder
that trusts its input is a key builder that eventually writes `grounds/../../etc`.

The prefix is human-readable on purpose: listing a bucket in the Cloudflare
dashboard and seeing which venue an orphan belongs to is worth more than a shorter
key. Epoch milliseconds plus 8 hex characters makes the leaf collision-free without
a round trip to check.

Renaming a ground's slug does **not** rewrite existing keys, and that is fine —
keys are opaque identifiers, and the row keeps pointing at the right bytes. Only
newly uploaded images pick up the new prefix.

## Upload

```
POST /v1/admin/grounds/:id/images?alt=Main%20pitch
Authorization: Bearer <staff token>
Content-Type: image/webp

<raw file bytes>
```

Raw binary, one request per image. No multipart parsing to get wrong, no base64
inflating the payload by a third, and a per-file request is also what makes a
progress bar straightforward in the admin UI.

The response returns the composed URL for immediate display alongside the key to
store:

```json
{
  "image": { "url": "https://images.groundsnearme.pk/grounds/…webp", "key": "grounds/…webp", "alt": "Main pitch", "sort": 0, "size": 184320 },
  "images": [ … ],
  "cover_image": "grounds/…webp"
}
```

Constraints, all enforced server-side:

| Rule | Value | Failure |
| --- | --- | --- |
| Formats | JPEG, PNG, WebP, AVIF | `415 UNSUPPORTED_MEDIA_TYPE` |
| Size | 8 MB | `413 PAYLOAD_TOO_LARGE` |
| Empty body | — | `400 VALIDATION_ERROR` |
| Images per ground | 12 | `400 VALIDATION_ERROR` |
| Caller | staff or superadmin | `403 FORBIDDEN` |

The content-type header decides the extension — the filename is never consulted and
never stored. Size is checked twice: once against `content-length` to reject early,
then again against the actual buffer, because a declared length is a claim and not a
fact.

Objects are written with `cache-control: public, max-age=31536000, immutable`. Safe
because keys are unique per upload: an image is never replaced in place, so a
year-long cache can never go stale. Replacing a photo means uploading a new one and
deleting the old.

There is **no public upload path**, and that is a scope decision rather than an
omission. Grounds are only ever created through the admin view, after a WhatsApp
conversation logged in `ground_leads`. No self-serve listing form means no anonymous
write path to the bucket at all.

## Cover image

`cover_image_url` on the ground row is what list views render. It is kept in step
automatically by `tg_grounds_sync_cover()`, which sets it to `images -> 0 ->> 'url'`
whenever it is null — so uploading the first photo sets the cover without a second
call.

`PATCH /v1/admin/grounds/:id/images` reorders, retitles and picks the cover in one
request. Send the full array in the desired order; the first entry becomes the cover
and `sort` is rewritten to match the array index, so the client never has to compute
sort values. Every key in the payload must already be on that row — this endpoint
cannot introduce an image, only rearrange one, which keeps "reorder" from becoming a
back door into the bucket.

## Delete

```
DELETE /v1/admin/grounds/:id/images
{ "key": "grounds/gulshan-cricket-arena/1756512000000-a1b2c3d4.webp" }
```

The row is updated **first**, then the object is deleted from R2. The order is
deliberate: if the bucket delete fails, the result is an orphaned object — harmless
and cheap — rather than a live row pointing at a 404. `sort` is recompacted, and if
the deleted image was the cover, the new `images[0]` takes over.

Orphans are the accepted failure mode of that ordering. There is no reaper job at
launch; at this scale a periodic manual sweep of the bucket against the keys in
`grounds.images` is cheaper to run than to build, and it is on the Phase 2 list in
[ROADMAP.md](ROADMAP.md).

## Configuration

| Setting | Where | Value |
| --- | --- | --- |
| `IMAGES` binding | `wrangler.toml` `[[r2_buckets]]` | bucket `groundsnearme-images` |
| `R2_PUBLIC_BASE_URL` | `wrangler.toml` `[vars]` | `https://images.groundsnearme.pk` |

Staging uses `groundsnearme-images-staging` and its own hostname, so a staging
upload can never land in the production bucket.

If `IMAGES` is unbound, upload and delete return `502 UPSTREAM_ERROR` with a clear
message rather than a stack trace, and every read path still works — existing keys
compose fine, since composing a URL needs no bucket access. `GET /v1/health`
reports `images_configured` for exactly this check.

If `R2_PUBLIC_BASE_URL` is empty, `publicUrl()` falls back to a root-relative
`/<key>`. That is a development convenience, not something to ship — set the var.

## What is not here

- **No resizing, cropping or format conversion.** Whatever the admin uploads is
  what gets served. Cloudflare Images or a resizing Worker is a Phase 2 decision,
  and because the row stores a key rather than a URL, adding one later does not
  touch the database.
- **No signed URLs.** The bucket is public-read by design — these are marketing
  photos of cricket grounds.
- **No Supabase Storage anywhere.** Not as a fallback, not for avatars.
  `profiles.avatar_url` is a plain URL column and holds whatever the auth provider
  gave back.
