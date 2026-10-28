// City ride safety (migration 0311): reporting a trip from the receipt,
// blocking a driver, the driver's request filters, and the passenger cover
// and driver's permit shown on the receipt and the Safety page. Pure: the
// server is supabase/migrations/0311_ride_reports_blocks_filters_cover.sql,
// the data lib/src/data/ride_safety_repository.dart.
library;

import 'date_order.dart';
import 'destination_mode.dart' show destinationOrder;
import 'format.dart';

/// The admin page key (Admin › Settings › Ride safety), grantable to sub-admins.
const rideSafetyPage = 'admin-settings-ride-safety';

/// Its address in the admin.
const rideSafetyPath = '/admin/m/ride-safety';

/// The rider's list of blocked drivers.
const blockedDriversPath = '/account/settings/blocked-drivers';

double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
bool _bool(Object? v, bool fallback) => v is bool ? v : (v == null ? fallback : '$v' == 'true');
String? _text(Object? v) {
  final s = '${v ?? ''}'.trim();
  return s.isEmpty || s == 'null' ? null : s;
}

DateTime? _time(Object? v) => DateTime.tryParse('${v ?? ''}');

// ---- Settings --------------------------------------------------------------------------------------

/// `ride_safety_settings`, one row; defaults as the migration's.
class RideSafetySettings {
  const RideSafetySettings({
    this.reportWindowDays = 30,
    this.maxBlocksPerRider = 20,
    this.blockFlagRiders = 3,
    this.minFareOn = true,
    this.minFareCap = 30,
    this.distanceOn = true,
    this.distanceMinKm = 1,
    this.distanceMaxKm = 10,
    this.sortOn = true,
    this.showDriverPermit = true,
    this.currency = 'MYR',
  });

  final int reportWindowDays;
  final int maxBlocksPerRider;
  final int blockFlagRiders;
  final bool minFareOn;
  final double minFareCap;
  final bool distanceOn;
  final double distanceMinKm;
  final double distanceMaxKm;
  final bool sortOn;
  final bool showDriverPermit;
  final String currency;

  factory RideSafetySettings.fromRow(Map<String, dynamic>? r) {
    if (r == null) return const RideSafetySettings();
    const d = RideSafetySettings();
    return RideSafetySettings(
      reportWindowDays: _int(r['report_window_days']) ?? d.reportWindowDays,
      maxBlocksPerRider: _int(r['max_blocks_per_rider']) ?? d.maxBlocksPerRider,
      blockFlagRiders: _int(r['block_flag_riders']) ?? d.blockFlagRiders,
      minFareOn: _bool(r['filter_min_fare_on'], true),
      minFareCap: _num(r['filter_min_fare_cap']) ?? d.minFareCap,
      distanceOn: _bool(r['filter_distance_on'], true),
      distanceMinKm: _num(r['filter_distance_min_km']) ?? d.distanceMinKm,
      distanceMaxKm: _num(r['filter_distance_max_km']) ?? d.distanceMaxKm,
      sortOn: _bool(r['filter_sort_on'], true),
      showDriverPermit: _bool(r['show_driver_permit'], true),
      currency: _text(r['currency']) ?? 'MYR',
    );
  }

  Map<String, dynamic> toRow() => {
        'report_window_days': reportWindowDays,
        'max_blocks_per_rider': maxBlocksPerRider,
        'block_flag_riders': blockFlagRiders,
        'filter_min_fare_on': minFareOn,
        'filter_min_fare_cap': minFareCap,
        'filter_distance_on': distanceOn,
        'filter_distance_min_km': distanceMinKm,
        'filter_distance_max_km': distanceMaxKm,
        'filter_sort_on': sortOn,
        'show_driver_permit': showDriverPermit,
      };

