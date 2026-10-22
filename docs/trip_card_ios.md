# Trip card on the iPhone (Live Activity)

The trip card shows a trip's progress on the lock screen and in the Dynamic
Island: finding a driver, the driver on the way (name, car, plate, minutes),
arrived, on the trip ("You will arrive at 4:05 PM", the car moving along the
bar to the drop pin), and done ("How was your ride?"). Buttons: Call, Chat,
Share trip, SOS (and Rate when done). Drivers get their own card.

Android has it already (a pinned notification, `TripCardNotifier.kt`). The
iPhone needs a small extra part of the app, a **Widget Extension**, which
Apple signs separately. Until it exists the app's `getride/trip_card` channel
answers "no card" (`TripCardStubPlugin` in `ios/Runner/AppDelegate.swift`)
and nothing else changes.

The code is written and waiting in `ios/TripCard/` (not in the Xcode project,
so today's builds are unaffected):

| File | Goes into |
| --- | --- |
| `TripCardAttributes.swift` | both the TripCard extension and Runner |
| `TripCardLiveActivity.swift`, `TripCardBundle.swift` | TripCard extension |
| `Info.plist`, `TripCard.entitlements` | TripCard extension |
| `Runner/TripCardActivities.swift` | Runner (replaces `TripCardStubPlugin`) |

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

Then tell Claude "the trip card profiles are in" and the changes below are made.

## What changes in the repo once they exist

1. **Xcode target** — a Widget Extension target `TripCard` (Live Activity),
   bundle id `com.taxxee.teksi.TripCard`, iOS 16.2+, Swift 5, embedded in
   Runner ("Embed Foundation Extensions"), with the files in the table above,
   `CODE_SIGN_ENTITLEMENTS = TripCard/TripCard.entitlements`,
   `INFOPLIST_FILE = TripCard/Info.plist`. `TripCardAttributes.swift` and
   `Runner/TripCardActivities.swift` join the Runner target.
2. **Runner** — `Runner.entitlements` gets the same App Group;
   `Info.plist` gets `NSSupportsLiveActivities = YES` and
   `NSSupportsLiveActivitiesFrequentUpdates = YES`; `AppDelegate.swift`
   registers `TripCardPlugin` in place of `TripCardStubPlugin` (and the stub
   is deleted).
3. **`.github/workflows/ios-release.yml`**
   - install `IOS_TRIPCARD_PROVISIONING_PROFILE` beside the app's profile,
     check it names `com.taxxee.teksi.TripCard`, export `TRIPCARD_UUID`;
   - the build-only xcconfig lines (today appended to
     `ios/Flutter/Release.xcconfig`, Runner only) get a TripCard twin,
     `ios/TripCard/Release.xcconfig`, with
     `PROVISIONING_PROFILE_SPECIFIER = $TRIPCARD_UUID` and the same team and
     identity, set as the TripCard target's base configuration;
   - `export.plist`'s `provisioningProfiles` gets
     `com.taxxee.teksi.TripCard` → `$TRIPCARD_UUID` (and the Ad Hoc one
     its Ad Hoc UUID);
   - the Associated Domains check stays Runner-only.
4. **Updates while the app is closed** (optional, after 1–3 work):
   `TripCardActivities` already hands each activity's push token to the app
   (`pushToken` on the channel). A small migration stores it
   (`trip_card_tokens`: ride id, profile id, token, platform), and a trigger
   on `ride_requests` (status change, and the driver's live position at most
   every 30 s) calls an Edge Function that sends
   `apns-push-type: liveactivity`, topic
   `com.taxxee.teksi.push-type.liveactivity`, body
   `{"aps":{"timestamp":…,"event":"update"|"end","content-state":{…}}}` where
   `content-state` has the keys of `TripCardAttributes.ContentState`. The
   same trigger sends Android an FCM data message
   `{type: "trip_card", ride_id, card: "<json>"}` or `{…, end: "1"}`
   (`TripCardPushReceiver.kt`).

## How it behaves

- Started by the app when a trip is found (`lib/src/data/trip_card_controller.dart`),
  updated on each new stage at once and within a stage at most every 15 s,
  ended on cancel; the done card stays Admin → Display Settings → Trip card's
  minutes (default 5, 0 = clears at once).
- Admin → Display Settings → Trip card switches it per service (Ride, Courier,
  Freight) and for drivers. Colours: App Page Settings, "Trip card · Preview".
- A courier delivery code and the trip code are never on the card.
- The buttons open `getride://trip/<ride>?do=call|chat|share|sos|cancel`
  (`&as=driver` on a driver's card); the router opens the trip and runs the
  same button there (`tripCardLinkLocation`).
