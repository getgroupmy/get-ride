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
   Relying Party ID **`www.getride.my`** (never change it once passkeys are
   saved: every one is bound to it), Display Name `get.ride`, Relying Party
   Origins: `https://www.getride.my`, plus the two `android:apk-key-hash:…`
   origins (below). Not the bare `getride.my`: it redirects to `www`, and
   Apple and Android refuse an association file behind a redirect.
2. **Android**: `assetlinks.json` (written by `scripts/ci/app_links.ts` on
   every web deploy) carries `get_login_creds` and both signing keys. The
   deploy's job summary prints the two `android:apk-key-hash:…` origins to
   add in step 1. If it says the upload key only, set
   `ANDROID_APP_LINK_SHA256` to the Play App Signing key (Play Console →
   App integrity → App signing).
3. **iOS**: `Runner.entitlements` has `webcredentials:www.getride.my`; the App
   ID `com.taxxee.teksi` has Associated Domains, and the App Store
   provisioning profile must be generated after that was enabled.
   `apple-app-site-association` carries `webcredentials`.
4. Both files must be served by `https://www.getride.my/.well-known/…`
   itself (the relying party's host), as `application/json`, with no redirect.

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

### More devices for chosen accounts (0298)

Admin → Users → an account → Devices sets how many devices it may use at
once (1 to 10, with a reason only admins see); App Settings → Sign-in
security lists those accounts and finds one to add. A new sign-in past the
allowance signs out the device that signed in longest ago, and that phone
is told the allowance. Such an account's devices are kept in
`account_devices` instead of `active_sessions` (phones from before 0298
watch that row and would sign out at every new sign-in), so a phone pushed
out learns it from its next request or its check on resume, not at once.