  RideSafetySettings copyWith({
    int? reportWindowDays,
    int? maxBlocksPerRider,
    int? blockFlagRiders,
    bool? minFareOn,
    double? minFareCap,
    bool? distanceOn,
    double? distanceMinKm,
    double? distanceMaxKm,
    bool? sortOn,
    bool? showDriverPermit,
  }) =>
      RideSafetySettings(
        reportWindowDays: reportWindowDays ?? this.reportWindowDays,
        maxBlocksPerRider: maxBlocksPerRider ?? this.maxBlocksPerRider,
        blockFlagRiders: blockFlagRiders ?? this.blockFlagRiders,
        minFareOn: minFareOn ?? this.minFareOn,
        minFareCap: minFareCap ?? this.minFareCap,
        distanceOn: distanceOn ?? this.distanceOn,
        distanceMinKm: distanceMinKm ?? this.distanceMinKm,
        distanceMaxKm: distanceMaxKm ?? this.distanceMaxKm,
        sortOn: sortOn ?? this.sortOn,
        showDriverPermit: showDriverPermit ?? this.showDriverPermit,
        currency: currency,
      );

  /// Why it can't be saved, in the admin's words; null when it can.
  String? get problem {
    if (reportWindowDays < 1 || reportWindowDays > 365) return 'Reports: 1 to 365 days.';
    if (maxBlocksPerRider < 1 || maxBlocksPerRider > 500) return 'Blocks per rider: 1 to 500.';
    if (blockFlagRiders < 1 || blockFlagRiders > 100) return 'Flag after 1 to 100 riders.';
    if (minFareCap < 1 || minFareCap > 10000) return 'The minimum fare cap is 1 to 10,000.';
    if (distanceMinKm < 0.5 || distanceMaxKm > 200) return 'Pickup distance: 0.5 to 200 km.';
    if (distanceMinKm > distanceMaxKm) return 'The shortest pickup distance is more than the longest.';
    return null;
  }

  /// The limits line on the admin's filter card.
  String get limitsLine =>
      'Limits: minimum fare filter up to ${formatMoney(minFareCap, currency, 0)}; '
      'pickup distance ${_km(distanceMinKm)} to ${_km(distanceMaxKm)} km.';
}

String _km(double km) => km == km.roundToDouble() ? '${km.round()}' : km.toStringAsFixed(1);

// ---- Report categories -----------------------------------------------------------------------------

/// A row of `trip_report_categories`.
class TripReportCategory {
  const TripReportCategory({
    this.id,
    required this.label,
    this.urgent = false,
    this.sosReminder = false,
    this.position = 0,
    this.active = true,
  });

  final String? id;
  final String label;
  final bool urgent;
  final bool sosReminder;
  final int position;
  final bool active;

  factory TripReportCategory.fromJson(Map<String, dynamic> r) => TripReportCategory(
        id: _text(r['id']),
        label: _text(r['label']) ?? 'Other',
        urgent: _bool(r['urgent'], false),
        sosReminder: _bool(r['sos_reminder'], false),
        position: _int(r['position']) ?? 0,
        active: _bool(r['active'], true),
      );

  Map<String, dynamic> toRow() => {
        'label': label.trim(),
        'urgent': urgent,
        'sos_reminder': sosReminder,
        'position': position,
        'active': active,
      };

  TripReportCategory copyWith({String? label, bool? urgent, bool? sosReminder, int? position, bool? active}) =>
      TripReportCategory(
        id: id,
        label: label ?? this.label,
        urgent: urgent ?? this.urgent,
        sosReminder: sosReminder ?? this.sosReminder,
        position: position ?? this.position,
        active: active ?? this.active,
      );
}

/// Why [label] can't name a category among [others] (the active ones, this
/// one left out); null when it can.
String? categoryLabelProblem(String label, Iterable<TripReportCategory> others) {
  final l = label.trim();
  if (l.isEmpty) return 'Give the category a name.';
  if (l.length > 40) return 'Up to 40 characters.';
  if (others.any((c) => c.active && c.label.trim().toLowerCase() == l.toLowerCase())) {
    return 'There is a category called $l already.';
  }
  return null;
}

/// The reminder under a category that shows it (Safety).
const sosReminderText = 'Safety reports go to the safety team first, any time of day. In danger now? Use SOS.';

