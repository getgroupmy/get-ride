#!/bin/sh
# Builds this week's maps and swaps them in (see README.md, "The weekly
# refresh"). Run as root from DSM Task Scheduler once a week, at night:
#
#   sh /volume1/docker/nas-maps/refresh.sh
#
# The first run makes the maps and starts everything (about 2 to 3 hours on
# the DS224+). Each stage builds into maps/next; what is live keeps serving
# until the swap, which stops the maps for about a minute (GET.ride asks the
# next provider meanwhile). If a stage fails, the live maps are left as they
# were and Admin shows the error. maps/status/refresh.json is what the agent
# reports to Admin.
set -eu

cd "$(dirname "$0")"
HERE=$(pwd)
MAPS="$HERE/maps"
NEXT="$MAPS/next"
WORK="$MAPS/work"
STATUS="$MAPS/status/refresh.json"
LOCK="$MAPS/status/refresh.lock"

# Malaysia, Singapore and Brunei.
PBF_URL="https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf"
BBOX="99.6,0.8,119.3,7.4"
TILES_MAXZOOM=15
OSRM_IMAGE="ghcr.io/project-osrm/osrm-backend:v26.4.0"
PMTILES_IMAGE="protomaps/go-pmtiles:v1.30.3"
NOMINATIM_IMAGE="mediagis/nominatim:5.3.2"
NODE_IMAGE="node:22.23.4-alpine"
BASEMAPS_VERSION="5.7.2"
PHOTON_LANGUAGES="en,ms,zh,ta"

if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"; else COMPOSE="docker-compose"; fi

env_value() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -1 | tr -d '\r"'; }
TILES_URL=$(env_value TILES_URL)
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
old_value() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$STATUS" 2>/dev/null | head -1; }

mkdir -p "$MAPS/status"
LAST_OK=$(old_value lastOkAt)
DATA_DATE=$(old_value dataDate)
TILES_DATE=$(old_value tilesDate)

# status <running true|false> <stage> <percent> [error]
status() {
  err=""
  [ -n "${4:-}" ] && err=$(printf '%s' "$4" | tr -d '"\\' | tr '\n' ' ' | cut -c1-300)
  next=$(date -u -d "+7 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  printf '{"running": %s, "stage": "%s", "percent": %s, "updatedAt": "%s", "lastOkAt": "%s", "lastError": "%s", "dataDate": "%s", "tilesDate": "%s", "nextAt": "%s"}\n' \
    "$1" "$2" "$3" "$(now)" "$LAST_OK" "$err" "$DATA_DATE" "$TILES_DATE" "$next" > "$STATUS.tmp"
  mv "$STATUS.tmp" "$STATUS"
  chmod 644 "$STATUS"
}

STAGE=download
cleanup() {
  code=$?
  docker rm -f maps-nominatim-import >/dev/null 2>&1 || true
  docker network rm maps-refresh >/dev/null 2>&1 || true
  rm -rf "$WORK"
  if [ "$code" -ne 0 ]; then
    if [ "$STAGE" = swap ]; then
      # Put back whatever was already moved aside, and start again.
      for part in osrm photon tiles style; do
        if [ -e "$MAPS/$part.old" ]; then rm -rf "${MAPS:?}/$part"; mv "$MAPS/$part.old" "$MAPS/$part"; fi
      done
      $COMPOSE up -d >/dev/null 2>&1 || true
    fi
    rm -rf "$NEXT"
    status false "$STAGE" 0 "The $STAGE stage failed (exit $code); the maps from before are still live."
    echo "Refresh failed at $STAGE." >&2
  fi
  rm -f "$LOCK"
}

if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
  echo "A refresh is already running (pid $(cat "$LOCK"))." >&2
  exit 1
fi
echo $$ > "$LOCK"
trap cleanup EXIT
trap 'exit 130' INT TERM

case "$TILES_URL" in
  https://*) ;;
  *) echo "Set TILES_URL in .env first (README.md)." >&2; exit 2 ;;
esac

rm -rf "$NEXT" "$WORK"
mkdir -p "$NEXT/osrm" "$NEXT/photon" "$NEXT/tiles" "$NEXT/style" "$WORK"

# 1. The OpenStreetMap extract (about 250 MB).
STAGE=download; status true download 5
echo "Downloading $PBF_URL"
curl -fsSL --retry 3 -o "$WORK/region.osm.pbf" "$PBF_URL"
curl -fsSL --retry 3 -o "$WORK/region.osm.pbf.md5" "$PBF_URL.md5"
want=$(cut -d' ' -f1 "$WORK/region.osm.pbf.md5")
got=$(md5sum "$WORK/region.osm.pbf" | cut -d' ' -f1)
[ "$want" = "$got" ] || { echo "The download is damaged (md5 differs)." >&2; exit 1; }
modified=$(curl -fsSI "$PBF_URL" | sed -n 's/^[Ll]ast-[Mm]odified: *//p' | tr -d '\r')
NEW_DATA_DATE=$(date -u -d "$modified" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || now)

