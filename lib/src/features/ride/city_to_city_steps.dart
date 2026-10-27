// City to City, the rider's trip in five steps (migration 0307; the
// approved mockup's TripSteps board): Where (exact pickup and drop-off,
// search or the map, swap, and "not available from here" when City to City
// is off at the pickup), When (date boxes, a time, flexible ± 30 minutes,
// within the route's book-ahead days), Car (whole car; sharing comes later;
// passengers and luggage), Price (the quote's breakdown and range, the
// rider's fare within it, or the route's fixed fare) and Check (the summary,
// In app or Cash as the settings allow, the cancel rule), then Find a driver.
// The server checks it all again on insert (C2C_* codes, shown as modals).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/city_to_city.dart';
import '../../core/commission.dart' show Geo;
import '../../data/city_to_city_repository.dart';
import '../../data/geo_service.dart' show Place;
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show showError;
import '../../widgets/date_boxes.dart';
import '../../widgets/page_style_host.dart';
import 'city_to_city_parts.dart';
import 'city_to_city_trip.dart' show openC2cTrip;
import 'freight_screen.dart' show freightPlaceSearchProvider, freightRouteProvider;

/// Opens the trip steps.
Future<void> openC2cSteps(BuildContext context) => Navigator.of(context)
    .push<void>(AppPageRoute(id: 'ride.city-to-city-steps', builder: (_) => const C2cStepsScreen()));

/// The country, state, city and suburb at a point; null when the geocoder
/// can't say. Overridden in tests.
final c2cAreaProvider = Provider<Future<Geo?> Function(LatLng)>((ref) => (p) async {
  try {
    final a = await ref.read(geoServiceProvider).reverseArea(p).timeout(const Duration(seconds: 6));
    if (a == null) return null;
    return Geo(country: a.country, state: a.state, city: a.city, suburb: a.suburb);
  } catch (_) {
    return null;
  }
});

/// The clock the steps read (a fixed one in tests).
final c2cClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

const _heads = ['Where are you going?', 'When do you leave?', 'Which car?', 'Your fare', 'Check your trip'];

class C2cStepsScreen extends ConsumerStatefulWidget {
  const C2cStepsScreen({super.key});

  @override
  ConsumerState<C2cStepsScreen> createState() => _C2cStepsScreenState();
}

class _C2cStepsScreenState extends ConsumerState<C2cStepsScreen> {
  int _step = 0;
  C2cEnd? _pickup, _drop;

  /// City to City at the pickup: null while asking.
  bool? _pickupOk;
  ({double km, double min})? _route;
  bool _routing = false;
  C2cQuote? _quote;
  final _date = TextEditingController();
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  bool _flexible = true;
  int _passengers = 1;
  C2cLuggage _luggage = C2cLuggage.small;
  double? _fare;
  C2cPayment? _payment;
  int _seq = 0;

  DateTime get _now => ref.read(c2cClockProvider)();

  @override
  void initState() {
    super.initState();
    _date.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _date.dispose();
    super.dispose();
  }

  // ---- Where ----

  Future<void> _pick({required bool pickup, bool onMap = false}) async {
    final near = (pickup ? _pickup : _drop) ?? _pickup ?? _drop;
    final Place? place = await ref.read(freightPlaceSearchProvider)(
      context,
      title: pickup ? 'Pickup address' : 'Drop-off address',
      near: near == null ? null : LatLng(near.lat, near.lng),
      onMap: onMap,
    );
    if (place == null || !mounted) return;
    final area = await ref.read(c2cAreaProvider)(place.point);
    if (!mounted) return;
    final end = C2cEnd(
      name: place.name.trim().isEmpty ? place.address : place.name,
      address: place.address.trim().isEmpty ? null : place.address,
      lat: place.point.latitude,
      lng: place.point.longitude,
      place: area ?? const Geo(),
    );
    setState(() {
      if (pickup) {
        _pickup = end;
      } else {
        _drop = end;
      }
      _quote = null;
    });
    await _ends();
  }

  void _swap() {
    setState(() {
      final a = _pickup;
      _pickup = _drop;
      _drop = a;
      _quote = null;
    });
    unawaited(_ends());
  }

