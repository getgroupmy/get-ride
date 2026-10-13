# Releasing to the App Store and Google Play

**Admin → Settings → App Release** (in the Flutter admin or the Expo
admin). Pick where the build goes, press the button, and GitHub Actions
builds this Flutter app, signs it and uploads it.

```
Admin console (Flutter or Expo)
  → Supabase edge function ios-release / android-release   (holds the GitHub token,
                                                              checks admin access)
  → .github/workflows/ios-release.yml      (macOS, ~25 min) → App Store Connect
  → .github/workflows/android-release.yml  (Ubuntu, ~8 min) → Google Play
```

The edge functions live in this repository (`supabase/functions/`), with
the rest of the backend, next to the workflows and the signing secrets. The consoles never see a signing key or a token.

## The app identity

Both stores get **`com.taxxee.teksi`**, the identity the Expo app shipped
under. So a release from here **replaces** whatever was last published
in that listing. The Expo app's EAS builds are no longer meant to be
uploaded to the stores.

Two things follow from sharing the listing:

* **Version numbers must keep going up.** Each store refuses a build
  number it has already seen, and EAS has already used some. The
  workflows use `github.run_number` plus an offset, so set these
  **repository variables** (Settings → Secrets and variables → Actions →
  Variables) above the highest numbers already in each store:
  * `IOS_BUILD_NUMBER_OFFSET`: above the highest build number in App
    Store Connect for the current version.
  * `ANDROID_VERSION_CODE_OFFSET`: above the highest version code in the
    Play Console.
* **Android must be signed with the existing upload key.** Play binds
  the app to its upload key. If the Expo app was built with EAS, Expo
  holds that keystore. Download it with `eas credentials` → Android →
  production → *Keystore: Download*, and use it below. A new key would be
  refused, and only Google can reset it.

### Upload key reset (October 2026)

