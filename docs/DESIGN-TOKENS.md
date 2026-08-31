# GroundsNearMe — design tokens

Extracted from `index.html` so the owner dashboard, the admin view and the private
finance dashboard can match the public site exactly rather than approximately. The
brief is explicit that these surfaces must look like the same product, and the
fastest way to fail at that is to eyeball a green and call it close enough.

Everything below is copied out of the public page's stylesheet, not invented. Where
the public site has no token for something a dashboard needs, that is called out as
a gap rather than filled in silently.

## Colour

```css
:root {
  --white:      #ffffff;
  --off:        #f7f8f6;   /* alternating section background */
  --emerald:    #0d4a2c;   /* primary brand, dark surfaces, button text on lime */
  --emerald-mid:#1a6b40;
  --lime:       #4ade80;   /* primary action fill, "slots open" */
  --lime-dark:  #22c55e;   /* eyebrow text */
  --ink:        #0d1a0f;   /* body text, headings */
  --muted:      #4a5c50;   /* secondary text, labels */
  --border:     #d8e8dc;
  --card-bg:    #f0f7f3;   /* outer card frame */
}
```

Copy this block verbatim into every dashboard stylesheet. Ten variables, no
additions — if a dashboard needs a colour that is not here, that is a design
decision to make deliberately, not a hex to inline.

Two conventions that are easy to get wrong:

- Lime is a **fill**, never text on white. `--lime` on `--white` fails contrast; the
  public site always pairs `--lime` background with `--emerald` text.
- Dark surfaces (`--emerald` background) use `rgba(255,255,255,0.65)` for secondary
  text and `rgba(255,255,255,0.4)` for tertiary, not `--muted`.

### Status colours

The public site defines exactly two badge variants:

```css
.badge-open { background: var(--lime);   color: var(--emerald); }
.badge-full { background: var(--border); color: var(--muted);   }
```

The API returns a third availability state — `closed` / *Closed Today* — which
`index.html` has no rule for yet, because the mock data never produced it. A
dashboard rendering real data needs it. Reuse `.badge-full`'s treatment rather than
introducing a red: a closed ground is not an error state.

Booking and subscription statuses have no tokens at all on the public site, since it
never shows them. Map them onto the existing palette rather than adding colours:

| State | Treatment |
| --- | --- |
| `confirmed`, `paid`, `collected` | `--lime` fill, `--emerald` text |
| `pending`, `unpaid`, `accrued` | `--card-bg` fill, `--emerald` text, `--border` outline |
| `cancelled`, `expired`, `no_show` | `--border` fill, `--muted` text |
| `completed` | `--emerald` fill, `--white` text |

That is four treatments for a dozen statuses, on purpose. A finance dashboard where
the numbers are legible beats one with a bespoke colour per enum value.

## Type

Plus Jakarta Sans, weights 300–800, from Google Fonts:

```html
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700;800&display=swap" rel="stylesheet" />
```

```css
body { font-family:'Plus Jakarta Sans', sans-serif; font-size:1rem; line-height:1.7; -webkit-font-smoothing:antialiased; }
```

| Role | Size | Weight | Letter-spacing |
| --- | --- | --- | --- |
| Display heading | `clamp(2.8rem, 6vw, 5rem)` | 800 | `-0.03em` |
| Section heading | `clamp(1.8rem, 3.5vw, 2.8rem)` | 800 | `-0.025em` |
| Card title | `1.0625rem` | 700 | `-0.01em` |
| Body | `1rem` / line-height `1.7` | 400 | — |
| Small / meta | `0.8125rem` | 500–700 | — |
| Eyebrow | `11px` | 700 | `0.18em`, uppercase |
| Field label | `0.6875rem` | 700 | `0.1em`, uppercase |
| Badge | `0.625rem` | 800 | `0.14em`, uppercase |

The pattern is consistent enough to state as a rule: **large text gets negative
tracking, small text gets positive tracking and uppercase.** Headings tighten as they
grow; labels and badges spread out. A dashboard table header is a field label
(`0.6875rem` / 700 / `0.1em` / uppercase), not a shrunken heading.

Numeric columns in the finance dashboard should use `font-variant-numeric: tabular-nums`
so figures align down a column. The public site has no need for it and therefore no
token — this is the one addition worth making.

## Shape

```css
border-radius: 0;
```

Everywhere, without exception. Cards, buttons, inputs, badges, images. The only
rounded element on the entire public site is `.btn-icon`, a 22px circle
(`border-radius:50%`) holding an arrow inside a button. Reproduce that exactly or
not at all.

