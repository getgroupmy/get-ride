/// Place fees (migration 0324): the pickup / drop-off fees of an airport or
/// a Multi-Gate place with its boundary on, as many as the admin sets (Admin
/// → Airport Areas → Fees, and a place's Fees tab), and the settings that go
/// with them (app_settings `place_fees`).
///
/// The server works out what a ride is charged (`place_ride_charges`, and
/// `place_fees_quote` for the app before booking); this file reads what it
/// answers, says it in words and checks the admin's form. Pure.
library;

import 'dart:math' as math;

/// Which end of the trip a fee is for.
enum PlaceFeeEnd { pickup, dropoff, either, each }

/// A fixed amount, or a percentage of the fare.
enum PlaceFeeAmountKind { fixed, percent }

/// Who gets the fee: the driver (an earning), the platform (taken back from
/// the driver's GET.credit) or nobody here (passed on, as tolls are).
enum PlaceFeeGoesTo { driver, platform, pass }

PlaceFeeEnd placeFeeEndOf(Object? v) => switch ('${v ?? ''}') {
  'dropoff' => PlaceFeeEnd.dropoff,
  'either' => PlaceFeeEnd.either,
  'each' => PlaceFeeEnd.each,
  _ => PlaceFeeEnd.pickup,
};

String placeFeeEndKey(PlaceFeeEnd e) => switch (e) {
  PlaceFeeEnd.pickup => 'pickup',
  PlaceFeeEnd.dropoff => 'dropoff',
  PlaceFeeEnd.either => 'either',
  PlaceFeeEnd.each => 'each',
};

/// The admin's words for each choice.
String placeFeeEndLabel(PlaceFeeEnd e) => switch (e) {
  PlaceFeeEnd.pickup => 'Pickup',
  PlaceFeeEnd.dropoff => 'Drop-off',
  PlaceFeeEnd.either => 'Either end (charged once)',
  PlaceFeeEnd.each => 'Each end',
};

PlaceFeeGoesTo placeFeeGoesToOf(Object? v) => switch ('${v ?? ''}') {
  'driver' => PlaceFeeGoesTo.driver,
  'platform' => PlaceFeeGoesTo.platform,
  _ => PlaceFeeGoesTo.pass,
};

String placeFeeGoesToLabel(PlaceFeeGoesTo g) => switch (g) {
  PlaceFeeGoesTo.driver => 'Driver',
  PlaceFeeGoesTo.platform => 'Platform',
  PlaceFeeGoesTo.pass => 'Passed on',
};

/// The days of the week as the server counts them: 0 is Sunday.
const placeFeeDayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const placeFeeAllDays = [0, 1, 2, 3, 4, 5, 6];

/// The most a fixed fee, a least or a most may be; a percentage's is 100.
const placeFeeMaxAmount = 1000.0;

double? _num(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v.trim()) : null);

double _cents(double v) => (v * 100).roundToDouble() / 100;

/// "08:00" from a stored time ("08:00:00"), or null.
String? placeFeeTimeOf(Object? v) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('${v ?? ''}'.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!), min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
}

/// A stored date ("2026-12-01"), or null.
String? placeFeeDateOf(Object? v) {
  final s = '${v ?? ''}'.trim();
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return null;
  return DateTime.tryParse(s) == null ? null : s;
}

/// One fee of a place (a `place_fees` row).
class PlaceFee {
  const PlaceFee({
    this.id,
    required this.areaId,
    this.enabled = true,
    this.sortOrder = 0,
    this.name = '',
    this.riderNote = '',
    this.appliesTo = PlaceFeeEnd.pickup,
    this.amountKind = PlaceFeeAmountKind.fixed,
    this.amount = 0,
    this.minAmount,
    this.maxAmount,
    this.services = const [],
    this.days = placeFeeAllDays,
    this.timeFrom,
    this.timeTo,
    this.dateFrom,
    this.dateTo,
    this.countStops = false,
    this.goesTo = PlaceFeeGoesTo.pass,
  });

  /// Null for a fee not saved yet.
  final String? id;
  final String areaId;
  final bool enabled;
  final int sortOrder;

  /// What riders see ("KLIA kerbside fee").
  final String name;

  /// Shown in the fare's (i) sheet: what it is for.
  final String riderNote;
  final PlaceFeeEnd appliesTo;
  final PlaceFeeAmountKind amountKind;