// ---- The receipt -----------------------------------------------------------------------------------

/// Passenger cover from `passenger_cover_for`.
class PassengerCover {
  const PassengerCover({
    required this.insurer,
    required this.policyNo,
    required this.coverAmount,
    this.currency = 'MYR',
    this.claimDays,
    this.hotline,
    this.termsUrl,
    this.place,
  });

  final String insurer;
  final String policyNo;
  final double coverAmount;
  final String currency;
  final int? claimDays;
  final String? hotline;
  final String? termsUrl;
  final String? place;

  /// Only a rule that is on and has real details ([shown] from the server,
  /// checked again here); null otherwise.
  static PassengerCover? fromJson(Object? v) {
    if (v is! Map) return null;
    final shown = _bool(v['shown'], true);
    final insurer = _text(v['insurer']);
    final policy = _text(v['policy_no']);
    final amount = _num(v['cover_amount']);
    if (!shown || insurer == null || policy == null || amount == null || amount <= 0) return null;
    return PassengerCover(
      insurer: insurer,
      policyNo: policy,
      coverAmount: amount,
      currency: _text(v['currency']) ?? 'MYR',
      claimDays: _int(v['claim_days']),
      hotline: _text(v['hotline']),
      termsUrl: _text(v['terms_url']),
      place: _text(v['place']),
    );
  }

  /// "Passenger personal accident cover by Contoh Takaful, policy PA-2026-0001, up to RM 50,000."
  String get coverLine =>
      'Passenger personal accident cover by $insurer, policy $policyNo, up to ${formatMoney(coverAmount, currency, 0)}.';

  /// How to claim, as the admin set it.
  String get claimLine {
    final hotlinePart = hotline == null ? '' : ' or call $hotline';
    final days = claimDays == null ? '' : ' within $claimDays ${claimDays == 1 ? 'day' : 'days'}';
    return 'To claim: report the trip below$hotlinePart$days. Cover details are set by the admin per region.';
  }
}

/// A driver's or vehicle's approved permit shown to passengers (0254).
class DriverPermitInfo {
  const DriverPermitInfo({required this.name, this.shortName, this.issuer, this.number, this.validUntil});

  final String name;
  final String? shortName;
  final String? issuer;
  final String? number;

  /// `yyyy-mm-dd`, as stored.
  final String? validUntil;

  factory DriverPermitInfo.fromJson(Map<String, dynamic> r) => DriverPermitInfo(
        name: _text(r['name']) ?? 'Permit',
        shortName: _text(r['short_name']),
        issuer: _text(r['issuer']),
        number: _text(r['number']),
        validUntil: _text(r['valid_until']),
      );

  /// "Driver licensed by APAD: E-hailing vehicle permit (eVP) valid to 30/06/2027."
  String line({DateOrder? order}) {
    final by = issuer == null ? 'Driver licensed' : 'Driver licensed by $issuer';
    final until = validUntil == null ? '' : ' valid to ${formatStoredDateForUser(validUntil, order: order)}';
    return '$by: $name$until.';
  }
}

/// The trip as the server words it for a report.
class SafetyTrip {
  const SafetyTrip({required this.ref, this.driverId, this.driverName, this.vehicle, this.route, this.completed = false});

  final String ref;
  final String? driverId;
  final String? driverName;
  final String? vehicle;
  final String? route;
  final bool completed;

  factory SafetyTrip.fromJson(Map<String, dynamic> r) => SafetyTrip(
        ref: _text(r['ref']) ?? '',
        driverId: _text(r['driver_id']),
        driverName: _text(r['driver_name']),
        vehicle: _text(r['vehicle']),
        route: _text(r['route']),
        completed: _bool(r['completed'], false),
      );

  /// "Hafiz R.", or "this driver".
  String get driverLabel => driverName ?? 'this driver';
}

/// An earlier, still open report of the trip.
typedef OpenReport = ({String ticketId, int? number, String? category});

