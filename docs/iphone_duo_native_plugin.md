# iPhone Duo fold bridge — native plugin (iOS)

The Flutter side of the fold is done and tested (`lib/src/core/window_class.dart`,
`lib/src/core/duo_fold.dart`, `lib/src/widgets/duo_fold_scope.dart`). It reads the
fold from `MediaQuery.displayFeatures` and lays the UI out around it.

- **Android** (Galaxy Fold / Flip, Pixel Fold, Surface Duo): nothing to do. Flutter
  already fills `MediaQuery.displayFeatures` from Jetpack WindowManager, so the fold
  flows straight into `window_class.dart`. (The `dual_screen` package reads the exact
  same `displayFeatures`.)
- **iOS (iPhone Duo)**: Flutter does **not** surface the crease, so this small plugin
  reads it natively and streams it to Dart over the `get_ride/duo_fold` `EventChannel`.
  `DuoFoldScope` turns each message into a `DisplayFeature` and injects it into
  `MediaQuery`, so every screen sees the Duo fold through the same path as Android.

> **Status: written from reference code, NOT compiled here.** This repo's CI is Linux;
> there is no Xcode. Build and verify this on **Xcode 27.1 + the iPhone Duo simulator**.
> The API names (`UIHingeInteraction`, `UIView.reservedRegions(kind:options:)`,
> `ReservedRegion`, `verticalBarEdge`) are taken from Apple's HIG and the community
> samples (pvinis/duo-demo, openHacking/DuoKit, Codelaby/IphoneDuo) — confirm each
> against the installed SDK before shipping; do not assume a signature that does not
> compile.

## This plugin is a stopgap — Flutter is adding it to the engine

[flutter/flutter#193025](https://github.com/flutter/flutter/pull/193025) ("[iOS] Populate
display features from the iPhone Duo hinge and reserved regions") teaches the iOS embedder
to fill `MediaQuery.displayFeatures` itself — a `FlutterDisplayFeaturesMonitor` that installs
`UIHingeInteraction`, re-reads `reservedRegions` on every hinge update and layout pass, and
reports them into the viewport metrics. It was **open against `flutter:master`** at the time
of writing (gated on Flutter CI moving to Xcode 27.1), not in any stable release this app uses.

So: **ship this plugin only until the app's Flutter includes #193025.** Once it does,
`displayFeatures` fills on iOS with no plugin, and `mergeFoldFeatures` already drops this
plugin's synthesized feature in favour of the engine's (so leaving the plugin in during the
overlap is harmless, not doubled). The whole thing can then be deleted.

Its mapping, confirmed to match ours: the division becomes **`DisplayFeatureType.fold`** (not
hinge — the inner panel is continuous), reported **only while the hinge is partially open**, as
a **zero-width `postureHalfOpened`** feature decided by hinge status + `isActive`; occlusion
becomes a `cutout`; bounds are **logical points**, scaled by the device pixel ratio.

## Channel contract (what Dart expects)

`EventChannel('get_ride/duo_fold')` streams a map; `duoFoldFromNative` parses it:

| key | type | meaning |
| --- | --- | --- |
| `hinge` | `String` | `closed` / `partiallyOpen` / `fullyOpen` / `unknown` / `none` |
| `angle` | `double?` | fold angle in degrees |
| `division` | `{x,y,w,h}?` | crease rect, **logical points** (= Flutter logical px) |
| `divisionActive` | `bool` | the crease is dividing the window now |
| `occlusions` | `[{x,y,w,h}]` | camera cut-outs |

Send rects in **points** (UIKit points == Flutter logical pixels), window-relative.
Only an **active** division is treated as a separating fold.

## Swift (reference — adapt to the real SDK, then compile)

Add `ios/Runner/DuoFoldPlugin.swift` to the Runner target and register it in
`AppDelegate.didFinishLaunchingWithOptions`:

```swift
// let controller = window?.rootViewController as! FlutterViewController
// DuoFoldPlugin.register(with: controller)
```

```swift
import Flutter
import UIKit

/// Streams the iPhone Duo fold to Dart over `get_ride/duo_fold`, mirroring
/// pvinis/duo-demo's WindowProbe: UIHingeInteraction for the pose, and
/// UIView.reservedRegions(kind:) for the crease and camera cut-outs.
final class DuoFoldPlugin: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private weak var host: UIView?
    private var hinge: UIHinge?

    static func register(with controller: FlutterViewController) {
        let plugin = DuoFoldPlugin()
        plugin.host = controller.view
        FlutterEventChannel(name: "get_ride/duo_fold", binaryMessenger: controller.binaryMessenger)
            .setStreamHandler(plugin)

        // Live hinge updates; reserved regions are re-read on each change.
        let interaction = UIHingeInteraction { [weak plugin] _, update in
            plugin?.hinge = update.hinge
            plugin?.emit()
        }
        controller.view.addInteraction(interaction)
    }

    func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        sink = eventSink; emit(); return nil
    }
    func onCancel(withArguments _: Any?) -> FlutterError? { sink = nil; return nil }

    private func emit() {
        guard let sink, let view = host, let window = view.window else { return }

        // The crease (division) that is dividing the window, converted to the
        // Flutter view's coordinate space (points).
        var division: [String: CGFloat]?
        var divisionActive = false
        for r in window.reservedRegions(kind: .division, options: [.includeInactive]) {
            let f = window.convert(r.frame, to: view)
            if r.isActive { division = rect(f); divisionActive = true; break }
            if division == nil { division = rect(f) }   // inactive fallback (position only)
        }

        let occlusions = window.reservedRegions(kind: .occlusion, options: [.includeInactive])
            .map { rect(window.convert($0.frame, to: view)) }

        sink([
            "hinge": name(hinge?.status),
            "angle": hinge.map { Double($0.angle) * 180 / .pi } as Any,
            "division": division as Any,
            "divisionActive": divisionActive,
            "occlusions": occlusions,
        ])
    }

    private func rect(_ r: CGRect) -> [String: CGFloat] {
        ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
    }
    private func name(_ s: UIHinge.Status?) -> String {
        switch s {
        case .closed: return "closed"
        case .partiallyOpen: return "partiallyOpen"
        case .fullyOpen: return "fullyOpen"
        case .none: return "none"
        default: return "unknown"
        }
    }
}
```

Also re-emit on `traitCollectionDidChange` / `viewDidLayoutSubviews` of the
`FlutterViewController`, so a rotate or Split-View resize refreshes the crease.

**Read the regions in `viewDidLayoutSubviews`, not only in the hinge handler.** Per
flutter/flutter#193025, the reserved regions *lag* the hinge: inside the hinge update the
division still reports its pre-move `isActive`; it clears ~2–15 ms after the hinge reads fully
open and becomes active ~1 s after folding, and there is **no change notification** for reserved
regions in the 27.1 headers. Reading on each layout pass is what catches the settled state. The
posture rule (treat active-while-open as a separating fold) covers the in-between window.

## Verifying without hardware (works today)

`DuoFoldScope` honours a **simulated** pose, so the whole Flutter layout path can be
exercised on any phone or the current simulators:

```dart
// anywhere in a debug build:
duoFoldSimulation.value = simulatedBookFold(MediaQuery.sizeOf(context));   // vertical crease
duoFoldSimulation.value = simulatedTabletopFold(MediaQuery.sizeOf(context)); // horizontal crease
duoFoldSimulation.value = null;                                            // off
```

This is how the widget tests drive it (`test/duo_fold_scope_test.dart`).
