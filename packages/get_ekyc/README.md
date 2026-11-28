# get_ekyc: GET eKYC for Flutter (iOS and Android)

Three ways to run a verification. Your **server** always creates it (with the
API key) and gives the app only the one-time `hosted_url`; the decision always
reaches your server by the signed webhook.

| Mode | Where it runs | Updates |
|---|---|---|
| `EkycMode.native` | Native screens in the app: document camera, selfie, head turns captured automatically with on-device face tracking | Wording, steps and checks come from the server; new screens come with SDK updates |
| `EkycMode.webView` | GET eKYC's hosted page inside the app (never the external browser) | Everything changes on the server at once, no app update |
| `GetEkyc.openInBrowser` | The phone's browser, back to the app through your `redirect_url` link | Same as webView |

```dart
import 'package:get_ekyc/get_ekyc.dart';

// 1. Ask YOUR server to start a check; it returns hosted_url (never the API key).
final url = await myServer.startIdentityCheck();

// 2a. In the app, native screens
final r = await GetEkyc.start(context, hostedUrl: url, language: 'ms');
// 2b. or the hosted page inside the app
final r = await GetEkyc.start(context, hostedUrl: url, mode: EkycMode.webView);

// 3. r.outcome: approved / review / rejected / submitted / cancelled / expired / invalid / error.
//    Use it to pick the next screen, then refresh the user from your server.
```

Browser and back (for web apps, or when you prefer it):

```dart
await GetEkyc.openInBrowser(url); // the server's redirect_url is e.g. getride://ekyc-done
// in your app-link handler:
final r = EkycResult.fromReturnUri(uri); // null if the link is not a GET eKYC return
```

## Add it to the app

```yaml
dependencies:
  get_ekyc:
    git:
      url: https://github.com/getgroupmy/get.ekyc
      path: sdk/flutter/get_ekyc
      ref: main   # or a tag, to update on your schedule
```

(If the app's build machine cannot read this repository, copy `sdk/flutter/get_ekyc`
into the app's `packages/` folder and use `path: packages/get_ekyc`.)

**iOS** (`ios/Runner/Info.plist`): `NSCameraUsageDescription`, e.g. "To photograph
your ID and take a selfie for identity verification." ML Kit needs iOS 15.5 or later
(`platform :ios, '15.5'` in the Podfile).

**Android**: `<uses-permission android:name="android.permission.CAMERA"/>` and
`minSdkVersion 21` or later.

**Passport chip (NFC, optional)**: on a phone with NFC the hosted page offers "Read
the chip" for an ePassport or an ID card with machine-readable lines (not MyKad: its
chip is not to the ICAO standard). The SDK opens the chip with BAC from the printed
MRZ and sends EF.SOD, DG1 and DG2 to get.ekyc, which checks them; the person can
always skip it.

- iOS: in `ios/Runner/Info.plist`, `NFCReaderUsageDescription` (e.g. "To read the chip
  in your passport for identity verification") and
  `com.apple.developer.nfc.readersession.iso7816.select-identifiers` = `[A0000002471001]`;
  the app's entitlements need `com.apple.developer.nfc.readersession.formats` = `[TAG]`,
  and the app ID needs the NFC Tag Reading capability in the Apple developer account.
- Android: nothing more (the NFC permission comes with `flutter_nfc_kit`).
- Phones without NFC, or with it switched off, never see the step.

Both are already in GET-Ride.

## Notes

- Head turns: the SDK asks for a turn to one side and then the other, and takes the
  photo itself once the pose is held. If tracking cannot see the face for 10 seconds,
  a manual shutter appears.
- Languages: `'en'` and `'ms'`. The consent notice text comes from the server.
- The app never holds the API key; the link opens one verification only, for 60 minutes.
- Tests: `flutter test` (API client, results, pose logic, the chip's BAC and secure
  messaging against ICAO 9303's worked example).