/// `trip_safety_info`: the receipt's safety part, for the trip's rider.
class TripSafetyInfo {
  const TripSafetyInfo({
    required this.trip,
    this.canReport = false,
    this.reportUntil,
    this.reportWindowDays = 30,
    this.report,
    this.categories = const [],
    this.blocked = false,
    this.cover,
    this.permits = const [],
  });

  final SafetyTrip trip;
  final bool canReport;
  final DateTime? reportUntil;
  final int reportWindowDays;
  final OpenReport? report;
  final List<TripReportCategory> categories;
  final bool blocked;
  final PassengerCover? cover;
  final List<DriverPermitInfo> permits;

  /// Null for anyone but the trip's rider (the server answers null).
  static TripSafetyInfo? fromJson(Object? v) {
    if (v is! Map) return null;
    final trip = v['trip'];
    if (trip is! Map) return null;
    final rep = v['report'];
    return TripSafetyInfo(
      trip: SafetyTrip.fromJson(Map<String, dynamic>.from(trip)),
      canReport: _bool(v['can_report'], false),
      reportUntil: _time(v['report_until']),
      reportWindowDays: _int(v['report_window_days']) ?? 30,
      report: rep is Map && _text(rep['ticket_id']) != null
          ? (ticketId: _text(rep['ticket_id'])!, number: _int(rep['ticket_number']), category: _text(rep['category']))
          : null,
      categories: [
        if (v['categories'] is List)
          for (final c in v['categories'] as List)
            if (c is Map) TripReportCategory.fromJson(Map<String, dynamic>.from(c)),
      ],
      blocked: _bool(v['blocked'], false),
      cover: PassengerCover.fromJson(v['cover']),
      permits: [
        if (v['permits'] is List)
          for (final p in v['permits'] as List)
            if (p is Map) DriverPermitInfo.fromJson(Map<String, dynamic>.from(p)),
      ],
    );
  }

  /// Whether the receipt shows the "You were covered on this trip" card.
  bool get showsCoverCard => cover != null || permits.isNotEmpty;

  /// The card's text: the cover line, then the permit line.
  String coverText({DateOrder? order}) => [
        if (cover != null) cover!.coverLine,
        for (final p in permits) p.line(order: order),
      ].join(' ');

  /// The card's title: covered, or just the permit.
  String get coverTitle => cover != null ? 'You were covered on this trip' : 'Your driver\'s permit';

  TripSafetyInfo copyWith({bool? blocked, OpenReport? report, bool? canReport}) => TripSafetyInfo(
        trip: trip,
        canReport: canReport ?? this.canReport,
        reportUntil: reportUntil,
        reportWindowDays: reportWindowDays,
        report: report ?? this.report,
        categories: categories,
        blocked: blocked ?? this.blocked,
        cover: cover,
        permits: permits,
      );
}

/// What `trip_report_create` answered.
class TripReportResult {
  const TripReportResult({
    required this.ticketId,
    this.number,
    this.category,
    this.urgent = false,
    this.blocked = false,
    this.blockError,
  });

  final String ticketId;
  final int? number;
  final String? category;
  final bool urgent;
  final bool blocked;
  final String? blockError;

  factory TripReportResult.fromJson(Object? v) {
    final m = v is Map ? v : const {};
    return TripReportResult(
      ticketId: '${m['ticket_id'] ?? ''}',
      number: _int(m['ticket_number']),
      category: _text(m['category']),
      urgent: _bool(m['urgent'], false),
      blocked: _bool(m['blocked'], false),
      blockError: _text(m['block_error']),
    );
  }

  /// "Report sent: ticket #10233 (Safety). Support replies in Help › My tickets. Hafiz R. is blocked."
  String message(String driver) {
    final no = number == null ? '' : ' #$number';
    final cat = category == null ? '' : ' ($category)';
    return [
      'Report sent: ticket$no$cat. Support replies in Help › My tickets.',
      if (blocked) '$driver is blocked.',
      if (blockError != null) 'We couldn\'t block $driver: $blockError',
    ].join(' ');
  }
}

