#!/usr/bin/env bash
# Retry a command that talks to somebody else's service.
#
# Used by the release workflows for the one long upload at the end of a
# build (App Store Connect, Google Play): losing it to a dropped packet
# would mean paying for the build twice. Bounded -- four attempts with
# backoff, then the failure stands.
#
# RETRY_NEVER_ON lists exit codes that mean "trying again cannot help"
# (scripts/play_upload.ts exits 3 for a refusal such as a disabled API or
# a version code already taken), so those fail at once.
#
# Usage:
#   scripts/ci/retry.sh xcrun altool --upload-app ...
#   RETRY_NEVER_ON=3 scripts/ci/retry.sh deno run ... scripts/play_upload.ts app.aab
set -uo pipefail

attempts="${RETRY_ATTEMPTS:-4}"
delay="${RETRY_DELAY:-10}"

# Exit codes that mean "this cannot come right on its own", space
# separated. Empty by default, because a `supabase` CLI failure gives
# no such signal and everything here was written for those.
#
# `scripts/play_upload.ts` does give one. The first real Play upload
# spent seventy seconds and four identical stack traces retrying a
# DISABLED API — a switch in a browser. Backoff against a
# configuration error is not resilience, it is four times the noise
# and four times as long to read.
never="${RETRY_NEVER_ON:-}"

out=""
if [ "${1:-}" = "-o" ]; then
  out="$2"
  shift 2
fi

if [ "$#" -eq 0 ]; then
  echo "retry.sh: nothing to run" >&2
  exit 2
fi

n=1
while true; do
  # Captured inside the branch, not after it. Read after an `if`, `$?`
  # is the status of the `if` itself — zero whenever the body ran — so
  # the first version of this reported every failure as exit 0 and, far
  # worse, *exited* 0 once the attempts ran out. A retry wrapper that
  # turns a genuine failure green is worse than no retry at all, and it
  # would have been invisible: the run goes green, which is what you
  # were hoping to see.
  status=0
  if [ -n "$out" ]; then
    "$@" > "$out" || status=$?
  else
    "$@" || status=$?
  fi

  if [ "$status" -eq 0 ]; then
    if [ -n "$out" ]; then cat "$out"; fi
    exit 0
  fi

  for code in $never; do
    if [ "$status" -eq "$code" ]; then
      echo "::error::\`$*\` failed with exit $status, which says trying" \
           "again cannot help. Not retrying." >&2
      exit "$status"
    fi
  done

  if [ "$n" -ge "$attempts" ]; then
    echo "::error::\`$*\` failed $attempts times; last exit $status" >&2
    exit "$status"
  fi

  echo "::warning::\`$*\` failed (attempt $n of $attempts, exit $status); retrying in ${delay}s" >&2
  sleep "$delay"
  n=$((n + 1))
  delay=$((delay * 2))
done
