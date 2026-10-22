// The trip card's Live Activity data (lib/src/core/trip_card.dart,
// TripCard.toPlatform). Shared by the app (Runner/TripCardActivities.swift,
// which starts and updates it) and the TripCard widget extension (which draws
// it), so it is a member of both targets (docs/trip_card_ios.md).
import ActivityKit
import Foundation

/// One set of the card's colours, as ARGB numbers (App Page Settings,
/// "Trip card · Preview").
struct TripCardColorSet: Codable, Hashable {
  var background: Int
  var accent: Int
  var text: Int
  var muted: Int

  static let standard = TripCardColorSet(
    background: 0xFF00_0000, accent: 0xFF2D_ABE2, text: 0xFFFF_FFFF, muted: 0xFFA9_B6C0)
}

struct TripCardPalette: Codable, Hashable {
  var light: TripCardColorSet
  var dark: TripCardColorSet
}

/// A button on the card: it opens the app on [uri] (getride://trip/...).
struct TripCardButton: Codable, Hashable {
  var id: String
  var label: String
  var uri: String
}

@available(iOS 16.1, *)
struct TripCardAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// finding, toPickup, arrived, onTrip or done.
    var stage: String
    var chip: String
    var compact: String
    var headline: String
    var emphasis: String?
    var subline: String
    var plate: String?
    var footTitle: String?
    var footText: String?
    /// 0 to 1: where the car is on the bar.
    var progress: Double
    var buttons: [TripCardButton]
    var colors: TripCardPalette
  }

  var rideId: String
  /// rider or driver.
  var role: String
  /// ride, courier or freight.
  var service: String
  /// Where tapping the card goes.
  var openUri: String
}