# 2. Routes: OSRM, car profile, multi-level Dijkstra (about 20 minutes).
STAGE=routes; status true routes 15
cp "$WORK/region.osm.pbf" "$NEXT/osrm/region.osm.pbf"
docker run --rm -v "$NEXT/osrm:/data" "$OSRM_IMAGE" osrm-extract -p /opt/car.lua /data/region.osm.pbf
docker run --rm -v "$NEXT/osrm:/data" "$OSRM_IMAGE" osrm-partition /data/region.osrm
docker run --rm -v "$NEXT/osrm:/data" "$OSRM_IMAGE" osrm-customize /data/region.osrm
rm -f "$NEXT/osrm/region.osm.pbf"

# 3. Search: a throwaway Nominatim import of the same file, which Photon
#    then reads into its own index (1 to 2 hours). Nominatim is removed after.
STAGE=search; status true search 30
$COMPOSE build photon >/dev/null
PW=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
docker network create maps-refresh >/dev/null
docker run -d --name maps-nominatim-import --network maps-refresh \
  -e PBF_PATH=/import/region.osm.pbf -e NOMINATIM_PASSWORD="$PW" -e IMPORT_WIKIPEDIA=false \
  -e THREADS=4 --shm-size=1g -v "$WORK:/import:ro" "$NOMINATIM_IMAGE" >/dev/null
echo "Waiting for the Nominatim import"
waited=0
until docker exec maps-nominatim-import curl -fs http://localhost:8080/status >/dev/null 2>&1; do
  docker inspect -f '{{.State.Running}}' maps-nominatim-import 2>/dev/null | grep -q true \
    || { echo "The Nominatim import stopped:" >&2; docker logs --tail 30 maps-nominatim-import >&2; exit 1; }
  waited=$((waited + 60))
  [ "$waited" -lt 21600 ] || { echo "The Nominatim import took over 6 hours." >&2; exit 1; }
  [ $((waited % 600)) -eq 0 ] && status true search 40
  sleep 60
done
status true search 55
chown "$(docker run --rm --entrypoint id getride-photon:1 -u)" "$NEXT/photon"
docker run --rm --network maps-refresh -v "$NEXT/photon:/data" getride-photon:1 \
  -nominatim-import -host maps-nominatim-import -port 5432 -database nominatim \
  -user nominatim -password "$PW" -languages "$PHOTON_LANGUAGES" -data-dir /data
docker rm -f maps-nominatim-import >/dev/null
docker network rm maps-refresh >/dev/null

# 4. The map: this region of the newest Protomaps planet build (a few
#    hundred MB; only the needed parts are downloaded).
STAGE=tiles; status true tiles 75
build=""
for back in 0 1 2 3 4 5 6 7 8 9 10; do
  day=$(date -u -d "-$back days" +%Y%m%d)
  if curl -fsI "https://build.protomaps.com/$day.pmtiles" >/dev/null 2>&1; then build=$day; break; fi
done
[ -n "$build" ] || { echo "No Protomaps build found in the last 10 days." >&2; exit 1; }
echo "Tiles from the Protomaps build of $build"
docker run --rm -v "$NEXT/tiles:/out" "$PMTILES_IMAGE" extract \
  "https://build.protomaps.com/$build.pmtiles" /out/basemap.pmtiles \
  --bbox="$BBOX" --maxzoom="$TILES_MAXZOOM"
NEW_TILES_DATE=$(date -u -d "$(echo "$build" | sed 's/\(....\)\(..\)\(..\)/\1-\2-\3/')" +%Y-%m-%dT%H:%M:%SZ)

# 5. The styles (light, dark), fonts and icons for the web app.
STAGE=style; status true style 90
docker run --rm -e TILES_URL="$TILES_URL" -v "$HERE/style:/src:ro" -v "$NEXT/style:/out" "$NODE_IMAGE" sh -c "
  set -e; mkdir -p /tmp/w; cd /tmp/w
  npm install --silent --no-audit --no-fund @protomaps/basemaps@$BASEMAPS_VERSION >/dev/null
  cp /src/make_style.mjs . && node make_style.mjs /out/styles
  wget -q -O assets.zip https://github.com/protomaps/basemaps-assets/archive/refs/heads/main.zip
  unzip -q assets.zip && cp -r basemaps-assets-main/fonts basemaps-assets-main/sprites /out/"
chmod -R a+rX "$NEXT"

# 6. Swap: stop, move the new data in, start (about a minute).
STAGE=swap; status true swap 97
$COMPOSE stop osrm photon tiles gateway agent >/dev/null 2>&1 || true
for part in osrm photon tiles style; do
  rm -rf "${MAPS:?}/$part.old"
  [ -e "$MAPS/$part" ] && mv "$MAPS/$part" "$MAPS/$part.old"
  mv "$NEXT/$part" "$MAPS/$part"
done
DATA_DATE=$NEW_DATA_DATE
TILES_DATE=$NEW_TILES_DATE
LAST_OK=$(now)
status false swap 100
$COMPOSE up -d
for part in osrm photon tiles style; do rm -rf "${MAPS:?}/$part.old"; done
rm -rf "$NEXT"
echo "Maps refreshed: OpenStreetMap of $DATA_DATE, tiles of $build."
