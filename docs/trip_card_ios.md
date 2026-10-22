# Trip card on the iPhone (Live Activity)

The trip card shows a trip's progress on the lock screen and in the Dynamic
Island: finding a driver, the driver on the way (name, car, plate, minutes),
arrived, on the trip ("You will arrive at 4:05 PM", the car moving along the
bar to the drop pin), and done ("How was your ride?"). Buttons: Call, Chat,
Share trip, SOS (and Rate when done). Drivers get their own card.

Android has it already (a pinned notification, `TripCardNotifier.kt`). The
iPhone draws it in a small extra part of the app, the **TripCard Widget
Extension** (`com.taxxee.teksi.TripCard`, iOS 16.2+), which Apple signs
separately. On iOS below 16.2 the app's `getride/trip_card` channel answers
"no card" and nothing else changes.

| File | Target |
| --- | --- |
| `ios/TripCard/TripCardAttributes.swift` | both TripCard and Runner |
| `ios/TripCard/TripCardLiveActivity.swift`, `TripCardBundle.swift` | TripCard |
| `ios/TripCard/Info.plist`, `TripCard.entitlements` | TripCard (settings) |
| `ios/TripCard/Debug.xcconfig`, `Release.xcconfig` | TripCard's base configurations |
| `ios/Runner/TripCardActivities.swift` (`TripCardPlugin`) | Runner |

## What the owner does (Apple Developer, about 20 minutes)

The app's bundle id is `com.taxxee.teksi` (Team as in the
`APP_STORE_CONNECT_*` / `IOS_*` secrets).

1. **App Group** — Certificates, Identifiers & Profiles → Identifiers → `+` →
   App Groups → `group.com.taxxee.teksi`. (Live Activities don't strictly
   need it; it lets the card and the app share files later, e.g. the
   driver's photo, without another profile round.)
2. **App ID for the card** — Identifiers → `+` → App IDs → App → Explicit
   bundle id `com.taxxee.teksi.TripCard`, description "GET.ride Trip card".
   Capabilities: **App Groups** (pick `group.com.taxxee.teksi`). Nothing else.
3. **Main App ID** `com.taxxee.teksi` → Edit → tick **App Groups** and pick
   the same group. Push Notifications stays on. Save. (This invalidates the
   current profile: step 4 makes a new one.)
4. **Profiles** (Profiles → `+`):
   - App Store profile for `com.taxxee.teksi` again (same certificate) and
     replace the `IOS_PROVISIONING_PROFILE` secret with its base64
     (`base64 -i GET_ride.mobileprovision | pbcopy`).
   - App Store profile for `com.taxxee.teksi.TripCard`, same certificate.
     New repository secret `IOS_TRIPCARD_PROVISIONING_PROFILE` = its base64.
   - If you use Ad Hoc builds: the same two as Ad Hoc profiles;
     `IOS_ADHOC_PROVISIONING_PROFILE` (replace) and
     `IOS_TRIPCARD_ADHOC_PROVISIONING_PROFILE` (new).
5. **APNs key** (only for updates while the app is closed): the project
   already has one for ride calls. The Edge Function secrets
   `APNS_AUTH_KEY` (the .p8's text), `APNS_KEY_ID` and `APNS_TEAM_ID`
   (`supabase/functions/_shared/apns.ts`) serve Live Activity pushes too;
   no new key is needed. If they are not set yet: Keys → `+` → Apple Push
   Notifications service (APNs) → download the .p8 once, then
   `supabase secrets set APNS_AUTH_KEY="$(cat AuthKey_XXXX.p8)" APNS_KEY_ID=XXXX APNS_TEAM_ID=YYYY`.

All of the above is done (App Group, both App IDs, App Store profiles in
`IOS_PROVISIONING_PROFILE` and `IOS_TRIPCARD_PROVISIONING_PROFILE`; the Ad Hoc
pair `IOS_ADHOC_PROVISIONING_PROFILE` / `IOS_TRIPCARD_ADHOC_PROVISIONING_PROFILE`
if Ad Hoc builds are wanted).

## What is in the repo

1. **Xcode target** `TripCard` in `ios/Runner.xcodeproj` (product type
   app-extension, `TripCard.appex`): bundle id `com.taxxee.teksi.TripCard`,
   iOS 16.2, Swift 5, `INFOPLIST_FILE = TripCard/Info.plist`,
   `CODE_SIGN_ENTITLEMENTS = TripCard/TripCard.entitlements`,
   `SKIP_INSTALL = YES`, `APPLICATION_EXTENSION_API_ONLY = YES`, links
   WidgetKit and SwiftUI. Its base configurations `ios/TripCard/*.xcconfig`
   include Flutter's `Generated.xcconfig`, so the card's version and build
   number are always the app's (App Store Connect refuses a mismatch).
   Runner depends on it and copies it in an **Embed Foundation Extensions**
   phase placed right after "Embed Frameworks" and before "Thin Binary"
   (later than "Thin Binary" Xcode reports "Cycle inside Runner"). The
   Runner target stays at iOS 15.0 and links ActivityKit *optional* (weak),
   so iPhones on 15.x still start the app.
   The app's Swift packages (Flutter's generated plugin package) stay on
   Runner only; there is no Podfile.
2. **Runner** — `Runner.entitlements` has the App Group
   `group.com.taxxee.teksi` beside push and Associated Domains; `Info.plist`
   has `NSSupportsLiveActivities` and `NSSupportsLiveActivitiesFrequentUpdates`;
   `AppDelegate.swift` registers `TripCardPlugin`, whose calls answer false
   below iOS 16.2. The old stub plugin is gone.
3. **`.github/workflows/ios-release.yml`**
   - stops with an error when `IOS_TRIPCARD_PROVISIONING_PROFILE` is
     missing, when it is not for `<team>.com.taxxee.teksi.TripCard`, or when
     either App Store profile lacks the App Group; exports `TRIPCARD_UUID`;
   - appends the extension's manual signing (team, `TRIPCARD_UUID`, Apple
     Distribution) to `ios/TripCard/Release.xcconfig`, as it does for Runner
     in `ios/Flutter/Release.xcconfig`;
   - `export.plist` maps `com.taxxee.teksi.TripCard` to `TRIPCARD_UUID`;
   - Ad Hoc: needs both Ad Hoc profiles (with the App Group). If the app's is
     there but the card's is missing or wrong, the Ad Hoc IPA is skipped with
     a warning and the App Store IPA is published instead; the release goes
     on;
   - the Associated Domains step still edits Runner's entitlements only.
   The CI build (`flutter build ios --release --no-codesign` in
   `flutter.yml`) builds the extension unsigned.

