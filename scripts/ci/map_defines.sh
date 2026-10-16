#!/usr/bin/env bash
# The map tile sources for a build, as a --dart-define-from-file JSON.
#
#   scripts/ci/map_defines.sh OUT.json
#   flutter build … --dart-define-from-file=OUT.json
#
# Reads from the environment (each optional; empty means "use the app's
# default", which is what lib/src/widgets/map_tiles.dart and map_traffic.dart
# already do for an empty define):
#
#   MAP_TILE_URL            light base tiles (default: OpenStreetMap)
#   MAP_TILE_URL_DARK       dark base tiles
#   MAP_TILE_URL_SATELLITE  satellite imagery
#   MAP_TILE_URL_TRAFFIC    traffic overlay, a full XYZ template with its key
#   MAP_TILE_URL_TRAFFIC_FALLBACK  backup traffic template, fetched per tile
#                           when the primary fails (quota, outage)
#   TOM_TOM_API_KEY         when MAP_TILE_URL_TRAFFIC is empty, the traffic
#                           overlay is TomTom's relative-flow tiles with this key
#   HERE_API_KEY            HERE's traffic-flow tiles: the backup behind
#                           TomTom, or the primary when there is no TomTom key
#   GOOGLE_MAPS_ANDROID_API_KEY / GOOGLE_MAPS_IOS_API_KEY
#                           the Maps SDK key this build carries (in the
#                           manifest / Info.plist, not here): when set, the app
#                           may draw Google's own map (GOOGLE_MAPS_NATIVE=true)
#
# Written as JSON (via jq) rather than passed as --dart-define arguments so
# a key never lands on a command line, and so `{z}`/`&` survive untouched.
# The file holds keys: it goes in $RUNNER_TEMP and is never printed.
set -euo pipefail

out="${1:?usage: map_defines.sh OUT.json}"

tomtom=""
if [ -n "${TOM_TOM_API_KEY:-}" ]; then
  tomtom="https://api.tomtom.com/traffic/map/4/tile/flow/relative0/{z}/{x}/{y}.png?key=${TOM_TOM_API_KEY}"
fi
here=""
if [ -n "${HERE_API_KEY:-}" ]; then
  here="https://traffic.maps.hereapi.com/v3/flow/mc/{z}/{x}/{y}/png?apiKey=${HERE_API_KEY}"
fi

# Primary: an explicit template, else TomTom, else HERE.
traffic="${MAP_TILE_URL_TRAFFIC:-}"
[ -n "$traffic" ] || traffic="$tomtom"
[ -n "$traffic" ] || traffic="$here"

# Backup: an explicit template, else HERE (unless HERE is already primary).
fallback="${MAP_TILE_URL_TRAFFIC_FALLBACK:-}"
if [ -z "$fallback" ] && [ "$here" != "$traffic" ]; then
  fallback="$here"
fi

# Google's own map: only a build that carries a Maps SDK key may draw it.
native=""
if [ -n "${GOOGLE_MAPS_ANDROID_API_KEY:-}${GOOGLE_MAPS_IOS_API_KEY:-}" ]; then
  native="true"
fi

jq -n \
  --arg light "${MAP_TILE_URL:-}" \
  --arg dark "${MAP_TILE_URL_DARK:-}" \
  --arg satellite "${MAP_TILE_URL_SATELLITE:-}" \
  --arg traffic "$traffic" \
  --arg fallback "$fallback" \
  --arg native "$native" \
  '{MAP_TILE_URL: $light, MAP_TILE_URL_DARK: $dark,
    MAP_TILE_URL_SATELLITE: $satellite, MAP_TILE_URL_TRAFFIC: $traffic,
    MAP_TILE_URL_TRAFFIC_FALLBACK: $fallback, GOOGLE_MAPS_NATIVE: $native}' > "$out"
chmod 600 "$out"

# Say what is on, never what the values are.
for name in MAP_TILE_URL MAP_TILE_URL_DARK MAP_TILE_URL_SATELLITE MAP_TILE_URL_TRAFFIC MAP_TILE_URL_TRAFFIC_FALLBACK \
  GOOGLE_MAPS_NATIVE; do
  if [ -n "$(jq -r --arg k "$name" '.[$k]' "$out")" ]; then
    echo "$name: set"
  else
    echo "$name: not set (app default)"
  fi
done
