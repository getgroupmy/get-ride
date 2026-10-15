// Handing a trip over mid-way (migration 0199): the driver asks, the
// passenger approves, another partner (asked by code, or the first nearby
// to accept) meets the car and finishes the trip. They collect the fare and
// pay the commission, and pass a share of the net to the first driver as
// GET credit when the trip completes.
import 'package:flutter/foundation.dart';

/// Admin → Trip handover. The share can be set per region too (Regions →
/// handoverSharePercent); this is the default.
@immutable
class TripHandoverConfig {
  const TripHandoverConfig({
    this.enabled = true,
    this.sharePercent = 10,
    this.nearbyRadiusKm = 5,
    this.answerMinutes = 5,
  });

  static const off = TripHandoverConfig(enabled: false);

  final bool enabled;

  /// Of the trip's net earnings, to the driver who handed it over.
  final double sharePercent;

  /// How far "nearby" partners are asked from.
  final double nearbyRadiusKm;

  /// How long the passenger, then the partners, have to answer.
  final int answerMinutes;

  factory TripHandoverConfig.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    double n(Object? v, double d) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? d;
    return TripHandoverConfig(
      enabled: m['enabled'] != false,
      sharePercent: n(m['sharePercent'], 10),
      nearbyRadiusKm: n(m['nearbyRadiusKm'], 5),
      answerMinutes: n(m['answerMinutes'], 5).round(),
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'sharePercent': sharePercent,
    'nearbyRadiusKm': nearbyRadiusKm,
    'answerMinutes': answerMinutes,
  };

  TripHandoverConfig copyWith({bool? enabled, double? sharePercent, double? nearbyRadiusKm, int? answerMinutes}) =>
      TripHandoverConfig(
        enabled: enabled ?? this.enabled,
        sharePercent: sharePercent ?? this.sharePercent,
        nearbyRadiusKm: nearbyRadiusKm ?? this.nearbyRadiusKm,
        answerMinutes: answerMinutes ?? this.answerMinutes,
      );

  /// Why it can't be saved, or null.
  String? get problem {
    if (sharePercent < 0 || sharePercent > 100) return 'The share is a percentage from 0 to 100.';
    if (nearbyRadiusKm < 0.5 || nearbyRadiusKm > 50) return 'Nearby is 0.5 to 50 km.';
    if (answerMinutes < 1 || answerMinutes > 30) return 'Answer time is 1 to 30 minutes.';
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is TripHandoverConfig &&
      other.enabled == enabled &&
      other.sharePercent == sharePercent &&
      other.nearbyRadiusKm == nearbyRadiusKm &&
      other.answerMinutes == answerMinutes;

  @override
  int get hashCode => Object.hash(enabled, sharePercent, nearbyRadiusKm, answerMinutes);
}

enum TripHandoverStatus {
  awaitingRider,
  offered,
  accepted,
  declinedRider,
  declinedDriver,
  cancelled,
  expired;

  static TripHandoverStatus parse(Object? v) => switch (v) {
    'awaiting_rider' => awaitingRider,
    'offered' => offered,
    'accepted' => accepted,
    'declined_rider' => declinedRider,
    'declined_driver' => declinedDriver,
    'cancelled' => cancelled,
    _ => expired,
  };

