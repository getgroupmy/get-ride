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
#   TOM_TOM_API_KEY         when MAP_TILE_URL_TRAFFIC is empty, the traffic
#                           overlay is TomTom's relative-flow tiles with this key
#
# Written as JSON (via jq) rather than passed as --dart-define arguments so
# a key never lands on a command line, and so `{z}`/`&` survive untouched.
# The file holds keys: it goes in $RUNNER_TEMP and is never printed.
set -euo pipefail

out="${1:?usage: map_defines.sh OUT.json}"

traffic="${MAP_TILE_URL_TRAFFIC:-}"
if [ -z "$traffic" ] && [ -n "${TOM_TOM_API_KEY:-}" ]; then
  traffic="https://api.tomtom.com/traffic/map/4/tile/flow/relative0/{z}/{x}/{y}.png?key=${TOM_TOM_API_KEY}"
fi

jq -n \
  --arg light "${MAP_TILE_URL:-}" \
  --arg dark "${MAP_TILE_URL_DARK:-}" \
  --arg satellite "${MAP_TILE_URL_SATELLITE:-}" \
  --arg traffic "$traffic" \
  '{MAP_TILE_URL: $light, MAP_TILE_URL_DARK: $dark,
    MAP_TILE_URL_SATELLITE: $satellite, MAP_TILE_URL_TRAFFIC: $traffic}' > "$out"
chmod 600 "$out"

# Say what is on, never what the values are.
for name in MAP_TILE_URL MAP_TILE_URL_DARK MAP_TILE_URL_SATELLITE MAP_TILE_URL_TRAFFIC; do
  if [ -n "$(jq -r --arg k "$name" '.[$k]' "$out")" ]; then
    echo "$name: set"
  else
    echo "$name: not set (app default)"
  fi
done
