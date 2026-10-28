#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Switches the visitor stats on in a built index.html: puts the Umami script
# address and website ID (deploy/nas-stats) into <meta name="getride-stats">,
# which web/stats.js reads. Both come from repository variables:
#
#   STATS_SCRIPT_URL   https://stats.getride.my/s.js
#   STATS_WEBSITE_ID   the website's ID in Umami
#
# Either unset (or not the right shape): the stats stay off and the build
# goes on. Never fails the deploy.
#
# Usage: scripts/ci/stats_meta.sh build/web/index.html
# ---------------------------------------------------------------------------
set -uo pipefail

file="${1:?index.html to update}"
url="${STATS_SCRIPT_URL:-}"
id="${STATS_WEBSITE_ID:-}"

if [ -z "$url" ] || [ -z "$id" ]; then
  echo "Visitor stats off: STATS_SCRIPT_URL and STATS_WEBSITE_ID are not both set."
  exit 0
fi
if ! [[ "$url" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]*)?\.js$ ]]; then
  echo "::warning::STATS_SCRIPT_URL is not an https address of a .js file; visitor stats left off."
  exit 0
fi
if ! [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "::warning::STATS_WEBSITE_ID is not an Umami website ID; visitor stats left off."
  exit 0
fi

sed -i "s|<meta name=\"getride-stats\" content=\"\">|<meta name=\"getride-stats\" content=\"$url $id\">|" "$file"
if grep -q "content=\"$url $id\"" "$file"; then
  echo "Visitor stats on: $url"
else
  echo "::warning::<meta name=\"getride-stats\"> not found in $file; visitor stats left off."
fi
exit 0
