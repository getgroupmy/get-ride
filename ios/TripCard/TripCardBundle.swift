// The TripCard widget extension's entry point: only the trip card's Live
// Activity. Not in the Xcode project yet (docs/trip_card_ios.md).
import SwiftUI
import WidgetKit

@main
struct TripCardBundle: WidgetBundle {
  var body: some Widget {
    if #available(iOS 16.2, *) {
      TripCardLiveActivity()
    }
  }
}
