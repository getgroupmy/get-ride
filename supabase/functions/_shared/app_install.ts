/**
 * The latest build of the app, for downloading and installing directly.
 *
 * ios-release.yml / android-release.yml publish each build as the rolling
 * GitHub release `ios-latest` / `android-latest` (scripts/ci/publish_build.sh):
 * the app (getride.ipa / getride.apk) plus build.json describing it. The
 * `app-install` function reads that back for Admin → App Release and the
 * public getride.my/install page, and serves the manifest an iPhone needs
 * to install an Ad Hoc build over the air (itms-services).
 *
 * This module holds the decisions and imports nothing, so it is tested
 * without a server (`app_install_test.ts`).
 */

export type BuildPlatform = "ios" | "android";

export const BUILD_ASSETS: Record<BuildPlatform, { tag: string; asset: string; bundle?: string }> = {
  ios: { tag: "ios-latest", asset: "getride.ipa" },
  // The App Bundle Play takes: downloadable from Admin, never installable.
  android: { tag: "android-latest", asset: "getride.apk", bundle: "getride.aab" },
};

export const DEFAULT_BUILDS_REPOSITORY = "getgroupmy/get-ride";
export const DEFAULT_BUNDLE_ID = "com.taxxee.teksi";
export const APP_TITLE = "GET.ride";

/** The platform asked for, or null for anything else. */
export function platformOf(raw: unknown): BuildPlatform | null {
  return raw === "ios" || raw === "android" ? raw : null;
}

/** The GitHub API address of a platform's rolling release. */
export function releaseApiUrl(repo: string, platform: BuildPlatform): string {
  return `https://api.github.com/repos/${repo}/releases/tags/${BUILD_ASSETS[platform].tag}`;
}

interface ReleaseAsset {
  name: string;
  size: number;
  url: string;
  updatedAt: string | null;
}

/** The release's assets by name, as far as they are well formed. */
export function assetsOf(release: unknown): Map<string, ReleaseAsset> {
  const out = new Map<string, ReleaseAsset>();
  const list = (release as { assets?: unknown })?.assets;
  if (!Array.isArray(list)) return out;
  for (const a of list) {
    const name = a?.name;
    const url = a?.browser_download_url;
    if (typeof name !== "string" || typeof url !== "string" || !url.startsWith("https://")) continue;
    out.set(name, {
      name,
      size: typeof a.size === "number" ? a.size : 0,
      url,
      updatedAt: typeof a.updated_at === "string" ? a.updated_at : null,
    });
  }
  return out;
}

export interface AppBuild {
  available: boolean;
  platform: BuildPlatform;
  version?: string;
  build?: string;
  bundle_id?: string;
  size?: number;
  /** An iPhone can install it over the air (Ad Hoc). Android: always. */
  installable?: boolean;
  sha?: string;
  run_number?: string;
  created_at?: string;
  /** The file itself. */
  download_url?: string;
  /** iOS: the itms-services manifest. */
  manifest_url?: string;
  /** What installs it on a phone: the itms-services link, or the APK. */
  install_url?: string;
  /** Android: the App Bundle (.aab) for a hand upload to Play, when published. */
  bundle_url?: string;
  bundle_size?: number;
}

const text = (v: unknown): string | undefined =>
  typeof v === "string" && v.trim() !== "" ? v.trim() : undefined;

/**
 * What the admin and the install page are told, from the release and its
 * build.json. Without the app asset there is nothing to offer.
 */
export function appBuildFrom(
  platform: BuildPlatform,
  release: unknown,
  info: unknown,
  manifestUrl: string,
): AppBuild {
  const assets = assetsOf(release);
  const asset = assets.get(BUILD_ASSETS[platform].asset);
  if (!asset) return { available: false, platform };
  const bundleName = BUILD_ASSETS[platform].bundle;
  const bundle = bundleName ? assets.get(bundleName) : undefined;
  const b = (info && typeof info === "object" ? info : {}) as Record<string, unknown>;
  // An Android APK always installs; an iPhone build only when Ad Hoc.
  const installable = platform === "android" ? true : b.installable === true;
  const out: AppBuild = {
    available: true,
    platform,
    version: text(b.version),
    build: text(b.build),
    bundle_id: text(b.bundle_id) ?? DEFAULT_BUNDLE_ID,
    size: asset.size || (typeof b.size === "number" ? b.size : undefined),
    installable,
    sha: text(b.sha),
    run_number: text(b.run_number),
    created_at: text(b.created_at) ?? asset.updatedAt ?? undefined,
    download_url: asset.url,
  };
  if (bundle) {
    out.bundle_url = bundle.url;
    if (bundle.size) out.bundle_size = bundle.size;
  }
  if (platform === "ios" && installable) {
    out.manifest_url = manifestUrl;
    out.install_url = itmsServicesUrl(manifestUrl);
  } else if (platform === "android") {
    out.install_url = asset.url;
  }
  return out;
}

/** The link an iPhone opens to install from a manifest. */
export function itmsServicesUrl(manifestUrl: string): string {
  return `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestUrl)}`;
}

function xml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

/** The manifest iOS reads to install an Ad Hoc build over the air. */
export function manifestPlist(build: AppBuild): string | null {
  if (build.platform !== "ios" || !build.available || !build.installable || !build.download_url) return null;
  const version = build.version ?? "1.0.0";
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key><string>software-package</string>
          <key>url</key><string>${xml(build.download_url)}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key><string>${xml(build.bundle_id ?? DEFAULT_BUNDLE_ID)}</string>
        <key>bundle-version</key><string>${xml(version)}</string>
        <key>kind</key><string>software</string>
        <key>title</key><string>${xml(APP_TITLE)}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
`;
}
