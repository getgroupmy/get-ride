// What a finished hire becomes: the driver's end-of-hire declaration, the
// stored trip record and its receipt. Ported from the Expo app's
// `utils/meterTripDetails.ts`, `utils/meterTripsStore.ts` (the pure half) and
// `utils/meterReceipt.ts`.
import 'dart:math' as math;

import 'taxi_meter.dart';

const airportSurcharge = 3.0;
const minPax = 1, maxPax = 8;
const minLuggage = 0, maxLuggage = 6;
const maxCharges = 99.5;

enum MeterAirport { none, pickup, dropoff }

double _round2(double n) => (n * 100).round() / 100;

int? _clampCount(Object? v, int min, int max) => v is num && v.isFinite ? v.round().clamp(min, max) : null;
int? clampPax(Object? v) => _clampCount(v, minPax, maxPax);
int? clampLuggage(Object? v) => _clampCount(v, minLuggage, maxLuggage);

double sanitizeCharges(Object? v) => v is num && v.isFinite ? _round2(v.toDouble().clamp(0.0, maxCharges)) : 0;

/// Keeps what can be a money amount: digits and one decimal point (a comma
/// counts as one), at most four whole digits and two decimals.
String sanitizeChargesText(String text) {
  final cleaned = text.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.]'), '');
  final parts = cleaned.split('.');
  final head = parts.first.length > 4 ? parts.first.substring(0, 4) : parts.first;
  if (parts.length == 1) return head;
  final tail = parts.skip(1).join();
  return '$head.${tail.length > 2 ? tail.substring(0, 2) : tail}';
}

double chargesFromText(String text) => sanitizeCharges(double.tryParse(sanitizeChargesText(text)) ?? 0);

String chargesToText(double v) {
  final a = sanitizeCharges(v);
  return a > 0 ? a.toStringAsFixed(2) : '';
}

/// The end-of-hire form. Nothing is pre-selected: a defaulted "1 passenger,
/// no bags" would be the meter guessing on the passenger's receipt.
class MeterTripDetailsDraft {
  const MeterTripDetailsDraft({this.pax, this.luggage, this.charges = 0, this.airport});
  final int? pax;
  final int? luggage;
  final double charges;
  final MeterAirport? airport;

  MeterTripDetailsDraft copyWith({int? pax, int? luggage, double? charges, MeterAirport? airport}) =>
      MeterTripDetailsDraft(
        pax: pax ?? this.pax,
        luggage: luggage ?? this.luggage,
        charges: charges ?? this.charges,
        airport: airport ?? this.airport,
      );
}

class MeterTripDetails {
  const MeterTripDetails({
    required this.pax,
    required this.luggage,
    required this.charges,
    required this.airport,
    required this.airportSurcharge,
  });
  final int pax;
  final int luggage;
  final double charges;
  final MeterAirport airport;
  final double airportSurcharge;
}

List<String> missingTripDetails(MeterTripDetailsDraft d) => [
      if (clampPax(d.pax) == null) 'passengers',
      if (clampLuggage(d.luggage) == null) 'luggage',
      if (d.airport == null) 'airport',
    ];

String? describeMissingTripDetails(MeterTripDetailsDraft d) {
  final m = missingTripDetails(d);
  return m.isEmpty ? null : 'Still to declare: ${m.join(' · ')}';
}

/// The answered form, or null while anything is unanswered (which is what
/// the confirm key is gated on).
MeterTripDetails? resolveTripDetails(MeterTripDetailsDraft d) {
  final pax = clampPax(d.pax), luggage = clampLuggage(d.luggage), airport = d.airport;
  if (pax == null || luggage == null || airport == null) return null;
  return MeterTripDetails(
    pax: pax,
    luggage: luggage,
    charges: sanitizeCharges(d.charges),
    airport: airport,
    airportSurcharge: airport == MeterAirport.none ? 0 : airportSurcharge,
  );
}