  /// A fixed amount, or a percentage of the fare.
  final double amount;

  /// For a percentage: the least and the most it comes to (null: none).
  final double? minAmount, maxAmount;

  /// The vehicle services (by name, as rides carry them) it is for; empty
  /// for every service.
  final List<String> services;

  /// 0 = Sunday. With hours past midnight, the day they start.
  final List<int> days;

  /// "HH:MM"; both null for all day. A [timeTo] before [timeFrom] runs past
  /// midnight.
  final String? timeFrom, timeTo;

  /// "yyyy-mm-dd", each optional.
  final String? dateFrom, dateTo;

  /// A stop inside the place counts like a drop-off.
  final bool countStops;
  final PlaceFeeGoesTo goesTo;

  bool get percent => amountKind == PlaceFeeAmountKind.percent;

  factory PlaceFee.fromRow(Map<String, dynamic> r) => PlaceFee(
    id: r['id'] as String?,
    areaId: '${r['area_id'] ?? ''}',
    enabled: r['enabled'] != false,
    sortOrder: _num(r['sort_order'])?.round() ?? 0,
    name: '${r['name'] ?? ''}',
    riderNote: '${r['rider_note'] ?? ''}',
    appliesTo: placeFeeEndOf(r['applies_to']),
    amountKind: r['amount_kind'] == 'percent' ? PlaceFeeAmountKind.percent : PlaceFeeAmountKind.fixed,
    amount: _num(r['amount']) ?? 0,
    minAmount: _num(r['min_amount']),
    maxAmount: _num(r['max_amount']),
    services: [
      if (r['services'] is List)
        for (final s in r['services'] as List)
          if ('$s'.trim().isNotEmpty) '$s'.trim(),
    ],
    days: () {
      final d = [
        if (r['days'] is List)
          for (final x in r['days'] as List)
            if (_num(x) case final n? when n >= 0 && n <= 6) n.round(),
      ];
      return d.isEmpty ? placeFeeAllDays : (d.toSet().toList()..sort());
    }(),
    timeFrom: placeFeeTimeOf(r['time_from']),
    timeTo: placeFeeTimeOf(r['time_to']),
    dateFrom: placeFeeDateOf(r['date_from']),
    dateTo: placeFeeDateOf(r['date_to']),
    countStops: r['count_stops'] == true,
    goesTo: placeFeeGoesToOf(r['goes_to']),
  );

  /// The row to save (a new fee gets its id from the database).
  Map<String, dynamic> toRow() => {
    'id': ?id,
    'area_id': areaId,
    'enabled': enabled,
    'sort_order': sortOrder,
    'name': name.trim(),
    'rider_note': riderNote.trim(),
    'applies_to': placeFeeEndKey(appliesTo),
    'amount_kind': percent ? 'percent' : 'fixed',
    'amount': _cents(amount),
    'min_amount': percent && minAmount != null ? _cents(minAmount!) : null,
    'max_amount': percent && maxAmount != null ? _cents(maxAmount!) : null,
    'services': services,
    'days': days,
    'time_from': timeFrom == null || timeTo == null ? null : timeFrom,
    'time_to': timeFrom == null || timeTo == null ? null : timeTo,
    'date_from': dateFrom,
    'date_to': dateTo,
    'count_stops': countStops,
    'goes_to': goesTo.name,
  };

  PlaceFee copyWith({
    bool? enabled,
    int? sortOrder,
    String? name,
    String? riderNote,
    PlaceFeeEnd? appliesTo,
    PlaceFeeAmountKind? amountKind,
    double? amount,
    double? Function()? minAmount,
    double? Function()? maxAmount,
    List<String>? services,
    List<int>? days,
    String? Function()? timeFrom,
    String? Function()? timeTo,
    String? Function()? dateFrom,
    String? Function()? dateTo,
    bool? countStops,
    PlaceFeeGoesTo? goesTo,
  }) => PlaceFee(
    id: id,
    areaId: areaId,
    enabled: enabled ?? this.enabled,
    sortOrder: sortOrder ?? this.sortOrder,
    name: name ?? this.name,
    riderNote: riderNote ?? this.riderNote,
    appliesTo: appliesTo ?? this.appliesTo,
    amountKind: amountKind ?? this.amountKind,
    amount: amount ?? this.amount,
    minAmount: minAmount == null ? this.minAmount : minAmount(),
    maxAmount: maxAmount == null ? this.maxAmount : maxAmount(),
    services: services ?? this.services,
    days: days ?? this.days,
    timeFrom: timeFrom == null ? this.timeFrom : timeFrom(),
    timeTo: timeTo == null ? this.timeTo : timeTo(),
    dateFrom: dateFrom == null ? this.dateFrom : dateFrom(),
    dateTo: dateTo == null ? this.dateTo : dateTo(),
    countStops: countStops ?? this.countStops,
    goesTo: goesTo ?? this.goesTo,
  );

