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

# The second file of each duplicate pair from before this check was renamed
# with a trailing digit (00241_, 00421_, 00641_, 00891_). Those files moved to
# migrations_archive/ with the 0098 squash; list any future exception here.
# New migrations use NNNN.
SUFFIXED=()

is_suffixed() {
  local f
  for f in "${SUFFIXED[@]+"${SUFFIXED[@]}"}"; do
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
