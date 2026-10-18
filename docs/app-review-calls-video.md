# App Review video: in-app calls (foreground and background)

Apple asks for a screen recording from a **physical iPhone running the build
under review**. It has to show the real system behaviour (CallKit's incoming
call screen on the Lock Screen, the green call pill while the app is in the
background), which only a device produces. This page is the shot list and the
review notes to record and submit it in one take.

## What the app does (for the review notes)

- Rider ↔ driver calls during a ride, and user ↔ support agent calls, are
  WebRTC audio calls (`flutter_webrtc`) inside GET.ride. No phone number is
  shared.
- Incoming calls arrive by **VoIP push (PushKit)** and are reported to
  **CallKit** at once (`ios/Runner/AppDelegate.swift`,
  `pushRegistry(_:didReceiveIncomingPushWith:)` →
  `flutter_callkit_incoming`), so they ring when the app is in the
  background, closed, or the phone is locked.
- Background modes used and why: `voip` (incoming calls), `audio` (keeps the
  call's audio running when the user leaves the app), `remote-notification`,
  `location` (live trip tracking, unrelated to calls).
- Microphone permission is asked the first time a call is placed or answered.

## Setup (before recording)

1. Two iPhones with the **TestFlight build that is being submitted**:
   phone A = rider account, phone B = driver account (approved, online).
   A support-agent account can replace B for the support-call path.
2. On phone A: Settings → Control Centre → add **Screen Recording**; turn on
   the microphone in the recording's long-press menu so the call audio is
   heard. Do Not Disturb off, ringer on, volume up.
3. Book a ride on A and accept it on B, so the two are on an active ride
   (calls are only offered during a ride).
4. Notifications allowed on both phones; microphone permission not yet
   granted on A, so the permission prompt is shown once in the video.

## Shot list (one continuous recording on phone A, about 2 minutes)

| # | Time | Action | Must be visible |
| --- | --- | --- | --- |
| 1 | 0:00 | Start recording on the Home Screen, open GET.ride | App launching, signed in |
| 2 | 0:05 | Open the active ride ("Driver on the way") | Driver card with **Call** |
| 3 | 0:10 | Tap **Call** | Microphone permission prompt → Allow; call screen "Calling…" |
| 4 | 0:20 | B answers | Call connected, timer running; speak both ways; toggle **Mute** and **Speaker** |
| 5 | 0:40 | Swipe up to the Home Screen with the call live | **Green call pill / Dynamic Island** shows the call continuing; audio still heard |
| 6 | 0:50 | Tap the green pill | Returns to GET.ride's call screen, same call |
| 7 | 1:00 | Hang up | Call ends, back to the ride |
| 8 | 1:05 | Swipe up to leave GET.ride in the background; then **lock** phone A | Lock Screen |
| 9 | 1:15 | From B, tap **Call** on the rider card | A rings on the **Lock Screen** with the CallKit screen ("GET.ride Audio") |
| 10 | 1:20 | Slide to answer on A | Call connects without opening the app first; audio both ways |
| 11 | 1:35 | Unlock / open the app from the call screen | GET.ride shows the live call |
| 12 | 1:45 | Hang up; force-quit GET.ride from the app switcher | App fully closed |
| 13 | 1:55 | Call A again from B | A rings via CallKit with the app **closed**; answer, then hang up |
| 14 | 2:10 | Stop recording | |

Lock-screen moments (9–10, 13) are not captured by the iPhone's own screen
recorder. Film those with a second camera pointed at phone A, or connect A to
a Mac and record with QuickTime (File → New Movie Recording → choose the
iPhone), which does capture the Lock Screen.

## App Review notes (paste into App Store Connect)

> GET.ride lets a rider and their driver, and a user and our support team,
> talk through an in-app audio call without sharing phone numbers. Calls use
> WebRTC. Incoming calls are delivered by PushKit VoIP pushes and reported to
> CallKit immediately, so the call rings when the app is in the background,
> closed or the phone is locked. The `audio` background mode keeps a call's
> audio running when the user switches to another app.
>
> To test: sign in with the rider demo account on one device and the driver
> demo account on another, book a ride from the rider account and accept it
> from the driver account, then tap Call on either side. The attached video
> shows a call placed and answered in the foreground, continuing in the
> background, and an incoming call ringing on the Lock Screen and with the
> app closed.
>
> Demo accounts: rider `<phone / PIN>`, driver `<phone / PIN>`.

## Checks before submitting

- `aps-environment` in `ios/Runner/Runner.entitlements` is `development` in
  the repo; the App Store / TestFlight export must sign with production
  push (the release workflow's provisioning profile decides this). VoIP
  pushes from the backend must go to the **production** APNs host for the
  TestFlight build, or step 9 will not ring.
- Every VoIP push must be reported to CallKit; iOS stops delivering VoIP
  pushes to an app that skips it, and review rejects it.
- Demo accounts must be able to complete a ride without real payment.