  /// "RM 5.00", or "10% (RM 3.00 to RM 8.00)".
  String amountText(String Function(double) money) {
    if (!percent) return money(amount);
    final pct = '${amount == amount.roundToDouble() ? amount.toStringAsFixed(0) : amount}%';
    final lo = minAmount, hi = maxAmount;
    if (lo == null && hi == null) return pct;
    if (lo != null && hi != null) return '$pct (${money(lo)} to ${money(hi)})';
    return lo != null ? '$pct (at least ${money(lo)})' : '$pct (at most ${money(hi!)})';
  }

  /// "Every day", "Mon to Fri, 08:00 to 10:00", "Fri, 22:00 to 02:00 · 1 Dec 2026 to 31 Dec 2026".
  String whenText({String Function(String date)? date}) {
    final d = [...days]..sort();
    String dayText;
    if (d.length == 7) {
      dayText = 'Every day';
    } else if (d.length == 5 && d.join() == '12345') {
      dayText = 'Mon to Fri';
    } else if (d.length == 2 && d.join() == '06') {
      dayText = 'Sat and Sun';
    } else {
      dayText = [for (final x in d) placeFeeDayNames[x]].join(', ');
    }
    final parts = [
      dayText,
      if (timeFrom != null && timeTo != null && timeFrom != timeTo) '$timeFrom to $timeTo',
    ].join(', ');
    final show = date ?? (s) => s;
    final range = switch ((dateFrom, dateTo)) {
      (null, null) => null,
      (final a?, null) => 'from ${show(a)}',
      (null, final b?) => 'until ${show(b)}',
      (final a?, final b?) => '${show(a)} to ${show(b)}',
    };
    return range == null ? parts : '$parts · $range';
  }

  /// What is wrong with the form, in words; null when it can be saved.
  String? get problem {
    final n = name.trim();
    if (n.isEmpty) return 'Give the fee a name riders will see.';
    if (n.length > 60) return 'The name is at most 60 characters.';
    if (riderNote.trim().length > 240) return 'The note is at most 240 characters.';
    if (!amount.isFinite || amount <= 0) return 'Enter the amount.';
    if (percent && amount > 100) return 'A percentage is at most 100.';
    if (!percent && amount > placeFeeMaxAmount) return 'A fee is at most ${placeFeeMaxAmount.toStringAsFixed(0)}.';
    if (percent) {
      for (final v in [minAmount, maxAmount]) {
        if (v != null && (v < 0 || v > placeFeeMaxAmount)) {
          return 'The least and the most are from 0 to ${placeFeeMaxAmount.toStringAsFixed(0)}.';
        }
      }
      if (minAmount != null && maxAmount != null && minAmount! > maxAmount!) {
        return 'The least can\'t be more than the most.';
      }
    }
    if (days.isEmpty) return 'Choose at least one day.';
    if ((timeFrom == null) != (timeTo == null)) return 'Set both the from and the to time, or neither.';
    if (dateFrom != null && dateTo != null && dateFrom!.compareTo(dateTo!) > 0) {
      return 'The first day is after the last day.';
    }
    if (services.length > 50) return 'Choose at most 50 services.';
    return null;
  }
}

/// The place fee settings (app_settings `place_fees`), each with its
/// default when missing.
class PlaceFeeSettings {
  const PlaceFeeSettings({
    this.lockScheduled = true,
    this.timeZone = defaultTimeZone,
    this.showMapLabel = true,
    this.showAddressHint = true,
    this.showCardBadge = true,
    this.showOutline = true,
    this.badgeText = defaultBadgeText,
    this.addressHintText = defaultHintText,
    this.maxTotal,
  });

