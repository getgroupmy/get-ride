#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Fails when two files in supabase/migrations/ share a version, or a file is
# not named NNNN_lower_snake_case.sql.
#
# The Supabase CLI (`supabase db push`) uses the digits before the first "_"
# as the migration version, and versions must be unique. PRs written in
# parallel each take "the next free number", so two of them merging can both
# keep it (three 0089s in October 2026). Pick the next number after the
# highest one on main, and re-check after merging main into your branch.
#
# Usage: ./supabase/check-migration-numbers.sh
# ---------------------------------------------------------------------------
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migrations"

# The second file of each duplicate pair from before this check, renamed with
# a trailing digit so its version is unique and still sorts right after its
# pair. The only five-digit versions allowed; new migrations use NNNN.
SUFFIXED=(
  00241_partner_profile_columns.sql
  00421_push_notifications.sql
  00641_settings_entries_write_policy_reapply.sql
  00891_wallet_transfer_requests_participant_rls.sql
)

is_suffixed() {
  local f
  for f in "${SUFFIXED[@]}"; do
    [[ "$f" == "$1" ]] && return 0
  done
  return 1
}

status=0
declare -A seen=()

for path in "$DIR"/*; do
  name="$(basename "$path")"
  if [[ "$name" =~ ^([0-9]{4})_[a-z0-9_]+\.sql$ ]] \
    || { is_suffixed "$name" && [[ "$name" =~ ^([0-9]{5})_ ]]; }; then
    version="${BASH_REMATCH[1]}"
  else
    echo "::error file=supabase/migrations/$name::Migration file must be named NNNN_lower_snake_case.sql"
    status=1
    continue
  fi
  if [[ -n "${seen[$version]:-}" ]]; then
    echo "::error file=supabase/migrations/$name::Migration version $version is used by both ${seen[$version]} and $name. Renumber the newer one to the next free number."
    status=1
  else
    seen[$version]="$name"
  fi
done

if [[ $status -eq 0 ]]; then
  echo "Migration numbers OK (${#seen[@]} files)."
fi
exit $status
