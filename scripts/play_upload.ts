/**
 * Upload an Android App Bundle to Google Play.
 *
 *     deno run --allow-read --allow-env --allow-net \
 *       scripts/play_upload.ts <bundle.aab>
 *
 * The Play equivalent of `xcrun altool --upload-app`, except that Google
 * ships no CLI for it -- the documented route is the Publishing API, and
 * the usual answer is fastlane. This is a hundred lines instead of a Ruby
 * toolchain: a second vendor would be a second place the signing key
 * lives.
 *
 * ## The edit is a transaction
 *
 * Nothing happens until the commit. `edits.insert` opens one, the bundle
 * and the track assignment go inside it, and `edits.commit` applies the
 * lot. A run that dies halfway leaves the edit abandoned rather than the
 * app half-released, and an abandoned edit expires on its own -- which is
 * why there is no cleanup here and no attempt to reuse one.
 *
 * ## What it reads
 *
 *   PLAY_SERVICE_ACCOUNT  the whole service account JSON
 *   PLAY_PACKAGE_NAME     com.taxxee.teksi
 *   PLAY_TRACK            internal | alpha | beta | production
 *   PLAY_RELEASE_NOTES    optional, one line, shown to testers
 */
import {
  googleAccessToken,
  type ServiceAccount,
} from "./google_auth.ts";

const API = "https://androidpublisher.googleapis.com";
const UPLOAD = `${API}/upload/androidpublisher/v3/applications`;
const EDITS = `${API}/androidpublisher/v3/applications`;

/** The scope that makes the token a Play token. */
export const SCOPE = "https://www.googleapis.com/auth/androidpublisher";

/** Google's own language tag for the release notes. */
export const LANGUAGE = "en-US";

export type Track = "internal" | "alpha" | "beta" | "production";

const TRACKS: readonly Track[] = ["internal", "alpha", "beta", "production"];

/**
 * The track, or null if it is not one.
 *
 * An allow-list rather than a cast: this value is interpolated into a URL path, and a
 * track nobody checked would be a request to whatever that spelled.
 */
export function trackOf(raw: unknown): Track | null {
  return typeof raw === "string" && (TRACKS as readonly string[]).includes(raw)
    ? raw as Track
    : null;
}

/**
 * The track update.
 *
 * `status: "completed"` rather than `draft`: a draft release sits in the
 * console waiting for somebody to press a button, which on an automated
 * release is an upload that succeeded and then reached nobody -- the
 * same failure `ITSAppUsesNonExemptEncryption` fixes on the Apple side.
 *
 * Release notes are optional to Play and are sent only when there are
 * some, because an empty `releaseNotes` array is not the same as no
 * key and shows testers a blank change list.
 */
export function trackBody(
  versionCode: number,
  notes: string,
): Record<string, unknown> {
  const release: Record<string, unknown> = {
    versionCodes: [String(versionCode)],
    status: "completed",
  };
  const said = notes.trim();
  if (said) {
    release.releaseNotes = [{ language: LANGUAGE, text: said }];
  }
  return { releases: [release] };
}

/**
 * What Play said, turned into what to do about it.
 *
 * Every sentence here was chosen because the raw message names the
 * wrong end of the problem.
 */
/**
 * The exit code that means "trying again cannot help".
 *
 * `scripts/ci/retry.sh` is told not to retry this one. The first real
 * upload spent seventy seconds and four identical stack traces on a
 * disabled API — a setting in a browser, which no amount of backoff
 * was ever going to change.
 */
export const PERMANENT_EXIT = 3;

/**
 * Whether trying again could ever change the answer.
 *
 * 4xx is Google's decision about this request: a missing permission,
 * an API nobody enabled, a version code already used. None of them
 * heal on their own. 5xx is Google having a bad moment, and 429 is
 * being asked to slow down — both worth another go.
 */
export function isPermanent(status: number): boolean {
  return status >= 400 && status < 500 && status !== 429;
}

/** A refusal, carrying whether it is worth retrying. */
export class PlayRefusal extends Error {
  constructor(message: string, readonly permanent: boolean) {
    super(message);
    this.name = "PlayRefusal";
  }
}

