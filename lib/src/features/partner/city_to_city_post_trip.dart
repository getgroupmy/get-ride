// City to City per-seat trips for drivers (migration 0310; the approved
// board 16, Post a trip):
//
//   Post a trip   From and To, when it leaves (date boxes and a time), the
//                 meeting points (each a time after leaving), door pickup,
//                 women only, a repeat and parcels where the region's rule
//                 allows them, Instant or I approve riders (when the rule
//                 lets the driver pick), free seats, the seat price inside
//                 the admin's limits, the luggage room, and what the driver
//                 keeps if every seat is booked.
//   Posted trips  the Post a trip tab: each trip with its seats booked and
//                 requests waiting; a trip's page shows the requests
//                 (Approve, Decline; the cards move with the locked offer
//                 motion), the passengers (Call, Chat), Start trip, Finish
//                 trip and Cancel trip (the give-up fee per booked rider).
//
// The server checks everything again (C2C_* codes, shown as modals).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/city_to_city.dart';
import '../../core/city_to_city_seats.dart';
import '../../core/commission.dart' show Geo;
import '../../data/city_to_city_repository.dart';
import '../../data/geo_service.dart' show Place;
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show AsyncView, EmptyState, showError, showInfo;
import '../../widgets/date_boxes.dart';
import '../../widgets/offer_motion.dart';
import '../../widgets/page_style_host.dart';
import '../ride/city_to_city_parts.dart';
import '../ride/city_to_city_steps.dart' show c2cAreaProvider, c2cClockProvider;
import '../ride/city_to_city_trip.dart' show c2cLauncherProvider, openC2cChat;
import '../ride/freight_screen.dart' show freightPlaceSearchProvider, freightRouteProvider;

/// Opens Post a trip.
Future<void> openC2cPostTrip(BuildContext context) => Navigator.of(context)
    .push<void>(AppPageRoute(id: 'driver.city-to-city-post', builder: (_) => const C2cPostTripScreen()));

/// Opens posted trip [id].
Future<void> openC2cDriverSeatTrip(BuildContext context, String id) => Navigator.of(context).push<void>(
  AppPageRoute(id: 'driver.city-to-city-seat-trip', builder: (_) => C2cDriverSeatTripScreen(tripId: id)),
);

// ---- Post a trip ------------------------------------------------------------------------------------------

class C2cPostTripScreen extends ConsumerStatefulWidget {
  const C2cPostTripScreen({super.key});

  @override
  ConsumerState<C2cPostTripScreen> createState() => _C2cPostTripScreenState();
}

class _C2cPostTripScreenState extends ConsumerState<C2cPostTripScreen> {
  C2cEnd? _from, _to;
  ({double km, double min})? _route;
  C2cPostTerms? _terms;
  bool _loading = false;
  final _date = TextEditingController();
  final _until = TextEditingController();
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  final _points = <C2cMeetingPoint>[];
  int _seats = 3;
  double? _price;
  C2cJoinMode _join = C2cJoinMode.instant;
  bool _door = false, _women = false, _suitcase = false;
  C2cRepeat _repeat = C2cRepeat.none;
  int _parcels = 0;
  C2cParcelSize _parcelSize = C2cParcelSize.small;
  double _parcelPrice = 10;
  int _seq = 0;

  DateTime get _now => ref.read(c2cClockProvider)();

