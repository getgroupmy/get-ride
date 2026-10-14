/**
 * Write the two files that let a link on qr.getride.my open the app.
 *
 *     deno run --allow-read --allow-write --allow-env \
 *       scripts/ci/app_links.ts <output dir>
 *
 * Run by .github/workflows/deploy-web.yml into
 * `.vercel/output/static/.well-known/`, so they are served at
 *
 *   https://qr.getride.my/.well-known/apple-app-site-association  (iOS)
 *   https://qr.getride.my/.well-known/assetlinks.json             (Android)
 *
 * A My QR code encodes https://qr.getride.my/<ref|me|now>/<token>
 * (lib/src/core/my_qr.dart). With these files the phone checks that the
 * app really belongs to the site and opens it on the code instead of the
 * browser; without them the link still works, on the web app.
 *
 * ## What it reads (all optional)
 *
 *   APP_LINKS_PROFILE_PLIST  the decoded App Store provisioning profile
 *                            (an XML plist): its TeamIdentifier
 *   APPLE_TEAM_ID            the team id, when there is no profile
 *   APP_LINKS_KEYTOOL        `keytool -list -v` of the upload keystore: its
 *                            SHA-256 certificate fingerprints
 *   ANDROID_APP_LINK_SHA256  more fingerprints, comma separated: the Google
 *                            Play App Signing key, which is not the upload
 *                            key and is only shown in Play Console
 *
 * A file whose inputs are missing is skipped with a notice rather than
 * written wrong: an association naming the wrong team or key is worse
 * than none, because the phone caches the answer.
 *
 * Nothing here is a secret. A team id and a certificate fingerprint are
 * public by design -- these very files publish them.
 */

/** The app's id on both stores. */
export const APP_ID = "com.taxxee.teksi";

/** The paths on qr.getride.my that are a code (QrKind.pathSegment). */
export const LINK_PATHS = ["/ref/*", "/me/*", "/now/*"] as const;

const TEAM_ID = /^[A-Z0-9]{10}$/;

/** Whether [s] is an Apple team id (ten capitals and digits). */
export function isTeamId(s: unknown): s is string {
  return typeof s === "string" && TEAM_ID.test(s);
}

function plistString(xml: string, key: string): string | null {
  // The first <string> after the key, whether the value is a string or an
  // array of them (TeamIdentifier and ApplicationIdentifierPrefix are
  // arrays). Deliberately small: a provisioning profile is Apple's
  // well-formed XML, not arbitrary input.
  const at = xml.indexOf(`<key>${key}</key>`);
  if (at < 0) return null;
  const rest = xml.slice(at + key.length + 11);
  const m = rest.match(/^\s*(?:<array>\s*)?<string>([^<]*)<\/string>/);
  return m ? m[1].trim() : null;
}

/** The team id in a decoded provisioning profile, or null. */
export function teamIdFromProfile(xml: string): string | null {
  for (const key of ["TeamIdentifier", "ApplicationIdentifierPrefix"]) {
    const v = plistString(xml, key);
    if (isTeamId(v)) return v;
  }
  return null;
}

/**
 * A SHA-256 fingerprint as assetlinks.json wants it (`AB:CD:…`, 32 pairs,
 * upper case), from that form or plain hex; null for anything else.
 */
export function normalizeFingerprint(raw: string): string | null {
  const hex = raw.trim().replace(/^sha-?256\s*:?\s*/i, "").replace(/[:\s]/g, "");
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) return null;
  return hex.toUpperCase().match(/../g)!.join(":");
}

/** Every SHA-256 fingerprint `keytool -list -v` printed (one per alias). */
export function keytoolFingerprints(output: string): string[] {
  const found: string[] = [];
  for (const m of output.matchAll(/SHA-?256:\s*([0-9A-Fa-f:]+)/g)) {
    const f = normalizeFingerprint(m[1]);
    if (f) found.push(f);
  }
  return found;
}

/**
 * The fingerprints in a comma (or space) separated list, and the entries
 * that are not one, so a typo in the variable is reported rather than
 * silently dropped.
 */
export function parseFingerprintList(
  list: string,
): { fingerprints: string[]; rejected: string[] } {
  const fingerprints: string[] = [];
  const rejected: string[] = [];
  for (const part of list.split(/[,;\n]+/)) {
    const s = part.trim();
    if (!s) continue;
    const f = normalizeFingerprint(s);
    if (f) fingerprints.push(f);
    else rejected.push(s);
  }
  return { fingerprints, rejected };
}

/** [lists] flattened, in order, without repeats. */
export function dedupe(...lists: string[][]): string[] {
  return [...new Set(lists.flat())];
}

/** apple-app-site-association for [teamId]. */
export function appleAppSiteAssociation(
  teamId: string,
  appId: string = APP_ID,
): Record<string, unknown> {
  if (!isTeamId(teamId)) throw new Error(`not a team id: ${teamId}`);
  return {
    // Passkeys: the app may use credentials saved for this domain (the
    // relying party www.getride.my; Runner.entitlements asks for
    // webcredentials:www.getride.my).
    webcredentials: { apps: [`${teamId}.${appId}`] },
    applinks: {
      apps: [],
      details: [
        {
          appIDs: [`${teamId}.${appId}`],
          // `components` for iOS 13+, `paths` for anything older.
          components: LINK_PATHS.map((p) => ({ "/": p })),
          paths: [...LINK_PATHS],
        },
      ],
    },
  };
}

