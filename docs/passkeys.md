# Passkeys and one device per account

Both ship **off**. Admin → App Settings → **Sign-in security** turns them on.

## Passkeys

Sign in with face, fingerprint or screen lock instead of number + PIN.
GoTrue (Supabase Auth) does the WebAuthn checks and starts the session;
the app code is `lib/src/features/auth/passkey/` (ported from iAkauntan).

A passkey is saved after signing in once with number + PIN: the app offers
it once after sign-in, and Settings → Passkeys saves, lists and removes them.

### Before turning a surface on

1. **Supabase → Authentication → Configuration → Passkeys** (beta): on,
   Relying Party ID **`getride.my`** (never change it: every saved passkey
   is bound to it), Display Name `get.ride`, Relying Party Origins:
   `https://getride.my,https://www.getride.my,https://qr.getride.my`,
   plus the two `android:apk-key-hash:…` origins (below).
2. **Android**: `assetlinks.json` (written by `scripts/ci/app_links.ts` on
   every web deploy) carries `get_login_creds` and both signing keys. The
   deploy's job summary prints the two `android:apk-key-hash:…` origins to
   add in step 1. If it says the upload key only, set
   `ANDROID_APP_LINK_SHA256` to the Play App Signing key (Play Console →
   App integrity → App signing).
3. **iOS**: `Runner.entitlements` has `webcredentials:getride.my`; the App
   ID `com.taxxee.teksi` has Associated Domains, and the App Store
   provisioning profile must be generated after that was enabled.
   `apple-app-site-association` carries `webcredentials`.
4. Both files must be served by `https://getride.my/.well-known/…` itself
   (the relying party is the apex), as `application/json`, with no redirect.

Then: website switch, Android switch, iOS switch, each when its surface is
ready. A surface whose files are missing shows "This app is not set up for
passkeys on this system yet" rather than a button that does nothing.

The plugin's own web half (`passkeys_web`) is replaced by a no-op in
`packages/passkeys_web` (see `dependency_overrides` in `pubspec.yaml`): the
real one calls a JS global while plugins register and blanks every page.
The web app uses the browser's WebAuthn (`passkey_web.dart`).

## One device per account

Accounts that are not in `admin_access` (admins and sub-admins) may be
signed in on one device at a time; the newest sign-in wins (migration 0180).

* Every sign-in (PIN, SMS code, passkey) calls `claim_session`, which
  records the session and deletes the account's other Auth sessions.
* PostgREST's pre-request hook `request_guard` refuses every API call from
  any other session with `signed_in_elsewhere` (401), so the old device
  can't use its last token either. A new session gets two minutes to claim.
* The old device notices at once (its `active_sessions` row changes),
  on resume and every 3 minutes, signs out and says why.
* Admin → Users → an account shows its device and **Sign out all devices**.

Turn it on only once App updates' minimum is 1.4.8 or later: older builds
are not told why they stopped working.
