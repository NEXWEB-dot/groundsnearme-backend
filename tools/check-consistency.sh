#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GroundsNearMe — static consistency checks.
#
# These cross-check the three artefacts that drift apart in practice: the SQL
# migrations, the Worker that calls them, and the API contract the frontend
# binds to. Nothing here executes the code — that is what `npm test` in
# workers/api does (62 unit tests). This runs with no dependencies beyond bash,
# so it works before `npm install` and in any CI image.
#
#   ./tools/check-consistency.sh
#
# Exit code 0 = consistent, 1 = at least one mismatch.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="$ROOT/workers/api"
SRC="$API/src"
MIG="$ROOT/supabase/migrations"
DOCS="$ROOT/docs"

fails=0
checks=0

ok()   { checks=$((checks+1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { checks=$((checks+1)); fails=$((fails+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
note() { printf '        %s\n' "$1"; }
head1(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
head1 "1. Every RPC the Worker calls exists in a migration"

rpc_calls=$(
  { grep -rhoE "sbRpc\([[:space:]]*env,[[:space:]]*'[a-z_]+'" "$SRC" | sed -E "s/.*'([a-z_]+)'.*/\1/"
    grep -rhoE "\['[a-z_]+',[[:space:]]*\{\}\]"            "$SRC" | sed -E "s/\['([a-z_]+)'.*/\1/"
  } | sort -u
)
rpc_defined=$(grep -rhoE "^create or replace function public\.[a-z_]+" "$MIG" | sed 's/.*public\.//' | sort -u)

missing_rpc=0
while read -r fn; do
  [ -z "$fn" ] && continue
  if printf '%s\n' "$rpc_defined" | grep -qx "$fn"; then :; else
    bad "RPC '$fn' is called but never defined in supabase/migrations"
    missing_rpc=1
  fi
done <<< "$rpc_calls"
[ "$missing_rpc" -eq 0 ] && ok "$(printf '%s\n' "$rpc_calls" | grep -c .) RPC names all resolve"

# ---------------------------------------------------------------------------
head1 "2. Every table the Worker queries exists in a migration"

tables_used=$(
  grep -rhoE "[a-z_]{3,}\?(select|on_conflict|id=eq|owner_id=eq)" "$SRC" \
    | sed -E 's/\?.*//' | sort -u
)
tables_defined=$(grep -rhoE "^create table if not exists public\.[a-z_]+" "$MIG" | sed 's/.*public\.//' | sort -u)
# Views are queryable too.
views_defined=$(grep -rhoE "^create or replace view public\.[a-z_]+" "$MIG" | sed 's/.*public\.//' | sort -u)

missing_tbl=0
while read -r t; do
  [ -z "$t" ] && continue
  if printf '%s\n%s\n' "$tables_defined" "$views_defined" | grep -qx "$t"; then :; else
    bad "table/view '$t' is queried by the Worker but not defined in migrations"
    missing_tbl=1
  fi
done <<< "$tables_used"
[ "$missing_tbl" -eq 0 ] && ok "$(printf '%s\n' "$tables_used" | grep -c .) table names all resolve"

# ---------------------------------------------------------------------------
head1 "3. Migrations have balanced \$\$ delimiters"

unbalanced=0
for f in "$MIG"/*.sql "$ROOT/supabase/seed.sql"; do
  [ -f "$f" ] || continue
  n=$(grep -o '\$\$' "$f" | wc -l | tr -d ' ')
  if [ $((n % 2)) -ne 0 ]; then
    bad "$(basename "$f") has $n \$\$ markers (odd — a function body is unterminated)"
    unbalanced=1
  fi
done
[ "$unbalanced" -eq 0 ] && ok "all SQL files have an even number of \$\$ markers"

# ---------------------------------------------------------------------------
head1 "4. The service-role key stays out of anything a browser can reach"

# Only files that could actually be committed matter here. node_modules,
# .wrangler build output and .git are generated or ignored, and scanning them
# made this check fail for anyone who had ever run `wrangler dev`.
allowed_service='src/lib/supabase\.js|src/index\.js|\.dev\.vars|wrangler\.toml|docs/|tools/|README|^\.gitignore$'
offenders=$(find "$ROOT" \
    \( -name node_modules -o -name .wrangler -o -name .git -o -name dist \) -prune -o \
    -type f -print 2>/dev/null \
  | xargs grep -l "SUPABASE_SERVICE_ROLE_KEY" 2>/dev/null \
  | sed "s#^$ROOT/##" | grep -vE "$allowed_service" || true)
if [ -z "$offenders" ]; then
  ok "SUPABASE_SERVICE_ROLE_KEY referenced only in the Worker's server-side files"
else
  bad "service-role key referenced in files that should not have it:"
  printf '        %s\n' $offenders
fi

# .dev.vars is where the real key goes locally, so it must never be tracked.
# It was committed once with placeholder values, which is exactly how a real key
# ends up in a commit later.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  tracked_secrets=$(git -C "$ROOT" ls-files | grep -E '(^|/)\.dev\.vars$|(^|/)\.env$' || true)
  if [ -z "$tracked_secrets" ]; then
    ok ".dev.vars is not tracked by git — only .dev.vars.example is"
  else
    bad "a local secrets file is tracked by git:"
    printf '        %s\n' $tracked_secrets
    note "git rm --cached the file and add it to .gitignore"
  fi
fi

sr_true=$(grep -rl "serviceRole: true" "$SRC" | sed "s#^$SRC/##" || true)
if [ "$sr_true" = "index.js" ] || [ -z "$sr_true" ]; then
  ok "serviceRole:true used only by the scheduled handler (src/index.js)"
else
  bad "serviceRole:true used outside src/index.js: $sr_true"
  note "browser-originated requests must carry the caller's token so RLS applies"
fi

# ---------------------------------------------------------------------------
head1 "5. Every relative import resolves to a real file"

broken=0
imports=$(grep -rhoE "from '(\./|\.\./)[^']+\.js'" "$SRC" "$API/test" 2>/dev/null | sort -u)
while read -r spec; do
  [ -z "$spec" ] && continue
  rel=$(printf '%s' "$spec" | sed -E "s/^from '//; s/'$//")
  # Resolve against both roots that use relative imports.
  found=0
  for base in "$SRC" "$SRC/lib" "$SRC/routes" "$API/test"; do
    [ -f "$base/$rel" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    bad "unresolvable import: $rel"
    broken=1
  fi
done <<< "$imports"
[ "$broken" -eq 0 ] && ok "$(printf '%s\n' "$imports" | grep -c .) distinct relative imports all resolve"

# ---------------------------------------------------------------------------
head1 "6. Every handler wired in router.js is actually exported"

router="$SRC/router.js"
unexported=0
# The import lines themselves contain "me.js", which would otherwise be read as
# an alias reference to a handler called 'js'. Only the route table is scanned.
route_table=$(grep -vE "^[[:space:]]*import " "$router")
while read -r alias path; do
  [ -z "$alias" ] && continue
  modfile="$SRC/${path#./}"
  [ -f "$modfile" ] || continue
  for fn in $(printf '%s\n' "$route_table" | grep -oE "\b$alias\.[a-zA-Z]+" | sed "s/$alias\.//" | sort -u); do
    if grep -qE "export (async )?function $fn\b|export const $fn\b|export \{[^}]*\b$fn\b" "$modfile"; then :; else
      bad "router.js uses $alias.$fn but ${path} does not export '$fn'"
      unexported=1
    fi
  done
done <<< "$(grep -oE "import \* as [a-zA-Z]+ from '\./[^']+'" "$router" \
  | sed -E "s/import \* as ([a-zA-Z]+) from '([^']+)'/\1 \2/")"
[ "$unexported" -eq 0 ] && ok "every handler referenced by router.js is exported"

# ---------------------------------------------------------------------------
head1 "7. docs/API-CONTRACT.md matches the route table"

contract="$DOCS/API-CONTRACT.md"
if [ ! -f "$contract" ]; then
  bad "docs/API-CONTRACT.md is missing — the frontend has nothing to bind to"
else
  routes_code=$(grep -oE "r\.(get|post|patch|put|delete)\('/v1[^']*'" "$router" \
    | sed -E "s/r\.([a-z]+)\('(.*)'/\U\1\E \2/" | sort -u)
  routes_doc=$(grep -ohE "^\| *\`(GET|POST|PATCH|PUT|DELETE) /v1[^\`]*\`" "$contract" \
    | sed -E 's/^\| *`//; s/`$//' | sed -E 's/ +$//' | sort -u)

  only_code=$(comm -23 <(printf '%s\n' "$routes_code") <(printf '%s\n' "$routes_doc"))
  only_doc=$(comm -13 <(printf '%s\n' "$routes_code") <(printf '%s\n' "$routes_doc"))

  if [ -z "$only_code" ] && [ -z "$only_doc" ]; then
    ok "$(printf '%s\n' "$routes_code" | grep -c .) endpoints documented, none undocumented"
  else
    [ -n "$only_code" ] && { bad "implemented but undocumented:"; printf '        %s\n' $only_code; }
    [ -n "$only_doc" ]  && { bad "documented but not implemented:"; printf '        %s\n' $only_doc; }
  fi
fi

# ---------------------------------------------------------------------------
head1 "8. The dev seed still mirrors the frontend's mock data"

seed="$ROOT/supabase/seed.sql"
# index.html lives in the sibling frontend repo (groundsnearme/).
# Fall back gracefully if the frontend repo is not checked out next to this one.
FRONTEND_ROOT="$(dirname "$ROOT")/groundsnearme"
mock="$FRONTEND_ROOT/index.html"
if [ -f "$seed" ] && [ -f "$mock" ]; then
  drift=0
  for token in 2500 3200 1800 920000000001 920000000002 920000000003 \
               'Star Indoor Cricket' 'Champions Arena' 'Gulshan-e-Iqbal' 'Nazimabad'; do
    if grep -qF "$token" "$mock" && ! grep -qF "$token" "$seed"; then
      bad "index.html shows '$token' but supabase/seed.sql does not"
      drift=1
    fi
  done
  [ "$drift" -eq 0 ] && ok "seed prices, WhatsApp numbers and ground names match index.html"
else
  bad "cannot compare seed with index.html (one of them is missing)"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '\033[32m%s/%s checks passed.\033[0m\n' "$checks" "$checks"
  printf 'Static only — run `npm test` (Node 20+) and apply the migrations to a real\n'
  printf 'Supabase project to verify behaviour.\n'
  exit 0
fi
printf '\033[31m%s of %s checks failed.\033[0m\n' "$fails" "$checks"
exit 1