export function uploadRefusal(status: number, said: string): string {
  // The Cloud project has the service account but not the API. It is
  // a separate switch in a separate part of the console from creating
  // the account, and creating one does not turn it on.
  if (said.includes("has not been used in project") ||
      said.includes("it is disabled")) {
    return "The Google Play Android Developer API is not enabled on " +
      "the Cloud project this service account belongs to. Creating the " +
      "account does not enable it — it is a separate switch. Open the " +
      "console link in the message above, press Enable, wait a couple " +
      "of minutes for it to propagate, and run this again.";
  }
  // The one that will happen to whoever sets this up. The Publishing
  // API cannot create an app and will not take the FIRST bundle for one
  // that has never had a release -- that upload goes through the
  // console by hand, once, and every later one can come from here.
  if (
    said.includes("Only releases with status draft may be created") ||
    said.includes("no application was found") ||
    (status === 404 && said.includes("applicationNotFound"))
  ) {
    return "Google Play has no released version of this app yet. The " +
      "Publishing API cannot create an app or take its first bundle: " +
      "upload one build by hand in the Play Console, once, and this " +
      "workflow can do every one after it. See docs/store-release.md.";
  }
  if (status === 403 && said.includes("permission")) {
    return "The service account cannot see this app. Granting it in " +
      "Google Cloud is not enough -- it also has to be invited under " +
      "Play Console, Users and permissions, with Release access to " +
      "this app, and that invitation is a separate screen.";
  }
  if (said.includes("already been used") || said.includes("already exists")) {
    return "Play has seen this version code before. It is the workflow " +
      "run number plus ANDROID_VERSION_CODE_OFFSET, so a build uploaded " +
      "some other way (the Expo app's EAS builds, or a manual upload) " +
      "already used it. Raise the ANDROID_VERSION_CODE_OFFSET repository " +
      "variable above the highest version code in the Play Console.";
  }
  if (said.includes("not signed") || said.includes("certificate")) {
    return "Play refused the signature. The bundle was signed with a " +
      "different key from the one this app is registered to -- most " +
      "often the debug key, which is what the build falls back to when " +
      "key.properties is missing.";
  }
  const trimmed = said.trim();
  return trimmed.length > 0 && trimmed.length <= 400
    ? trimmed
    : `Play answered ${status}`;
}

/** The message inside Play's error body, where there is one. */
export function messageOf(body: string): string {
  try {
    const parsed = JSON.parse(body);
    const said = parsed?.error?.message;
    if (typeof said === "string" && said.trim()) return said;
  } catch {
    // Not JSON. Plenty of Google's 4xx pages are not.
  }
  return body;
}

async function call(
  url: string,
  token: string,
  init: RequestInit = {},
): Promise<unknown> {
  const res = await fetch(url, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(init.headers ?? {}),
    },
  });
  const body = await res.text();
  if (!res.ok) {
    throw new PlayRefusal(
      uploadRefusal(res.status, messageOf(body)),
      isPermanent(res.status),
    );
  }
  return body ? JSON.parse(body) : {};
}

async function main() {
  const path = Deno.args[0];
  if (!path) {
    console.error("usage: play_upload.ts <bundle.aab>");
    Deno.exit(2);
  }

  const raw = Deno.env.get("PLAY_SERVICE_ACCOUNT") ?? "";
  let sa: ServiceAccount;
  try {
    sa = JSON.parse(raw);
  } catch {
    console.error(
      "PLAY_SERVICE_ACCOUNT is not JSON. It is the whole service " +
        "account file, braces included, not the private key on its own.",
    );
    Deno.exit(1);
  }

  const pkg = Deno.env.get("PLAY_PACKAGE_NAME") ?? "";
  const track = trackOf(Deno.env.get("PLAY_TRACK"));
  if (!pkg || !track) {
    console.error(
      `PLAY_PACKAGE_NAME must be set and PLAY_TRACK must be one of ` +
        `${TRACKS.join(", ")}.`,
    );
    Deno.exit(1);
  }
  const notes = Deno.env.get("PLAY_RELEASE_NOTES") ?? "";

  const token = await googleAccessToken(sa, SCOPE);

  const edit = await call(`${EDITS}/${pkg}/edits`, token, {
    method: "POST",
  }) as { id: string };
  console.log(`edit ${edit.id} opened`);

  const bundle = await call(
    `${UPLOAD}/${pkg}/edits/${edit.id}/bundles?uploadType=media`,
    token,
    {
      method: "POST",
      headers: { "Content-Type": "application/octet-stream" },
      body: await Deno.readFile(path),
    },
  ) as { versionCode: number };
  console.log(`uploaded version code ${bundle.versionCode}`);

  await call(`${EDITS}/${pkg}/edits/${edit.id}/tracks/${track}`, token, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(trackBody(bundle.versionCode, notes)),
  });
  console.log(`assigned to ${track}`);

  await call(`${EDITS}/${pkg}/edits/${edit.id}:commit`, token, {
    method: "POST",
  });
  console.log(`committed. Version code ${bundle.versionCode} is on ${track}.`);
}

if (import.meta.main) {
  try {
    await main();
  } catch (error) {
    // A refusal is reported as the sentence it was turned into, not as
    // a Deno stack trace through `call`. The stack says where the
    // throw was, which is never where the problem is — and the first
    // real run printed it four times.
    if (error instanceof PlayRefusal) {
      console.error(error.message);
      Deno.exit(error.permanent ? PERMANENT_EXIT : 1);
    }
    throw error;
  }
}
