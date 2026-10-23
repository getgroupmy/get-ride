// Admin → Edit Partner: the driver's real status now, and whether a vehicle
// can be linked to this partner (its other driver online or on a job: no).
// Pure; read from driver_presence, ride_requests, ride_offers,
// safety_incidents and vehicle_active_session by PeopleRepository.live.
import 'people_logic.dart' show vehicleForPlate;

/// What the driver is doing, in the order a job runs.
enum PartnerLive {
  noVehicle('No vehicle linked'),
  offline('Offline'),
  online('Online'),
  offering('Offering'),
  pickup('Going to pickup'),
  waiting('Waiting for passenger'),
  trip('On trip'),
  unpaid('Ended, payment pending'),
  sos('SOS');

  const PartnerLive(this.label);
  final String label;

  /// Online, offering or on a job: the vehicle is in use.
  bool get busy => this != noVehicle && this != offline;

  /// The step on the job strip (Online to Ended), or null off it.
  int? get step => switch (this) {
        online => 0,
        offering => 1,
        pickup => 2,
        waiting => 3,
        trip => 4,
        unpaid => 5,
        _ => null,
      };
}

/// The job strip under the status.
const partnerLiveSteps = ['Online', 'Offering', 'Going to pickup', 'Waiting', 'On trip', 'Payment pending', 'Ended'];

/// A phone that reported online this long ago still counts as online, as on
/// God View (0272: "free" within 3 minutes).
const partnerOnlineFresh = Duration(minutes: 3);

/// A ride ended this long ago and still unpaid stops counting as "payment
/// pending" for the driver's status (it is a support case by then).
const partnerUnpaidWindow = Duration(hours: 12);

/// One driver's rows, as read for [partnerLiveOf].
class PartnerLiveRows {
  const PartnerLiveRows({
    this.presence,
    this.rides = const [],
    this.offers = const [],
    this.incidents = const [],
  });

  /// driver_presence (profile_id, online, updated_at).
  final Map<String, dynamic>? presence;

  /// ride_requests with partner_id = the driver, newest first: the active
  /// one (accepted / arrived / on_trip) and recent completed ones.
  final List<Map<String, dynamic>> rides;

  /// ride_offers (status 'pending') made by the driver.
  final List<Map<String, dynamic>> offers;

  /// safety_incidents (open / acknowledged) on the driver.
  final List<Map<String, dynamic>> incidents;
}

/// The status and its one-line detail.
typedef PartnerLiveStatus = ({PartnerLive status, String detail, Map<String, dynamic>? ride});

DateTime? _t(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toUtc();

String _ago(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds.clamp(0, 59)} s ago';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}

String _rideName(Map<String, dynamic> r) {
  final to = '${r['drop_name'] ?? ''}'.trim();
  return to.isEmpty ? 'the current ride' : 'to $to';
}

/// What [rows] say the driver is doing at [now]. [hasVehicle] false is "No
/// vehicle linked" unless a job or an SOS is still running.
PartnerLiveStatus partnerLiveOf(PartnerLiveRows rows, {required bool hasVehicle, required DateTime now}) {
  if (rows.incidents.any((i) => i['status'] == 'open' || i['status'] == 'acknowledged')) {
    final at = _t(rows.incidents.first['created_at']);
    return (status: PartnerLive.sos, detail: at == null ? 'SOS open' : 'SOS pressed ${_ago(now.difference(at))}', ride: null);
  }
  for (final r in rows.rides) {
    final s = r['status'];
    if (s == 'accepted') return (status: PartnerLive.pickup, detail: 'Going to pick up, ${_rideName(r)}', ride: r);
    if (s == 'arrived') {
      final at = _t(r['arrived_at']);
      return (
        status: PartnerLive.waiting,
        detail: at == null ? 'At the pickup' : 'At the pickup for ${_ago(now.difference(at)).replaceAll(' ago', '')}',
        ride: r,
      );
    }
    if (s == 'on_trip') return (status: PartnerLive.trip, detail: 'Ongoing, ${_rideName(r)}', ride: r);
  }
  for (final r in rows.rides) {
    final done = _t(r['completed_at']);
    final pay = r['payment_status'];
    if (r['status'] == 'completed' &&
        (pay == 'due' || pay == 'cash_pending') &&
        done != null &&
        now.difference(done) < partnerUnpaidWindow) {
      return (
        status: PartnerLive.unpaid,
        detail: pay == 'cash_pending' ? 'Rider says paid in cash, driver to confirm' : 'Ended ${_ago(now.difference(done))}, not paid yet',
        ride: r,
      );
    }
  }
  if (!hasVehicle) return (status: PartnerLive.noVehicle, detail: 'Assign a vehicle below before the driver can go online', ride: null);
  final p = rows.presence;
  final seen = _t(p?['updated_at']);
  final online = p?['online'] == true && seen != null && now.difference(seen) < partnerOnlineFresh;
  if (online) {
    final live = rows.offers.where((o) {
      final until = _t(o['expires_at']);
      return o['status'] == 'pending' && (until == null || until.isAfter(now));
    }).toList();
    if (live.isNotEmpty) {
      final amount = num.tryParse('${live.first['amount'] ?? ''}');
      return (
        status: PartnerLive.offering,
        detail: amount == null ? 'Sent an offer, waiting for the rider' : 'Offered RM ${amount.toStringAsFixed(2)}, waiting for the rider',
        ride: null,
      );
    }
    return (status: PartnerLive.online, detail: 'Free, waiting for requests', ride: null);
  }
  return (
    status: PartnerLive.offline,
    detail: seen == null ? 'Never been online' : 'Last online ${_ago(now.difference(seen))}',
    ride: null,
  );
}

/// Who else has a vehicle, and what they are doing.
typedef VehicleHolder = ({String userId, String name, PartnerLive status, String detail});

/// Whether this partner may take the vehicle: only while nobody else is
/// online or on a job with it.
bool vehicleLinkable(List<VehicleHolder> holders) => !holders.any((h) => h.status.busy);

/// The vehicle's line under it in the picker.
String vehicleUseLine(List<VehicleHolder> holders) {
  if (holders.isEmpty) return 'Not linked to anyone';
  final busy = holders.where((h) => h.status.busy).toList();
  if (busy.isNotEmpty) return 'In use by ${busy.first.name} · ${busy.first.status.label}';
  final h = holders.first;
  return 'Linked to ${h.name} · Offline${holders.length > 1 ? ' (+${holders.length - 1})' : ''}';
}

/// This partner's own vehicles: owned by them, or linked to them now.
bool vehicleIsOwn(Map<String, dynamic> v, {required String? userId, required String? partnerId, Object? plate}) {
  if (userId != null && userId.isNotEmpty && v['auth_user_id'] == userId) return true;
  if (partnerId != null && v['owner_partner_id'] == partnerId) return true;
  return identical(vehicleForPlate([v], plate), v);
}

/// The picker's list: with no search, only this partner's own vehicles; a
/// search finds anyone's (plate, make, model or owner), at most 20.
List<Map<String, dynamic>> vehiclesToShow(
  Iterable<Map<String, dynamic>> vehicles,
  String query, {
  required bool Function(Map<String, dynamic>) isOwn,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return vehicles.where(isOwn).take(20).toList();
  return vehicles
      .where((v) => ['plate', 'make', 'model', 'owner_name'].any((k) => '${v[k] ?? ''}'.toLowerCase().contains(q)))
      .take(20)
      .toList();
}
