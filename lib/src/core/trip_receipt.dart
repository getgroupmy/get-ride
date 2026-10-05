/// The receipt for one finished ride request (Expo `app/ride-detail.tsx`),
/// read from the stored row rather than passed along by the screen that
/// ended the trip, so it can be opened again from the trip list.
library;

import 'package:intl/intl.dart';

import '../data/models.dart';
import 'format.dart';

/// A stable booking number for a request: "GR-" and the first eight
/// characters of its id. Expo made one up at random on every open, so the
/// same trip printed a different number each time.
String tripBookingNo(String id) {
  final hex = id.replaceAll('-', '').toUpperCase();
  return 'GR-${hex.length >= 8 ? hex.substring(0, 8) : hex}';
}

/// One priced line on the receipt.
typedef ReceiptLine = ({String label, double amount});

class TripReceipt {
  const TripReceipt({
    required this.bookingNo,
    required this.status,
    required this.currency,
    required this.pickup,
    required this.drop,
    required this.lines,
    required this.charged,
    this.date,
    this.startedAt,
    this.endedAt,
    this.distanceKm,
    this.service,
    this.paymentMode,
    this.counterpartLabel,
    this.counterpart,
    this.vehicle,
    this.cancelReason,
  });

  final String bookingNo;
  final RideStatus status;
  final String currency;
  final String pickup;
  final String drop;

  /// Trip fare, then any tolls and other charges recorded on the ride.
  final List<ReceiptLine> lines;

  /// False for a cancelled or expired request: nothing was billed.
  final bool charged;

  final DateTime? date;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final double? distanceKm;
  final String? service;
  final String? paymentMode;

  /// "Driver" on the rider's copy, "Passenger" on the driver's.
  final String? counterpartLabel;
  final String? counterpart;
  final String? vehicle;
  final String? cancelReason;

  double get total => charged ? lines.fold(0, (s, l) => s + l.amount) : 0;

  /// Minutes between pickup and drop-off, when both were stamped.
  int? get tripMinutes {
    if (startedAt == null || endedAt == null) return null;
    final m = endedAt!.difference(startedAt!).inMinutes;
    return m < 0 ? null : m;
  }

  String get statusLabel => switch (status) {
    RideStatus.completed => 'Completed',
    RideStatus.cancelled => 'Cancelled',
    RideStatus.expired => 'Expired',
    _ => status.label,
  };

  /// Builds the receipt for [r] as seen by the rider, or by the driver when
  /// [asDriver] is set.
  factory TripReceipt.fromRide(RideRequest r, {bool asDriver = false}) {
    final charged = r.status == RideStatus.completed;
    final fare = r.effectiveFare ?? 0;
    final tolls = r.tollCharges ?? 0;
    final other = r.otherCharges ?? 0;
    final vehicle = [r.partnerVehicle, r.partnerPlate].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    return TripReceipt(
      bookingNo: tripBookingNo(r.id),
      status: r.status,
      currency: r.currency,
      pickup: r.pickupLabel,
      drop: r.dropLabel,
      lines: [
        (label: 'Trip fare', amount: fare),
        if (tolls > 0) (label: 'Tolls', amount: tolls),
        if (other > 0) (label: 'Other charges', amount: other),
      ],
      charged: charged,
      date: r.completedAt ?? r.cancelledAt ?? r.createdAt,
      startedAt: r.startedAt,
      endedAt: r.completedAt,
      distanceKm: r.distanceKm,
      service: r.service,
      paymentMode: r.paymentMode,
      counterpartLabel: asDriver ? 'Passenger' : 'Driver',
      counterpart: asDriver ? r.riderName : r.partnerName,
      vehicle: asDriver || vehicle.isEmpty ? null : vehicle,
      cancelReason: r.status == RideStatus.cancelled ? r.cancelReason : null,
    );
  }

  /// Label/value rows shared by the screen, the PDF and the share text.
  List<(String, String)> get details => [
    ('Booking no.', bookingNo),
    ('Status', statusLabel),
    if (date != null) ('Date', DateFormat('d MMM yyyy, h:mm a').format(date!.toLocal())),
    if (service != null) ('Service', service!),
    if (startedAt != null) ('Picked up', DateFormat('h:mm a').format(startedAt!.toLocal())),
    if (endedAt != null) ('Dropped off', DateFormat('h:mm a').format(endedAt!.toLocal())),
    if (tripMinutes != null) ('Trip time', formatDuration(tripMinutes)),
    if (distanceKm != null) ('Distance', formatDistance(distanceKm)),
    if (counterpart != null && counterpart!.trim().isNotEmpty) (counterpartLabel ?? 'Driver', counterpart!.trim()),
    if (vehicle != null) ('Vehicle', vehicle!),
    if (paymentMode != null) ('Payment', paymentMode!),
    if (cancelReason != null && cancelReason!.trim().isNotEmpty) ('Reason', cancelReason!.trim()),
  ];

  /// Plain text for sharing or the clipboard.
  String get text {
    final b = StringBuffer()
      ..writeln('GET.ride trip receipt')
      ..writeln('$pickup → $drop');
    for (final (k, v) in details) {
      b.writeln('$k: $v');
    }
    if (charged) {
      for (final l in lines) {
        b.writeln('${l.label}: ${formatMoney(l.amount, currency)}');
      }
      b.writeln('Total: ${formatMoney(total, currency)}');
    } else {
      b.writeln('No charge');
    }
    return b.toString().trimRight();
  }
}