String? describeAirportLeg(MeterAirport a) => switch (a) {
      MeterAirport.pickup => 'Airport pickup',
      MeterAirport.dropoff => 'Airport drop-off',
      MeterAirport.none => null,
    };

// ---- The record ------------------------------------------------------------------

/// One end of a hire: when and where (the odometer comes with the OBD-II
/// slice of this port).
class MeterWaypoint {
  const MeterWaypoint({required this.at, this.latitude, this.longitude, this.place, this.odometerKm});
  final int at;
  final double? latitude;
  final double? longitude;
  final String? place;
  final double? odometerKm;

  Map<String, dynamic> toJson() =>
      {'at': at, 'latitude': latitude, 'longitude': longitude, 'place': place, 'odometerKm': odometerKm};

  static MeterWaypoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    if (at is! num) return null;
    double? n(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    final lat = n(raw['latitude']), lng = n(raw['longitude']);
    final place = '${raw['place'] ?? ''}'.trim();
    return MeterWaypoint(
      at: at.toInt(),
      // A half fix is no fix.
      latitude: lng == null ? null : lat,
      longitude: lat == null ? null : lng,
      place: place.isEmpty ? null : place,
      odometerKm: n(raw['odometerKm']),
    );
  }

  MeterWaypoint withPlace(String? place) =>
      MeterWaypoint(at: at, latitude: latitude, longitude: longitude, place: place, odometerKm: odometerKm);

  /// The place, else the coordinates, else "NO FIX".
  String get label {
    if ((place ?? '').isNotEmpty) return place!;
    if (latitude != null && longitude != null) {
      return '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}';
    }
    return 'NO FIX';
  }
}

/// A finished hire on the device's trip log (the meter's paper roll).
class MeterTrip {
  const MeterTrip({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.distanceM,
    required this.elapsedMs,
    required this.waitingMs,
    required this.rateLabel,
    required this.period,
    required this.flagFare,
    required this.nightMultiplier,
    required this.currency,
    required this.fare,
    required this.extra,
    required this.pax,
    required this.luggage,
    required this.airport,
    required this.airportSurcharge,
    required this.cardSurcharge,
    required this.total,
    required this.obdSamples,
    required this.gpsSamples,
    this.plate,
    this.driver,
    this.pickup,
    this.dropoff,
  });

  final String id;
  final int startedAt;
  final int endedAt;
  final double distanceM;
  final int elapsedMs;
  final int waitingMs;

