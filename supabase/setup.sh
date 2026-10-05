#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot Supabase bootstrap for a freshly cloned project.
#
# Usage:
#   export SUPABASE_DB_URL="postgres://postgres:[PASSWORD]@db.[ref].supabase.co:5432/postgres"
#   ./supabase/setup.sh                # schema + seed (+ edge functions if CLI present)
#   ./supabase/setup.sh --reset        # drop everything first, then schema+seed
#   ./supabase/setup.sh --schema-only  # skip seed
#   ./supabase/setup.sh --no-functions # skip deploying edge functions
#
# Requires: psql in PATH. Install via Postgres client tools, e.g.:
#   macOS  : brew install libpq && brew link --force libpq
#   Ubuntu : sudo apt-get install -y postgresql-client
# ---------------------------------------------------------------------------
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SUPABASE_DB_URL:-}" ]]; then
  echo "Error: SUPABASE_DB_URL is not set."
  echo "Find it in Supabase Dashboard → Project Settings → Database → Connection string (URI)."
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "Error: psql not found. Install the Postgres client first."
  exit 1
fi

RESET=0
SEED=1
FUNCTIONS=1
for arg in "$@"; do
  case "$arg" in
    --reset)        RESET=1     ;;
    --schema-only)  SEED=0      ;;
    --no-functions) FUNCTIONS=0 ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

if [[ $RESET -eq 1 ]]; then
  echo "→ Resetting (dropping existing tables)…"
  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f "$DIR/reset.sql"
fi

echo "→ Applying schema…"
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f "$DIR/schema.sql"

if [[ $SEED -eq 1 ]]; then
  echo "→ Seeding default data…"
  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f "$DIR/seed.sql"
fi

# schema.sql already contains every migration, so record them all as applied;
# otherwise the first `supabase db push` would try to re-run the whole history.
if command -v supabase >/dev/null 2>&1 || command -v npx >/dev/null 2>&1; then
  echo "→ Recording migration history…"
  "$DIR/baseline-migration-history.sh" || {
    echo "  ! Could not record it. Run ./supabase/baseline-migration-history.sh"
    echo "    before the first \`supabase db push\`."
  }
else
  echo "→ Skipping migration history (no Supabase CLI or npx)."
  echo "  Run ./supabase/baseline-migration-history.sh before the first \`supabase db push\`."
fi

# ---------------------------------------------------------------------------
# Edge functions (push notification sender). Best-effort: requires the Supabase
# CLI and a linked project. Without this step the in-app "Push Notification"
# screen reports "Send failed" because supabase.functions.invoke("send-push")
# has nothing to call. Skip with --no-functions or set SUPABASE_PROJECT_REF.
# ---------------------------------------------------------------------------
if [[ $FUNCTIONS -eq 1 ]]; then
  if command -v supabase >/dev/null 2>&1; then
    echo "→ Deploying edge functions…"
    REF_ARG=()
    [[ -n "${SUPABASE_PROJECT_REF:-}" ]] && REF_ARG=(--project-ref "$SUPABASE_PROJECT_REF")
    for fn in send-push ai-route-proxy document-ai-verify ios-release android-release; do
      if supabase functions deploy "$fn" --no-verify-jwt "${REF_ARG[@]}"; then
        echo "  ✓ $fn deployed."
      else
        echo "  ! Could not deploy $fn automatically."
        echo "    Run manually:  supabase functions deploy $fn --no-verify-jwt"
      fi
    done
  else
    echo "→ Skipping edge functions (Supabase CLI not found)."
    echo "  Deploy them manually (push notifications + AI fare estimates):"
    echo "    supabase functions deploy send-push --no-verify-jwt"
    echo "    supabase functions deploy ai-route-proxy --no-verify-jwt"
    echo "    supabase functions deploy document-ai-verify --no-verify-jwt"
    echo "    supabase functions deploy ios-release --no-verify-jwt"
    echo "    supabase functions deploy android-release --no-verify-jwt"
  fi
fi

echo "✓ Supabase setup complete."
