#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Line up the database's migration history with supabase/migrations/ so that
# `supabase db push` only applies migrations that are genuinely new.
#
# Run it once on a database whose schema already matches the migrations
# folder, i.e. the live project before its first `db push` (its schema came
# from hand-applied SQL), or a project just bootstrapped from schema.sql
# (setup.sh runs this for you). It:
#   1. marks every local migration as applied, and
#   2. removes history rows with no local file (versions recorded by other
#      tools, e.g. the Supabase MCP's timestamp versions).
# It only writes supabase_migrations.schema_migrations; no schema or data
# changes. Safe to re-run.
#
# Don't run it on a database that is missing migrations: they would be
# recorded as applied and `db push` would skip them.
#
# Usage:
#   export SUPABASE_DB_URL="postgres://postgres:PASSWORD@db.REF.supabase.co:5432/postgres"
#   ./supabase/baseline-migration-history.sh
#
# Use the direct connection or the session pooler (port 5432), and
# percent-encode special characters in the password (@ as %40, : as %3A,
# / as %2F, # as %23). It reads the history back afterwards and fails unless
# it holds exactly the local versions.
#
# Requires psql, and the Supabase CLI on PATH or npx.
# ---------------------------------------------------------------------------
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"

if [[ -z "${SUPABASE_DB_URL:-}" ]]; then
  echo "Error: SUPABASE_DB_URL is not set."
  exit 1
fi
if ! command -v psql >/dev/null 2>&1; then
  echo "Error: psql not found."
  exit 1
fi
if command -v supabase >/dev/null 2>&1; then
  SUPABASE=(supabase)
elif command -v npx >/dev/null 2>&1; then
  SUPABASE=(npx --yes supabase)
else
  echo "Error: neither the Supabase CLI nor npx is on PATH."
  exit 1
fi

# An unencoded "@" in the password makes the URL ambiguous: psql and the
# Supabase CLI can split it differently and end up talking to different places.
AUTHORITY="${SUPABASE_DB_URL#*://}"
AUTHORITY="${AUTHORITY%%/*}"
AT_SIGNS="${AUTHORITY//[^@]/}"
if [[ ${#AT_SIGNS} -gt 1 ]]; then
  echo "Error: SUPABASE_DB_URL has more than one \"@\" before the host."
  echo "Percent-encode special characters in the password (@ as %40, : as %3A,"
  echo "/ as %2F, # as %23), or reset it to letters and digits only."
  exit 1
fi

mapfile -t LOCAL < <(ls "$DIR/migrations" | sed -E 's/^([0-9]+)_.*/\1/' | sort)

# Prints the recorded versions, one per line; nothing when the history table
# doesn't exist yet. Fails when the database can't be reached.
recorded_versions() {
  psql "$SUPABASE_DB_URL" -At -v ON_ERROR_STOP=1 -c \
    "select version from supabase_migrations.schema_migrations order by version" 2>/dev/null \
    && return 0
  local exists
  exists="$(psql "$SUPABASE_DB_URL" -At -v ON_ERROR_STOP=1 -c \
    "select to_regclass('supabase_migrations.schema_migrations') is not null")" || {
    echo "Error: could not connect with SUPABASE_DB_URL." >&2
    return 1
  }
  [[ "$exists" == "f" ]] || {
    echo "Error: could not read supabase_migrations.schema_migrations." >&2
    return 1
  }
}

RECORDED_OUT="$(recorded_versions)"
mapfile -t RECORDED <<<"$RECORDED_OUT"

STALE=()
for v in "${RECORDED[@]}"; do
  [[ -z "$v" ]] && continue
  if ! printf '%s\n' "${LOCAL[@]}" | grep -qx -- "$v"; then
    STALE+=("$v")
  fi
done

cd "$ROOT"
if [[ ${#STALE[@]} -gt 0 ]]; then
  echo "==> Removing ${#STALE[@]} history row(s) with no local file: ${STALE[*]}"
  "${SUPABASE[@]}" migration repair --db-url "$SUPABASE_DB_URL" --status reverted "${STALE[@]}"
fi

echo "==> Marking ${#LOCAL[@]} local migration(s) as applied"
"${SUPABASE[@]}" migration repair --db-url "$SUPABASE_DB_URL" --status applied "${LOCAL[@]}"

# The CLI can report success without the rows landing where psql looks
# (suspected cause: a password containing "@"), so check rather than trust it.
echo "==> Checking the recorded history"
EXPECTED="$(printf '%s\n' "${LOCAL[@]}" | sort)"
ACTUAL="$(recorded_versions | sort)"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "Error: the history table does not match supabase/migrations/."
  DIFF="$(diff <(echo "$EXPECTED") <(echo "$ACTUAL") || true)"
  echo "  missing: $(grep -c '^<' <<<"$DIFF" || true), extra: $(grep -c '^>' <<<"$DIFF" || true)"
  echo "The repair did not land where psql reads. Check SUPABASE_DB_URL"
  echo "(direct or session-pooler connection, encoded password) and re-run."
  exit 1
fi

echo "==> Done (${#LOCAL[@]} versions recorded). \`supabase db push\` will now apply only migrations added after this point."