/** assetlinks.json for [fingerprints]. */
export function assetLinks(
  fingerprints: string[],
  appId: string = APP_ID,
): unknown[] {
  if (fingerprints.length === 0) throw new Error("no fingerprints");
  return [
    {
      // handle_all_urls opens My QR links in the app; get_login_creds lets
      // it use passkeys saved for this domain (Credential Manager).
      relation: ["delegate_permission/common.handle_all_urls", "delegate_permission/common.get_login_creds"],
      target: {
        namespace: "android_app",
        package_name: appId,
        sha256_cert_fingerprints: fingerprints,
      },
    },
  ];
}

/**
 * The origin an Android app signs passkey requests with, for Supabase →
 * Authentication → Passkeys → Relying Party Origins: the signing
 * certificate's SHA-256, base64url without padding.
 */
export function apkKeyHashOrigin(fingerprint: string): string {
  const hex = fingerprint.replace(/:/g, "");
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return "android:apk-key-hash:" + btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** What to write, and what to say about what was not. */
export interface Plan {
  files: Record<string, string>;
  notices: string[];
  warnings: string[];
}

export interface Inputs {
  profilePlist?: string | null;
  teamIdVar?: string | null;
  keytoolOutput?: string | null;
  sha256Var?: string | null;
}

/** Decides both files from what the workflow had. Pure. */
export function plan(inputs: Inputs): Plan {
  const files: Record<string, string> = {};
  const notices: string[] = [];
  const warnings: string[] = [];

  // iOS: the team from the profile the app is signed with, else the
  // variable. They agree in practice; the profile wins because it is what
  // actually signs the app.
  let teamId: string | null = null;
  if (inputs.profilePlist) {
    teamId = teamIdFromProfile(inputs.profilePlist);
    if (!teamId) warnings.push("The provisioning profile names no team id; trying APPLE_TEAM_ID.");
  }
  const teamVar = (inputs.teamIdVar ?? "").trim();
  if (!teamId && teamVar) {
    if (isTeamId(teamVar)) teamId = teamVar;
    else warnings.push(`APPLE_TEAM_ID "${teamVar}" is not a 10-character team id; ignored.`);
  }
  if (teamId) {
    files["apple-app-site-association"] = JSON.stringify(appleAppSiteAssociation(teamId));
  } else {
    notices.push(
      "No Apple team id (no IOS_PROVISIONING_PROFILE secret, no APPLE_TEAM_ID variable): " +
        "apple-app-site-association not written, so iPhones open qr.getride.my links in Safari.",
    );
  }

  // Android: the upload key, plus whatever the variable adds (the Play App
  // Signing key: the one a Play-installed app is actually signed with).
  const fromKeystore = keytoolFingerprints(inputs.keytoolOutput ?? "");
  const listed = parseFingerprintList(inputs.sha256Var ?? "");
  for (const r of listed.rejected) {
    warnings.push(`ANDROID_APP_LINK_SHA256 entry "${r}" is not a SHA-256 fingerprint; ignored.`);
  }
  const fingerprints = dedupe(fromKeystore, listed.fingerprints);
  if (fingerprints.length) {
    files["assetlinks.json"] = JSON.stringify(assetLinks(fingerprints));
    notices.push(
      "Passkey origins for Supabase -> Authentication -> Passkeys -> Relying Party Origins: " +
        fingerprints.map(apkKeyHashOrigin).join(","),
    );
  } else {
    notices.push(
      "No signing fingerprint (no ANDROID_KEYSTORE_BASE64 secret, no ANDROID_APP_LINK_SHA256 variable): " +
        "assetlinks.json not written, so Android opens qr.getride.my links in the browser.",
    );
  }
  if (fromKeystore.length && !listed.fingerprints.length) {
    notices.push(
      "assetlinks.json lists the upload key only. An app installed from Google Play is signed with " +
        "the Play App Signing key: set ANDROID_APP_LINK_SHA256 to its SHA-256 (Play Console -> App integrity).",
    );
  }
  return { files, notices, warnings };
}

async function readOptional(path: string | undefined): Promise<string | null> {
  if (!path) return null;
  try {
    return await Deno.readTextFile(path);
  } catch {
    return null;
  }
}

async function main(): Promise<void> {
  const out = Deno.args[0];
  if (!out) {
    console.error("usage: app_links.ts <output dir>");
    Deno.exit(2);
  }
  const p = plan({
    profilePlist: await readOptional(Deno.env.get("APP_LINKS_PROFILE_PLIST")),
    teamIdVar: Deno.env.get("APPLE_TEAM_ID"),
    keytoolOutput: await readOptional(Deno.env.get("APP_LINKS_KEYTOOL")),
    sha256Var: Deno.env.get("ANDROID_APP_LINK_SHA256"),
  });
  await Deno.mkdir(out, { recursive: true });
  const summary: string[] = [];
  for (const [name, body] of Object.entries(p.files)) {
    await Deno.writeTextFile(`${out}/${name}`, body + "\n");
    console.log(`wrote ${out}/${name}`);
    console.log(body);
    summary.push(`* App links: \`/.well-known/${name}\` written`);
  }
  for (const n of p.notices) {
    console.log(`::notice::${n}`);
    summary.push(`* App links: ${n}`);
  }
  for (const w of p.warnings) {
    console.log(`::warning::${w}`);
    summary.push(`* App links: ${w}`);
  }
  const path = Deno.env.get("GITHUB_STEP_SUMMARY");
  if (path && summary.length) {
    await Deno.writeTextFile(path, summary.join("\n") + "\n", { append: true });
  }
}

if (import.meta.main) {
  await main();
}
