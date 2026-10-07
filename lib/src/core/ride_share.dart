// A ride shared by link (migration 0108): the address it lives at, the
// message it is sent with, and the read-only view the link opens. Pure.
import 'package:latlong2/latlong.dart';

import '../data/models.dart';

/// Where shared rides are opened: the web app, which needs no account.
const rideShareBase = 'https://getride.my';

/// How often the shared page re-reads the ride (it has no realtime feed).
const rideShareRefresh = Duration(seconds: 10);

/// A token is a UUID; anything else is not worth asking the server about.
bool isShareToken(String s) =>
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false).hasMatch(s.trim());

String rideShareUrl(String token, {String base = rideShareBase}) => '$base/share/$token';

/// The text the link is sent with.
String rideShareMessage(RideRequest r, String url) {
  final who = r.isForOthers ? 'Your GET.ride to ${r.dropLabel}' : 'Follow my GET.ride to ${r.dropLabel}';
  return '$who: $url';
}

/// The ride as the link shows it: no phone numbers, and the trip code only
/// on a ride booked for someone else, before pickup.
class SharedRide {
  SharedRide(this.raw);
  final Map<String, dynamic> raw;

  static double? _d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
  static String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  static DateTime? _t(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

  RideStatus get status => RideStatus.parse(raw['status'] as String?);
  String? get service => _s(raw['service']);
  String get passenger => _s(raw['passenger']) ?? 'Passenger';
  bool get bookedForOthers => raw['booked_for_others'] == true;
  String get pickupName => _s(raw['pickup_name']) ?? 'Pickup';
  String? get pickupAddress => _s(raw['pickup_address']);
  String get dropName => _s(raw['drop_name']) ?? 'Destination';
  String? get dropAddress => _s(raw['drop_address']);
  double? get distanceKm => _d(raw['distance_km']);
  double? get durationMin => _d(raw['duration_min']);
  double? get fare => _d(raw['fare']);
  String get currency => _s(raw['currency']) ?? 'MYR';
  String? get paymentMode => _s(raw['payment_mode']);
  String? get driverName => _s(raw['partner_name']);
  String? get driverPhoto => _s(raw['partner_photo']);
  String? get vehicle => _s(raw['partner_vehicle']);
  String? get plate => _s(raw['partner_plate']);
  double? get driverRating => _d(raw['partner_rating']);
  double? get driverHeading => _d(raw['partner_live_heading']);
  DateTime? get driverSeenAt => _t(raw['partner_live_at']);
  String? get tripCode => _s(raw['otp']);
  DateTime? get createdAt => _t(raw['created_at']);
  DateTime? get startedAt => _t(raw['started_at']);
  DateTime? get endedAt => _t(raw['completed_at']) ?? _t(raw['cancelled_at']);

  LatLng? _at(String lat, String lng) {
    final a = _d(raw[lat]), b = _d(raw[lng]);
    return a == null || b == null ? null : LatLng(a, b);
  }

  LatLng? get pickup => _at('pickup_lat', 'pickup_lng');
  LatLng? get drop => _at('drop_lat', 'drop_lng');
  LatLng? get driver =>
      status.isOngoing && status != RideStatus.open ? _at('partner_live_lat', 'partner_live_lng') : null;

  List<({String name, LatLng point})> get stops {
    final list = raw['stops'];
    if (list is! List) return const [];
    return [
      for (final s in list)
        if (s is Map && _d(s['lat']) != null && _d(s['lng']) != null)
          (name: _s(s['name']) ?? 'Stop', point: LatLng(_d(s['lat'])!, _d(s['lng'])!)),
    ];
  }
}

/// What the shared page leads with.
String sharedRideHeadline(SharedRide r) => switch (r.status) {
  RideStatus.open => 'Looking for a driver',
  RideStatus.accepted => '${r.driverName ?? 'The driver'} is on the way to the pickup',
  RideStatus.arrived => '${r.driverName ?? 'The driver'} has arrived at the pickup',
  RideStatus.onTrip => 'On the way to ${r.dropName}',
  RideStatus.completed => 'Arrived at ${r.dropName}',
  RideStatus.cancelled => 'This ride was cancelled',
  RideStatus.expired => 'No driver was found for this ride',
};
