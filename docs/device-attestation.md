# Device attestation (Play Integrity / App Attest)

Status: **scaffold in place, inert.** The pieces below are committed but do
nothing until a native build + provider credentials exist. Nothing in the
current app flow depends on them, and they can never block a legitimate
sign-up while inactive.

## Why

The device-based duplicate-account guard (migrations `0071`/`0072`) relies on
`user_sessions.device_id`, which is **client-supplied**. A modified client can
forge a fresh `device_id` per sign-up. The server has no way to read a real
hardware id — iOS and Android both forbid it (this is also why IMEI is
inaccessible).

Attestation is the un-forgeable complement. It does **not** give a stable
cross-reinstall hardware id (neither platform exposes one), but it gives
Google-/Apple-signed proof that a request comes from a **genuine, unmodified
app on a genuine device**. That defeats the high-volume attack the plain
`device_id` can't: emulators and scripted/tampered clients mass-registering
accounts. A determined human with several real phones can still make several
accounts — no client-side technique changes that.

| Signal | Forgeable? | Stops reinstall abuse? | Stops emulator/bot farms? |
|---|---|---|---|
| `device_id` (0070) | Yes (client-set) | Partially (survives reinstall on real device) | No |
| Play Integrity / App Attest | No (platform-signed) | No | **Yes** |

Use them together: `device_id` links accounts on the same real device;
attestation ensures the device is real to begin with.

## What's committed

- `supabase/migrations/0073_device_attestation.sql` — `device_attestations`
  log table (admin-read; service-role write), applied to the DB. Inert on its
  own.
- `supabase/functions/attest-device/index.ts` — edge function that verifies a
  Play Integrity or App Attest token and records the verdict. The request
  plumbing is complete. **Play Integrity verification is implemented** (OAuth2
  service-account JWT → `decodeIntegrityToken` → device/app verdict checks) but
  **untested** — it needs a real token from a signed device to exercise. **App
  Attest is still stubbed** (returns `passed: false`) because a correct verifier
  needs CBOR + X.509-chain validation that must be built on a vetted library and
  tested on a real device, not hand-rolled blind. **Not deployed.**
- `expo/utils/attestation.ts` — client wrapper. `attestAndRecord()` is a no-op
  returning `{ available: false }` because there is no native attestation
  module in the Rork/Expo-Go build. `requestNativeAttestationToken()` is the
  single place to add the native call.

## Activation checklist

### 1. Native build
Play Integrity and App Attest need native code that Expo Go / the Rork managed
flow cannot run. Produce a custom **dev client / EAS build** first. Add a
native attestation module (e.g. a Play Integrity + App Attest package or a
small config-plugin/native module) and call it from
`requestNativeAttestationToken()`.

### 2. Android — Play Integrity
1. Enable the **Play Integrity API** in a Google Cloud project and link it to
   the app in **Play Console**.
2. Create a **service account** with access and download its JSON key.
3. Set Supabase secrets:
   ```
   supabase secrets set ANDROID_PACKAGE_NAME=com.getride.app
   supabase secrets set GOOGLE_SERVICE_ACCOUNT_JSON="$(cat sa.json)"
   ```
4. `verifyPlayIntegrity()` is already implemented (OAuth2 + `decodeIntegrityToken`
   + verdict checks). Deploy, send a real integrity token from a signed device,
   and confirm the `device_attestations` verdict looks right before trusting it.

### 3. iOS — App Attest
1. Add the **App Attest** entitlement to the app.
2. Note the Apple **Team ID** and **bundle id**; set secrets:
   ```
   supabase secrets set APPLE_APP_ATTEST_TEAM_ID=XXXXXXXXXX
   supabase secrets set APPLE_APP_ATTEST_BUNDLE_ID=com.getride.app
   ```
3. Implement `verifyAppAttest()` (CBOR decode + x5c chain to Apple's App Attest
   root + nonce/rpId checks — noted inline). The credential id becomes a strong
   per-install `attest_key_id`.

### 4. Deploy + wire
```
supabase functions deploy attest-device --no-verify-jwt
```
Call `attestAndRecord(userId)` from the sign-up flow (e.g. right after a
successful `registerUser` in `pin-setup.tsx`), best-effort — it already fails
open.

### 5. (Optional) Enforce
Once verdicts are trusted end-to-end on real devices, add a
`requireAttestation` flag to the `device_account_guard` config
(`utils/deviceGuard.ts` + `device_guard_config()`), and in `set_login_pin`
reject a new account whose device has no recent passing `device_attestations`
row — mirroring the existing `DEVICE_LIMIT` path. Roll this out **after**
confirming real devices reliably pass, or it will lock out legitimate users.

## Testing note
Attestation deliberately fails on emulators and unsigned builds, so it can only
be verified on a real, signed device. Keep enforcement (step 5) off until that
verification is done; logging (steps 1–4) is safe to enable first and lets you
watch pass/fail rates in `device_attestations` before you gate anything on it.