  static const defaultTimeZone = 'Asia/Kuala_Lumpur';
  static const defaultBadgeText = 'incl. place fee';
  static const defaultHintText = '{name} {amount} applies here';
  static const defaults = PlaceFeeSettings();

  /// A ride booked for later is charged the fee worked out at booking.
  final bool lockScheduled;

  /// The time zone the days and hours are read in.
  final String timeZone;
  final bool showMapLabel, showAddressHint, showCardBadge;

  /// The place's outline on the rider's map when an end of the trip (or a
  /// counted stop) is in a place with a fee (0325).
  final bool showOutline;
  final String badgeText;

  /// With {name} and {amount}.
  final String addressHintText;

  /// The most all place fees may add to one ride; null for no cap.
  final double? maxTotal;

  factory PlaceFeeSettings.fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    bool b(String k) => raw[k] is bool ? raw[k] as bool : true;
    String s(String k, String def, int max) {
      final v = '${raw[k] ?? ''}'.trim();
      return v.isEmpty || v.length > max ? def : v;
    }

    final cap = _num(raw['maxTotal']);
    return PlaceFeeSettings(
      lockScheduled: b('lockScheduled'),
      timeZone: s('timeZone', defaultTimeZone, 64),
      showMapLabel: b('showMapLabel'),
      showAddressHint: b('showAddressHint'),
      showCardBadge: b('showCardBadge'),
      showOutline: b('showOutline'),
      badgeText: s('badgeText', defaultBadgeText, 40),
      addressHintText: s('addressHintText', defaultHintText, 120),
      maxTotal: cap == null || cap < 0 || cap > 10000 ? null : cap,
    );
  }

  Map<String, dynamic> toJson() => {
    'lockScheduled': lockScheduled,
    'timeZone': timeZone.trim(),
    'percentOf': 'fare',
    'showMapLabel': showMapLabel,
    'showAddressHint': showAddressHint,
    'showCardBadge': showCardBadge,
    'showOutline': showOutline,
    'badgeText': badgeText.trim(),
    'addressHintText': addressHintText.trim(),
    'maxTotal': maxTotal,
  };

  PlaceFeeSettings copyWith({
    bool? lockScheduled,
    String? timeZone,
    bool? showMapLabel,
    bool? showAddressHint,
    bool? showCardBadge,
    bool? showOutline,
    String? badgeText,
    String? addressHintText,
    double? Function()? maxTotal,
  }) => PlaceFeeSettings(
    lockScheduled: lockScheduled ?? this.lockScheduled,
    timeZone: timeZone ?? this.timeZone,
    showMapLabel: showMapLabel ?? this.showMapLabel,
    showAddressHint: showAddressHint ?? this.showAddressHint,
    showCardBadge: showCardBadge ?? this.showCardBadge,
    showOutline: showOutline ?? this.showOutline,
    badgeText: badgeText ?? this.badgeText,
    addressHintText: addressHintText ?? this.addressHintText,
    maxTotal: maxTotal == null ? this.maxTotal : maxTotal(),
  );

  /// What is wrong with the form; null when it can be saved.
  String? get problem {
    if (timeZone.trim().isEmpty) return 'Choose the time zone.';
    final badge = badgeText.trim(), hint = addressHintText.trim();
    if (badge.isEmpty || badge.length > 40) return 'The badge text is 1 to 40 characters.';
    if (hint.isEmpty || hint.length > 120) return 'The address hint is 1 to 120 characters.';
    final cap = maxTotal;
    if (cap != null && (cap < 0 || cap > 10000)) return 'The most per ride is from 0 to 10000.';
    return null;
  }
}

/// One place fee line on a ride or a quote (a `ride_requests.charges`
/// entry with `place_fee`).
class PlaceFeeLine {
  const PlaceFeeLine({
    required this.name,
    required this.amount,
    this.end = 'pick',
    this.feeId,
    this.areaId,
    this.goesTo = PlaceFeeGoesTo.pass,
    this.note,
    this.locked = false,
  });

  final String name;
  final double amount;

  /// pick, drop, stop or once (either end).
  final String end;
  final String? feeId, areaId;
  final PlaceFeeGoesTo goesTo;

  /// The admin's note for riders; null for none.
  final String? note;

  /// Worked out when a ride for later was booked, and kept.
  final bool locked;