  /// The card (or built-in tariff) it was billed on, as the receipt names it.
  final String rateLabel;
  final MeterPeriod period;
  final double flagFare;
  final double nightMultiplier;
  final String currency;
  final double fare;
  final double extra;
  final int? pax;
  final int? luggage;
  final MeterAirport airport;
  final double airportSurcharge;
  final double cardSurcharge;
  final double total;
  final int obdSamples;
  final int gpsSamples;
  final String? plate;
  final String? driver;
  final MeterWaypoint? pickup;
  final MeterWaypoint? dropoff;

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAt': startedAt,
        'endedAt': endedAt,
        'distanceM': distanceM,
        'elapsedMs': elapsedMs,
        'waitingMs': waitingMs,
        'rateLabel': rateLabel,
        'period': period.name,
        'flagFare': flagFare,
        'nightMultiplier': nightMultiplier,
        'currency': currency,
        'fare': fare,
        'extra': extra,
        'pax': pax,
        'luggage': luggage,
        'airport': airport.name,
        'airportSurcharge': airportSurcharge,
        'cardSurcharge': cardSurcharge,
        'total': total,
        'obdSamples': obdSamples,
        'gpsSamples': gpsSamples,
        'plate': plate,
        'driver': driver,
        'pickup': pickup?.toJson(),
        'dropoff': dropoff?.toJson(),
      };

  /// A stored record, or null when it is not one. Missing fields take the
  /// defaults a record from an older build would have meant.
  static MeterTrip? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], endedAt = raw['endedAt'];
    if (id is! String || endedAt is! num) return null;
    double d(String k) => raw[k] is num ? (raw[k] as num).toDouble() : 0;
    int i(String k) => raw[k] is num ? (raw[k] as num).toInt() : 0;
    String? s(String k) => raw[k] is String && (raw[k] as String).trim().isNotEmpty ? (raw[k] as String).trim() : null;
    final airport = MeterAirport.values.where((a) => a.name == raw['airport']).firstOrNull ?? MeterAirport.none;
    return MeterTrip(
      id: id,
      startedAt: raw['startedAt'] is num ? (raw['startedAt'] as num).toInt() : endedAt.toInt(),
      endedAt: endedAt.toInt(),
      distanceM: d('distanceM'),
      elapsedMs: i('elapsedMs'),
      waitingMs: i('waitingMs'),
      rateLabel: s('rateLabel') ?? 'Meter',
      period: raw['period'] == 'night' ? MeterPeriod.night : MeterPeriod.day,
      flagFare: d('flagFare'),
      nightMultiplier: raw['nightMultiplier'] is num ? d('nightMultiplier') : 1,
      currency: s('currency') ?? 'RM',
      fare: d('fare'),
      extra: d('extra'),
      pax: clampPax(raw['pax']),
      luggage: clampLuggage(raw['luggage']),
      airport: airport,
      airportSurcharge: d('airportSurcharge'),
      cardSurcharge: d('cardSurcharge'),
      total: d('total'),
      obdSamples: i('obdSamples'),
      gpsSamples: i('gpsSamples'),
      plate: s('plate'),
      driver: s('driver'),
      pickup: MeterWaypoint.fromJson(raw['pickup']),
      dropoff: MeterWaypoint.fromJson(raw['dropoff']),
    );
  }

  MeterTrip withEnds({MeterWaypoint? pickup, MeterWaypoint? dropoff}) => MeterTrip(
        id: id,
        startedAt: startedAt,
        endedAt: endedAt,
        distanceM: distanceM,
        elapsedMs: elapsedMs,
        waitingMs: waitingMs,
        rateLabel: rateLabel,
        period: period,
        flagFare: flagFare,
        nightMultiplier: nightMultiplier,
        currency: currency,
        fare: fare,
        extra: extra,
        pax: pax,
        luggage: luggage,
        airport: airport,
        airportSurcharge: airportSurcharge,
        cardSurcharge: cardSurcharge,
        total: total,
        obdSamples: obdSamples,
        gpsSamples: gpsSamples,
        plate: plate,
        driver: driver,
        pickup: pickup ?? this.pickup,
        dropoff: dropoff ?? this.dropoff,
      );
}

/// Builds the record from the meter's state (Expo `buildMeterTrip`). The fare
/// is passed in, priced from the state being stored, never from what the
/// screen last drew.
MeterTrip buildMeterTrip(
  MeterState state, {
  required String id,
  required int endedAt,
  required double fare,
  required MeterTripDetails details,
  required String rateLabel,
  required MeterPeriod period,
  required double flagFare,
  required double nightMultiplier,
  required String currency,
  double cardSurcharge = 0,
  String? plate,
  String? driver,
  MeterWaypoint? pickup,
  MeterWaypoint? dropoff,
}) {
  final card = cardSurcharge.isFinite ? math.max(0.0, cardSurcharge) : 0.0;
  return MeterTrip(
    id: id,
    startedAt: state.startedAt ?? endedAt,
    endedAt: endedAt,
    distanceM: math.max(0, state.distanceM),
    elapsedMs: math.max(0, state.elapsedMs),
    waitingMs: math.max(0, state.waitingMs),
    rateLabel: rateLabel,
    period: period,
    flagFare: flagFare,
    nightMultiplier: period == MeterPeriod.night ? nightMultiplier : 1,
    currency: currency,
    fare: fare,
    extra: details.charges,
    pax: details.pax,
    luggage: details.luggage,
    airport: details.airport,
    airportSurcharge: details.airportSurcharge,
    cardSurcharge: card,
    total: meterGrandTotal(fare, [details.charges, details.airportSurcharge, card]),
    obdSamples: state.obdSamples,
    gpsSamples: state.gpsSamples,
    plate: (plate ?? '').trim().isEmpty ? null : plate!.trim(),
    driver: (driver ?? '').trim().isEmpty ? null : driver!.trim(),
    pickup: pickup,
    dropoff: dropoff,
  );
}