### Still to do

- **A first signed build.** No Xcode here: the project file was written by
  hand and checked with two parsers, but only a real build proves it. Run
  `gh workflow run ios-release.yml -R getgroupmy/get-ride --ref <branch> -f lane=testflight -f notes="trip card iOS"`
  (it also uploads to App Store Connect and republishes `ios-latest`).
- **Updates while the app is closed** (optional): `TripCardActivities`
  already hands each activity's push token to the app (`pushToken` on the
  channel). A small migration stores it (`trip_card_tokens`: ride id,
  profile id, token, platform), and the Edge Function `trip-card-push`
  (migration 0274, already sending Android's FCM data message
  `{type: "trip_card", ride_id, card: "<json>"}` built by
  `_shared/trip_card.ts`) also sends `apns-push-type: liveactivity`, topic
  `com.taxxee.teksi.push-type.liveactivity`, body
  `{"aps":{"timestamp":…,"event":"update"|"end","content-state":{…}}}` where
  `content-state` has the keys of `TripCardAttributes.ContentState`. The
  APNs secrets (`APNS_AUTH_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
  `supabase/functions/_shared/apns.ts`) serve it; no new key is needed.

## How to test on an iPhone

1. iPhone on iOS 16.2 or later (Dynamic Island: iPhone 14 Pro or later;
   other models show the lock-screen card only). Settings → GET.ride → Live
   Activities on (it is on by default).
2. Install the TestFlight build (or the Ad Hoc IPA from Admin → App
   Release on a registered phone).
3. Book a ride (or take one as a driver) with Admin → Display Settings →
   Trip card on for that service. Lock the phone: the card shows "Finding a
   driver", then the driver on the way with car and plate, arrived, on the
   trip with the car moving along the bar, and done ("How was your ride?").
4. Tap Call / Chat / Share trip / SOS on the card: the app opens on the trip
   and runs that button. Tap the card itself: the trip opens.
5. Cancel a ride: the card goes at once. Finish one: the done card stays the
   admin's minutes.
6. On iOS 15 the app runs as before, with no card.
7. If nothing shows: Xcode → Devices → the phone's console, filter
   `[trip card]` from the app's log (`start: false` means Live Activities are
   off or the request was refused).

## How it behaves

- Started by the app when a trip is found (`lib/src/data/trip_card_controller.dart`),
  updated on each new stage at once and within a stage at most every 15 s,
  ended on cancel; the done card stays Admin → Display Settings → Trip card's
  minutes (default 5, 0 = clears at once).
- While the app is closed (Android), the server moves the card: at once on a
  new status, and with the driver's position at most every 30 s per ride
  (migration 0274, Edge Function `trip-card-push`). The minutes there are
  counted in a straight line (the server has no road route).
- Admin → Display Settings → Trip card switches it per service (Ride, Courier,
  Freight) and for drivers. Colours: App Page Settings, "Trip card · Preview".
- A courier delivery code and the trip code are never on the card.
- The buttons open `getride://trip/<ride>?do=call|chat|share|sos|cancel`
  (`&as=driver` on a driver's card); the router opens the trip and runs the
  same button there (`tripCardLinkLocation`).