  /// A charges entry that is a place fee, else null.
  static PlaceFeeLine? fromCharge(Object? raw) {
    if (raw is! Map || raw['place_fee'] == null) return null;
    final v = _num(raw['value']);
    final name = '${raw['name'] ?? ''}'.trim();
    if (v == null || v <= 0 || name.isEmpty) return null;
    final note = '${raw['note'] ?? ''}'.trim();
    return PlaceFeeLine(
      name: name,
      amount: v,
      end: '${raw['airport'] ?? 'pick'}',
      feeId: '${raw['place_fee']}',
      areaId: raw['area'] == null ? null : '${raw['area']}',
      goesTo: placeFeeGoesToOf(raw['goes_to']),
      note: note.isEmpty ? null : note,
      locked: raw['locked'] == true,
    );
  }

  /// "pickup", "drop-off", "stop"; empty for a fee charged once.
  String get endText => switch (end) {
    'pick' => 'pickup',
    'drop' => 'drop-off',
    'stop' => 'stop',
    _ => '',
  };

  /// "KLIA kerbside fee (pickup)".
  String get label => endText.isEmpty ? name : '$name ($endText)';
}

/// The place fee lines of a ride's or a booking's charges.
List<PlaceFeeLine> placeFeeLinesOf(Object? charges) => [
  if (charges is List)
    for (final c in charges) ?PlaceFeeLine.fromCharge(c),
];

/// Their total, to the cent.
double placeFeesTotal(Iterable<PlaceFeeLine> lines) => _cents(lines.fold(0.0, (a, l) => a + l.amount));

/// The names of a ride's place fees that are passed on (for the driver's
/// offer card: neither the driver's nor the platform's).
Set<String> passedOnPlaceFeeNames(Object? charges) => {
  for (final l in placeFeeLinesOf(charges))
    if (l.goesTo == PlaceFeeGoesTo.pass) l.name,
};

/// One end's place and its fees, from the quote.
class PlaceFeeEndInfo {
  const PlaceFeeEndInfo({required this.areaId, required this.name, required this.fees});

  final String areaId;

  /// The airport's or place's name.
  final String name;
  final List<({String name, double amount})> fees;

  double get total => _cents(fees.fold(0.0, (a, f) => a + f.amount));

  static PlaceFeeEndInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fees = [
      if (raw['fees'] is List)
        for (final f in raw['fees'] as List)
          if (f is Map)
            if (_num(f['amount']) case final a? when a > 0) (name: '${f['name'] ?? ''}'.trim(), amount: a),
    ];
    if (fees.isEmpty) return null;
    return PlaceFeeEndInfo(areaId: '${raw['area_id'] ?? ''}', name: '${raw['name'] ?? ''}'.trim(), fees: fees);
  }

  /// The first fee's name when there is one, else the place's: what the
  /// map label and the address hint call it.
  String get feeName => fees.length == 1 && fees.first.name.isNotEmpty ? fees.first.name : name;
}

/// What the app shows of the place fees (the quote's display settings).
class PlaceFeeDisplay {
  const PlaceFeeDisplay({
    this.showMapLabel = true,
    this.showAddressHint = true,
    this.showCardBadge = true,
    this.showOutline = true,
    this.badgeText = PlaceFeeSettings.defaultBadgeText,
    this.addressHintText = PlaceFeeSettings.defaultHintText,
  });

  final bool showMapLabel, showAddressHint, showCardBadge, showOutline;
  final String badgeText, addressHintText;

  factory PlaceFeeDisplay.fromJson(Object? raw) {
    final s = PlaceFeeSettings.fromJson(raw);
    return PlaceFeeDisplay(
      showMapLabel: s.showMapLabel,
      showAddressHint: s.showAddressHint,
      showCardBadge: s.showCardBadge,
      showOutline: s.showOutline,
      badgeText: s.badgeText,
      addressHintText: s.addressHintText,
    );
  }
}

/// The server's answer before booking (`place_fees_quote`): the lines the
/// ride will be stamped with, their total, each end's place and fees, and
/// what to show.
class PlaceFeesQuote {
  const PlaceFeesQuote({
    this.lines = const [],
    this.total = 0,
    this.pickup,
    this.drop,
    this.display = const PlaceFeeDisplay(),
  });

  static const none = PlaceFeesQuote();