/// The block sheet's words.
String blockSheetText(String driver) =>
    'You won\'t be matched with $driver again: they won\'t see your requests and you won\'t get their offers. '
    'They aren\'t told. You can unblock them in Settings › Blocked drivers.';

// ---- Blocked drivers -------------------------------------------------------------------------------

/// A row of `my_blocked_drivers`.
class BlockedDriver {
  const BlockedDriver({required this.driverId, required this.name, this.photo, this.vehicle, this.blockedAt});

  final String driverId;
  final String name;
  final String? photo;
  final String? vehicle;
  final DateTime? blockedAt;

  factory BlockedDriver.fromJson(Map<String, dynamic> r) => BlockedDriver(
        driverId: '${r['driver_id'] ?? ''}',
        name: _text(r['name']) ?? 'Driver',
        photo: _text(r['photo']),
        vehicle: _text(r['vehicle']),
        blockedAt: _time(r['blocked_at']),
      );

  /// "Perodua Bezza · WXY 1234 · blocked 12/05/2027".
  String subtitle({DateOrder? order}) => [
        ?vehicle,
        if (blockedAt != null) 'blocked ${formatDateForUser(blockedAt!.toLocal(), order: order)}',
      ].join(' · ');
}

// ---- Driver request filters -------------------------------------------------------------------------

/// How the driver's list is sorted. Nearest first (distance) is how the
/// list always read, and stays the default.
enum RequestSort {
  newest('newest', 'Newest'),
  price('price', 'Price'),
  distance('distance', 'Distance');

  const RequestSort(this.key, this.label);
  final String key;
  final String label;

  static RequestSort parse(Object? v) =>
      RequestSort.values.where((s) => s.key == '$v').firstOrNull ?? RequestSort.distance;
}

/// The step of the minimum fare (RM 5) and the pickup distance (1 km).
const requestFareStep = 5.0;
const requestKmStep = 1.0;

/// The driver's filters (`driver_request_filters`, and on the phone).
class RequestFilters {
  const RequestFilters({this.minFare = 0, this.maxKm, this.sort = RequestSort.distance});

  /// 0: any fare.
  final double minFare;

  /// Null: any distance.
  final double? maxKm;
  final RequestSort sort;

  static const none = RequestFilters();

  factory RequestFilters.fromJson(Object? v) {
    if (v is! Map) return none;
    return RequestFilters(
      minFare: _num(v['min_fare']) ?? 0,
      maxKm: _num(v['max_km']),
      sort: RequestSort.parse(v['sort']),
    );
  }

  Map<String, dynamic> toJson() => {'min_fare': minFare, 'max_km': maxKm, 'sort': sort.key};

  RequestFilters copyWith({double? minFare, double? maxKm, bool anyDistance = false, RequestSort? sort}) =>
      RequestFilters(
        minFare: minFare ?? this.minFare,
        maxKm: anyDistance ? null : (maxKm ?? this.maxKm),
        sort: sort ?? this.sort,
      );

  /// What applies under the admin's [s]: a filter the admin switched off is
  /// none, the rest kept within the limits.
  RequestFilters within(RideSafetySettings s) => RequestFilters(
        minFare: s.minFareOn ? minFare.clamp(0, s.minFareCap).toDouble() : 0,
        maxKm: !s.distanceOn || maxKm == null ? null : maxKm!.clamp(s.distanceMinKm, s.distanceMaxKm).toDouble(),
        sort: s.sortOn ? sort : RequestSort.distance,
      );

  /// Whether anything is filtered or sorted.
  bool get active => minFare > 0 || maxKm != null || sort != RequestSort.distance;

  /// The line under "Requests": "From RM 10 · within 5 km · by price", or
  /// "All requests near you, nearest first".
  String summary(String currency) {
    if (!active) return 'All requests near you, nearest first';
    return [
      if (minFare > 0) 'From ${formatMoney(minFare, currency, 0)}',
      if (maxKm != null) 'within ${_km(maxKm!)} km',
      switch (sort) {
        RequestSort.newest => 'newest first',
        RequestSort.price => 'highest fare first',
        RequestSort.distance => 'nearest first',
      },
    ].join(' · ');
  }

