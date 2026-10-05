/// Emergency SOS (Expo `app/safety.tsx` and the ride-tracking SOS button).
///
/// Expo's SOS text promised "your details and live location" but sent
/// neither; here the message carries a map link to the rider's position when
/// one is known, and the driver and car when sent from a ride.
library;

/// The public emergency number the ride screen dials (Malaysia, as in Expo).
const emergencyNumber = '999';

/// Digits and a leading + only, as SMS apps expect.
String cleanPhone(String raw) {
  final t = raw.trim();
  final digits = t.replaceAll(RegExp(r'[^\d]'), '');
  return t.startsWith('+') ? '+$digits' : digits;
}

/// The SOS text.
String sosMessage({double? lat, double? lng, String? driver, String? plate}) {
  final b = StringBuffer(
    'EMERGENCY: I need help. This is an SOS alert from the GET.ride app. '
    'Please contact me immediately.',
  );
  if (lat != null && lng != null) {
    b.write(' My location: https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}');
  }
  final ride = [
    if (driver != null && driver.trim().isNotEmpty) 'driver ${driver.trim()}',
    if (plate != null && plate.trim().isNotEmpty) 'car ${plate.trim()}',
  ];
  if (ride.isNotEmpty) b.write(' I am on a GET.ride trip (${ride.join(', ')}).');
  return b.toString();
}

/// An `sms:` link to every contact with [body] filled in. iOS reads the body
/// after `&`, Android after `?` (Expo `safety.tsx`).
Uri sosSmsUri(List<String> phones, String body, {required bool ios}) {
  final numbers = phones.map(cleanPhone).where((p) => p.isNotEmpty).join(',');
  return Uri.parse('sms:$numbers${ios ? '&' : '?'}body=${Uri.encodeComponent(body)}');
}
