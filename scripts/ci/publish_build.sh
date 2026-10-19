#!/usr/bin/env bash
# Publish the build a release workflow just made as the rolling GitHub
# release `<platform>-latest`, so Admin → App Release can offer it for
# download, as an install link and as a QR code (supabase/functions/
# app-install reads it back).
#
#   scripts/ci/publish_build.sh <ios|android> <file> <build number> <installable: true|false> [bundle.aab] [abi=split.apk ...]
#
# The release holds the app (getride.ipa / getride.apk) and build.json
# describing it; on Android, given the fifth argument, also getride.aab,
# the bundle Play takes, for an admin to download and upload by hand (it
# is not installable, so it gets no install link or QR), and each
# `abi=file` after it as getride-<abi>.apk: the APK for one processor
# (arm64-v8a, armeabi-v7a), about a third of the universal getride.apk,
# which app-install hands a phone in its place. getride.apk stays, for old
# links and as the fallback. It is deleted and created again each time, like
# gateway-latest, so its tag always points at the commit that was built.
# Needs GH_TOKEN with contents: write.
set -euo pipefail

platform=$1
file=$2
build=$3
installable=$4
bundle=${5:-}
splits=("${@:6}")

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
extra=()
if [ -n "$bundle" ]; then
  [ "$platform" = android ] || { echo "::error::only an Android release carries a bundle"; exit 2; }
  cp "$bundle" "$dir/getride.aab"
  extra=("$dir/getride.aab")
fi
# "arm64-v8a": {"asset": "getride-arm64-v8a.apk", "size": 59768832}, ...
apks=""
for pair in ${splits[@]+"${splits[@]}"}; do
  abi=${pair%%=*}
  path=${pair#*=}
  [ "$platform" = android ] || { echo "::error::only an Android release has per-processor APKs"; exit 2; }
  case "$abi" in
    arm64-v8a|armeabi-v7a|x86_64) ;;
    *) echo "::error::unknown ABI $abi"; exit 2 ;;
  esac
  [ -f "$path" ] || { echo "::warning::no $abi APK at $path; publishing without it"; continue; }
  name="getride-$abi.apk"
  cp "$path" "$dir/$name"
  extra+=("$dir/$name")
  apks="$apks${apks:+, }\"$abi\": {\"asset\": \"$name\", \"size\": $(wc -c < "$dir/$name" | tr -d ' ')}"
done

cat > "$dir/build.json" <<JSON
{
  "platform": "$platform",
  "version": "$version",
  "build": "$build",
  "bundle_id": "${BUNDLE_ID:-com.taxxee.teksi}",
  "asset": "$asset",
  "size": $size,
  "installable": $installable,
  "apks": {$apks},
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
gh release create "$tag" "$dir/$asset" "$dir/build.json" ${extra[@]+"${extra[@]}"} \
  --target "$GITHUB_SHA" \
  --prerelease \
  --title "GET.ride $title $version ($build)" \
  --notes "$how Built from ${GITHUB_SHA::7}, run #$GITHUB_RUN_NUMBER."

echo "published $asset ($size bytes)${bundle:+ and getride.aab}${apks:+ and per-processor APKs: $apks} as $tag"