The card construction is a doubled frame, which is what gives the site its depth
without a drop shadow:

```css
.card-outer { background:var(--card-bg); border:1px solid var(--border); padding:6px; }
.card-inner { background:var(--white); border:1px solid var(--border);
              box-shadow: inset 0 1px 0 rgba(255,255,255,0.9); padding:20px; }
```

A 6px gutter of `--card-bg` around a white panel. Dashboard panels, stat tiles and
table containers should use the same two-element structure rather than a single
bordered div — it is the most recognisable thing about the visual language.

## Space and layout

```css
.container { max-width:1200px; margin:0 auto; padding:0 48px; }
```

Section rhythm is `120px 0` for major sections, `72px 0` for the stats band, and
sections alternate `--white` / `--off` backgrounds.

Spacing is a small hand-picked scale rather than a strict multiple:
`2, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48`. Gaps of 8px inside components,
32–48px between them. Stay on that list instead of rounding to a 4px grid — the odd
values (5px icon gaps, the 6px card gutter) are load-bearing.

| Breakpoint | Container padding | Grid change |
| --- | --- | --- |
| ≤1024px | `0 32px` | 3-up grids become 2-up; side-by-side becomes stacked |
| ≤768px | `0 20px` | everything single-column; nav links hide, hamburger appears |
| ≤480px | `0 20px` | — |

A dashboard is denser than a marketing page, so `120px` section padding is wrong
there. Use the 4px scale and the container width, drop the vertical rhythm to
`48px`–`64px`, and keep the horizontal padding identical so the two surfaces line up
when a user moves between them.

## Motion

One easing curve for the entire site:

```css
cubic-bezier(0.22, 1, 0.36, 1)
```

An ease-out quint. Every transition uses it. Durations are the vocabulary:

| Duration | Used for |
| --- | --- |
| `0.15s` | button press / `transform` on active |
| `0.2s` | text colour on hover |
| `0.25s` | background, border, gap on hover |
| `0.35s`–`0.4s` | hamburger, mobile nav, nav padding |
| `600ms` | card lift on hover |
| `700ms` | scroll reveal |

The scroll reveal is the site's signature motion:

```css
.reveal { opacity:0; transform:translateY(32px);
          transition: opacity 700ms cubic-bezier(0.22,1,0.36,1),
                      transform 700ms cubic-bezier(0.22,1,0.36,1); }
```

Driven by `IntersectionObserver` on the public site. Worth carrying into the
dashboards for section entry, but not onto table rows or live numbers — a figure that
fades in every time a filter changes reads as slow, not premium.

Two details that make hover feel considered rather than generic: `.venue-slots-link`
animates its `gap` (5px → wider) so the arrow slides away from the text, and
`.btn-icon` transforms its circle independently of the button. Both are cheap to
reuse.

`html { scroll-behavior: smooth }` is set globally. The public site has no
`prefers-reduced-motion` block; adding one to the dashboards is a straightforward
improvement rather than a divergence.

## Icons

Phosphor, **thin** weight, via CDN:

```html
<script src="https://unpkg.com/@phosphor-icons/web@2.0.3/src/index.js"></script>
```

```html
<i class="ph-thin ph-arrow-right"></i>
```

Always `ph-thin`. Never `ph-bold`, `ph-fill` or `ph-duotone` — the hairline weight
against 800-weight headings is a deliberate contrast, and a filled icon breaks it
immediately. Pin the version; an unpinned `@latest` will eventually change glyphs.

Icons the dashboards will need that the public site already establishes:
`ph-map-pin`, `ph-calendar`, `ph-clock`, `ph-currency-circle-dollar`, `ph-users`,
`ph-caret-down`, `ph-arrow-right`, `ph-circle` (as an 8px status dot).

## Applying this to a dashboard

Practical order for a new dashboard page:

1. Copy the `:root` block and the font `<link>` verbatim.
2. Copy `.container`, `.card-outer`, `.card-inner`, `.btn-primary`, `.btn-ghost`,
   `.eyebrow`, `.section-heading` unchanged.
3. Build dashboard-specific components (tables, stat tiles, filter bars) using only
   those tokens.
4. Tighten vertical rhythm; leave horizontal padding and max-width alone.
5. Add exactly three things the public site lacks: a `closed` badge variant,
   `tabular-nums` on numeric columns, and a `prefers-reduced-motion` block.

Anything beyond that list should be questioned. Two surfaces drift apart one
reasonable-looking exception at a time.
