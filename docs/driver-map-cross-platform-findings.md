# Driver map — cross-platform findings (iOS vs Android)

Status: **source analysis done; physical-device results NOT RUN.**

The diagnostic build was authored in an environment with **no Flutter SDK and no
physical devices**, so no device run, pixel measurement, screen recording or log
was produced here. The device matrix below is a template to be filled in from a
tester's exported logs + recordings (see
`docs/driver-map-diagnostics-ios-android.md`). Nothing in it is invented.

## Source analysis (current HEAD)

Traced `driverPositionStreamProvider` (Geolocator, `distanceFilter: 5`, mapped to
`LatLng`) → `PartnerScreen` → `DriverHomeMap.me` → `RideMap` → the native/flutter
dot, and the camera/gesture paths.

| # | Area | What the code does (HEAD) | Assessment |
|---|------|---------------------------|------------|
| 1 | Dot anchoring | Native base draws its own dot (`myLocationEnabled`); a flutter tile base draws a flutter_map `Marker` at `me`. `RideMap` suppresses the flutter dot when `nativeMe && native base`. | Anchored in both cases; **not** a screen overlay. `expectedDotRenderer`/`duplicateDot` encode this invariant and the overlay flags a violation. |
| 2 | Follow suspend | `_onPositionChanged(_, gesture)` calls `onGesture` only on real gestures; `_center` early-returns while `!_follow`; `_onHeading` no longer moves the camera. | GPS/compass cannot steal the camera while suspended. Covered by diagnostics (follow/gesture events). |
| 3 | Follow glide | `_glide` 600 ms; **fixed on the stabilization branch**: `_from = camera.center` (was `_to ?? camera.center`), so a mid-glide fix no longer snaps forward. | The pre-fix `_to ?? camera.center` was the most likely jitter/snap cause. Verify on device via `camera_sample` origins. |
| 4 | Heading | `compass.dart`: course-when-moving vs compass-when-stopped, 0/360 wrap, 3° threshold, shortest-angle. Drawn as a screen-fixed chevron over the dot; map stays north-up. | Wrap/threshold already handled. Confirm no spin at 359°→0° on device (scenario I). |
| 5 | Provider parity | `appleRouteBaseActive` / `googleNativeBaseActive` + `nativeMe` decide the single dot. | Exactly one dot by construction; the overlay's duplicate-dot check is the runtime guard. |
| 6 | Sheet offset | `_offset = (0, -sheetInset/2)`; camera target uses it; dot clear of the sheet. | Confirm no apparent "jump" when the sheet changes height (scenario G). |
| 7 | Pixel error | Flutter tile base: `camera.latLngToScreenOffset(me)` ≈ the marker (error ~0). Native base: SDK dot position not exposed → **N/A**. | Pixel error is only meaningful on the flutter base; native drift must be judged from the reference marker + recording. |

## Device matrix — TO BE FILLED BY TESTER (currently NOT RUN)

For each row: iPhone result, Android result, provider, timestamp/video ref, log
event ids, actual vs expected, source file/function, confidence, open questions.

| ID | Scenario | iPhone | Android | Provider | Video/log ref | Notes |
|----|----------|--------|---------|----------|---------------|-------|
| A | Stationary 60 s | NOT RUN | NOT RUN | | | |
| B | Pan | NOT RUN | NOT RUN | | | |
| C | Pinch zoom | NOT RUN | NOT RUN | | | |
| D | Rotate | NOT RUN | NOT RUN | | | |
| E | Follow OFF, GPS/compass | NOT RUN | NOT RUN | | | |
| F | Recenter | NOT RUN | NOT RUN | | | |
| G | Bottom sheet | NOT RUN | NOT RUN | | | |
| H | Street/satellite + provider | NOT RUN | NOT RUN | | | |
| I | Heading 359°→0° | NOT RUN | NOT RUN | | | |
| J | Background/resume, permission | NOT RUN | NOT RUN | | | |
| K | Walk / observed drive | NOT RUN | NOT RUN | | | |
| L | Screen rotate / scale | NOT RUN | NOT RUN | | | |

## Diagnosis categories to assign per observation

1. GPS sensor wander (input coordinate moving) vs fixed-reference stability.
2. Native/flutter projection mismatch (esp. zoom/rotation).
3. Camera-follow restart / stale animation origin / follow re-enabled.
4. Compass noise / wrong rotation sign / heading wraparound.
5. Duplicate or vanishing dot on provider change.
6. Bottom-sheet / viewport offset mistaken for location movement.
7. Correct geographic behavior that merely changes screen pixel position.

## Conditions to record before comparing iOS vs Android

Same stationary location, short time window, each device's location accuracy
mode, and whether Google Play services / the native Google map are available.
Sensor accuracy and native SDKs differ — do not claim results are directly
comparable without recording these.
