# Driver map diagnostics (iOS + Android)

A **debug-only, opt-in** instrumentation mode for the driver home map
(`lib/src/features/partner/driver_home_map.dart`). It helps a tester tell apart,
on a physical phone, the three things that look like "the blue dot drifting":

1. **GPS sensor wander** — the input coordinate itself moving.
2. **Projection / renderer mismatch** — the dot not sitting where its coordinate
   projects (native-base vs flutter overlay).
3. **Expected screen motion** — a correctly anchored dot moving across the screen
   because the map was panned.

It never ships in release, is off by default in debug, logs only locally, and
redacts coordinates unless the tester explicitly consents.

## What it is / is not

- **Is:** an on-screen overlay, a bounded in-memory event log, a fixed
  geographic reference marker, and a user-initiated JSONL/CSV export to the OS
  share sheet.
- **Is not:** any change to production ride logic, dispatch, pricing, auth,
  passenger maps, permissions, or GPS polling. No network/Supabase upload of any
  kind. No background location.

## Turning it on

Gated by `driverMapDiagnosticsEnabled` = `kDebugMode && DRIVER_MAP_DIAGNOSTICS`.
A release build compiles it out.

```bash
cd /path/to/get-ride            # the Flutter app root

flutter devices                 # find your physical device id

# iOS (physical iPhone, precise location granted for the GPS scenarios)
flutter run -d <IOS_DEVICE_ID> --debug --dart-define=DRIVER_MAP_DIAGNOSTICS=true

# Android (physical phone, USB debugging on)
flutter run -d <ANDROID_DEVICE_ID> --debug --dart-define=DRIVER_MAP_DIAGNOSTICS=true
```

Optional: `--dart-define=APP_SHA=$(git rev-parse --short HEAD)` stamps the commit
onto every exported row (otherwise the app version+build is used).

Open the partner home map (go online as a TEKSI/e-hailing partner). A small
`DIAG …` pill appears top-left. Tap it to expand the panel.

## The overlay

Collapsed pill: `DIAG <provider> <⟳ following | • free> #<event count>` (plus `‼`
if a duplicate dot is detected). Tap to expand; `▾` to collapse. It occupies only
its own corner box, so it never swallows the map's pan/zoom gestures.

Expanded panel shows, live:

- platform / OS / device / build SHA
- provider (`apple_native` / `google_native` / `flutter_tiles`) + satellite
- map ready, follow, gesture, animation-active
- **dot renderer** and a **‼ DUPLICATE DOT** banner if both a native and a
  flutter dot are ever visible at once
- GPS age / accuracy / speed / course, compass heading
- camera zoom / rotation, bottom-sheet inset
- **err px** — pixel error on a flutter tile base; **N/A** on a native base
  (the SDK does not expose its system dot's screen position)
- reference-marker lock state, event count, last event
- coordinates — **only** when "exact coords" consent is on

Buttons: `clear`, `JSONL`, `CSV`, `lock ref` / `clear ref`, and the
`exact coords` consent switch.

## Privacy / redaction

- Coordinates (`gps_lat/lng`, `camera_lat/lng`) are **null in every export by
  default**. They are included only when the tester turns on the **exact coords**
  consent switch, which carries an on-screen warning.
- Pixel offsets and errors are **not** locations and are always kept.
- Never logged at all: user ids, tokens, passenger details, trip ids, addresses,
  auth headers.
- Export is **local only** (share sheet / download). Nothing is sent to a server
  or Supabase, ever, and no automatic upload exists.

## The fixed reference marker

`lock ref` drops a magenta crosshair at the current fix; `clear ref` removes it.
It stays on that **geographic** point through pan/zoom/rotation even if live GPS
wanders — so if the blue dot moves but the crosshair stays glued to the same
road feature, that was GPS wander, not projection drift. (Drawn as a flutter_map
marker; on a native base it shares a flutter overlay's projection, which is
itself the thing under test.)

## Event schema (export)

JSONL = one JSON object per line; CSV = `driverMapCsvColumns` header + one row
per event (`schema_version: 1`). Fields: `timestamp_utc`, `elapsed_ms`
(monotonic, for aligning with a screen recording), `platform`, `os_version`,
`device_model`, `app_sha`, `provider`, `event`
(`gps_fix|heading|gesture_start|gesture_end|camera_sample|camera_move_requested|
recenter_tap|follow_changed|provider_changed|map_ready|lifecycle|export`),
`follow`, `gesture`, `animation_active`, `gps_age_ms`, `gps_accuracy_m`,
`speed_mps`, `gps_lat`, `gps_lng`, `camera_lat`, `camera_lng`, `zoom`,
`rotation_deg`, `heading_deg`, `sheet_inset_px`, `dot_renderer`,
`expected_dot_px`, `measured_dot_px`, `error_px`, `notes`. Camera movement is
sampled at ~10 Hz (never per frame); transitions are logged in full. The buffer
holds the most recent ~800 events.

### Sample sanitized JSONL line

```json
{"schema_version":1,"timestamp_utc":"2026-01-01T00:00:00.000Z","elapsed_ms":1234,"platform":"ios","os_version":"iOS 18.1","device_model":"iPhone15,2","app_sha":"abc1234","provider":"google_native","event":"gps_fix","follow":true,"gesture":null,"animation_active":null,"gps_age_ms":null,"gps_accuracy_m":8.2,"speed_mps":0.0,"gps_lat":null,"gps_lng":null,"camera_lat":null,"camera_lng":null,"zoom":17.0,"rotation_deg":null,"heading_deg":null,"sheet_inset_px":null,"dot_renderer":"native","expected_dot_px":null,"measured_dot_px":null,"error_px":null,"notes":null}
```

## Scenario checklist (per device; see the findings doc for the full matrix)

Reset the log (`clear`), show the overlay and device clock, start a screen
recording, run the steps, then `JSONL`/`CSV` export and share to yourself.

A. Stationary 60 s, hands off — dot near real location, no unexpected camera snaps.
B. Pan around — follow OFF, dot moves on screen but stays geographically anchored.
C. Pinch 18→14→18 — live dot and reference stay on their correct geographic points.
D. Rotate two-finger — correct anchor, follow not re-enabled.
E. Follow OFF, wait for GPS/compass — camera stays put.
F. Recenter after pan/zoom — follow ON, returns to driver, zoom preserved.
G. Expand/collapse sheet — no false drift, controls reachable.
H. Switch street/satellite + provider — exactly one dot, no flicker.
I. Rotate device, heading 359°→0° — no uncontrolled spin.
J. Background/resume, deny/regrant location — no crash, recovers.
K. Walk / passenger-observed drive — smooth follow, no repeated snapping.
L. Rotate screen / display scale — marker anchored, controls reachable.

## Submitting results

For each scenario, attach the screen recording **and** the exported log
(JSONL or CSV), and note device, OS, provider, and app SHA (all are in the log
header fields). Keep "exact coords" **off** unless precise-location sharing is
intended. See `docs/driver-map-cross-platform-findings.md` for the comparison
table to fill in.
