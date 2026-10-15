// Scheduled rides (migration 0189): the admin's settings, a booking as the
// app shows it, and the rules the booking screens apply. Pure.
import 'package:flutter/foundation.dart';

/// Admin → App Settings → Scheduled rides, as `scheduled_rides_config()`
/// returns it. Off until the admin turns it on.
@immutable
class ScheduledRidesConfig {
  const ScheduledRidesConfig({
    this.enabled = false,
    this.minLeadMinutes = 30,
    this.maxDaysAhead = 7,
    this.feeFixed = 0,
    this.feePercent = 0,
    this.feeToDriver = false,
    this.freeCancelMinutes = 60,
    this.lateCancelFee = 0,
    this.advance = false,
    this.releaseMinutes = 20,
    this.reminderMinutes = 60,
    this.interestNoticeMinutes = 60,
  });

  final bool enabled;

  /// The soonest a ride may be booked for, from now.
  final int minLeadMinutes;

  /// The furthest ahead a ride may be booked.
  final int maxDaysAhead;

  /// The scheduling fee: a fixed amount plus a percentage of the fare.
  final double feeFixed;
  final double feePercent;

  /// Who keeps the scheduling fee: the driver, or (false) the platform,
  /// which takes it back from the driver's GET credit after the trip.
  final bool feeToDriver;

  /// The rider cancels free until this long before pickup.
  final int freeCancelMinutes;

  /// Charged on a cancel after that; 0 for none.
  final double lateCancelFee;

  /// Drivers see bookings ahead and pre-accept them (Grab's Advance
  /// Booking); false: a booking reaches drivers when it is released.
  final bool advance;

  /// How long before pickup a booking goes out to drivers as a ride.
  final int releaseMinutes;

  /// The rider's reminder before pickup; 0 for none.
  final int reminderMinutes;

  /// How long before pickup drivers interested in a booking are told it is
  /// ready to accept (migration 0198); 0: never, so interest only shows.
  final int interestNoticeMinutes;

  static const off = ScheduledRidesConfig();