  /// Still waiting for the passenger or a partner.
  bool get open => this == awaitingRider || this == offered;
}

String _pct(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceAll(RegExp(r'0$'), '');

/// A handover the signed-in account is part of: as the driver who asked,
/// the partner who took it ([incoming]), or the passenger.
@immutable
class TripHandover {
  const TripHandover({
    required this.id,
    required this.rideId,
    required this.status,
    this.nearby = false,
    this.incoming = false,
    this.fromName,
    this.toName,
    this.note,
    this.answerBy,
    this.sharePercent,
    this.shareAmount,
    this.meetLat,
    this.meetLng,
    this.boardedAt,
  });

  final String id;
  final String rideId;
  final TripHandoverStatus status;

  /// Sent to partners nearby (else to one partner, by code).
  final bool nearby;

  /// The signed-in partner took (or was asked to take) it.
  final bool incoming;
  final String? fromName;
  final String? toName;
  final String? note;
  final DateTime? answerBy;
  final double? sharePercent;

  /// Moved when the trip completed; null until then.
  final double? shareAmount;
  final double? meetLat;
  final double? meetLng;
  final DateTime? boardedAt;

  static String? _s(Object? v) => (v as String?)?.trim().isEmpty ?? true ? null : (v as String).trim();
  static double? _n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

  factory TripHandover.fromRow(Map<String, dynamic> r) => TripHandover(
    id: '${r['id']}',
    rideId: '${r['ride_id']}',
    status: TripHandoverStatus.parse(r['status']),
    nearby: r['mode'] == 'nearby',
    incoming: r['incoming'] == true,
    fromName: _s(r['from_name']),
    toName: _s(r['to_name']),
    note: _s(r['note']),
    answerBy: DateTime.tryParse('${r['answer_by'] ?? ''}')?.toLocal(),
    sharePercent: _n(r['share_percent']),
    shareAmount: _n(r['share_amount']),
    meetLat: _n(r['meet_lat']),
    meetLng: _n(r['meet_lng']),
    boardedAt: DateTime.tryParse('${r['boarded_at'] ?? ''}')?.toLocal(),
  );

  /// Who would take the trip, as the passenger is told.
  String get whoTakesOver => nearby && toName == null ? 'another driver nearby' : toName ?? 'another driver';

  /// What the driver who asked reads while it is open, and after.
  String get driverStatusLabel => switch (status) {
    TripHandoverStatus.awaitingRider => 'Waiting for the passenger to approve',
    TripHandoverStatus.offered =>
      nearby
          ? 'Asking partners nearby: the first to accept takes it'
          : 'Waiting for ${toName ?? 'the partner'} to accept',
    TripHandoverStatus.accepted => '${toName ?? 'Another partner'} is taking over the trip',
    TripHandoverStatus.declinedRider => 'The passenger would rather you finish the trip',
    TripHandoverStatus.declinedDriver => 'No partner took it. Please carry on.',
    TripHandoverStatus.cancelled => 'You withdrew it',
    TripHandoverStatus.expired => 'No answer in time. Please carry on.',
  };

  /// The first driver's part of the net, as they are told.
  String shareLabel(String currency) {
    if (shareAmount != null) return '$currency ${shareAmount!.toStringAsFixed(2)} added to your GET credit';
    final p = sharePercent;
    return p == null
        ? "You'll get a share of the trip's net earnings"
        : "You'll get ${_pct(p)}% of the trip's net earnings";
  }
}

/// A trip a driver asks the signed-in partner (by code, or as one of those
/// nearby) to take over. The passenger isn't named.
@immutable
class HandoverOffer {
  const HandoverOffer({
    required this.id,
    required this.rideId,
    required this.answerBy,
    this.fromName,
    this.note,
    this.meetLat,
    this.meetLng,
    this.dropAddress,
    this.fare = 0,
    this.currency = 'RM',
    this.sharePercent = 0,
  });

  final String id;
  final String rideId;
  final DateTime answerBy;
  final String? fromName;
  final String? note;

  /// Where the car is.
  final double? meetLat;
  final double? meetLng;
  final String? dropAddress;
  final double fare;
  final String currency;

  /// Of the net, passed to the driver handing over.
  final double sharePercent;

  factory HandoverOffer.fromRow(Map<String, dynamic> r) => HandoverOffer(
    id: '${r['id']}',
    rideId: '${r['ride_id']}',
    answerBy: DateTime.tryParse('${r['answer_by'] ?? ''}')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
    fromName: TripHandover._s(r['from_name']),
    note: TripHandover._s(r['note']),
    meetLat: TripHandover._n(r['meet_lat']),
    meetLng: TripHandover._n(r['meet_lng']),
    dropAddress: TripHandover._s(r['drop_address']),
    fare: TripHandover._n(r['fare']) ?? 0,
    currency: TripHandover._s(r['currency']) ?? 'RM',
    sharePercent: TripHandover._n(r['share_percent']) ?? 0,
  );

  String get title => '${fromName ?? 'A driver'} needs you to take over a trip';

  /// "RM 42.00 fare · you pass 10% of the net to Ali".
  String get terms =>
      '$currency ${fare.toStringAsFixed(2)} fare · you collect it and pass '
      '${_pct(sharePercent)}% of the net to ${fromName ?? 'them'}';
}

/// The open handover in [all] for [rideId], else the latest one; null when none.
TripHandover? handoverForRide(List<TripHandover> all, String rideId) {
  TripHandover? latest;
  for (final h in all) {
    if (h.rideId != rideId) continue;
    if (h.status.open) return h;
    latest ??= h;
  }
  return latest;
}
