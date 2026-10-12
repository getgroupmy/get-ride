// Admin → Bluetooth & safety report: what ble_safety_report /
// ble_safety_report_trips (0158) say, read for the page. Pure, so tested
// without a database.

/// The periods the report offers, in days.
const bleReportPeriods = [7, 30, 90];

/// One Malaysian day of trip starts.
class BleReportDay {
  const BleReportDay({required this.day, this.ble = 0, this.pin = 0, this.other = 0});

  final DateTime day;
  final int ble, pin, other;

  int get total => ble + pin + other;
}

class BleSafetyReport {
  const BleSafetyReport({
    this.days = 7,
    this.startsBle = 0,
    this.startsPin = 0,
    this.startsNone = 0,
    this.startsUnknown = 0,
    this.daily = const [],
    this.handshakeRides = 0,
    this.bothPhones = 0,
    this.seenBothWays = 0,
    this.reports = 0,
    this.matchedReports = 0,
    this.avgRssi,
    this.farApart = 0,
    this.noProximity = 0,
    this.separations = 0,
    this.answeredOk = 0,
    this.lostOpen = 0,
    this.lostFound = 0,
    this.lostReturned = 0,
    this.lostNotFound = 0,
  });

  final int days;

  /// How trips started: Bluetooth, the trip code, no code (an old ride), or
  /// an app from before the start was recorded.
  final int startsBle, startsPin, startsNone, startsUnknown;
  final List<BleReportDay> daily;

  /// Rides that used the pickup handshake; of those, where both phones took
  /// part; and where each phone saw the other.
  final int handshakeRides, bothPhones, seenBothWays;

  /// Sightings the phones reported, and how many were the right phone.
  final int reports, matchedReports;

  /// The matched sightings' average signal (dBm), for a distance hint.
  final int? avgRssi;

  final int farApart, noProximity, separations, answeredOk;
  final int lostOpen, lostFound, lostReturned, lostNotFound;

  int get startsTotal => startsBle + startsPin + startsNone + startsUnknown;

  /// Trips that started some other way than Bluetooth or the code.
  int get startsOther => startsNone + startsUnknown;

  int get flagged => farApart + noProximity + separations;
  int get lostTotal => lostOpen + lostFound + lostReturned + lostNotFound;

  factory BleSafetyReport.fromJson(Object? json) {
    if (json is! Map) return const BleSafetyReport();
    Map<String, dynamic> obj(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};
    int n(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;
    final starts = obj(json['starts']);
    final hand = obj(json['handshake']);
    final safety = obj(json['safety']);
    final daily = <BleReportDay>[
      if (json['daily'] is List)
        for (final d in json['daily'] as List)
          if (d is Map && DateTime.tryParse('${d['day']}') != null)
            BleReportDay(
              day: DateTime.parse('${d['day']}'),
              ble: (d['ble'] as num?)?.toInt() ?? 0,
              pin: (d['pin'] as num?)?.toInt() ?? 0,
              other: (d['other'] as num?)?.toInt() ?? 0,
            ),
    ];
    return BleSafetyReport(
      days: (json['days'] as num?)?.toInt() ?? 7,
      startsBle: n(starts, 'ble'),
      startsPin: n(starts, 'pin'),
      startsNone: n(starts, 'none'),
      startsUnknown: n(starts, 'unknown'),
      daily: daily,
      handshakeRides: n(hand, 'rides'),
      bothPhones: n(hand, 'both_phones'),
      seenBothWays: n(hand, 'seen_both_ways'),
      reports: n(hand, 'reports'),
      matchedReports: n(hand, 'matched_reports'),
      avgRssi: (hand['avg_rssi'] as num?)?.round(),
      farApart: n(safety, 'far_apart'),
      noProximity: n(safety, 'no_proximity'),
      separations: n(safety, 'separations'),
      answeredOk: n(safety, 'answered_ok'),
      lostOpen: n(safety, 'lost_open'),
      lostFound: n(safety, 'lost_found'),
      lostReturned: n(safety, 'lost_returned'),
      lostNotFound: n(safety, 'lost_not_found'),
    );
  }
}

/// "42%", or "—" when there is nothing to take a share of.
String reportShare(int part, int whole) => whole <= 0 ? '—' : '${(100 * part / whole).round()}%';

/// What a flagged trip is flagged for.
enum BleReportKind { farApart, noProximity, separated, lostItem }

BleReportKind? bleReportKindOf(Object? raw) => switch (raw) {
  'far_apart' => BleReportKind.farApart,
  'no_proximity' => BleReportKind.noProximity,
  'separated' => BleReportKind.separated,
  'lost_item' => BleReportKind.lostItem,
  _ => null,
};

String bleReportKindLabel(BleReportKind k) => switch (k) {
  BleReportKind.farApart => 'Started away from the passenger',
  BleReportKind.noProximity => "Started without the phones meeting",
  BleReportKind.separated => 'Apart mid-trip',
  BleReportKind.lostItem => 'Lost item reported',
};

/// One trip behind the safety numbers.
class BleReportTrip {
  const BleReportTrip({
    required this.requestId,
    required this.kind,
    required this.at,
    this.rideStatus,
    this.pickupName,
    this.riderName,
    this.driverName,
    this.answeredOk = false,
    this.startMethod,
    this.detail,
  });

  final String requestId;
  final BleReportKind kind;
  final DateTime at;
  final String? rideStatus, pickupName, riderName, driverName, startMethod, detail;

  /// The passenger tapped "I'm OK" on the safety check.
  final bool answeredOk;

  static BleReportTrip? fromRow(Object? row) {
    if (row is! Map) return null;
    final kind = bleReportKindOf(row['kind']);
    final at = DateTime.tryParse('${row['at']}');
    final id = row['request_id'];
    if (kind == null || at == null || id is! String) return null;
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return BleReportTrip(
      requestId: id,
      kind: kind,
      at: at.toLocal(),
      rideStatus: text(row['ride_status']),
      pickupName: text(row['pickup_name']),
      riderName: text(row['rider_name']),
      driverName: text(row['driver_name']),
      answeredOk: row['answered_ok'] == true,
      startMethod: text(row['start_method']),
      detail: text(row['detail']),
    );
  }

  static List<BleReportTrip> listFrom(Object? rows) => [
    if (rows is List)
      for (final r in rows) ?BleReportTrip.fromRow(r),
  ];

  /// "Rina → Dan", with whichever names are known.
  String get people => [riderName ?? 'Passenger', driverName ?? 'Driver'].join(' → ');

  /// How the trip started, for the sheet.
  String get startedBy => switch (startMethod) {
    'ble' => 'Bluetooth',
    'pin' => 'Trip code',
    'none' => 'No code',
    _ => '—',
  };
}