  @override
  bool operator ==(Object other) =>
      other is RequestFilters && other.minFare == minFare && other.maxKm == maxKm && other.sort == sort;

  @override
  int get hashCode => Object.hash(minFare, maxKm, sort);
}

/// [requests] the driver's [filters] keep, sorted, and how many they hid.
/// [exempt] ones (booked with this driver, assigned to them) always stay.
/// An unknown fare or distance is kept: hiding work over a missing number is
/// worse than showing too much. Newest keeps the order given (the server's,
/// newest first); price puts the highest fare first; distance the nearest.
({List<T> shown, int hidden}) applyRequestFilters<T>(
  List<T> requests,
  RequestFilters filters, {
  required double? Function(T) fare,
  required double? Function(T) awayKm,
  bool Function(T)? exempt,
}) {
  final shown = <T>[];
  var hidden = 0;
  for (final r in requests) {
    final keep = (exempt?.call(r) ?? false) ||
        ((filters.minFare <= 0 || (fare(r) ?? double.infinity) >= filters.minFare) &&
            (filters.maxKm == null || (awayKm(r) ?? 0) <= filters.maxKm!));
    if (keep) {
      shown.add(r);
    } else {
      hidden++;
    }
  }
  switch (filters.sort) {
    case RequestSort.newest:
      break;
    case RequestSort.price:
      _stableSort(shown, (a, b) => (fare(b) ?? 0).compareTo(fare(a) ?? 0));
    case RequestSort.distance:
      _stableSort(shown, (a, b) => (awayKm(a) ?? double.infinity).compareTo(awayKm(b) ?? double.infinity));
  }
  return (shown: shown, hidden: hidden);
}

void _stableSort<T>(List<T> list, int Function(T, T) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < indexed.length; i++) {
    list[i] = indexed[i].$2;
  }
}

/// The queue's order: nearest first ([destinationOrder], as it always was)
/// for [RequestSort.distance]; otherwise [items] as [applyRequestFilters]
/// sorted them, those toward the driver's destination first.
List<T> requestQueueOrder<T>(
  List<T> items,
  RequestSort sort, {
  required bool Function(T) toward,
  required double? Function(T) awayKm,
}) {
  if (sort == RequestSort.distance) return destinationOrder(items, toward: toward, awayKm: awayKm);
  return [for (final x in items) if (toward(x)) x, for (final x in items) if (!toward(x)) x];
}

/// "2 requests hidden by your filters".
String hiddenRequestsLine(int n) => '$n ${n == 1 ? 'request' : 'requests'} hidden by your filters';

// ---- Admin -----------------------------------------------------------------------------------------

/// A row of `admin_driver_safety_flags`, by driver (the partner's sign-in id).
class DriverSafetyFlag {
  const DriverSafetyFlag({this.reports = 0, this.urgent = 0, this.blocks = 0, this.blocksSinceReview = 0, this.flagged = false});

  final int reports;
  final int urgent;
  final int blocks;
  final int blocksSinceReview;
  final bool flagged;

  factory DriverSafetyFlag.fromJson(Map<String, dynamic> r) => DriverSafetyFlag(
        reports: _int(r['reports']) ?? 0,
        urgent: _int(r['urgent']) ?? 0,
        blocks: _int(r['blocks']) ?? 0,
        blocksSinceReview: _int(r['blocks_since_review']) ?? 0,
        flagged: _bool(r['flagged'], false),
      );