  @override
  void initState() {
    super.initState();
    for (final c in [_date, _until]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _date.dispose();
    _until.dispose();
    super.dispose();
  }

  DateTime? get _leaveAt {
    final d = parseIsoDate(_date.text);
    return d == null ? null : DateTime(d.year, d.month, d.day, _time.hour, _time.minute);
  }

  Future<C2cEnd?> _pickEnd(String title, C2cEnd? near) async {
    final Place? place = await ref.read(freightPlaceSearchProvider)(
      context,
      title: title,
      near: near == null ? null : LatLng(near.lat, near.lng),
    );
    if (place == null || !mounted) return null;
    final area = await ref.read(c2cAreaProvider)(place.point);
    if (!mounted) return null;
    return C2cEnd(
      name: place.name.trim().isEmpty ? place.address : place.name,
      address: place.address.trim().isEmpty ? null : place.address,
      lat: place.point.latitude,
      lng: place.point.longitude,
      place: area ?? const Geo(),
    );
  }

  Future<void> _pick({required bool from}) async {
    final end = await _pickEnd(from ? 'Where the trip starts' : 'Where the trip ends', from ? _from : _to ?? _from);
    if (end == null) return;
    setState(() {
      if (from) {
        _from = end;
        // The start is the first meeting point until the driver changes it.
        if (_points.isEmpty || _points.first.minutes == 0) {
          if (_points.isNotEmpty) _points.removeAt(0);
          _points.insert(0, C2cMeetingPoint(name: end.name, address: end.address, lat: end.lat, lng: end.lng));
        }
      } else {
        _to = end;
      }
      _terms = null;
    });
    await _load();
  }

  /// The route and what the rule allows for it.
  Future<void> _load() async {
    final a = _from, b = _to;
    if (a == null || b == null) return;
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final r = await ref.read(freightRouteProvider)(LatLng(a.lat, a.lng), LatLng(b.lat, b.lng));
      if (r == null) throw StateError("Couldn't find a road between them. Pick the places again.");
      final terms = await ref.read(cityToCityRepositoryProvider).postTerms(from: a, to: b, km: r.km, min: r.min);
      if (!mounted || seq != _seq) return;
      setState(() {
        _route = r;
        _terms = terms;
        _loading = false;
        _seats = _seats.clamp(1, math.max(terms.terms.maxSeats, 1));
        _price = terms.limits.clamp(_price ?? terms.limits.price ?? c2cRound0(((terms.limits.low) + (terms.limits.high ?? terms.limits.low)) / 2));
        _join = switch (terms.terms.joinMode) {
          C2cJoinMode.approve => C2cJoinMode.approve,
          C2cJoinMode.instant => C2cJoinMode.instant,
          C2cJoinMode.driverPicks => _join == C2cJoinMode.driverPicks ? C2cJoinMode.instant : _join,
        };
        _door = _door && terms.terms.doorOn;
        _women = _women && terms.terms.womenOn && terms.verifiedWoman;
        if (!terms.terms.repeatOn) _repeat = C2cRepeat.none;
        if (!terms.terms.parcelsOn) _parcels = 0;
        _parcelPrice = _parcelPrice.clamp(terms.terms.parcelMinPrice, terms.terms.parcelMaxPrice).toDouble();
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() => _loading = false);
      showError(context, e);
    }
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: _time, helpText: 'Time to leave');
    if (t != null && mounted) setState(() => _time = t);
  }