  factory ScheduledRidesConfig.fromJson(Object? json) {
    if (json is! Map) return off;
    double n(String k, double d) {
      final v = json[k];
      return v is num ? v.toDouble() : double.tryParse('$v') ?? d;
    }

    int i(String k, int d) => n(k, d.toDouble()).round();
    return ScheduledRidesConfig(
      enabled: json['enabled'] == true,
      minLeadMinutes: i('minLeadMinutes', 30),
      maxDaysAhead: i('maxDaysAhead', 7),
      feeFixed: n('feeFixed', 0),
      feePercent: n('feePercent', 0),
      feeToDriver: json['feeTo'] == 'driver',
      freeCancelMinutes: i('freeCancelMinutes', 60),
      lateCancelFee: n('lateCancelFee', 0),
      advance: json['mode'] == 'advance',
      releaseMinutes: i('releaseMinutes', 20),
      reminderMinutes: i('reminderMinutes', 60),
      interestNoticeMinutes: i('interestNoticeMinutes', 60),
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'minLeadMinutes': minLeadMinutes,
    'maxDaysAhead': maxDaysAhead,
    'feeFixed': feeFixed,
    'feePercent': feePercent,
    'feeTo': feeToDriver ? 'driver' : 'platform',
    'freeCancelMinutes': freeCancelMinutes,
    'lateCancelFee': lateCancelFee,
    'mode': advance ? 'advance' : 'release',
    'releaseMinutes': releaseMinutes,
    'reminderMinutes': reminderMinutes,
    'interestNoticeMinutes': interestNoticeMinutes,
  };

  ScheduledRidesConfig copyWith({
    bool? enabled,
    int? minLeadMinutes,
    int? maxDaysAhead,
    double? feeFixed,
    double? feePercent,
    bool? feeToDriver,
    int? freeCancelMinutes,
    double? lateCancelFee,
    bool? advance,
    int? releaseMinutes,
    int? reminderMinutes,
    int? interestNoticeMinutes,
  }) => ScheduledRidesConfig(
    enabled: enabled ?? this.enabled,
    minLeadMinutes: minLeadMinutes ?? this.minLeadMinutes,
    maxDaysAhead: maxDaysAhead ?? this.maxDaysAhead,
    feeFixed: feeFixed ?? this.feeFixed,
    feePercent: feePercent ?? this.feePercent,
    feeToDriver: feeToDriver ?? this.feeToDriver,
    freeCancelMinutes: freeCancelMinutes ?? this.freeCancelMinutes,
    lateCancelFee: lateCancelFee ?? this.lateCancelFee,
    advance: advance ?? this.advance,
    releaseMinutes: releaseMinutes ?? this.releaseMinutes,
    reminderMinutes: reminderMinutes ?? this.reminderMinutes,
    interestNoticeMinutes: interestNoticeMinutes ?? this.interestNoticeMinutes,
  );

  /// What is wrong with these settings, or null: the server's own limits.
  String? get problem {
    if (minLeadMinutes < 5 || minLeadMinutes > 1440) return 'The soonest booking must be 5–1440 minutes ahead.';
    if (maxDaysAhead < 1 || maxDaysAhead > 30) return 'Bookings may be made 1–30 days ahead.';
    if (feeFixed < 0 || feeFixed > 1000) return 'The fixed fee must be 0–1000.';
    if (feePercent < 0 || feePercent > 100) return 'The fee percentage must be 0–100.';
    if (freeCancelMinutes < 0 || freeCancelMinutes > 1440) return 'Free cancellation must be 0–1440 minutes.';
    if (lateCancelFee < 0 || lateCancelFee > 1000) return 'The late cancellation fee must be 0–1000.';
    if (releaseMinutes < 5 || releaseMinutes > 180) return 'Release must be 5–180 minutes before pickup.';
    if (reminderMinutes < 0 || reminderMinutes > 1440) return 'The reminder must be 0–1440 minutes before pickup.';
    if (interestNoticeMinutes < 0 || interestNoticeMinutes > 1440) {
      return 'The ready-to-accept notice must be 0–1440 minutes before pickup.';
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is ScheduledRidesConfig && mapEquals(other.toJson(), toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);
}

double _cents(double v) => (v * 100).roundToDouble() / 100;

/// The scheduling fee on a ride of [fare]: the fixed part plus the
/// percentage, to the cent, as the server works it out.
double schedulingFee(double fare, ScheduledRidesConfig c) => _cents(c.feeFixed + fare * c.feePercent / 100);

/// The soonest pickup that can be booked at [now], on the next 5 minutes.
DateTime earliestPickup(DateTime now, ScheduledRidesConfig c) {
  final t = now.add(Duration(minutes: c.minLeadMinutes + 1));
  final extra = (5 - t.minute % 5) % 5;
  return DateTime(t.year, t.month, t.day, t.hour, t.minute + extra);
}

/// The furthest pickup that can be booked at [now].
DateTime latestPickup(DateTime now, ScheduledRidesConfig c) => now.add(Duration(days: c.maxDaysAhead));

/// Why [at] can't be booked at [now], or null.
String? pickupTimeProblem(DateTime at, DateTime now, ScheduledRidesConfig c) {
  if (at.isBefore(now.add(Duration(minutes: c.minLeadMinutes)))) {
    return 'Pick a time at least ${c.minLeadMinutes} minutes from now.';
  }
  if (at.isAfter(latestPickup(now, c))) {
    return 'Rides can be booked up to ${c.maxDaysAhead} ${c.maxDaysAhead == 1 ? 'day' : 'days'} ahead.';
  }
  return null;
}

/// Whether cancelling at [now] is past the free window.
bool isLateCancel(DateTime pickupAt, DateTime now, ScheduledRidesConfig c) =>
    now.isAfter(pickupAt.subtract(Duration(minutes: c.freeCancelMinutes)));

/// The fee for cancelling at [now]: 0 while it is free.
double cancelFeeAt(DateTime pickupAt, DateTime now, ScheduledRidesConfig c) =>
    isLateCancel(pickupAt, now, c) ? c.lateCancelFee : 0;

/// When a booking stops being free to cancel.
DateTime freeCancelUntil(DateTime pickupAt, ScheduledRidesConfig c) =>
    pickupAt.subtract(Duration(minutes: c.freeCancelMinutes));

enum ScheduledStatus { scheduled, assigned, released, completed, cancelled, expired }

ScheduledStatus scheduledStatusOf(Object? v) =>
    ScheduledStatus.values.firstWhere((s) => s.name == v, orElse: () => ScheduledStatus.scheduled);

/// A booking (a `scheduled_rides` row), for the rider, the driver who took
/// it, or an admin.
@immutable
class ScheduledRide {
  const ScheduledRide({
    required this.id,
    required this.pickupAt,
    required this.status,
    this.riderId,
    this.service,
    this.pickupAddress,
    this.dropAddress,
    this.fare = 0,
    this.schedulingFee = 0,
    this.currency,
    this.bookedForName,
    this.bookedForPhone,
    this.partnerId,
    this.rideId,
    this.distanceKm,
    this.cancelFee = 0,
    this.cancelFeeStatus = 'none',
    this.cancelledBy,
  });

  final String id;
  final DateTime pickupAt;
  final ScheduledStatus status;
  final String? riderId;
  final String? service;
  final String? pickupAddress;
  final String? dropAddress;
  final double fare;
  final double schedulingFee;
  final String? currency;
  final String? bookedForName;
  final String? bookedForPhone;
  final String? partnerId;

  /// The ride it became, once released.
  final String? rideId;
  final double? distanceKm;
  final double cancelFee;

  /// none, charged (from the GET wallet), due (owed), billed (on a later
  /// ride) or paid.
  final String cancelFeeStatus;
  final String? cancelledBy;

  static double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  factory ScheduledRide.fromRow(Map<String, dynamic> r) => ScheduledRide(
    id: '${r['id']}',
    pickupAt: DateTime.tryParse('${r['pickup_at']}')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
    status: scheduledStatusOf(r['status']),
    riderId: r['rider_id'] as String?,
    service: r['service'] as String?,
    pickupAddress: r['pickup_address'] as String?,
    dropAddress: r['drop_address'] as String?,
    fare: _num(r['fare']),
    schedulingFee: _num(r['scheduling_fee']),
    currency: r['currency'] as String?,
    bookedForName: r['booked_for_name'] as String?,
    bookedForPhone: r['booked_for_phone'] as String?,
    partnerId: r['partner_id'] as String?,
    rideId: r['ride_id'] as String?,
    distanceKm: r['distance_km'] == null ? null : _num(r['distance_km']),
    cancelFee: _num(r['cancel_fee']),
    cancelFeeStatus: (r['cancel_fee_status'] as String?) ?? 'none',
    cancelledBy: r['cancelled_by'] as String?,
  );

  /// Still to happen: the rider can cancel it.
  bool get upcoming =>
      status == ScheduledStatus.scheduled || status == ScheduledStatus.assigned || status == ScheduledStatus.released;

  bool get driverConfirmed => partnerId != null && status != ScheduledStatus.scheduled;

  /// What the rider pays for the ride (before tolls and taxes).
  double get total => _cents(fare + schedulingFee);
}

/// The booking's state in a few words, for its card.
String scheduledStatusLabel(ScheduledRide r) => switch (r.status) {
  ScheduledStatus.scheduled => 'Booked · finding a driver nearer the time',
  ScheduledStatus.assigned => 'Driver confirmed',
  ScheduledStatus.released => r.partnerId != null ? 'Your driver is on the way' : 'Finding your driver now',
  ScheduledStatus.completed => 'Completed',
  ScheduledStatus.cancelled => switch (r.cancelFeeStatus) {
    'charged' => 'Cancelled · late fee charged',
    'due' || 'billed' => 'Cancelled · late fee added to your next ride',
    'paid' => 'Cancelled · late fee paid',
    _ => 'Cancelled',
  },
  ScheduledStatus.expired => 'No driver was found · not charged',
};

/// The server's refusal (SCHEDULED_* with a hint) as one sentence.
String scheduleErrorMessage(String message, {String? hint}) {
  if (hint != null && hint.trim().isNotEmpty) return hint.trim();
  // Not SCHEDULED_OFFER_GONE, which starts the same.
  if (RegExp(r'SCHEDULED_OFF\b').hasMatch(message)) return 'Scheduled rides are not available.';
  if (message.contains('SCHEDULED_TIME')) return 'Pick another pickup time.';
  if (message.contains('SCHEDULED_LIMIT')) return 'You already have 5 upcoming rides.';
  if (message.contains('SCHEDULED_TAKEN')) return 'Another driver has taken this ride.';
  if (message.contains('SCHEDULED_CLASH')) return 'You already have a ride within an hour of this one.';
  if (message.contains('SCHEDULED_ON_TRIP')) return 'The trip has already started.';
  if (message.contains('SCHEDULED_CLOSED')) return 'This booking can no longer be cancelled.';
  if (message.contains('SCHEDULED_NOT_ADVANCE')) return "Mark it as interested: you'll be told when you can accept it.";
  if (message.contains('SCHEDULED_TOO_LATE')) return 'It is too close to pickup for that.';
  if (message.contains('SCHEDULED_OFFER_GONE')) return 'This request is no longer open.';
  if (message.contains('SCHEDULED_CODE_SELF')) return 'That is your own code.';
  if (message.contains('SCHEDULED_CODE_WAIT')) return "Too many codes that didn't match. Try again later.";
  if (message.contains('SCHEDULED_CODE')) return "Check the driver's My Ride code, or scan their GET.me QR.";
  if (message.contains('RIDE_FARE_INVALID')) return 'The fare could not be worked out. Please try again.';
  return message;
}

// ---- Upcoming bookings, interest and handovers (migration 0198) ----------------------------

/// A booking no driver has yet, as a driver sees it on Upcoming: whether
/// they marked it, and whether (and from when) they may accept it.
@immutable
class UpcomingBooking {
  const UpcomingBooking({required this.ride, this.interested = false, this.canAccept = false, this.acceptFrom});

  final ScheduledRide ride;
  final bool interested;

  /// Advance booking, or interested and told it is ready.
  final bool canAccept;

  /// When an interested driver is told it is ready; null with advance
  /// booking (always open) or with the notice off.
  final DateTime? acceptFrom;

  factory UpcomingBooking.fromRow(Map<String, dynamic> r) => UpcomingBooking(
    ride: ScheduledRide.fromRow({...r, 'status': 'scheduled'}),
    interested: r['interested'] == true,
    canAccept: r['can_accept'] == true,
    acceptFrom: DateTime.tryParse('${r['accept_from'] ?? ''}')?.toLocal(),
  );
}

/// A driver handing a booking over (transfer) or a passenger asking a
/// driver (assign), still waiting for that driver's answer.
enum ScheduledOfferKind { transfer, assign }

@immutable
class ScheduledOffer {
  const ScheduledOffer({
    required this.id,
    required this.kind,
    required this.incoming,
    required this.expiresAt,
    required this.ride,
    this.otherName,
  });

  final String id;
  final ScheduledOfferKind kind;

  /// Sent to the signed-in driver (else made by them, or by the passenger).
  final bool incoming;

  /// The other side: the driver handing over, or the driver asked. Null for
  /// the passenger, who isn't named.
  final String? otherName;
  final DateTime expiresAt;

  /// The booking, as the driver asked needs it.
  final ScheduledRide ride;

  factory ScheduledOffer.fromRow(Map<String, dynamic> r) => ScheduledOffer(
    id: '${r['id']}',
    kind: r['kind'] == 'transfer' ? ScheduledOfferKind.transfer : ScheduledOfferKind.assign,
    incoming: r['incoming'] == true,
    otherName: (r['other_name'] as String?)?.trim().isEmpty ?? true ? null : (r['other_name'] as String).trim(),
    expiresAt: DateTime.tryParse('${r['expires_at']}')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
    ride: ScheduledRide.fromRow({...r, 'id': r['scheduled_ride_id'], 'status': 'scheduled'}),
  );

  /// What the driver asked reads: who wants what.
  String get incomingTitle => switch (kind) {
    ScheduledOfferKind.transfer => '${otherName ?? 'A driver'} wants to hand this ride to you',
    ScheduledOfferKind.assign => 'A passenger chose you for this ride',
  };

  /// What the one who asked reads while waiting.
  String get waitingLabel => 'Waiting for ${otherName ?? 'the driver'} to accept';
}

/// "Today", "Tomorrow" or "Fri 16 Oct": the day headings on Upcoming.
String bookingDayLabel(DateTime at, DateTime now) {
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${days[at.weekday - 1]} ${at.day} ${months[at.month - 1]}';
}

/// [items] in runs of the same day, keeping their order (soonest first).
List<(String, List<T>)> groupByBookingDay<T>(List<T> items, DateTime Function(T) at, DateTime now) {
  final out = <(String, List<T>)>[];
  for (final item in items) {
    final label = bookingDayLabel(at(item), now);
    if (out.isEmpty || out.last.$1 != label) {
      out.add((label, [item]));
    } else {
      out.last.$2.add(item);
    }
  }
  return out;
}
