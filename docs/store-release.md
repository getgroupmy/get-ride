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
   email with **Release** access to this app.

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

* **The domain.** `deploy/domains.txt` lists the domains the web project must
  serve. Every production web deploy adds any that are missing to the Vercel
  project and, if the zone is on Vercel DNS, creates the CNAME. If DNS is
  elsewhere, the deploy's summary has a warning with the exact record to add
  (`qr CNAME cname.vercel-dns.com`, or what Vercel recommends). To serve a new
  subdomain, add a line there; nothing is ever removed.
* **The verification files**, written at every web deploy and served on
  every domain of the project:
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
4. **DNS**, only if the deploy warned about it: add the record it names at
   the DNS provider of `getride.my`.

After the next push to `main` (web deploy), check:

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
| Web deploy warns about `qr.getride.my` DNS | Add the record the warning names at the DNS provider |