  Future<void> _addPoint() async {
    final end = await _pickEnd('Meeting point', _points.lastOrNull == null ? _from : null);
    if (end == null || !mounted) return;
    final base = _time.hour * 60 + _time.minute;
    final last = _points.isEmpty ? 0 : _points.last.minutes;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: ((base + last + 15) ~/ 60) % 24, minute: (base + last + 15) % 60),
      helpText: 'When you are at ${end.name}',
    );
    if (t == null || !mounted) return;
    final minutes = (t.hour * 60 + t.minute - base + 1440) % 1440;
    if (minutes > 240) {
      showInfo(context, 'A meeting point is up to 4 hours after leaving.');
      return;
    }
    setState(() {
      _points
        ..add(C2cMeetingPoint(name: end.name, address: end.address, lat: end.lat, lng: end.lng, minutes: minutes))
        ..sort((a, b) => a.minutes.compareTo(b.minutes));
    });
  }

  String? get _problem {
    final terms = _terms;
    if (_from == null || _to == null) return 'Pick where the trip starts and ends.';
    if (terms == null) return _loading ? null : 'Pick the places again.';
    final block = terms.block;
    if (block != null) return block;
    final leave = _leaveAt;
    if (leave == null) return 'Pick the day you leave.';
    if (leave.isBefore(_now.add(c2cMinLead))) return 'Leave at least 1 hour from now.';
    if (leave.isAfter(_now.add(Duration(days: terms.terms.postAheadDays)))) {
      return 'Post up to ${terms.terms.postAheadDays} days ahead.';
    }
    if (_points.isEmpty) return 'Add a meeting point.';
    final price = _price;
    if (price == null) return 'Price a seat.';
    final why = terms.limits.problem(price);
    if (why != null) return why;
    if (_repeat != C2cRepeat.none && parseIsoDate(_until.text) == null) return 'Pick the last day to repeat.';
    return null;
  }

  int get _repeatCount {
    final leave = _leaveAt, until = parseIsoDate(_until.text);
    if (_repeat == C2cRepeat.none || leave == null || until == null) return 1;
    return 1 + c2cRepeatDates(leave, _repeat, until).length;
  }

  Future<void> _post() async {
    final terms = _terms, leave = _leaveAt, r = _route, price = _price;
    if (terms == null || leave == null || r == null || price == null || _problem != null) return;
    try {
      final out = await ref.read(cityToCityRepositoryProvider).postTrip(
        from: _from!,
        to: _to!,
        km: r.km,
        min: r.min,
        leaveAt: leave,
        points: _points,
        seats: _seats,
        seatPrice: price,
        join: _join,
        womenOnly: _women,
        door: _door,
        parcelSlots: _parcels,
        parcelSize: _parcels > 0 ? _parcelSize : null,
        parcelPrice: _parcels > 0 ? _parcelPrice : null,
        repeat: _repeat,
        repeatUntil: _repeat == C2cRepeat.none ? null : parseIsoDate(_until.text),
        suitcase: _suitcase,
      );
      ref.invalidate(c2cDriverSeatTripsProvider);
      if (!mounted) return;
      showInfo(
        context,
        out.posted > 1
            ? 'Posted ${out.posted} trips.${out.skipped > 0 ? ' ${out.skipped} skipped: you had another trip then.' : ''}'
            : 'Trip posted. Riders can book your seats now.',
      );
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final terms = _terms;
    final rule = terms?.terms;
    final limits = terms?.limits;
    final now = _now;
    final today = DateTime(now.year, now.month, now.day);
    final leave = _leaveAt;
    final price = _price ?? 0;
    final cur = limits?.currency ?? 'MYR';
    final total = c2cRound2(_seats * price);
    final problem = _problem;
    Widget field(String label, String? value, VoidCallback onTap, Key key) => Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.labelLarge),
        const SizedBox(height: 4),
        OutlinedButton(
          key: key,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            alignment: Alignment.centerLeft,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onTap,
          child: Text(value ?? 'Pick', overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
    Widget tick(String keyName, String label, bool value, ValueChanged<bool>? on) => CheckboxListTile(
      key: ValueKey('c2c-post-$keyName'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(label),
      value: value,
      onChanged: on == null ? null : (v) => on(v ?? false),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Post a trip')),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(
              key: const ValueKey('c2c-post-list'),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                Row(children: [
                  field('From city', _from?.line, () => _pick(from: true), const ValueKey('c2c-post-from')),
                  const SizedBox(width: 10),
                  field('To city', _to?.line, () => _pick(from: false), const ValueKey('c2c-post-to')),
                ]),
                if (_loading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
                if (terms?.block != null) ...[
                  const SizedBox(height: 10),
                  C2cBanner(
                    key: const ValueKey('c2c-post-block'),
                    icon: Icons.block,
                    title: "Can't post this trip",
                    line: terms!.block!,
                    fill: look.box,
                    ink: look.onBox,
                  ),
                ],
                const SizedBox(height: 12),
                Text('Leaving', style: t.textTheme.labelLarge),
                const SizedBox(height: 4),
                DateBoxesField(
                  key: const ValueKey('c2c-post-date'),
                  label: 'Date',
                  controller: _date,
                  firstDate: today,
                  lastDate: today.add(Duration(days: rule?.postAheadDays ?? 30)),
                  isRequired: true,
                ),
                const SizedBox(height: 6),
                Row(children: [
                  OutlinedButton.icon(
                    key: const ValueKey('c2c-post-time'),
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule),
                    label: Text(_time.format(context)),
                  ),
                  const SizedBox(width: 10),
                  if (leave != null)
                    Expanded(
                      child: Text(c2cDayTime(leave),
                          key: const ValueKey('c2c-post-when'), style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                    ),
                ]),
                const SizedBox(height: 12),
                Text('Meeting points', style: t.textTheme.labelLarge),
                const SizedBox(height: 4),
                for (final (i, p) in _points.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: C2cBox(
                      key: ValueKey('c2c-post-point-$i'),
                      border: look.line,
                      color: Colors.transparent,
                      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                      child: Row(children: [
                        Icon(Icons.pin_drop_outlined, color: look.muted, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            leave == null ? '+${p.minutes} min  ${p.name}' : '${c2cClock(p.at(leave))} ${p.name}',
                            style: t.textTheme.bodyMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove ${p.name}',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _points.removeAt(i)),
                        ),
                      ]),
                    ),
                  ),
                if (_points.length < 5)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('c2c-post-add-point'),
                      onPressed: _addPoint,
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Add a meeting point'),
                    ),
                  ),
                if (rule != null) ...[
                  if (rule.doorOn)
                    tick('door', c2cDoorLine(rule.doorMaxKm, rule.doorPerKm, cur), _door, (v) => setState(() => _door = v)),
                  if (rule.womenOn && terms!.verifiedWoman)
                    tick('women', 'Women only', _women, (v) => setState(() => _women = v)),
                  if (rule.repeatOn) ...[
                    tick('repeat', leave == null ? 'Repeat this trip' : c2cRepeatLine(
                        _repeat == C2cRepeat.none ? C2cRepeat.weekly : _repeat, leave),
                        _repeat != C2cRepeat.none,
                        (v) => setState(() => _repeat = v ? C2cRepeat.weekly : C2cRepeat.none)),
                    if (_repeat != C2cRepeat.none) ...[
                      SegmentedButton<C2cRepeat>(
                        key: const ValueKey('c2c-post-repeat-mode'),
                        style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                        segments: [
                          for (final m in C2cRepeat.values.skip(1)) ButtonSegment(value: m, label: Text(m.label)),
                        ],
                        selected: {_repeat},
                        onSelectionChanged: (v) => setState(() => _repeat = v.first),
                      ),
                      const SizedBox(height: 8),
                      DateBoxesField(
                        key: const ValueKey('c2c-post-until'),
                        label: 'Last day',
                        controller: _until,
                        firstDate: leave ?? today,
                        lastDate: (leave ?? today).add(Duration(days: rule.repeatMaxWeeks * 7)),
                        helperText: 'Up to ${rule.repeatMaxWeeks} weeks; $_repeatCount trips',
                      ),
                    ],
                  ],
                  if (rule.parcelsOn) ...[
                    tick('parcels', 'Take parcels in the boot', _parcels > 0,
                        (v) => setState(() => _parcels = v ? 1 : 0)),
                    if (_parcels > 0) ...[
                      _StepRow(
                        label: 'Parcel slots',
                        hint: 'Up to ${rule.parcelMaxSlots}',
                        value: '$_parcels',
                        keyName: 'parcels',
                        onDown: _parcels > 1 ? () => setState(() => _parcels--) : null,
                        onUp: _parcels < rule.parcelMaxSlots ? () => setState(() => _parcels++) : null,
                      ),
                      SegmentedButton<C2cParcelSize>(
                        key: const ValueKey('c2c-post-parcel-size'),
                        style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                        segments: [
                          for (final z in C2cParcelSize.values)
                            if (z.index <= rule.parcelMaxSize.index) ButtonSegment(value: z, label: Text(z.label)),
                        ],
                        selected: {_parcelSize.index <= rule.parcelMaxSize.index ? _parcelSize : rule.parcelMaxSize},
                        onSelectionChanged: (v) => setState(() => _parcelSize = v.first),
                      ),
                      _StepRow(
                        label: 'Price a parcel',
                        hint: '${c2cMoney(rule.parcelMinPrice, cur)} to ${c2cMoney(rule.parcelMaxPrice, cur)}',
                        value: c2cMoney(_parcelPrice, cur),
                        keyName: 'parcel-price',
                        onDown: _parcelPrice - 1 >= rule.parcelMinPrice ? () => setState(() => _parcelPrice -= 1) : null,
                        onUp: _parcelPrice + 1 <= rule.parcelMaxPrice ? () => setState(() => _parcelPrice += 1) : null,
                      ),
                    ],
                  ],
                  const SizedBox(height: 6),
                  if (rule.joinMode == C2cJoinMode.driverPicks)
                    SegmentedButton<C2cJoinMode>(
                      key: const ValueKey('c2c-post-join'),
                      segments: const [
                        ButtonSegment(value: C2cJoinMode.instant, label: Text('Instant booking')),
                        ButtonSegment(value: C2cJoinMode.approve, label: Text('I approve riders')),
                      ],
                      selected: {_join},
                      onSelectionChanged: (v) => setState(() => _join = v.first),
                    )
                  else
                    Text(
                      rule.joinMode == C2cJoinMode.instant
                          ? 'Riders book at once here.'
                          : 'You approve each rider here.',
                      key: const ValueKey('c2c-post-join-fixed'),
                      style: t.textTheme.bodySmall?.copyWith(color: look.muted),
                    ),
                  _StepRow(
                    label: 'Free seats',
                    hint: 'Up to the seats in your car',
                    value: '$_seats',
                    keyName: 'seats',
                    onDown: _seats > 1 ? () => setState(() => _seats--) : null,
                    onUp: _seats < rule.maxSeats ? () => setState(() => _seats++) : null,
                  ),
                  _StepRow(
                    label: 'Price a seat',
                    hint: limits!.hint,
                    value: c2cMoney(price, cur),
                    keyName: 'price',
                    onDown: limits.mode == C2cSeatPriceMode.fixed || price - 5 < limits.low
                        ? null
                        : () => setState(() => _price = price - 5),
                    onUp: limits.mode == C2cSeatPriceMode.fixed || (limits.high != null && price + 5 > limits.high!)
                        ? null
                        : () => setState(() => _price = price + 5),
                  ),
                  const SizedBox(height: 6),
                  Text('Luggage room', style: t.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  SegmentedButton<bool>(
                    key: const ValueKey('c2c-post-luggage'),
                    segments: const [
                      ButtonSegment(value: false, label: Text('Small bags only')),
                      ButtonSegment(value: true, label: Text('1 suitcase each')),
                    ],
                    selected: {_suitcase},
                    onSelectionChanged: (v) => setState(() => _suitcase = v.first),
                  ),
                  const SizedBox(height: 12),
                  C2cBox(
                    key: const ValueKey('c2c-post-earn-box'),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('If every seat is booked', style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
                      Text(c2cEarnLine(_seats, price, cur),
                          key: const ValueKey('c2c-post-earn'),
                          style: t.textTheme.titleMedium?.copyWith(color: look.onBox, fontWeight: FontWeight.w600)),
                      Text(c2cSeatKeepLine(total, terms!.commissionRate, cur),
                          key: const ValueKey('c2c-post-keep'),
                          style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
                    ]),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (problem != null && terms != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(problem, key: const ValueKey('c2c-post-problem'),
                      style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                ),
              SizedBox(
                height: 52,
                width: double.infinity,
                child: BusyButton.filled(
                  key: const ValueKey('c2c-post-submit'),
                  onPressed: problem == null && terms != null ? _post : null,
                  child: Text(c2cPostButton(_seats, trips: _repeatCount)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A label, its hint, and − value + round buttons.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.hint, required this.value, required this.keyName, this.onDown, this.onUp});
  final String label, hint, value, keyName;
  final VoidCallback? onDown, onUp;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.textTheme.titleSmall),
            Text(hint, style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
          ]),
        ),
        C2cRoundButton(key: ValueKey('c2c-post-$keyName-down'), icon: Icons.remove, tooltip: 'Less', onPressed: onDown),
        SizedBox(
          width: 72,
          child: Text(value,
              key: ValueKey('c2c-post-$keyName'),
              textAlign: TextAlign.center,
              style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ),
        C2cRoundButton(key: ValueKey('c2c-post-$keyName-up'), icon: Icons.add, tooltip: 'More', onPressed: onUp),
      ]),
    );
  }
}

// ---- The Post a trip tab ------------------------------------------------------------------------------------

/// The driver's posted trips and Post a trip.
class C2cPostedTripsTab extends ConsumerWidget {
  const C2cPostedTripsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final trips = ref.watch(c2cDriverSeatTripsProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(c2cDriverSeatTripsProvider),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          C2cBox(
            key: const ValueKey('c2c-post-intro'),
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Post a trip and sell seats', style: t.textTheme.titleMedium?.copyWith(color: look.onBox)),
              const SizedBox(height: 4),
              Text('Going to another city anyway? Post the trip; riders book seats and pay per seat.',
                  style: t.textTheme.bodyMedium?.copyWith(color: look.mutedOnBox, height: 1.4)),
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const ValueKey('c2c-post-open'),
                onPressed: () => openC2cPostTrip(context),
                icon: const Icon(Icons.add_road),
                label: const Text('Post a trip'),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          AsyncView<List<C2cTrip>>(
            value: trips,
            onRetry: () => ref.invalidate(c2cDriverSeatTripsProvider),
            data: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: EmptyState(
                      key: ValueKey('c2c-posted-none'),
                      icon: Icons.event_seat_outlined,
                      title: 'No posted trips yet',
                      message: 'Your posted trips and their riders show here.',
                    ),
                  )
                : Column(children: [for (final trip in list) _PostedTripRow(trip: trip)]),
          ),
        ],
      ),
    );
  }
}

