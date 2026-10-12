#!/usr/bin/env bash
# Publish the build a release workflow just made as the rolling GitHub
# release `<platform>-latest`, so Admin → App Release can offer it for
# download, as an install link and as a QR code (supabase/functions/
# app-install reads it back).
#
#   scripts/ci/publish_build.sh <ios|android> <file> <build number> <installable: true|false>
#
# The release holds two assets: the app (getride.ipa / getride.apk) and
# build.json describing it. It is deleted and created again each time, like
# gateway-latest, so its tag always points at the commit that was built.
# Needs GH_TOKEN with contents: write.
set -euo pipefail

platform=$1
file=$2
build=$3
installable=$4

case "$platform" in
  ios) asset=getride.ipa; title=iOS ;;
  android) asset=getride.apk; title=Android ;;
  *) echo "::error::platform must be ios or android, not $platform"; exit 2 ;;
esac

tag="$platform-latest"
version=$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
dir="$RUNNER_TEMP/publish-$platform"
rm -rf "$dir" && mkdir -p "$dir"
cp "$file" "$dir/$asset"
size=$(wc -c < "$dir/$asset" | tr -d ' ')

cat > "$dir/build.json" <<JSON
{
  "platform": "$platform",
  "version": "$version",
  "build": "$build",
  "bundle_id": "${BUNDLE_ID:-com.taxxee.teksi}",
  "asset": "$asset",
  "size": $size,
  "installable": $installable,
  "sha": "$GITHUB_SHA",
  "run_id": "$GITHUB_RUN_ID",
  "run_number": "$GITHUB_RUN_NUMBER",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

if [ "$platform" = ios ] && [ "$installable" = true ]; then
  how="Install over the air from Admin → App Release (share the link or scan the QR). Only iPhones registered in the Ad Hoc profile can install it."
elif [ "$platform" = ios ]; then
  how="App Store-signed: download it for Transporter, but it can't be installed directly. Add IOS_ADHOC_PROVISIONING_PROFILE for an installable build."
else
  how="Install from Admin → App Release (share the link or scan the QR). Signed with the upload key, so remove a Play-installed copy first."
fi

gh release delete "$tag" --cleanup-tag --yes 2>/dev/null || true
gh release create "$tag" "$dir/$asset" "$dir/build.json" \
  --target "$GITHUB_SHA" \
  --prerelease \
  --title "GET.ride $title $version ($build)" \
  --notes "$how Built from ${GITHUB_SHA::7}, run #$GITHUB_RUN_NUMBER."

echo "published $asset ($size bytes) as $tag"
