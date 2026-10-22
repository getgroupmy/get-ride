// The TripCard widget extension's entry point: only the trip card's Live
// Activity. The extension targets iOS 16.2, where Live Activities take
// ActivityContent (docs/trip_card_ios.md).
import SwiftUI
import WidgetKit

@main
struct TripCardBundle: WidgetBundle {
  var body: some Widget {
    TripCardLiveActivity()
  }
}