The first Flutter release (5 Oct 2026, run 37354331936) was refused by Play:
the bundle was signed with the key in the `ANDROID_KEYSTORE_*` secrets, not
the upload key the listing was registered with (the Expo app's EAS key).
An upload key reset was requested the same day, and Google confirmed it
for **TEKSI. Bid, Agree & Ride (`com.taxxee.teksi`)**:

| | |
| --- | --- |
| New key valid from | **2026-10-07 11:29 UTC** |
| MD5 | `3A:2B:1A:B5:CF:89:2E:A2:D1:9C:22:B3:BE:E6:90:40` |
| SHA-1 | `18:6A:59:BA:4F:D5:C8:59:BD:32:66:F4:BE:60:5B:09:7A:36:B2:0C` |

The new key is now valid. Until that time `android-release.yml` refused to
build (an *Upload key reset hold* step, since removed). Before a release, make
sure the `ANDROID_KEYSTORE_*` secrets hold the key with the fingerprints above
(`keytool -list -v -keystore upload.jks`); keep that keystore safe, because it
is now the listing's upload key.

The marketing version (`1.0.0`) comes from `version:` in `pubspec.yaml`.
Raise it there for a new store version.

## What no button can do

**Skip review.** TestFlight and Play internal testing reach testers
within minutes of processing. **App Store**: the build is uploaded, and
you still submit it for review in App Store Connect. **Play production**:
the release rolls out once Play's review approves it. Either review takes
hours to days.

## Setup

### 1. The console button (Supabase function secrets)

Supabase dashboard → Edge Functions → Secrets:

| Name | What it is |
| --- | --- |
| `GITHUB_RELEASE_TOKEN` | A fine-grained GitHub token. Resource owner **getgroupmy**, only `getgroupmy/get-ride`, permission **Actions: Read and write**, nothing else. |
| `GITHUB_RELEASE_REPOSITORY` | Optional. Defaults to `getgroupmy/get-ride`. |
| `GITHUB_RELEASE_REF` | Optional. Unset, the repository's default branch is built. |

Then deploy the two functions from this repository's root:

```
supabase functions deploy ios-release --no-verify-jwt
supabase functions deploy android-release --no-verify-jwt
```

Until the token exists the cards say **Not set up yet**. To release, an
admin needs **edit** access to the `admin-settings-app-release` page
(full `*` admins have it). Read access shows the build list only.

### 2. iOS (Actions secrets in this repository)

In the Apple Developer account: an App ID for `com.taxxee.teksi` (it
already exists if the Expo app shipped), an **Apple Distribution**
certificate exported as a `.p12` with a password, an **App Store**
provisioning profile for that App ID, and an App Store Connect API key
(Users and Access → Integrations → App Store Connect API).

| Secret | Value |
| --- | --- |
| `IOS_DIST_CERT_P12` | `base64 -i dist.p12` |
| `IOS_DIST_CERT_PASSWORD` | the `.p12` password |
| `IOS_PROVISIONING_PROFILE` | `base64 -i profile.mobileprovision` |
| `APP_STORE_CONNECT_KEY_ID` | the 10-character Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | the issuer UUID |
| `APP_STORE_CONNECT_KEY_P8` | the whole `AuthKey_XXXX.p8`, BEGIN/END lines included |

On macOS use `base64 -i FILE`; there is no `-w` option.

### 3. Android (Actions secrets in this repository)

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -i upload.jks \| tr -d '\n'` (the existing upload key, see above) |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias |
| `ANDROID_KEY_PASSWORD` | key password |
| `PLAY_SERVICE_ACCOUNT` | the whole service account JSON |

The service account needs all three of these, and each is easy to
believe the others cover:

1. Google Cloud Console → the project linked to Play → IAM & Admin →
   Service Accounts → create one → Keys → Add key → JSON.
2. Google Cloud Console → APIs & Services → enable the **Google Play
   Android Developer API**.
3. Play Console → Users and permissions → invite the service account's
   email with **Release** access to this app: under App permissions,
   tick **Release apps to testing tracks** (internal / alpha / beta) and,
   for production, **Release to production, exclude devices, and use Play
   App Signing**. A permission change can take up to a day to reach the
   Publishing API.

When the upload is refused, the run says at which step. Refused when
opening the edit, the account cannot see the app (step 3 is missing).
Refused at the commit, after "uploaded version code" and "assigned to",
it can see the app but lacks the release permission for that track. Either
way Play's own words are quoted after the explanation.

Refused at the commit with "You must let us know whether your app uses
any Foreground Service permissions" (or another "let us know" / App
content item) is not an account problem: Play wants each foreground
service type the app declares explained once under Play Console → Policy →
App content → Foreground service permissions. Save that and re-run;
nothing in the workflow changes. The types, and what to say:

| Type | From | Use |
| --- | --- | --- |
| `FOREGROUND_SERVICE_LOCATION` | the app (geolocator) | the driver's live position to the rider on the way to pickup and during the trip, screen off included |
| `FOREGROUND_SERVICE_PHONE_CALL` | flutter_callkit_incoming | an incoming in-app voice call (rider, driver, support) rings with the app in the background |
| `FOREGROUND_SERVICE_MICROPHONE` | flutter_callkit_incoming | the audio of an ongoing in-app voice call keeps running in the background |

The call plugin also asks for `FOREGROUND_SERVICE_CAMERA` (for video
calls). Every GET.ride call is voice only, so `AndroidManifest.xml`
removes it, and the Flutter workflow's Android build fails if it ever
comes back.

If the Play listing has **never** had a release, Play will not take the
first bundle through the API. Run *Android release* from the Actions tab
with **Send it to Play unticked**, download the bundle from the run's
Artifacts, upload it by hand in the Play Console once, and every release
after that can come from the button.

### 4. Download, install link and QR code (testing without a store)

Every release run also publishes its build as a rolling GitHub release in
this (public) repository, replaced by the next run
(`scripts/ci/publish_build.sh`):

| Release | Asset | Installs on |
| --- | --- | --- |
| `android-latest` | `getride.apk`, same key and version code as the Play bundle | any Android phone. It is signed with the upload key, not Play's app signing key, so remove a Play-installed copy first |
| `android-latest` | `getride.aab`, the bundle Play takes, for a hand upload in the Play Console (Admin → App Release → Download .aab) | no phone: download only, so no install link or QR |
| `ios-latest` | `getride.ipa`, Ad Hoc signed | only the iPhones registered in the Ad Hoc profile |

Admin → App Release shows the latest build on each card, with **Download
.ipa / .apk**, **Share install link** and **QR code**. The link and the
QR both open the public page `https://getride.my/install/<ios|android>`.
On that page, **Install** opens the APK on Android, or the itms-services
link on an iPhone (open it in Safari).

The `app-install` edge function serves the build details and the iPhone's
install manifest. It is public, because the files are public release assets
already:

```
supabase functions deploy app-install --no-verify-jwt
```

It uses `GITHUB_RELEASE_TOKEN` when it is set, for GitHub's higher rate
limit, and works without it.

**For iPhone installs**, add the Actions secret
`IOS_ADHOC_PROVISIONING_PROFILE`. It is the base64 of an **Ad Hoc**
provisioning profile for `com.taxxee.teksi`, made with the same Apple
Distribution certificate:

1. Register each tester's iPhone UDID under Devices in the Apple Developer
   account.
2. Create the profile with those devices selected.
3. Regenerate the profile whenever you add a device.

Without this secret, the App Store IPA is published instead. It can be
downloaded (for example, for Transporter) but not installed, and the page
says so.

### 5. Push notifications (Firebase)

The apps get push through Firebase Cloud Messaging (FCM), which delivers to
Android directly and to iPhones through Apple's push service. Without this
step the apps build and work, just without notifications.

1. **Firebase project.** In the [Firebase console](https://console.firebase.google.com)
   create a project (or use an existing one), then add an **Android app** and
   an **iOS app**, both with the package / bundle id `com.taxxee.teksi`.
2. **Client ids → repository variables** (Settings → Secrets and variables →
   Actions → Variables). These are public identifiers, not secrets. From
   Project settings → General:

   | Variable | Where |
   | --- | --- |
   | `FIREBASE_PROJECT_ID` | Project ID |
   | `FIREBASE_MESSAGING_SENDER_ID` | Project number (also on the Cloud Messaging tab as *Sender ID*) |
   | `FIREBASE_ANDROID_APP_ID` | The Android app's *App ID* (`1:…:android:…`) |
   | `FIREBASE_ANDROID_API_KEY` | `current_key` in the Android app's `google-services.json` |
   | `FIREBASE_IOS_APP_ID` | The iOS app's *App ID* (`1:…:ios:…`) |
   | `FIREBASE_IOS_API_KEY` | `API_KEY` in the iOS app's `GoogleService-Info.plist` |

   The two config files are only read for those values; nothing is committed.
3. **iPhones: the APNs key.** Apple Developer → Certificates, IDs & Profiles →
   Keys → create a key with **Apple Push Notifications service (APNs)**, and
   download the `.p8`. Upload it in Firebase → Project settings → Cloud
   Messaging → Apple app configuration, with its Key ID and your Team ID.
4. **iPhones: the capability.** The App ID `com.taxxee.teksi` must have
   **Push Notifications** ticked (Identifiers → the App ID). If you tick it
   now, regenerate the App Store provisioning profile and replace the
   `IOS_PROVISIONING_PROFILE` secret, because the app now asks for the push
   entitlement and an old profile without it is refused at archive time.
5. **Sending: the service account.** Firebase → Project settings → Service
   accounts → *Generate new private key*. Put the whole JSON in Supabase →
   Edge Functions → Secrets as **`FCM_SERVICE_ACCOUNT`**. The `send-push`
   function (`supabase/functions/send-push`) uses it for every Flutter device.

The next store build picks up the variables. Notifications reach a phone once
someone signs in there and allows notifications.

### 6. App links (a scanned My QR code opens the app)

My QR codes encode `https://qr.getride.my/<ref|me|now>/<token>`. On a phone
with the app, the camera opens the app on the code (Android App Links, iOS
universal links); without it, the same link opens the web app. Older codes
(`https://getride.my/q/…`, `getride://…`) still scan in the app.

What is automatic:

* **The domain: a Cloudflare worker serves every `*.getride.my` subdomain.**
  `cloudflare/subdomain-proxy` is a worker on the route `*.getride.my/*`. For
  any subdomain (`qr`, or one added later) it fetches the same path from the
  production host Vercel already has a certificate for (`www.getride.my`) and
  returns that answer under the visitor's address. So a new subdomain needs
  no Vercel domain and no DNS record. A plain proxied record pointing at
  Vercel would not work: Vercel has no certificate for a name it was never
  given, and Cloudflare would answer 525. `/.well-known/*` comes back as
  Vercel's own 200 JSON, never a redirect (Apple does not follow redirects
  for `apple-app-site-association`).
  `.github/workflows/cloudflare-worker.yml` deploys it on pushes to `main`
  that touch it (or by hand: Actions → *Cloudflare worker* → Run workflow).
  It then makes sure the zone has a **proxied** wildcard record (`*` CNAME
  `getride.my`, orange cloud), because a worker route never fires for a DNS-only
  (grey) record. It creates that record only when no `*` record exists. It
  never changes an existing record, and warns if one is grey. Finally it
  requests `https://qr.getride.my/.well-known/…` and warns if either file is
  not a 200 JSON answer.
  * The apex, `www` and the worker's target host are always passed through to
    their own origin. That is also what makes a loop impossible (see
    `worker.js`). The route catches **every proxied** `*.getride.my` host,
    including ones with their own orange-clouded record, so before the first
    deploy check Cloudflare → DNS for proxied subdomains served elsewhere
    (`api`, `status`, …). Grey records are not affected. To keep those
    subdomains off the worker, set the repository variable
    **`SUBDOMAIN_PROXY_PASS_THROUGH`** (comma separated, `api` or
    `api.getride.my`) and re-run the workflow. **`SUBDOMAIN_PROXY_TARGET`**
    changes the host fetched from (default `www.getride.my`). Defaults are
    in `cloudflare/subdomain-proxy/wrangler.toml`.
  * A subdomain with its own explicit record (for example a grey `qr` CNAME)
    overrides the wildcard and bypasses the worker. The workflow warns about
    `qr`.
  * `deploy/domains.txt` is now only for domains that must be attached to the
    Vercel project itself (for example another apex). Do not list
    `*.getride.my` subdomains there: the web deploy would create a DNS-only
    record that bypasses the worker.
* **The verification files**, written at every web deploy and served on
  every domain of the project, and through the worker on every subdomain:
  `/.well-known/apple-app-site-association` (team id read from
  `IOS_PROVISIONING_PROFILE`) and `/.well-known/assetlinks.json` (the upload
  key's SHA-256 from `ANDROID_KEYSTORE_BASE64`). A file whose inputs are
  missing is skipped, with a notice in the run.
* **Android**: the intent filters are in the manifest; nothing to switch on.
* **iOS**: `ios-release.yml` adds `applinks:qr.getride.my` to the build's
  entitlements **only when the provisioning profile allows Associated
  Domains**. Otherwise the build still succeeds, with a warning, and the links
  open Safari.

What you do once:

1. **Apple: turn on Associated Domains.** Apple Developer → Certificates,
   IDs & Profiles → Identifiers → `com.taxxee.teksi` → tick **Associated
   Domains** → Save. Then Profiles → regenerate (edit, save) the **App Store**
   profile, download it and replace the `IOS_PROVISIONING_PROFILE` secret
   (`base64 -i profile.mobileprovision`). If you use an Ad Hoc profile, do the
   same for it and `IOS_ADHOC_PROVISIONING_PROFILE` — an Ad Hoc profile
   without the capability makes that run publish the App Store IPA instead.
   Then run *iOS release* again: links work from that build on.
2. **Google Play: the App Signing key.** An app installed from Play is signed
   by Google's **app signing key**, not the upload key. Play Console → the app
   → Test and release → **App integrity** → App signing → copy the
   *App signing key certificate* SHA-256, and set the repository variable
   **`ANDROID_APP_LINK_SHA256`** to it (Settings → Secrets and variables →
   Actions → Variables; several may be given, comma separated). Builds
   installed from the `android-latest` APK are signed with the upload key,
   which is already included.
3. **Optional: `APPLE_TEAM_ID`** (repository variable, the 10-character
   team id) — only used when `IOS_PROVISIONING_PROFILE` is not set.
4. **Cloudflare: one API token for the worker and DNS.** dash.cloudflare.com →
   My Profile → API Tokens → Create Token → **Custom token**:
   * Account → **Workers Scripts → Edit**
   * Zone → **Workers Routes → Edit**
   * Zone → **DNS → Edit**
   * Zone → **Zone → Read**

   Account resources: your account. Zone resources: *Specific zone* →
   **getride.my**. Save the token as the Actions **secret**
   `CLOUDFLARE_API_TOKEN`. The worker workflow and the web deploy's
   *Domains* step both use it. Also add the Actions **variable**
   `CLOUDFLARE_ACCOUNT_ID` (the *Account ID* on the account's overview page in
   the dashboard). Without it, wrangler has to look the account up, which
   needs the extra permission User → Memberships → Read. Then run
   Actions → *Cloudflare worker* → Run workflow. Without the token the
   workflow stays green and its summary says what is missing.
5. **Cloudflare: SSL/TLS mode Full (strict).** getride.my → SSL/TLS →
   Overview → **Full (strict)**. The worker fetches `https://www.getride.my`,
   a host Vercel holds a valid certificate for, so strict validation costs
   nothing. The same goes for any proxied record that points straight at
   Vercel (`www` or the apex, if they are orange-clouded). If `www` is
   orange-clouded, the worker's own fetch of it also goes through the zone's
   settings. *Flexible* would talk plain HTTP to Vercel, and Vercel's HTTPS
   redirect would then loop.
6. **Vercel's `qr.getride.my` domain** (added by hand, or by an earlier
   deploy from `deploy/domains.txt`) is harmless and can stay. It is only
   used if a DNS-only `qr` record points at Vercel. If Cloudflare has such a
   record, delete it (the workflow warns about it) so `qr` goes through the
   worker like every other subdomain. Removing the domain from the Vercel
   project is optional.

After the next push to `main` (web deploy), check:

* `curl -I https://qr.getride.my/.well-known/apple-app-site-association`
  answers `HTTP/2 200` with `content-type: application/json` and no
  `location` header. Seeing both a `cf-ray` and an `x-vercel-id` header is
  expected: Cloudflare (the worker) answered, with Vercel behind it.
* <https://qr.getride.my/.well-known/apple-app-site-association> — JSON naming
  `<TEAMID>.com.taxxee.teksi` and `/ref/*`, `/me/*`, `/now/*`
  (Apple's CDN caches it; a new file can take a day to reach phones).
* <https://qr.getride.my/.well-known/assetlinks.json>, and Google's
  [Digital Asset Links tester](https://developers.google.com/digital-asset-links/tools/generator)
  with host `qr.getride.my`, package `com.taxxee.teksi` and the fingerprint.
* On an Android phone with the app: `adb shell pm get-app-links com.taxxee.teksi`
  should show `qr.getride.my: verified`. If it says otherwise after fixing the
  files, `adb shell pm verify-app-links --re-verify com.taxxee.teksi`.
* Scan a My QR code with the camera: it should offer to open GET.ride.

## Flutter version

Every workflow that installs Flutter (`flutter.yml`, `android-release.yml`,
`ios-release.yml`, `deploy-web.yml`, `gateway.yml`) pins it with
`flutter-version: 3.47.7` instead of taking whatever `stable` is that day.
Five plugins (`firebase_core`, `flutter_callkit_incoming`,
`flutter_native_contact_picker`, `flutter_tts`, `flutter_webrtc`) still apply
the Kotlin Gradle Plugin, which Flutter warns a future release will refuse to
build; all five were on their latest versions when this was written. To move
Flutter on: change all seven `flutter-version` lines in one PR, and merge it
only when the Flutter workflow (Android build included) is green. Upgrade the
plugins first once their authors ship versions without the old plugin.

## When something goes wrong

Every run writes a summary on its Actions page, saying what was uploaded
or why nothing was. The console's *Recent builds* list links to each run.

| Symptom | Cause |
| --- | --- |
| Card says *Not set up yet* | `GITHUB_RELEASE_TOKEN` missing, or the functions not deployed |
| Run finishes immediately, summary lists secrets | Actions secrets missing; the run stops rather than fails |
| "profile is for X, not com.taxxee.teksi" | Provisioning profile made for a different App ID |
| Play: version code already used | Raise `ANDROID_VERSION_CODE_OFFSET` |
| App Store Connect: build number already used | Raise `IOS_BUILD_NUMBER_OFFSET` |
| Play refused the signature | Not signed with the listing's upload key |
| "API has not been used in project" | Step 2 of the service account setup |
| iOS archive: profile "doesn't include the aps-environment entitlement" | Push Notifications not enabled on the App ID, or an old profile; step 4 of the push setup |
| No notifications arrive, `push_notifications` shows them failed | `FCM_SERVICE_ACCOUNT` missing or from another Firebase project; step 5 of the push setup |
| No token in `push_tokens` after signing in | The build has no `FIREBASE_*` variables, or notifications were not allowed on the phone |
| 403 "caller does not have permission" | Step 3 of the service account setup |
| iOS run warns "profile has no Associated Domains" | Step 1 of the app links setup |
| A scanned My QR code opens the browser, not the app | Verification file missing or wrong (check the URLs in step 6), a Play install without `ANDROID_APP_LINK_SHA256`, or an iOS build made before Associated Domains was on |
| *Cloudflare worker* run says "subdomain proxy was not deployed" | `CLOUDFLARE_API_TOKEN` secret missing; app links step 4 |
| Worker deploy fails on `/memberships` or "more than one account" | Set the `CLOUDFLARE_ACCOUNT_ID` variable (app links step 4) |
| Worker deploy fails with an authentication/permission error | The token lacks Workers Scripts → Edit (account) or Workers Routes → Edit (zone `getride.my`) |
| Worker run warns `*.getride.my` is DNS only | Cloudflare → DNS → the `*` record → Proxied (orange cloud); a route never fires for a grey record |
| Worker run warns `qr.getride.my` has its own DNS-only record | That record bypasses the worker. Delete it (or set it to Proxied) so the wildcard and worker serve `qr` |
| `qr.getride.my` answers 525 / 526 | The request reached Vercel without the worker: the `*` (or `qr`) record is grey, or the route is not attached. Re-run *Cloudflare worker*. A 526 means SSL mode Full (strict) met an invalid origin certificate: check `www.getride.my` itself |
| `qr.getride.my` does not resolve | No `*` record yet: run *Cloudflare worker* with the token set |
| `.well-known` file answers 404 through the worker | The web deploy skipped it (inputs missing, see its *App link files* step), or `SUBDOMAIN_PROXY_TARGET` names a host without it |
| Another subdomain (api, status…) now shows the web app | Its record is proxied (orange), so the `*.getride.my/*` route catches it too: add it to `SUBDOMAIN_PROXY_PASS_THROUGH` and re-run *Cloudflare worker*. Grey records are never affected |
| Web deploy warns about a domain's DNS | A domain in `deploy/domains.txt`: add the record the warning names, or set `CLOUDFLARE_API_TOKEN` (step 4). Never list `*.getride.my` subdomains there |
| Web deploy warns the Cloudflare CNAME is proxied | For a `deploy/domains.txt` domain: Cloudflare → DNS → the record → grey (DNS only) |
