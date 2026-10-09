#!/usr/bin/env bash
# Admin → App Settings → App Icon, baked into a store build: the icon on a
# phone's home screen is part of the installed app, so a release build takes
# the admin's published icon (`app_branding.app_icon_url`) in place of
# assets/branding/icon.png and regenerates the launcher icons from it.
#
# Never fails the release: with no icon published, the backend unreachable or
# a file that is not an image, the build keeps the built-in icon.
set -uo pipefail

config=lib/src/config.dart
url="${SUPABASE_URL:-$(grep -oE "https://[a-z0-9]+\.supabase\.co" "$config" | head -1)}"
key="${SUPABASE_ANON_KEY:-$(grep -oE "eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+" "$config" | head -1)}"
keep() { echo "Keeping the built-in app icon: $1"; exit 0; }

[ -n "$url" ] && [ -n "$key" ] || keep "no backend configured"
row=$(curl -fsS --max-time 20 "$url/rest/v1/app_branding?id=eq.global&select=app_icon_url" \
  -H "apikey: $key" -H "Authorization: Bearer $key") || keep "could not read app_branding"
icon=$(printf '%s' "$row" | sed -nE 's/.*"app_icon_url":"([^"]+)".*/\1/p')
case "$icon" in
  https://*) ;;
  *) keep "no icon published" ;;
esac

tmp=$(mktemp)
curl -fsSL --max-time 60 "$icon" -o "$tmp" || keep "could not download $icon"
# A PNG or a JPEG, by its first bytes, whatever the URL says.
magic=$(head -c 4 "$tmp" | od -An -tx1 | tr -d ' \n')
case "$magic" in
  89504e47 | ffd8ff*) ;;
  *) keep "$icon is not a PNG or JPEG" ;;
esac

cp assets/branding/icon.png "$tmp.builtin"
cp "$tmp" assets/branding/icon.png
if dart run flutter_launcher_icons; then
  echo "App icon: $icon"
else
  cp "$tmp.builtin" assets/branding/icon.png
  git checkout -- android ios macos windows web 2>/dev/null || true
  keep "flutter_launcher_icons could not use $icon"
fi