class _PostedTripRow extends StatelessWidget {
  const _PostedTripRow({required this.trip});
  final C2cTrip trip;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final x = trip;
    final waiting = x.requests.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: look.box,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: ValueKey('c2c-posted-${x.id}'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => openC2cDriverSeatTrip(context, x.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(x.route, style: t.textTheme.titleMedium?.copyWith(color: look.onBox))),
                if (waiting > 0 && !x.status.ended)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: look.chosen, borderRadius: BorderRadius.circular(10)),
                    child: Text('$waiting ${waiting == 1 ? 'request' : 'requests'}',
                        style: t.textTheme.labelSmall?.copyWith(color: look.onChosen, fontWeight: FontWeight.w600)),
                  )
                else
                  Text(x.status.label, style: t.textTheme.labelSmall?.copyWith(color: look.mutedOnBox)),
              ]),
              const SizedBox(height: 4),
              Text('${c2cDayTime(x.leaveAt)} · ${x.seatsBooked} of ${x.seatsTotal} seats booked · '
                  '${c2cMoney(x.seatPrice, x.currency)} a seat',
                  style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---- A posted trip ---------------------------------------------------------------------------------------

class C2cDriverSeatTripScreen extends ConsumerWidget {
  const C2cDriverSeatTripScreen({super.key, required this.tripId});
  final String tripId;

  Future<void> _decide(BuildContext context, WidgetRef ref, C2cSeatBooking b, bool approve) async {
    String? reason;
    if (!approve) {
      final ok = await showAppDialog<bool>(
        id: 'city-to-city.seat-decline',
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Decline this request?'),
          content: Text('${b.riderName} is told, and any fare held goes back to them.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
            FilledButton(
              key: const ValueKey('c2c-seat-decline-confirm'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Decline'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      reason = null;
    }
    try {
      await ref.read(cityToCityRepositoryProvider).seatDecide(b.id, approve: approve, reason: reason);
      ref.invalidate(c2cDriverSeatTripsProvider);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _progress(BuildContext context, WidgetRef ref, C2cTrip x, C2cTripStatus to) async {
    try {
      await ref.read(cityToCityRepositoryProvider).tripProgress(x.id, to);
      ref.invalidate(c2cDriverSeatTripsProvider);
      if (context.mounted && to == C2cTripStatus.completed) {
        showInfo(context, 'Trip finished. In-app fares are paid to you less commission.');
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, C2cTrip x) async {
    final booked = x.riding.where((b) => b.status.withDriver).length;
    var series = false;
    final ok = await showAppDialog<bool>(
      id: 'city-to-city.trip-cancel',
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Cancel this trip?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(booked == 0
                ? 'No rider is booked yet. Requests waiting are declined.'
                : '$booked ${booked == 1 ? 'booking is' : 'bookings are'} cancelled and the riders told. The give-up fee '
                      'of each rider\'s region may apply to you, once for each.'),
            if (x.seriesId != null)
              CheckboxListTile(
                key: const ValueKey('c2c-trip-cancel-series'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Also cancel the later trips of this repeat'),
                value: series,
                onChanged: (v) => set(() => series = v ?? false),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep trip')),
            FilledButton(
              key: const ValueKey('c2c-trip-cancel-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(c).colorScheme.error,
                foregroundColor: Theme.of(c).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Cancel trip'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final r = await ref.read(cityToCityRepositoryProvider).tripCancel(x.id, series: series);
      ref.invalidate(c2cDriverSeatTripsProvider);
      if (!context.mounted) return;
      showInfo(
        context,
        r.fees > 0
            ? 'Trip cancelled. Give-up fees of ${c2cMoney(r.fees, x.currency)} were charged.'
            : 'Trip cancelled. The riders were told.',
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _call(BuildContext context, WidgetRef ref, C2cSeatBooking b) async {
    try {
      final c = await ref.read(cityToCityRepositoryProvider).contact(b.id);
      if (!context.mounted) return;
      final phone = c?.phone;
      if (phone == null) return showInfo(context, "The rider's phone number isn't available.");
      await ref.read(c2cLauncherProvider)(Uri(scheme: 'tel', path: phone));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final async = ref.watch(c2cDriverSeatTripsProvider);
    final now = ref.watch(c2cClockProvider)();
    return Scaffold(
      appBar: AppBar(title: const Text('Your posted trip')),
      body: SafeArea(
        child: AsyncView<List<C2cTrip>>(
          value: async,
          onRetry: () => ref.invalidate(c2cDriverSeatTripsProvider),
          data: (list) {
            final x = list.where((e) => e.id == tripId).firstOrNull;
            if (x == null) return const EmptyState(icon: Icons.route, title: 'Trip not found');
            final riding = x.riding;
            return Column(children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    C2cBox(
                      key: const ValueKey('c2c-seat-trip-summary'),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${c2cDayTime(x.leaveAt)} · ${x.route}',
                            style: t.textTheme.titleMedium?.copyWith(color: look.onBox, fontWeight: FontWeight.w600)),
                        Text('${x.seatsBooked} of ${x.seatsTotal} seats booked · ${c2cMoney(x.seatPrice, x.currency)} a seat · '
                            '${x.instant ? 'instant' : 'you approve'}',
                            style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
                        for (final p in x.meetingPoints)
                          C2cIconLine(icon: Icons.pin_drop_outlined, text: '${c2cClock(p.at(x.leaveAt))} ${p.name}'),
                      ]),
                    ),
                    if (x.requests.isNotEmpty && x.status == C2cTripStatus.scheduled) ...[
                      const SizedBox(height: 12),
                      Text('Requests', style: t.textTheme.titleSmall),
                      const SizedBox(height: 6),
                    ],
                    // The request cards come and go with the locked offer motion.
                    OfferMotionList(
                      gap: 8,
                      children: [
                        if (x.status == C2cTripStatus.scheduled)
                          for (final b in x.requests)
                            _RequestCard(
                              key: ValueKey('c2c-seat-request-motion-${b.id}'),
                              booking: b,
                              now: now,
                              onApprove: () => _decide(context, ref, b, true),
                              onDecline: () => _decide(context, ref, b, false),
                              onChat: () => openC2cChat(context, b.id, driver: true),
                            ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(riding.isEmpty ? 'No passengers yet' : 'Passengers', style: t.textTheme.titleSmall),
                    for (final b in riding)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: C2cBox(
                          key: ValueKey('c2c-seat-passenger-${b.id}'),
                          border: look.line,
                          color: Colors.transparent,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(b.who, style: t.textTheme.titleSmall),
                            if (b.names.length > 1)
                              Text(b.names.join(', '), style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                            Text(b.pickupLine, style: t.textTheme.bodySmall),
                            if (b.parcel && b.recipient != null)
                              Text('To: ${b.recipient}', style: t.textTheme.bodySmall),
                            Text(b.payLine, style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                            if (b.status.withDriver)
                              Row(children: [
                                TextButton.icon(
                                  key: ValueKey('c2c-seat-chat-${b.id}'),
                                  onPressed: () => openC2cChat(context, b.id, driver: true),
                                  icon: const Icon(Icons.chat),
                                  label: const Text('Chat'),
                                ),
                                TextButton.icon(
                                  key: ValueKey('c2c-seat-call-${b.id}'),
                                  onPressed: () => _call(context, ref, b),
                                  icon: const Icon(Icons.call),
                                  label: const Text('Call'),
                                ),
                              ]),
                          ]),
                        ),
                      ),
                  ],
                ),
              ),
              if (!x.status.ended)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Row(children: [
                    if (x.status == C2cTripStatus.scheduled) ...[
                      Expanded(
                        child: SizedBox(
                          height: 52,
                          child: OutlinedButton(
                            key: const ValueKey('c2c-trip-cancel'),
                            style: OutlinedButton.styleFrom(foregroundColor: look.drop, side: BorderSide(color: look.drop)),
                            onPressed: () => _cancel(context, ref, x),
                            child: const Text('Cancel trip'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: BusyButton.filled(
                          key: const ValueKey('c2c-trip-step'),
                          onPressed: () => _progress(context, ref, x,
                              x.status == C2cTripStatus.scheduled ? C2cTripStatus.onTrip : C2cTripStatus.completed),
                          child: Text(x.status == C2cTripStatus.scheduled ? 'Start trip' : 'Finish trip'),
                        ),
                      ),
                    ),
                  ]),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

/// A seat request: who, how many, where, the fare, when it lapses; Approve,
/// Decline and Chat.
class _RequestCard extends StatelessWidget {
  const _RequestCard({
    super.key,
    required this.booking,
    required this.now,
    required this.onApprove,
    required this.onDecline,
    required this.onChat,
  });
  final C2cSeatBooking booking;
  final DateTime now;
  final VoidCallback onApprove, onDecline, onChat;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    final left = b.expiresAt?.difference(now);
    return C2cBox(
      key: ValueKey('c2c-seat-request-${b.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(b.who, style: t.textTheme.titleSmall?.copyWith(color: look.onBox)),
        Text(b.pickupLine, style: t.textTheme.bodySmall?.copyWith(color: look.onBox)),
        Text([b.payLine, if (left != null && !left.isNegative) 'answer within ${c2cTimeLeft(left)}'].join(' · '),
            style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
        const SizedBox(height: 6),
        Row(children: [
          IconButton(tooltip: 'Chat', onPressed: onChat, icon: const Icon(Icons.chat_outlined)),
          Expanded(
            child: OutlinedButton(
              key: ValueKey('c2c-seat-decline-${b.id}'),
              onPressed: onDecline,
              child: const Text('Decline'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              key: ValueKey('c2c-seat-approve-${b.id}'),
              onPressed: onApprove,
              child: const Text('Approve'),
            ),
          ),
        ]),
      ]),
    );
  }
}
