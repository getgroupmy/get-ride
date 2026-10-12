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

/**
 * A refusal, carrying whether it is worth retrying -- and what Play
 * actually said. The sentence in `message` is our reading of it; `said`
 * is kept so the log shows Play's own words too, because the reading can
 * be wrong (run 10's "cannot see this app" came after the same account
 * had just uploaded a bundle to that app).
 */
export class PlayRefusal extends Error {
  constructor(
    message: string,
    readonly permanent: boolean,
    readonly said: string = "",
    readonly status: number = 0,
  ) {
    super(message);
    this.name = "PlayRefusal";
  }
}

/** Play's own words for a refusal, when they add to our sentence. */
export function playSaid(error: PlayRefusal): string | null {
  const said = error.said.trim();
  if (!said || said === error.message.trim()) return null;
  const clipped = said.length > 1000 ? `${said.slice(0, 1000)}…` : said;
  return `Play said (HTTP ${error.status}): ${clipped}`;
}

/**
 * Which call Play refused: opening the edit, uploading the bundle,
 * assigning it to the track, or committing.
 *
 * It matters for a 403. Refused at `open`, the account cannot see the
 * app at all. Refused later, it already could -- the edit opened -- and
 * what is missing is the permission for that one step, most often
 * "Release apps to testing tracks" at the commit.
 */
export type Stage = "open" | "upload" | "track" | "commit";

/** The Play Console permission a track's release needs. */
export function releasePermission(track: Track | null): string {
  return track === "production"
    ? "Release to production, exclude devices, and use Play App Signing"
    : "Release apps to testing tracks";
}

/**
 * Whether Play refused because a Play Console declaration (App content)
 * is missing, rather than for anything about the account or the bundle.
 */
export function isDeclarationRefusal(said: string): boolean {
  return /you must let us know|declaration|app content/i.test(said);
}

export function uploadRefusal(
  status: number,
  said: string,
  stage: Stage = "open",
  track: Track | null = null,
): string {
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
  // Play wants a declaration filled in under App content first (Android
  // release run 12: "You must let us know whether your app uses any
  // Foreground Service permissions."). Checked before the permission
  // branch below, which that sentence would otherwise match on the word
  // "permissions" and send whoever reads it to the wrong screen.
  if (isDeclarationRefusal(said)) {
    return "Play wants a declaration filled in before it will release " +
      "this build. In Play Console, open the app, Policy > App content, " +
      "and complete the item Play names below (for a foreground service: " +
      "Foreground service permissions, saying what each one is used for). " +
      "Nothing is wrong with the service account, and the next run needs " +
      "no change here once the declaration is saved.";
  }
  if (status === 403 && said.includes("permission")) {
    if (stage === "open") {
      return "The service account cannot see this app. Granting it in " +
        "Google Cloud is not enough -- it also has to be invited under " +
        "Play Console, Users and permissions, with Release access to " +
        "this app, and that invitation is a separate screen.";
    }
    // The edit opened, so the account can see the app; it is one
    // permission short for this step.
    const step = stage === "commit"
      ? "release it"
      : stage === "track"
      ? "assign it to a track"
      : "upload a bundle";
    return `The service account can open an edit for this app but may not ${step}. ` +
      "In Play Console, Users and permissions, open the service account, " +
      `App permissions, this app, and tick "${releasePermission(track)}", ` +
      "then Apply. A permission change can take up to a day to reach " +
      "the Publishing API, so a run straight after the change may still " +
      "be refused.";
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

/**
 * Whether Play refused the commit only because it can't send the changes
 * for review by itself. It says so when the app has changes that must be
 * sent from the Console (a rejected update, managed publishing, a policy
 * declaration due): the edit itself is fine, and committing it with
 * `changesNotSentForReview=true` applies it. Sending it for review is then
 * a button in the Play Console, where it is needed at all.
 */
export function wantsNotSentForReview(said: string): boolean {
  return said.includes("changesNotSentForReview");
}

/** The commit URL for an edit, with the not-sent-for-review flag when asked. */
export function commitUrl(base: string, pkg: string, editId: string, notSentForReview = false): string {
  const url = `${base}/${pkg}/edits/${editId}:commit`;
  return notSentForReview ? `${url}?changesNotSentForReview=true` : url;
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
  stage: Stage = "open",
  track: Track | null = null,
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
    const said = messageOf(body);
    throw new PlayRefusal(
      uploadRefusal(res.status, said, stage, track),
      isPermanent(res.status),
      said,
      res.status,
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
    "upload",
    track,
  ) as { versionCode: number };
  console.log(`uploaded version code ${bundle.versionCode}`);

  await call(`${EDITS}/${pkg}/edits/${edit.id}/tracks/${track}`, token, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(trackBody(bundle.versionCode, notes)),
  }, "track", track);
  console.log(`assigned to ${track}`);

  console.log(`committing edit ${edit.id}`);
  try {
    await call(commitUrl(EDITS, pkg, edit.id), token, { method: "POST" }, "commit", track);
  } catch (error) {
    // Play's raw text, not our sentence: a long message is clipped to
    // "Play answered 400" there and would hide the words looked for.
    if (!(error instanceof PlayRefusal) || !wantsNotSentForReview(error.said || error.message)) throw error;
    // The app has changes Play won't send for review by itself. Commit
    // the edit without sending it; the Console then offers "Send for
    // review" where review is needed.
    await call(commitUrl(EDITS, pkg, edit.id, true), token, { method: "POST" }, "commit", track);
    console.log(
      "committed without sending for review (Play asked for that). Open the " +
        "Play Console > Publishing overview and press Send for review if it is offered.",
    );
  }
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
      const raw = playSaid(error);
      if (raw) console.error(raw);
      Deno.exit(error.permanent ? PERMANENT_EXIT : 1);
    }
    throw error;
  }
}
