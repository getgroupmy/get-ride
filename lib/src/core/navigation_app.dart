/// Which app the driver's Navigate button opens (Expo `navigation.tsx` offered
/// the same three but never saved or used the choice).
library;

enum NavigationApp {
  google('Google Maps'),
  waze('Waze'),
  apple('Apple Maps');

  const NavigationApp(this.label);
  final String label;

  static NavigationApp fromName(String? name) =>
      NavigationApp.values.where((a) => a.name == name).firstOrNull ?? NavigationApp.google;
}

/// The apps worth offering here: Apple Maps only exists on Apple platforms.
List<NavigationApp> navigationAppsFor({required bool apple}) =>
    apple ? NavigationApp.values : const [NavigationApp.google, NavigationApp.waze];

/// A turn-by-turn link to ([lat], [lng]) in [app]. All three are https links
/// that the installed app claims, and otherwise open the web version, so a
/// missing app still gets the driver a route.
Uri navigationUri(NavigationApp app, double lat, double lng) {
  final at = '$lat,$lng';
  return switch (app) {
    NavigationApp.google => Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$at&travelmode=driving'),
    NavigationApp.waze => Uri.parse('https://waze.com/ul?ll=$at&navigate=yes'),
    NavigationApp.apple => Uri.parse('https://maps.apple.com/?daddr=$at&dirflg=d'),
  };
}