  /// The Partners list's words: "Reports: 3 (1 urgent) · Blocked by 4 riders, review".
  String? get line {
    final parts = [
      if (reports > 0) 'Reports: $reports${urgent > 0 ? ' ($urgent urgent)' : ''}',
      if (blocks > 0) 'Blocked by $blocks ${blocks == 1 ? 'rider' : 'riders'}${flagged ? ', review' : ''}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

Map<String, DriverSafetyFlag> driverSafetyFlagsByPartner(List<Map<String, dynamic>> rows) => {
      for (final r in rows)
        if ('${r['partner_id'] ?? ''}'.isNotEmpty) '${r['partner_id']}': DriverSafetyFlag.fromJson(r),
    };

/// One driver's reports and blocks (`admin_driver_safety`).
class AdminDriverSafety {
  const AdminDriverSafety({
    this.reports = const [],
    this.blocks = const [],
    this.blocksSinceReview = 0,
    this.flagRiders = 3,
    this.reviewedAt,
  });

  final List<({String ticketId, int? number, String category, bool urgent, String status, DateTime? at, String? rider})> reports;
  final List<({String? rider, DateTime? at, String source})> blocks;
  final int blocksSinceReview;
  final int flagRiders;
  final DateTime? reviewedAt;

  bool get flagged => blocksSinceReview >= flagRiders;

  factory AdminDriverSafety.fromJson(Object? v) {
    if (v is! Map) return const AdminDriverSafety();
    return AdminDriverSafety(
      reports: [
        if (v['reports'] is List)
          for (final r in v['reports'] as List)
            if (r is Map)
              (
                ticketId: '${r['ticket_id'] ?? ''}',
                number: _int(r['ticket_number']),
                category: _text(r['category']) ?? 'Report',
                urgent: _bool(r['urgent'], false),
                status: _text(r['status']) ?? 'open',
                at: _time(r['reported_at']),
                rider: _text(r['rider_name']),
              ),
      ],
      blocks: [
        if (v['blocks'] is List)
          for (final b in v['blocks'] as List)
            if (b is Map) (rider: _text(b['rider_name']), at: _time(b['blocked_at']), source: _text(b['source']) ?? 'receipt'),
      ],
      blocksSinceReview: _int(v['blocks_since_review']) ?? 0,
      flagRiders: _int(v['flag_riders']) ?? 3,
      reviewedAt: _time(v['reviewed_at']),
    );
  }
}

/// A passenger cover rule as the admin edits it (`passenger_cover_rules`).
class CoverRule {
  const CoverRule({
    this.id,
    this.country,
    this.state,
    this.city,
    this.enabled = true,
    this.insurer = '',
    this.policyNo = '',
    this.coverAmount,
    this.currency = 'MYR',
    this.claimDays,
    this.hotline = '',
    this.termsUrl = '',
  });

  final String? id;
  final String? country, state, city;
  final bool enabled;
  final String insurer;
  final String policyNo;
  final double? coverAmount;
  final String currency;
  final int? claimDays;
  final String hotline;
  final String termsUrl;

  factory CoverRule.fromJson(Map<String, dynamic> r) => CoverRule(
        id: _text(r['id']),
        country: _text(r['country']),
        state: _text(r['state']),
        city: _text(r['city']),
        enabled: _bool(r['enabled'], true),
        insurer: _text(r['insurer']) ?? '',
        policyNo: _text(r['policy_no']) ?? '',
        coverAmount: _num(r['cover_amount']),
        currency: _text(r['currency']) ?? 'MYR',
        claimDays: _int(r['claim_days']),
        hotline: _text(r['hotline']) ?? '',
        termsUrl: _text(r['terms_url']) ?? '',
      );

  Map<String, dynamic> toRow() => {
        'country': country,
        'state': state,
        'city': city,
        'enabled': enabled,
        'insurer': insurer.trim(),
        'policy_no': policyNo.trim(),
        'cover_amount': coverAmount,
        'currency': currency,
        'claim_days': claimDays,
        'hotline': hotline.trim(),
        'terms_url': termsUrl.trim(),
      };

  /// The default (no place) or the most specific place it names.
  bool get isDefault => country == null;
  String get placeLabel => isDefault ? 'Default (everywhere else)' : [city, state, country].whereType<String>().join(', ');

  /// How specific: city 3, state 2, country 1, the default 0.
  int get rank => city != null ? 3 : (state != null ? 2 : (country != null ? 1 : 0));

  /// Whether riders see it: on, with an insurer, a policy number and an amount.
  bool get hasDetails => insurer.trim().isNotEmpty && policyNo.trim().isNotEmpty && (coverAmount ?? 0) > 0;
  bool get shown => enabled && hasDetails;

  /// The admin list's summary.
  String get summary {
    if (!enabled) return 'Off: no cover shown here';
    if (!hasDetails) return 'On, but riders see nothing until it has an insurer, a policy number and an amount';
    return [
      'Insurer: $insurer',
      'Policy: $policyNo',
      'Cover: ${formatMoney(coverAmount, currency, 0)}',
      if (claimDays != null) 'Claim within $claimDays days',
      if (hotline.trim().isNotEmpty) 'Hotline ${hotline.trim()}',
      if (termsUrl.trim().isNotEmpty) 'Terms link',
    ].join(' · ');
  }

  /// Why it can't be saved; null when it can.
  String? get problem {
    if (state != null && country == null) return 'Pick the country of the state.';
    if (city != null && state == null) return 'Pick the state of the city.';
    if ((coverAmount ?? 0) < 0) return 'The cover amount can\'t be negative.';
    if (claimDays != null && (claimDays! < 1 || claimDays! > 3650)) return 'Claim days: 1 to 3650.';
    final t = termsUrl.trim();
    if (t.isNotEmpty && !RegExp(r'^https?://', caseSensitive: false).hasMatch(t)) {
      return 'The terms link starts with https://';
    }
    return null;
  }

  CoverRule copyWith({
    bool? enabled,
    String? insurer,
    String? policyNo,
    double? coverAmount,
    bool clearAmount = false,
    int? claimDays,
    bool clearDays = false,
    String? hotline,
    String? termsUrl,
  }) =>
      CoverRule(
        id: id,
        country: country,
        state: state,
        city: city,
        enabled: enabled ?? this.enabled,
        insurer: insurer ?? this.insurer,
        policyNo: policyNo ?? this.policyNo,
        coverAmount: clearAmount ? null : (coverAmount ?? this.coverAmount),
        currency: currency,
        claimDays: clearDays ? null : (claimDays ?? this.claimDays),
        hotline: hotline ?? this.hotline,
        termsUrl: termsUrl ?? this.termsUrl,
      );
}

/// The rule that applies to a place, as the server picks it: the most
/// specific one that holds it (even one that is off).
CoverRule? coverRuleFor(List<CoverRule> rules, {String? country, String? state, String? city}) {
  bool eq(String? rule, String? place) => rule == null || (place != null && rule.trim().toLowerCase() == place.trim().toLowerCase());
  CoverRule? best;
  for (final r in rules) {
    if (!eq(r.country, country) || !eq(r.state, state) || !eq(r.city, city)) continue;
    if (best == null || r.rank > best.rank) best = r;
  }
  return best;
}

// ---- Support ---------------------------------------------------------------------------------------

/// Whether a support ticket row is an urgent report still being handled.
bool ticketUrgentOpen(Map<String, dynamic> t) => t['priority'] == 'urgent' && t['status'] != 'closed';

/// Support's list order: urgent open reports first, then as given (newest
/// message first).
List<Map<String, dynamic>> urgentTicketsFirst(List<Map<String, dynamic>> tickets) {
  final urgent = [for (final t in tickets) if (ticketUrgentOpen(t)) t];
  return [...urgent, for (final t in tickets) if (!ticketUrgentOpen(t)) t];
}

/// The chip on a report's ticket: "Urgent · Safety", "Report · Fare"; null for other tickets.
String? ticketReportChip(Map<String, dynamic> t) {
  final cat = _text(t['report_category']);
  if (cat == null && t['reported_at'] == null) return null;
  return '${t['priority'] == 'urgent' ? 'Urgent' : 'Report'} · ${cat ?? 'Trip'}';
}
