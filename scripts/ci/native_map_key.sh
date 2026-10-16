#!/usr/bin/env bash
# The Maps SDK key a phone build carries (Google's own map, Admin → Settings →
# Maps → "Google Maps (native)"), into $GITHUB_ENV for the steps after.
#
#   scripts/ci/native_map_key.sh android|ios
#
# First the key in Admin → API Keys → Google → "Maps SDK for Android" /
# "Maps SDK for iOS" (the first one not switched off), read from the
# database with the SUPABASE_ACCESS_TOKEN repository secret; else the
# GOOGLE_MAPS_ANDROID_API_KEY / GOOGLE_MAPS_IOS_API_KEY repository secret,
# passed in as FALLBACK_KEY. Neither: the build keeps the app's own map.
# The key is masked in the log and never printed.
set -euo pipefail

platform="${1:?usage: native_map_key.sh android|ios}"
case "$platform" in
  android) service=maps_android; name=GOOGLE_MAPS_ANDROID_API_KEY; label="Maps SDK for Android" ;;
  ios) service=maps_ios; name=GOOGLE_MAPS_IOS_API_KEY; label="Maps SDK for iOS" ;;
  *) echo "usage: native_map_key.sh android|ios" >&2; exit 2 ;;
esac

key=""
from=""
if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  query="select k->>'value' as v
    from public.app_settings a,
      jsonb_array_elements(case jsonb_typeof(a.value) when 'array' then a.value else a.value->'providers' end) p,
      jsonb_array_elements(coalesce(p->'services', '[]')) s,
      jsonb_array_elements(coalesce(s->'keys', '[]')) k
    where a.key = 'api_providers' and p->>'id' = 'google' and s->>'id' = '$service'
      and coalesce(k->>'disabled', 'false') <> 'true' and coalesce(k->>'value', '') <> ''
    limit 1"
  body=$(jq -n --arg q "$query" '{query: $q}')
  if answer=$(curl -fsS -X POST "https://api.supabase.com/v1/projects/${PROJECT_REF:-rqlavogkgywxspuxgiwk}/database/query" \
      -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" -d "$body" 2>/dev/null); then
    key=$(jq -r '.[0].v // empty' <<<"$answer" 2>/dev/null || true)
    [ -n "$key" ] && from="Admin → API Keys"
  else
    echo "::warning::Could not read Admin → API Keys for the $platform map key; trying the repository secret."
  fi
fi
if [ -z "$key" ] && [ -n "${FALLBACK_KEY:-}" ]; then
  key="$FALLBACK_KEY"
  from="the $name repository secret"
fi

if [ -z "$key" ]; then
  echo "Google's own map: no $platform key (Admin → API Keys → Google → $label) — the app keeps its own map."
  exit 0
fi
echo "::add-mask::$key"
echo "$name=$key" >> "$GITHUB_ENV"
echo "Google's own map: the $platform key from $from."