  final List<PlaceFeeLine> lines;
  final double total;
  final PlaceFeeEndInfo? pickup, drop;
  final PlaceFeeDisplay display;

  bool get isEmpty => lines.isEmpty;

  factory PlaceFeesQuote.fromJson(Object? raw) {
    if (raw is! Map) return none;
    final lines = placeFeeLinesOf(raw['lines']);
    return PlaceFeesQuote(
      lines: lines,
      total: _num(raw['total']) ?? placeFeesTotal(lines),
      pickup: PlaceFeeEndInfo.fromJson(raw['pickup']),
      drop: PlaceFeeEndInfo.fromJson(raw['drop']),
      display: PlaceFeeDisplay.fromJson(raw['settings']),
    );
  }

  /// The address hint under an end ("KLIA kerbside fee RM 5.00 applies
  /// here"), or null when the end has no fee or hints are off.
  String? hintFor(PlaceFeeEndInfo? end, String Function(double) money) {
    if (end == null || !display.showAddressHint) return null;
    return placeFeeHint(display.addressHintText, name: end.feeName, amount: money(end.total));
  }

  /// The map label on an end's pin ("KLIA · RM 5.00"), or null.
  String? mapLabelFor(PlaceFeeEndInfo? end, String Function(double) money) {
    if (end == null || !display.showMapLabel) return null;
    return [if (end.name.isNotEmpty) end.name, money(end.total)].join(' · ');
  }

  /// The vehicle card badge, or null.
  String? get badge => isEmpty || !display.showCardBadge ? null : display.badgeText;
}

/// [template] with `{name}` and `{amount}` filled in, spaces tidied.
String placeFeeHint(String template, {required String name, required String amount}) =>
    template.replaceAll('{name}', name).replaceAll('{amount}', amount).replaceAll(RegExp(r'\s+'), ' ').trim();

/// The admin's list of a place's fees, in their order.
List<PlaceFee> placeFeesFor(Iterable<PlaceFee> all, String areaId) =>
    [for (final f in all) if (f.areaId == areaId) f]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

/// A fee moved [dir] (-1 up, +1 down) in [list]: the new sort order of
/// each fee whose order changes (all renumbered 0, 1, 2... so ties go).
Map<String, int> reorderPlaceFees(List<PlaceFee> list, String id, int dir) {
  final ids = [for (final f in list) f.id ?? ''];
  final i = ids.indexOf(id);
  final j = i + dir;
  if (i < 0 || j < 0 || j >= ids.length) return const {};
  final moved = [...ids]..removeAt(i);
  moved.insert(j, id);
  return {
    for (var k = 0; k < moved.length; k++)
      if (list.firstWhere((f) => f.id == moved[k]).sortOrder != k) moved[k]: k,
  };
}

/// The sort order for a new fee: after the last.
int nextPlaceFeeOrder(List<PlaceFee> list) => list.isEmpty ? 0 : list.map((f) => f.sortOrder).reduce(math.max) + 1;

/// What [fees] add to a trip with one end in their place, for the admin's
/// "Try a fare": the fees that are on, for [service] and for that end
/// ([pickup], else the drop-off), a percentage on [fare] within its least
/// and most. Days, hours and dates are left out (any time).
List<({String name, double amount})> placeFeesForTrial(
  Iterable<PlaceFee> fees, {
  required bool pickup,
  required String service,
  required double fare,
}) {
  final want = service.trim().toLowerCase();
  return [
    for (final f in [...fees]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
      if (f.enabled &&
          (f.services.isEmpty || f.services.any((s) => s.trim().toLowerCase() == want)) &&
          (f.appliesTo == PlaceFeeEnd.each ||
              f.appliesTo == PlaceFeeEnd.either ||
              f.appliesTo == (pickup ? PlaceFeeEnd.pickup : PlaceFeeEnd.dropoff)))
        if (_feeOn(f, fare) case final a when a > 0) (name: f.name.trim(), amount: a),
  ];
}

double _feeOn(PlaceFee f, double fare) {
  if (!f.percent) return _cents(f.amount);
  var v = _cents(math.max(0, fare) * f.amount / 100);
  if (f.minAmount != null) v = math.max(v, _cents(f.minAmount!));
  if (f.maxAmount != null) v = math.min(v, _cents(f.maxAmount!));
  return v;
}
