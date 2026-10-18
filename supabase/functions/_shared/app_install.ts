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
 * Android also gets one APK per processor (getride-arm64-v8a.apk,
 * getride-armeabi-v7a.apk), a third of the size of the universal
 * getride.apk, which stays for old links and as the fallback. A phone is
 * handed the one it runs: 64-bit by default, 32-bit when it says it is a
 * 32-bit-only phone (`?abi=armeabi-v7a`), the universal one when its split
 * is missing (`pickApk`). Every APK is listed in `apks` so the app can pick
 * for itself.
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

/** The per-processor APKs, by Android ABI, and the one that runs anywhere. */
export const SPLIT_APKS: Record<string, string> = {
  "arm64-v8a": "getride-arm64-v8a.apk",
  "armeabi-v7a": "getride-armeabi-v7a.apk",
};
export const UNIVERSAL_ABI = "universal";
/** What a phone that says nothing about itself gets: nearly every phone is 64-bit. */
export const DEFAULT_ABI = "arm64-v8a";

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

/** One installable APK: a processor's own, or the universal one. */
export interface AppApk {
  /** `arm64-v8a`, `armeabi-v7a` or `universal`. */
  abi: string;
  url: string;
  size?: number;
}

/** The ABI a request asks for (`?abi=`), or null for anything unknown. */
export function abiOf(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const s = raw.trim().toLowerCase();
  if (s === "arm64" || s === "aarch64" || s === "arm64-v8a") return "arm64-v8a";
  if (s === "arm" || s === "armv7" || s === "armeabi-v7a") return "armeabi-v7a";
  if (s === UNIVERSAL_ABI) return UNIVERSAL_ABI;
  return null;
}

/**
 * The APK to hand a phone that runs [abi] (null: unknown, so 64-bit): its
 * own split, else the universal APK, else (a phone that said nothing) any
 * split there is. Null when nothing installable is published.
 */
export function pickApk(apks: AppApk[], abi: string | null): AppApk | null {
  const by = (a: string) => apks.find((x) => x.abi === a);
  const want = abi ?? DEFAULT_ABI;
  return by(want) ?? by(UNIVERSAL_ABI) ?? (abi == null ? apks[0] : undefined) ?? null;
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
  /** Android: which APK download_url / install_url are (see `pickApk`). */
  abi?: string;
  /** Android: every APK published, 64-bit first, the universal one last. */
  apks?: AppApk[];
  /** Android: the App Bundle (.aab) for a hand upload to Play, when published. */
  bundle_url?: string;
  bundle_size?: number;
}

const text = (v: unknown): string | undefined =>
  typeof v === "string" && v.trim() !== "" ? v.trim() : undefined;

/** The APKs a release holds: the splits first, the universal one last. */
export function apksOf(assets: Map<string, ReleaseAsset>): AppApk[] {
  const out: AppApk[] = [];
  const add = (abi: string, name: string) => {
    const a = assets.get(name);
    if (a) out.push({ abi, url: a.url, ...(a.size ? { size: a.size } : {}) });
  };
  for (const [abi, name] of Object.entries(SPLIT_APKS)) add(abi, name);
  add(UNIVERSAL_ABI, BUILD_ASSETS.android.asset);
  return out;
}

/**
 * What the admin and the install page are told, from the release and its
 * build.json. Without the app asset there is nothing to offer. [abi] is the
 * phone's processor when it said (Android only; see `pickApk`).
 */
export function appBuildFrom(
  platform: BuildPlatform,
  release: unknown,
  info: unknown,
  manifestUrl: string,
  abi: string | null = null,
): AppBuild {
  const assets = assetsOf(release);
  const apks = platform === "android" ? apksOf(assets) : [];
  const picked = platform === "android" ? pickApk(apks, abi) : null;
  const asset = picked
    ? assets.get(SPLIT_APKS[picked.abi] ?? BUILD_ASSETS.android.asset)
    : platform === "ios"
    ? assets.get(BUILD_ASSETS.ios.asset)
    : undefined;
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
  if (picked) {
    out.abi = picked.abi;
    out.apks = apks;
    // build.json's size is the universal APK's; a split is only its own.
    if (picked.abi !== UNIVERSAL_ABI) out.size = asset.size || undefined;
  }
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