  /// Asks whether City to City is on at the pickup, and the route.
  Future<void> _ends() async {
    final seq = ++_seq;
    final a = _pickup, b = _drop;
    setState(() {
      _pickupOk = a == null ? null : _pickupOk;
      _routing = a != null && b != null;
    });
    if (a != null) {
      setState(() => _pickupOk = null);
      var ok = false;
      try {
        ok = await ref.read(cityToCityRepositoryProvider).availableAt(a.place);
      } catch (_) {}
      if (!mounted || seq != _seq) return;
      setState(() => _pickupOk = ok);
    }
    if (a == null || b == null) {
      setState(() {
        _route = null;
        _routing = false;
      });
      return;
    }
    final r = await ref.read(freightRouteProvider)(LatLng(a.lat, a.lng), LatLng(b.lat, b.lng));
    if (!mounted || seq != _seq) return;
    setState(() {
      _route = r;
      _routing = false;
    });
  }

  // ---- When ----

  DateTime? get _leaveAt {
    final d = parseIsoDate(_date.text);
    if (d == null) return null;
    return DateTime(d.year, d.month, d.day, _time.hour, _time.minute);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: _time, helpText: 'Time to leave');
    if (t != null && mounted) setState(() => _time = t);
  }

  // ---- Moving on ----

  bool get _canNext => switch (_step) {
    0 => _pickup != null && _drop != null && _pickupOk == true && _route != null,
    1 => _leaveAt != null && _quote != null && c2cLeaveProblem(_leaveAt!, _now, _quote!.bookAheadDays) == null,
    2 => true,
    3 => _fare != null && _quote != null && c2cFareProblem(_fare!, _quote!) == null,
    _ => _payment != null,
  };

  Future<void> _next() async {
    if (_step == 0) {
      final a = _pickup!, b = _drop!, r = _route!;
      try {
        final q = await ref.read(cityToCityRepositoryProvider).quote(
          lat: a.lat,
          lng: a.lng,
          pickup: a.place,
          drop: b.place,
          km: r.km,
          min: r.min,
        );
        if (!mounted) return;
        setState(() {
          _quote = q;
          _fare = c2cStartFare(q);
        });
      } catch (e) {
        if (mounted) showError(context, e);
        return;
      }
    }
    if (_step == 3) {
      final allowed = c2cPayments(ref.read(c2cSettingsProvider).value ?? const C2cSettings());
      if (_payment == null || !allowed.contains(_payment)) _payment = allowed.firstOrNull;
    }
    if (mounted) setState(() => _step++);
  }

  Future<void> _book() async {
    final q = _quote, r = _route, leave = _leaveAt, fare = _fare, pay = _payment;
    if (q == null || r == null || leave == null || fare == null || pay == null) return;
    try {
      final b = await ref.read(cityToCityRepositoryProvider).book(c2cBookingRow(
        pickup: _pickup!,
        drop: _drop!,
        distanceKm: r.km,
        durationMin: r.min,
        leaveAt: leave,
        flexible: _flexible,
        passengers: _passengers,
        luggage: _luggage,
        fare: fare,
        payment: pay,
      ));
      if (!mounted) return;
      ref.invalidate(c2cMyTripsProvider);
      await openC2cTrip(context, b.id, replace: true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  String get _routeName => C2cBooking(
    id: '',
    pickupName: _pickup?.name ?? '',
    pickupPlace: _pickup?.place ?? const Geo(),
    dropName: _drop?.name ?? '',
    dropPlace: _drop?.place ?? const Geo(),
    leaveAt: _now,
    fare: 0,
  ).route;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final settings = ref.watch(c2cSettingsProvider).value ?? const C2cSettings();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('City to City'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text('Step ${_step + 1} of 5', style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(
              key: const ValueKey('c2c-steps-list'),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                Row(children: [
                  for (var i = 0; i < 5; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: i <= _step ? look.accent : look.line,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                ]),
                const SizedBox(height: 14),
                Text(_heads[_step], style: t.textTheme.headlineSmall),
                const SizedBox(height: 14),
                switch (_step) {
                  0 => _where(),
                  1 => _when(),
                  2 => _car(),
                  3 => _price(),
                  _ => _check(settings),
                },
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(children: [
              if (_step > 0) ...[
                SizedBox(
                  width: 110,
                  height: 52,
                  child: OutlinedButton(
                    key: const ValueKey('c2c-back'),
                    onPressed: () => setState(() => _step--),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: _step < 4
                      ? BusyButton.filled(
                          key: const ValueKey('c2c-next'),
                          onPressed: _canNext ? _next : null,
                          child: const Text('Next'),
                        )
                      : BusyButton.filled(
                          key: const ValueKey('c2c-find-driver'),
                          onPressed: _canNext ? _book : null,
                          icon: const Icon(Icons.arrow_forward),
                          child: const Text('Find a driver'),
                        ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  // ---- Step 1: Where ----

  Widget _where() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _EndCard(
      key: const ValueKey('c2c-pickup'),
      pickup: true,
      end: _pickup,
      available: _pickupOk,
      onSearch: () => _pick(pickup: true),
      onMap: () => _pick(pickup: true, onMap: true),
    ),
    Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: OutlinedButton.icon(
          key: const ValueKey('c2c-swap'),
          onPressed: _pickup == null && _drop == null ? null : _swap,
          icon: const Icon(Icons.swap_vert),
          label: const Text('Swap'),
        ),
      ),
    ),
    _EndCard(
      key: const ValueKey('c2c-drop'),
      pickup: false,
      end: _drop,
      onSearch: () => _pick(pickup: false),
      onMap: () => _pick(pickup: false, onMap: true),
    ),
    if (_routing) ...[
      const SizedBox(height: 12),
      const LinearProgressIndicator(),
    ] else if (_pickup != null && _drop != null && _route == null) ...[
      const SizedBox(height: 12),
      Text("We couldn't work out the road between these addresses. Pick them again.",
          style: TextStyle(color: C2cLook.of(context).drop)),
    ],
  ]);

  // ---- Step 2: When ----

  Widget _when() {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final now = _now;
    final days = _quote?.bookAheadDays ?? 14;
    final leave = _leaveAt;
    final problem = leave == null ? null : c2cLeaveProblem(leave, now, days);
    final today = DateTime(now.year, now.month, now.day);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      C2cBox(
        color: look.hero,
        child: Row(children: [
          Icon(Icons.schedule, size: 32, color: look.onHero),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(leave == null ? 'Pick a day' : c2cLeaveText(leave),
                  style: t.textTheme.titleLarge?.copyWith(color: look.onHero, fontWeight: FontWeight.w700)),
              Text(leave == null ? 'and a time to leave' : c2cFlexText(leave, _flexible),
                  style: t.textTheme.bodyMedium?.copyWith(color: look.onHero)),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      DateBoxesField(
        key: const ValueKey('c2c-date'),
        label: 'Date',
        controller: _date,
        firstDate: today,
        lastDate: today.add(Duration(days: days)),
        isRequired: true,
      ),
      const SizedBox(height: 12),
      Text('Time', style: t.textTheme.labelLarge),
      const SizedBox(height: 4),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('c2c-time'),
          onPressed: _pickTime,
          icon: const Icon(Icons.schedule),
          label: Text(
            '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
            style: t.textTheme.titleMedium,
          ),
        ),
      ),
      const Divider(height: 28),
      SwitchListTile(
        key: const ValueKey('c2c-flexible'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Flexible ± 30 min'),
        subtitle: const Text('More drivers can take it'),
        value: _flexible,
        onChanged: (v) => setState(() => _flexible = v),
      ),
      Text('Book up to $days ${days == 1 ? 'day' : 'days'} ahead on this route.',
          style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
      if (problem != null) ...[
        const SizedBox(height: 8),
        Text(problem, key: const ValueKey('c2c-when-problem'), style: TextStyle(color: look.drop)),
      ],
    ]);
  }

  // ---- Step 3: Car ----

  Widget _car() {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      C2cBox(
        color: look.chosen,
        border: look.accent,
        child: Row(children: [
          Icon(Icons.radio_button_checked, color: look.onChosen),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Whole car', style: t.textTheme.titleMedium?.copyWith(color: look.onChosen, fontWeight: FontWeight.w600)),
              Text('Only your group, straight to the address',
                  style: t.textTheme.bodySmall?.copyWith(color: look.onChosen)),
            ]),
          ),
          Icon(Icons.directions_car, size: 28, color: look.onChosen),
        ]),
      ),
      const SizedBox(height: 10),
      C2cBox(
        border: look.line,
        child: Row(children: [
          Icon(Icons.radio_button_unchecked, color: look.mutedOnBox),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Share and pay per seat', style: t.textTheme.titleMedium?.copyWith(color: look.mutedOnBox)),
              Text('Ride with other riders', style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
            ]),
          ),
          Chip(label: const Text('Coming later'), visualDensity: VisualDensity.compact),
        ]),
      ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Passengers', style: t.textTheme.titleSmall),
            Text(c2cPassengerHint(_passengers), style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
          ]),
        ),
        C2cRoundButton(
          key: const ValueKey('c2c-pax-down'),
          icon: Icons.remove,
          tooltip: 'Fewer passengers',
          onPressed: _passengers > 1 ? () => setState(() => _passengers--) : null,
        ),
        SizedBox(
          width: 36,
          child: Text('$_passengers', textAlign: TextAlign.center, style: t.textTheme.titleLarge),
        ),
        C2cRoundButton(
          key: const ValueKey('c2c-pax-up'),
          icon: Icons.add,
          tooltip: 'More passengers',
          onPressed: _passengers < c2cMaxPassengers ? () => setState(() => _passengers++) : null,
        ),
      ]),
      const SizedBox(height: 14),
      Text('Luggage', style: t.textTheme.titleSmall),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final l in C2cLuggage.values)
          ChoiceChip(
            key: ValueKey('c2c-luggage-${l.key}'),
            label: Text(l.label),
            selected: _luggage == l,
            onSelected: (_) => setState(() => _luggage = l),
          ),
      ]),
    ]);
  }

  // ---- Step 4: Price ----

  Widget _price() {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final q = _quote!, r = _route!;
    final fare = _fare ?? c2cStartFare(q);
    final fixed = q.fareMode == C2cFareMode.fixed;
    final bar = c2cFareBar(fare, q);
    final atLow = !fixed && q.low != null && fare <= q.low!;
    final start = c2cStartFare(q);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      C2cBox(
        color: Colors.transparent,
        border: look.line,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c2cQuoteLine(q), style: t.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(c2cTripSize(r.km, r.min), style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
        ]),
      ),
      const SizedBox(height: 14),
      Text(c2cRangeLine(q, _routeName), style: t.textTheme.bodyLarge),
      if (!fixed && q.low != null && q.high != null) ...[
        const SizedBox(height: 12),
        SizedBox(
          height: 22,
          child: LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            return Stack(clipBehavior: Clip.none, children: [
              Positioned(
                left: 0,
                right: 0,
                top: 5,
                height: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: look.line, borderRadius: BorderRadius.circular(6)),
                ),
              ),
              Positioned(
                left: w * bar.start,
                width: w * (bar.end - bar.start),
                top: 5,
                height: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: look.accent.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(6)),
                ),
              ),
              Positioned(
                left: w * bar.at - 11,
                top: 0,
                width: 22,
                height: 22,
                child: DecoratedBox(
                  key: const ValueKey('c2c-fare-marker'),
                  decoration: BoxDecoration(
                    color: atLow ? look.onWarn : t.colorScheme.onSurface,
                    shape: BoxShape.circle,
                    border: Border.all(color: t.colorScheme.surface, width: 3),
                  ),
                ),
              ),
            ]);
          }),
        ),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(c2cMoney(q.low!, q.currency), style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
          Text(c2cMoney(q.high!, q.currency), style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
        ]),
      ],
      const SizedBox(height: 14),
      C2cBox(
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your fare, whole car', style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
              Text(c2cMoney(fare, q.currency),
                  key: const ValueKey('c2c-fare'),
                  style: t.textTheme.headlineMedium?.copyWith(color: look.onBox, fontWeight: FontWeight.w700)),
            ]),
          ),
          if (!fixed) ...[
            C2cRoundButton(
              key: const ValueKey('c2c-fare-down'),
              icon: Icons.remove,
              tooltip: 'Lower fare by ${c2cMoney(5, q.currency)}',
              onPressed: q.low == null || fare > q.low! ? () => setState(() => _fare = c2cStepFare(fare, -1, q)) : null,
            ),
            const SizedBox(width: 8),
            C2cRoundButton(
              key: const ValueKey('c2c-fare-up'),
              icon: Icons.add,
              tooltip: 'Raise fare by ${c2cMoney(5, q.currency)}',
              filled: true,
              onPressed: q.high == null || fare < q.high! ? () => setState(() => _fare = c2cStepFare(fare, 1, q)) : null,
            ),
          ],
        ]),
      ),
      if (atLow) ...[
        const SizedBox(height: 10),
        C2cBox(
          key: const ValueKey('c2c-fare-low'),
          color: look.warn,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.warning_amber, size: 20, color: look.onWarn),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Few drivers take this route at the bottom of the range. You may wait longer.',
                  style: t.textTheme.bodyMedium?.copyWith(color: look.onWarn)),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 10),
      Text(
        fixed
            ? 'Every driver on this route takes the fixed fare.'
            : 'Rounded to ${c2cMoney(start, q.currency)} to start. Drivers may offer a different price; you choose.',
        style: t.textTheme.bodySmall?.copyWith(color: look.muted),
      ),
    ]);
  }

  // ---- Step 5: Check ----

  Widget _check(C2cSettings settings) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final q = _quote!, leave = _leaveAt!, fare = _fare!;
    final pays = c2cPayments(settings);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      C2cBox(
        color: Colors.transparent,
        border: look.line,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${c2cLeaveText(leave)}${_flexible ? ' (± 30 min)' : ''}',
              style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          C2cIconLine(icon: Icons.trip_origin, color: look.accent, text: _pickup!.line),
          C2cIconLine(icon: Icons.location_on, color: look.drop, text: _drop!.line),
          C2cIconLine(icon: Icons.directions_car, text: c2cCarLine(_passengers)),
          C2cIconLine(icon: Icons.luggage, text: _luggage.label),
          Divider(height: 20, color: look.line),
          Row(children: [
            Expanded(child: Text('Your fare', style: t.textTheme.bodyMedium?.copyWith(color: look.muted))),
            Text(c2cMoney(fare, q.currency), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          ]),
          if (q.fareMode == C2cFareMode.card && q.addOn != 0)
            Text(
              'Suggested ${c2cMoney(q.suggested, q.currency)}: fare card ${c2cMoney(q.fareCard ?? 0, q.currency)} + '
              'City to City ${c2cMoney(q.addOn, q.currency)}',
              style: t.textTheme.bodySmall?.copyWith(color: look.muted),
            ),
        ]),
      ),
      const SizedBox(height: 14),
      Text('Pay', style: t.textTheme.titleSmall),
      const SizedBox(height: 6),
      Row(children: [
        for (final p in pays) ...[
          if (p != pays.first) const SizedBox(width: 8),
          Expanded(
            child: ChoiceChip(
              key: ValueKey('c2c-pay-${p.key}'),
              avatar: Icon(p == C2cPayment.inApp ? Icons.credit_card : Icons.payments, size: 20),
              label: SizedBox(width: double.infinity, child: Text(p.label, textAlign: TextAlign.center)),
              selected: _payment == p,
              showCheckmark: false,
              onSelected: (_) => setState(() => _payment = p),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline, size: 18, color: look.muted),
        const SizedBox(width: 6),
        Expanded(child: Text(settings.cancelLine, style: t.textTheme.bodySmall?.copyWith(color: look.muted))),
      ]),
    ]);
  }
}

