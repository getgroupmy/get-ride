// The app's side of the trip card on the iPhone (docs/trip_card_ios.md): the
// MethodChannel `getride/trip_card` (lib/src/data/trip_card_platform.dart)
// starts, updates and ends the trip's Live Activity, which the TripCard
// widget extension draws. In the Runner target together with
// ../TripCard/TripCardAttributes.swift; registered in AppDelegate.swift.
// Below iOS 16.2 every call answers false and the app carries on without a
// card.
import ActivityKit
import Flutter
import Foundation

/// The card as the app sends it (TripCard.toPlatform).
private struct TripCardPayload: Decodable {
  var rideId: String
  var role: String?
  var service: String?
  var stage: String
  var chip: String
  var compact: String?
  var headline: String
  var emphasis: String?
  var subline: String?
  var plate: String?
  var footTitle: String?
  var footText: String?
  var progress: Double?
  var openUri: String?
  var actions: [TripCardButton]?
  var ongoing: Bool?
  var clearAfterMs: Double?
  var colors: TripCardPalette?
}

final class TripCardPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "getride/trip_card", binaryMessenger: registrar.messenger())
    let plugin = TripCardPlugin()
    plugin.channel = channel
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 16.2, *) else {
      result(false)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start", "update":
      TripCardActivities.shared.show(args, channel: channel) { ok in DispatchQueue.main.async { result(ok) } }
    case "end":
      TripCardActivities.shared.end(rideId: args["rideId"] as? String ?? "")
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

@available(iOS 16.2, *)
final class TripCardActivities {
  static let shared = TripCardActivities()

  /// The ride's card still on screen (one the user swiped away or that
  /// ended is skipped, so the next update starts a new one).
  private func activity(_ rideId: String) -> Activity<TripCardAttributes>? {
    Activity<TripCardAttributes>.activities.first {
      $0.attributes.rideId == rideId && ($0.activityState == .active || $0.activityState == .stale)
    }
  }

  func show(_ args: [String: Any], channel: FlutterMethodChannel?, done: @escaping (Bool) -> Void) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled,
      let data = try? JSONSerialization.data(withJSONObject: args),
      let card = try? JSONDecoder().decode(TripCardPayload.self, from: data)
    else {
      done(false)
      return
    }
    let state = TripCardAttributes.ContentState(
      stage: card.stage,
      chip: card.chip,
      compact: card.compact ?? card.chip,
      headline: card.headline,
      emphasis: card.emphasis,
      subline: card.subline ?? "",
      plate: card.plate,
      footTitle: card.footTitle,
      footText: card.footText,
      progress: card.progress ?? 0,
      buttons: card.actions ?? [],
      colors: card.colors ?? TripCardPalette(light: .standard, dark: .standard))
    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
    let ongoing = card.ongoing ?? true
    let clearAfter = (card.clearAfterMs ?? 0) / 1000
    if let running = activity(card.rideId) {
      Task {
        if ongoing {
          await running.update(content)
        } else {
          // The done card stays the admin's minutes, then iOS takes it away.
          await running.end(content, dismissalPolicy: clearAfter > 0 ? .after(Date().addingTimeInterval(clearAfter)) : .immediate)
        }
        done(true)
      }
      return
    }
    if !ongoing {
      done(false)
      return
    }
    // One card at a time: another ride's goes.
    for other in Activity<TripCardAttributes>.activities {
      Task { await other.end(nil, dismissalPolicy: .immediate) }
    }
    do {
      let attributes = TripCardAttributes(
        rideId: card.rideId,
        role: card.role ?? "rider",
        service: card.service ?? "ride",
        openUri: card.openUri ?? "getride://trip/\(card.rideId)")
      let started = try Activity.request(attributes: attributes, content: content, pushType: .token)
      // The token the server sends updates to while the app is closed
      // (docs/trip_card_ios.md, "Updates while the app is closed").
      Task {
        for await token in started.pushTokenUpdates {
          let hex = token.map { String(format: "%02x", $0) }.joined()
          await MainActor.run {
            channel?.invokeMethod("pushToken", arguments: ["rideId": card.rideId, "token": hex])
          }
        }
      }
      done(true)
    } catch {
      done(false)
    }
  }

  func end(rideId: String) {
    guard let running = activity(rideId) else { return }
    Task { await running.end(nil, dismissalPolicy: .immediate) }
  }
}