({int count, double distanceM, double total}) summarizeMeterTrips(List<MeterTrip> trips) => (
      count: trips.length,
      distanceM: trips.fold(0.0, (s, t) => s + math.max(0.0, t.distanceM)),
      total: _round2(trips.fold(0.0, (s, t) => s + math.max(0.0, t.total))),
    );

// ---- The receipt -----------------------------------------------------------------

typedef ReceiptLine = ({String label, String value, bool strong});

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String formatDashDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day.toString().padLeft(2, '0')} ${_months[d.month - 1]} ${d.year}';
}

String formatDashTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h12:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// "Fare metered on GPS · 0 OBD / 412 GPS samples".
String meterReceiptFooterNote(MeterTrip t) {
  final onObd = t.obdSamples > 0 && t.obdSamples >= t.gpsSamples;
  return "Fare metered on ${onObd ? "the vehicle's OBD-II speed" : 'GPS'} · "
      '${t.obdSamples} OBD / ${t.gpsSamples} GPS samples';
}

/// The receipt, line by line (Expo `meterReceiptLines`). Each declared charge
/// is its own line; a record with no declaration or no ends prints no line
/// for them rather than a line of dashes. Unlike the Expo receipt, the flag
/// fall and night surcharge are the ones the hire was billed on, not the
/// built-in tariff's.
List<ReceiptLine> meterReceiptLines(MeterTrip t) {
  String money(double n) => '${t.currency} ${(n.isFinite ? n : 0).toStringAsFixed(2)}';
  ReceiptLine line(String l, String v, {bool strong = false}) => (label: l, value: v, strong: strong);
  final airport = describeAirportLeg(t.airport);
  return [
    line('Date', formatDashDate(t.endedAt)),
    line('Start', formatDashTime(t.startedAt)),
    line('End', formatDashTime(t.endedAt)),
    if (t.pickup != null) line('Pickup', t.pickup!.label),
    if (t.dropoff != null) line('Drop-off', t.dropoff!.label),
    line('Distance', formatMeterDistance(t.distanceM)),
    line('Trip time', formatMeterClock(t.elapsedMs)),
    line('Waiting', formatMeterClock(t.waitingMs)),
    line('Tariff', '${t.rateLabel} · ${t.period == MeterPeriod.night ? 'Night' : 'Day'}'),
    if (t.pax != null) line('Passengers', '${t.pax}'),
    if (t.luggage != null) line('Luggage', '${t.luggage}'),
    if (airport != null) line('Airport', airport),
    if (t.period == MeterPeriod.night && t.nightMultiplier > 1)
      line('Night surcharge', '+${((t.nightMultiplier - 1) * 100).round()}%'),
    line('Flag fall', money(t.flagFare * (t.period == MeterPeriod.night ? t.nightMultiplier : 1))),
    line('Metered fare', money(t.fare)),
    if (t.extra > 0) line('Tolls & charges', money(t.extra)),
    if (t.cardSurcharge > 0) line('Bags & passengers', money(t.cardSurcharge)),
    if (t.airportSurcharge > 0) line('Airport surcharge', money(t.airportSurcharge)),
    line('Total', money(t.total), strong: true),
  ];
}

/// Plain-text receipt, for copying or sharing.
String meterReceiptText(MeterTrip t, {String title = 'GET TAXI METER'}) => [
      title,
      if (t.plate != null) 'Vehicle ${t.plate}',
      if (t.driver != null) 'Driver ${t.driver}',
      '',
      for (final l in meterReceiptLines(t)) '${l.label}: ${l.value}',
      '',
      meterReceiptFooterNote(t),
      'Thank you for riding.',
    ].join('\n');