/// The pickup or drop-off: its label, the address, Pick on map, and for the
/// pickup whether City to City is on there.
class _EndCard extends StatelessWidget {
  const _EndCard({
    super.key,
    required this.pickup,
    required this.end,
    required this.onSearch,
    required this.onMap,
    this.available,
  });

  final bool pickup;
  final C2cEnd? end;
  final bool? available;
  final VoidCallback onSearch, onMap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final e = end;
    final off = pickup && e != null && available == false;
    final where = e?.place.city ?? e?.place.state ?? e?.place.country ?? 'here';
    final pin = off ? look.bad : (pickup ? look.chosen : look.bad);
    final onPin = off ? look.onBad : (pickup ? look.onChosen : look.onBad);
    return C2cBox(
      color: Colors.transparent,
      border: look.line,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(pickup ? Icons.trip_origin : Icons.location_on, size: 20, color: pickup ? look.accent : look.drop),
          const SizedBox(width: 6),
          Text(pickup ? 'Pickup address' : 'Drop-off address', style: t.textTheme.labelLarge),
        ]),
        const SizedBox(height: 6),
        InkWell(
          key: ValueKey(pickup ? 'c2c-pickup-search' : 'c2c-drop-search'),
          onTap: onSearch,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              e?.name ?? (pickup ? 'Where from? Type the exact address' : 'Where to? Type the exact address'),
              style: e == null
                  ? t.textTheme.titleMedium?.copyWith(color: look.muted)
                  : t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: ValueKey(pickup ? 'c2c-pickup-map' : 'c2c-drop-map'),
            onPressed: onMap,
            icon: const Icon(Icons.map),
            label: const Text('Pick on map'),
          ),
        ),
        if (e != null) ...[
          const SizedBox(height: 8),
          C2cBox(
            color: pin,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(off ? Icons.wrong_location : Icons.where_to_vote, size: 20, color: onPin),
              const SizedBox(width: 8),
              Expanded(child: Text(e.address ?? e.line, style: t.textTheme.bodySmall?.copyWith(color: onPin))),
              if (pickup && available == null) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
        ],
        if (off) ...[
          const SizedBox(height: 8),
          Text("City to City isn't available from $where yet.",
              key: const ValueKey('c2c-not-available'),
              style: t.textTheme.bodyMedium?.copyWith(color: look.drop, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(onPressed: onSearch, child: const Text('Choose another pickup')),
          ),
        ],
      ]),
    );
  }
}
