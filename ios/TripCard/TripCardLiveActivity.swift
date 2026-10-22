// The trip card on the iPhone: the lock screen card and the Dynamic Island,
// drawn as the approved sample (GET.ride and the stage chip, the headline
// with its accent part, the car and plate line, the car moving along the bar
// to the drop pin, and the buttons). Part of the TripCard widget extension
// (docs/trip_card_ios.md).
import ActivityKit
import SwiftUI
import WidgetKit

extension Color {
  /// A colour kept as an ARGB number.
  init(argb: Int) {
    let v = UInt32(truncatingIfNeeded: argb)
    self.init(
      .sRGB,
      red: Double((v >> 16) & 0xFF) / 255,
      green: Double((v >> 8) & 0xFF) / 255,
      blue: Double(v & 0xFF) / 255,
      opacity: Double((v >> 24) & 0xFF) / 255)
  }
}

@available(iOS 16.2, *)
private struct Palette {
  let background: Color
  let accent: Color
  let text: Color
  let muted: Color

  init(_ state: TripCardAttributes.ContentState, _ scheme: ColorScheme) {
    let set = scheme == .dark ? state.colors.dark : state.colors.light
    background = Color(argb: set.background)
    accent = Color(argb: set.accent)
    text = Color(argb: set.text)
    muted = Color(argb: set.muted)
  }
}

/// The headline with its emphasis in the accent colour.
@available(iOS 16.2, *)
private func headline(_ state: TripCardAttributes.ContentState, _ p: Palette) -> Text {
  guard let em = state.emphasis, let range = state.headline.range(of: em) else {
    return Text(state.headline).foregroundColor(p.text)
  }
  return Text(String(state.headline[..<range.lowerBound])).foregroundColor(p.text)
    + Text(em).foregroundColor(p.accent)
    + Text(String(state.headline[range.upperBound...])).foregroundColor(p.text)
}

/// The bar: the rail, the part done, the car at [progress] and the pin.
@available(iOS 16.2, *)
private struct TripTrack: View {
  let progress: Double
  let p: Palette

  var body: some View {
    GeometryReader { geo in
      let width = max(0, geo.size.width - 22)
      let x = width * min(max(progress, 0), 1)
      ZStack(alignment: .leading) {
        Capsule().fill(p.muted.opacity(0.35)).frame(width: width, height: 4)
        Capsule().fill(p.accent).frame(width: x, height: 4)
        Image(systemName: "car.fill")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(p.text)
          .offset(x: min(max(x - 10, 0), width))
        Image(systemName: "mappin.circle.fill")
          .font(.system(size: 18))
          .foregroundColor(p.accent)
          .offset(x: width + 2)
      }
      .frame(height: 22)
    }
    .frame(height: 22)
  }
}

@available(iOS 16.2, *)
private struct Chip: View {
  let text: String
  let p: Palette

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .bold))
      .foregroundColor(p.text)
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .background(Capsule().fill(p.accent.opacity(0.25)))
  }
}

@available(iOS 16.2, *)
private struct Brand: View {
  let p: Palette

  var body: some View {
    (Text("GET.").foregroundColor(p.text) + Text("ride").foregroundColor(p.accent))
      .font(.system(size: 15, weight: .heavy))
  }
}

@available(iOS 16.2, *)
private struct Buttons: View {
  let buttons: [TripCardButton]
  let p: Palette

  var body: some View {
    HStack(spacing: 8) {
      ForEach(buttons, id: \.id) { b in
        if let url = URL(string: b.uri) {
          Link(destination: url) {
            Text(b.label)
              .font(.system(size: 12, weight: .bold))
              .foregroundColor(p.text)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 7)
              .background(RoundedRectangle(cornerRadius: 10).fill(p.text.opacity(0.12)))
          }
        }
      }
    }
  }
}

@available(iOS 16.2, *)
struct TripCardLockScreen: View {
  let state: TripCardAttributes.ContentState
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let p = Palette(state, scheme)
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Brand(p: p)
        Spacer()
        Chip(text: state.chip, p: p)
      }
      headline(state, p).font(.system(size: 20, weight: .heavy)).lineLimit(2)
      if !state.subline.isEmpty || state.plate != nil {
        HStack(spacing: 8) {
          if !state.subline.isEmpty {
            Text(state.subline).font(.system(size: 12)).foregroundColor(p.muted).lineLimit(1)
          }
          if let plate = state.plate {
            Text(plate)
              .font(.system(size: 11, weight: .semibold, design: .monospaced))
              .foregroundColor(.black)
              .padding(.horizontal, 6)
              .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
          }
        }
      }
      TripTrack(progress: state.progress, p: p)
      if let title = state.footTitle {
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(p.text)
          if let text = state.footText {
            Text(text).font(.system(size: 12)).foregroundColor(p.muted)
          }
        }
      }
      if !state.buttons.isEmpty {
        Buttons(buttons: state.buttons, p: p)
      }
    }
    .padding(16)
    .background(p.background)
  }
}

@available(iOS 16.2, *)
struct TripCardLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TripCardAttributes.self) { context in
      TripCardLockScreen(state: context.state)
        .widgetURL(URL(string: context.attributes.openUri))
    } dynamicIsland: { context in
      let p = Palette(context.state, .dark)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Brand(p: p)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Chip(text: context.state.chip, p: p)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 8) {
            headline(context.state, p).font(.system(size: 17, weight: .heavy)).lineLimit(2)
            TripTrack(progress: context.state.progress, p: p)
            if !context.state.buttons.isEmpty {
              Buttons(buttons: context.state.buttons, p: p)
            }
          }
        }
      } compactLeading: {
        Image(systemName: "car.fill").foregroundColor(p.accent)
      } compactTrailing: {
        Text(context.state.compact).font(.system(size: 13, weight: .bold)).foregroundColor(p.text)
      } minimal: {
        Image(systemName: "car.fill").foregroundColor(p.accent)
      }
      .widgetURL(URL(string: context.attributes.openUri))
    }
  }
}
