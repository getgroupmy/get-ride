// City to City per-seat trips for riders (migration 0310; the approved
// board 17, Book a seat):
//
//   Find a trip   Book a seat or Whole car; From and To, the day (date
//                 boxes), the seats; the trips drivers posted: the time, how
//                 long, the seat price, the driver and seats left, the tags
//                 (Instant or Driver approves, Women only, Door pickup, a
//                 repeat, parcels).
//   Book a seat   the trip, the seats (each passenger named when more than
//                 1; a family host picks who rides from their family, 0317),
//                 where to meet (a meeting point, or the rider's door with
//                 its extra), or a parcel instead, Family (the member's own
//                 seats on the host's GET.wallet), In app or Cash (the way to
//                 pay when it is held now), the total and Book (or Request).
//   The booking   the rider's trip page (city_to_city_trip.dart) shows it;
//                 this file adds the driver and co-riders card and the page
//                 for a request waiting for the driver.
//
// The server checks it all again (C2C_* codes, shown as modals).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/booking_modules.dart' show familyModuleSeatTrip;
import '../../core/city_to_city.dart';
import '../../core/city_to_city_seats.dart';
import '../../core/commission.dart' show Geo;
import '../../core/family.dart' show FamilyPick, possessive;
import '../../data/city_to_city_repository.dart';
import '../../data/family_repository.dart' show familyPayOptionProvider;
import '../../data/geo_service.dart' show Place;
import '../../providers.dart' show profileProvider;
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show EmptyState, showError, showInfo;
import '../../widgets/date_boxes.dart';
import '../../widgets/page_style_host.dart';
import 'city_to_city_parts.dart';
import 'city_to_city_steps.dart' show c2cAreaProvider, c2cClockProvider, openC2cSteps;
import 'city_to_city_trip.dart' show openC2cChat, openC2cTrip;
import 'freight_screen.dart' show freightPlaceSearchProvider;

/// Opens Find a trip.
Future<void> openC2cSeatSearch(BuildContext context) => Navigator.of(context)
    .push<void>(AppPageRoute(id: 'ride.city-to-city-seats', builder: (_) => const C2cSeatSearchScreen()));

/// Opens Book a seat on [trip], starting at [seats] seats.
Future<void> openC2cSeatBook(BuildContext context, C2cTrip trip, {int seats = 1}) => Navigator.of(context).push<void>(
  AppPageRoute(id: 'ride.city-to-city-seat-book', builder: (_) => C2cSeatBookScreen(trip: trip, seats: seats)),
);

Future<C2cEnd?> _pickEnd(BuildContext context, WidgetRef ref, String title, C2cEnd? near) async {
  final Place? place = await ref.read(freightPlaceSearchProvider)(
    context,
    title: title,
    near: near == null ? null : LatLng(near.lat, near.lng),
  );
  if (place == null || !context.mounted) return null;
  final area = await ref.read(c2cAreaProvider)(place.point);
  return C2cEnd(
    name: place.name.trim().isEmpty ? place.address : place.name,
    address: place.address.trim().isEmpty ? null : place.address,
    lat: place.point.latitude,
    lng: place.point.longitude,
    place: area ?? const Geo(),
  );
}

/// A place as searched: its city (else state), country.
Geo _searchGeo(Geo g) => Geo(country: g.country, state: g.city == null ? g.state : null, city: g.city);

// ---- Find a trip --------------------------------------------------------------------------------------------

class C2cSeatSearchScreen extends ConsumerStatefulWidget {
  const C2cSeatSearchScreen({super.key});

  @override
  ConsumerState<C2cSeatSearchScreen> createState() => _C2cSeatSearchScreenState();
}

class _C2cSeatSearchScreenState extends ConsumerState<C2cSeatSearchScreen> {
  C2cEnd? _from, _to;
  final _day = TextEditingController();
  int _seats = 1;
  List<C2cTrip>? _found;

  @override
  void initState() {
    super.initState();
    _day.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _day.dispose();
    super.dispose();
  }

  Future<void> _pick(bool from) async {
    final end = await _pickEnd(context, ref, from ? 'From city' : 'To city', from ? _from : _to ?? _from);
    if (end == null || !mounted) return;
    setState(() {
      if (from) {
        _from = end;
      } else {
        _to = end;
      }
      _found = null;
    });
  }

  Future<void> _search() async {
    final a = _from, b = _to;
    if (a == null || b == null) return;
    try {
      final list = await ref.read(cityToCityRepositoryProvider).searchTrips(
        from: _searchGeo(a.place),
        to: _searchGeo(b.place),
        day: parseIsoDate(_day.text),
        seats: _seats,
      );
      if (mounted) setState(() => _found = list);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final now = ref.watch(c2cClockProvider)();
    final today = DateTime(now.year, now.month, now.day);
    final day = parseIsoDate(_day.text);
    final a = _from, b = _to;
    final route = a == null || b == null
        ? null
        : '${a.place.city ?? a.place.state ?? a.name} to ${b.place.city ?? b.place.state ?? b.name}';
    Widget end(String label, C2cEnd? e, bool from) => Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.labelLarge),
        const SizedBox(height: 4),
        OutlinedButton(
          key: ValueKey(from ? 'c2c-seat-from' : 'c2c-seat-to'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            alignment: Alignment.centerLeft,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: () => _pick(from),
          child: Text(e == null ? 'Pick' : (e.place.city ?? e.place.state ?? e.name), overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
    return Scaffold(
      appBar: AppBar(title: Text(route ?? 'Book a seat')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            SegmentedButton<bool>(
              key: const ValueKey('c2c-seat-mode'),
              segments: const [
                ButtonSegment(value: true, label: Text('Book a seat')),
                ButtonSegment(value: false, label: Text('Whole car')),
              ],
              selected: const {true},
              onSelectionChanged: (v) {
                if (v.first) return;
                Navigator.of(context).pop();
                openC2cSteps(context);
              },
            ),
            const SizedBox(height: 12),
            Row(children: [end('From city', a, true), const SizedBox(width: 10), end('To city', b, false)]),
            const SizedBox(height: 10),
            DateBoxesField(
              key: const ValueKey('c2c-seat-day'),
              label: 'Day (any in the next 14 days if empty)',
              controller: _day,
              firstDate: today,
              lastDate: today.add(const Duration(days: 90)),
            ),
            Row(children: [
              Expanded(child: Text('Seats', style: t.textTheme.titleSmall)),
              C2cRoundButton(
                key: const ValueKey('c2c-seat-search-down'),
                icon: Icons.remove,
                tooltip: 'Fewer seats',
                onPressed: _seats > 1 ? () => setState(() => _seats--) : null,
              ),
              SizedBox(width: 36, child: Text('$_seats', textAlign: TextAlign.center, style: t.textTheme.titleMedium)),
              C2cRoundButton(
                key: const ValueKey('c2c-seat-search-up'),
                icon: Icons.add,
                tooltip: 'More seats',
                onPressed: _seats < 6 ? () => setState(() => _seats++) : null,
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              height: 48,
              child: BusyButton.filled(
                key: const ValueKey('c2c-seat-search'),
                onPressed: a != null && b != null ? _search : null,
                child: const Text('Find trips'),
              ),
            ),
            if (_found != null) ...[
              const SizedBox(height: 14),
              Text(
                [?route, if (day != null) c2cDayTime(day).split(',').first, '$_seats ${_seats == 1 ? 'seat' : 'seats'}']
                    .join(' · '),
                key: const ValueKey('c2c-seat-search-line'),
                style: t.textTheme.bodySmall?.copyWith(color: look.muted),
              ),
              const SizedBox(height: 8),
              if (_found!.isEmpty)
                const EmptyState(
                  key: ValueKey('c2c-seat-none'),
                  icon: Icons.event_seat_outlined,
                  title: 'No trips found',
                  message: 'Try another day, or book a whole car.',
                ),
              for (final trip in _found!) _TripCard(trip: trip, seats: _seats),
            ],
          ],
        ),
      ),
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip, required this.seats});
  final C2cTrip trip;
  final int seats;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final x = trip;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: look.line)),
        child: InkWell(
          key: ValueKey('c2c-seat-trip-${x.id}'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => openC2cSeatBook(context, x, seats: seats),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(c2cClock(x.leaveAt), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(c2cDurationText(x.durationMin), style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                ),
                Text(c2cMoney(x.seatPrice, x.currency),
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 4),
              Text(c2cTripDriverLine(x), style: t.textTheme.bodyMedium),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final (label, tone) in c2cTripTags(x))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: switch (tone) { 'good' => look.good, 'pink' => look.chosen, _ => look.box },
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(label,
                        style: t.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: switch (tone) { 'good' => look.onGood, 'pink' => look.onChosen, _ => look.onBox },
                        )),
                  ),
              ]),
              if (!x.mayBook) ...[
                const SizedBox(height: 6),
                Text('Women only: verify your ID as a woman to book.',
                    style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

// ---- Book a seat ----------------------------------------------------------------------------------------------

class C2cSeatBookScreen extends ConsumerStatefulWidget {
  const C2cSeatBookScreen({super.key, required this.trip, this.seats = 1});
  final C2cTrip trip;
  final int seats;

  @override
  ConsumerState<C2cSeatBookScreen> createState() => _C2cSeatBookScreenState();
}

class _C2cSeatBookScreenState extends ConsumerState<C2cSeatBookScreen> {
  late int _seats = widget.seats.clamp(1, _maxSeats).toInt();

  /// The meeting point picked, or -1 for the rider's door.
  int _pick = 0;
  C2cEnd? _door;
  bool _parcel = false;
  C2cParcelSize _size = C2cParcelSize.small;
  final _names = <TextEditingController>[];
  final _familyIds = <String?>[];
  final _recipient = TextEditingController();
  final _phone = TextEditingController();
  final _parcelNote = TextEditingController();
  C2cPayment? _payment;
  bool _payPicked = false;
  C2cPayWay? _way;
  C2cPayInfo? _info;

  int get _maxSeats => math.max(1, math.min(widget.trip.maxPerBooking, widget.trip.seatsLeft));

  @override
  void initState() {
    super.initState();
    for (final c in [_recipient, _phone, _parcelNote]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
    _ensureNames();
    _loadPay();
  }

  @override
  void dispose() {
    for (final c in [..._names, _recipient, _phone, _parcelNote]) {
      c.dispose();
    }
    super.dispose();
  }

  void _ensureNames() {
    while (_names.length < _seats) {
      final c = TextEditingController(
        text: _names.isEmpty ? (ref.read(profileProvider).value?.name ?? '') : '',
      )..addListener(() {
          if (mounted) setState(() {});
        });
      _names.add(c);
      _familyIds.add(null);
    }
  }

  Future<void> _loadPay() async {
    try {
      final info = await ref.read(cityToCityRepositoryProvider).seatPayInfo(widget.trip.id);
      if (mounted) setState(() => _info = info);
    } catch (_) {}
  }

  Future<void> _pickDoor() async {
    final first = widget.trip.meetingPoints.firstOrNull;
    final end = await _pickEnd(
      context,
      ref,
      'Your pickup address',
      first == null ? null : C2cEnd(name: first.name, lat: first.lat, lng: first.lng),
    );
    if (end == null || !mounted) return;
    setState(() {
      _door = end;
      _pick = -1;
    });
  }

  ({double km, double extra, C2cMeetingPoint? nearest, bool ok})? get _doorQuote {
    final d = _door;
    return d == null ? null : c2cDoorQuote(widget.trip, d.lat, d.lng);
  }

  double get _total {
    final x = widget.trip;
    if (_parcel) return x.parcelPrice ?? 0;
    return c2cSeatTotal(x.seatPrice, _seats, doorExtra: _pick == -1 ? (_doorQuote?.extra ?? 0) : 0);
  }

  List<C2cPassenger> get _passengers => [
    for (var i = 0; i < _seats && i < _names.length; i++) (name: _names[i].text, familyMemberId: _familyIds[i]),
  ];

  bool get _inApp => _payment == C2cPayment.inApp || _payment == C2cPayment.family;

  bool get _held => _inApp && (_info?.when ?? C2cPayWhen.hold) == C2cPayWhen.hold;

  /// Family (0317): the family member the host picked to ride, the first one
  /// named; with an adult when the host (the first seat) rides too.
  FamilyPick? get _familyPick {
    if (_parcel) return null;
    for (var i = 0; i < _seats && i < _familyIds.length; i++) {
      final id = _familyIds[i];
      if (id != null) return (id: id, withAdult: i > 0 && _familyIds[0] == null);
    }
    return null;
  }

  String? get _problem {
    final x = widget.trip;
    if (!x.mayBook) return 'This trip is for women only.';
    if (_parcel) {
      if (_recipient.text.trim().isEmpty || !RegExp(r'^\+?[0-9 ]{6,20}$').hasMatch(_phone.text.trim())) {
        return "Give the recipient's name and phone number.";
      }
    } else {
      if (x.seatsLeft < _seats) return 'Not enough seats are left.';
      final why = c2cNamesProblem(_seats, _passengers);
      if (why != null) return why;
    }
    if (_pick == -1) {
      final q = _doorQuote;
      if (q == null) return 'Pick your pickup address.';
      if (!q.ok) return 'Your address is too far off the route. Pick a meeting point.';
    }
    if (_payment == null) return 'Pick how to pay.';
    if (_held && _way == null) return 'Pick a way to pay.';
    return null;
  }

  Future<void> _book() async {
    final x = widget.trip;
    final pay = _payment;
    if (pay == null || _problem != null) return;
    final door = _door;
    final dues = _held ? (_info?.duesTotal ?? 0) : 0.0;
    try {
      final r = await ref.read(cityToCityRepositoryProvider).bookSeat(
        tripId: x.id,
        seats: _parcel ? 1 : _seats,
        pickup: _pick == -1 && door != null
            ? {'kind': 'door', 'name': door.name, 'address': ?door.address, 'lat': door.lat, 'lng': door.lng}
            : {'kind': 'meeting', 'index': _pick},
        payment: pay,
        passengers: _parcel || (_seats == 1 && _familyIds.first == null) ? const [] : _passengers,
        way: _held ? _way : null,
        expected: _held ? c2cRound2(_total + dues) : null,
        parcel: _parcel
            ? {
                'size': _size.key,
                'recipientName': _recipient.text.trim(),
                'recipientPhone': _phone.text.trim(),
                if (_parcelNote.text.trim().isNotEmpty) 'note': _parcelNote.text.trim(),
              }
            : null,
        family: _familyPick,
      );
      ref.invalidate(c2cMyTripsProvider);
      if (!mounted) return;
      showInfo(
        context,
        r.status == 'booked'
            ? 'Booked. ${x.driverName} sees you on the trip; reminders follow your settings.'
            : 'Request sent. ${x.driverName} answers soon; you can chat meanwhile.',
      );
      if (mounted) await openC2cTrip(context, r.id, replace: true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final x = widget.trip;
    final settings = ref.watch(c2cSettingsProvider).value ?? const C2cSettings();
    // Family (0317): the member's own seats on the host's GET.wallet.
    final familyPay = ref.watch(familyPayOptionProvider(familyModuleSeatTrip)).value;
    final payments = c2cPaymentsWithFamily(settings, family: familyPay?.available ?? false);
    // The first way (Family, once it is known) until the rider picks one.
    if (!_payPicked || !payments.contains(_payment)) _payment = payments.firstOrNull;
    final info = _info;
    final ways = _payment == C2cPayment.family ? const [C2cPayWay.wallet] : info?.ways ?? const <C2cPayWay>[];
    if (_held && (_way == null || !ways.contains(_way))) _way = ways.firstOrNull;
    final payFrom = _payment == C2cPayment.family
        ? '${possessive(familyPay?.hostName ?? 'Family host')} GET wallet'
        : 'your ${_way == C2cPayWay.coin ? 'coins' : 'GET wallet'}';
    final family = ref.watch(c2cPassengerChoicesProvider).value ?? const <C2cPassenger>[];
    final door = _doorQuote;
    final total = _total;
    final problem = _problem;
    Widget radio(int i, String label, String note, {Key? key}) {
      final on = _pick == i;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: on ? look.accent : look.line, width: on ? 2 : 1),
          ),
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(12),
            onTap: () => i == -1 ? _pickDoor() : setState(() => _pick = i),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(children: [
                  Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: on ? look.accent : look.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: t.textTheme.titleSmall),
                      Text(note, style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(_parcel ? 'Send a parcel' : 'Book a seat')),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(
              key: const ValueKey('c2c-seat-book-list'),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                C2cBox(
                  key: const ValueKey('c2c-seat-book-summary'),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${c2cDayTime(x.leaveAt)} · ${x.route}',
                        style: t.textTheme.titleMedium?.copyWith(color: look.onBox, fontWeight: FontWeight.w600)),
                    Text(
                      [x.driverLine, if (x.carLine.isNotEmpty) x.carLine, '${x.seatsLeft} of ${x.seatsTotal} seats left']
                          .join(' · '),
                      style: t.textTheme.bodyMedium?.copyWith(color: look.onBox),
                    ),
                    Text(
                      '${x.suitcase ? '1 suitcase each' : 'Small bags only'} · ${c2cJoinLine(x)}'
                      '${x.womenOnly ? ' · Women only' : ''}',
                      key: const ValueKey('c2c-seat-join-line'),
                      style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox),
                    ),
                    if (x.note != null) Text(x.note!, style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
                  ]),
                ),
                if (x.parcelsLeft > 0 && x.parcelPrice != null) ...[
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    key: const ValueKey('c2c-seat-or-parcel'),
                    segments: const [
                      ButtonSegment(value: false, label: Text('A seat')),
                      ButtonSegment(value: true, label: Text('A parcel')),
                    ],
                    selected: {_parcel},
                    onSelectionChanged: (v) => setState(() => _parcel = v.first),
                  ),
                ],
                const SizedBox(height: 10),
                if (_parcel) ...[
                  Text('Parcel up to ${x.parcelMaxSize?.label.toLowerCase() ?? 'small'}, '
                      '${c2cMoney(x.parcelPrice ?? 0, x.currency)}', style: t.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  SegmentedButton<C2cParcelSize>(
                    key: const ValueKey('c2c-parcel-size'),
                    segments: [
                      for (final z in C2cParcelSize.values)
                        if (z.index <= (x.parcelMaxSize ?? C2cParcelSize.small).index)
                          ButtonSegment(value: z, label: Text(z.label)),
                    ],
                    selected: {_size},
                    onSelectionChanged: (v) => setState(() => _size = v.first),
                  ),
                  Text(_size.hint, style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                  TextField(
                    key: const ValueKey('c2c-parcel-recipient'),
                    controller: _recipient,
                    decoration: const InputDecoration(labelText: 'Who collects it'),
                  ),
                  TextField(
                    key: const ValueKey('c2c-parcel-phone'),
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Their phone number'),
                  ),
                  TextField(
                    key: const ValueKey('c2c-parcel-note'),
                    controller: _parcelNote,
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: "What's in it (optional)"),
                  ),
                ] else ...[
                  Row(children: [
                    Expanded(child: Text('Seats', style: t.textTheme.titleSmall)),
                    C2cRoundButton(
                      key: const ValueKey('c2c-seat-down'),
                      icon: Icons.remove,
                      tooltip: 'Fewer seats',
                      onPressed: _seats > 1 ? () => setState(() => _seats--) : null,
                    ),
                    SizedBox(
                      width: 32,
                      child: Text('$_seats',
                          key: const ValueKey('c2c-seat-count'), textAlign: TextAlign.center, style: t.textTheme.titleMedium),
                    ),
                    C2cRoundButton(
                      key: const ValueKey('c2c-seat-up'),
                      icon: Icons.add,
                      tooltip: 'More seats',
                      onPressed: _seats < _maxSeats
                          ? () => setState(() {
                                _seats++;
                                _ensureNames();
                              })
                          : null,
                    ),
                  ]),
                  if (_seats == 1 && family.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text('Who rides', style: t.textTheme.titleSmall),
                    Wrap(spacing: 6, children: [
                      ChoiceChip(
                        key: const ValueKey('c2c-seat-who-me'),
                        label: const Text('Me'),
                        selected: _familyIds.first == null,
                        onSelected: (_) => setState(() {
                          _familyIds[0] = null;
                          _names[0].text = ref.read(profileProvider).value?.name ?? '';
                        }),
                      ),
                      for (final f in family)
                        ChoiceChip(
                          key: ValueKey('c2c-seat-who-${f.familyMemberId}'),
                          label: Text(f.name),
                          selected: _familyIds.first == f.familyMemberId,
                          onSelected: (_) => setState(() {
                            _familyIds[0] = f.familyMemberId;
                            _names[0].text = f.name;
                          }),
                        ),
                    ]),
                  ],
                  if (_seats > 1) ...[
                    const SizedBox(height: 6),
                    Text('Who rides', style: t.textTheme.titleSmall),
                    if (family.isNotEmpty)
                      Wrap(spacing: 6, children: [
                        for (final f in family)
                          ActionChip(
                            label: Text(f.name),
                            onPressed: () {
                              final i = [for (var k = 1; k < _seats; k++) if (_names[k].text.trim().isEmpty) k].firstOrNull;
                              if (i == null) return;
                              setState(() {
                                _names[i].text = f.name;
                                _familyIds[i] = f.familyMemberId;
                              });
                            },
                          ),
                      ]),
                    for (var i = 0; i < _seats; i++)
                      TextField(
                        key: ValueKey('c2c-seat-name-$i'),
                        controller: _names[i],
                        maxLength: 80,
                        decoration: InputDecoration(labelText: i == 0 ? 'You' : 'Passenger ${i + 1}', counterText: ''),
                      ),
                  ],
                ],
                const SizedBox(height: 10),
                Text(_parcel ? 'Where to hand it over' : 'Where to meet', style: t.textTheme.titleSmall),
                const SizedBox(height: 6),
                for (final (i, p) in x.meetingPoints.indexed)
                  radio(i, p.name, 'Meeting point · ${c2cClock(p.at(x.leaveAt))}', key: ValueKey('c2c-seat-point-$i')),
                if (x.doorPickup && !_parcel)
                  radio(
                    -1,
                    _door == null ? 'My address' : 'My address: ${_door!.name}',
                    door == null
                        ? 'Door pickup within ${(x.doorMaxKm ?? 0).toStringAsFixed(0)} km of the route, '
                              '+ ${c2cMoney(x.doorPerKm ?? 0, x.currency)} a km'
                        : door.ok
                        ? c2cDoorNote(door.km, door.extra, x.currency)
                        : 'Too far: ${door.km} km off the route (up to ${x.doorMaxKm} km)',
                    key: const ValueKey('c2c-seat-door'),
                  ),
                if (!_parcel && x.coridersOn)
                  Text('You see who else rides once you are booked.',
                      style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                const SizedBox(height: 10),
                Text('Payment', style: t.textTheme.titleSmall),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  for (final p in payments)
                    ChoiceChip(
                      key: ValueKey('c2c-seat-pay-${p.key}'),
                      label: Text(p == C2cPayment.family && familyPay != null ? familyPay.label : p.label),
                      selected: _payment == p,
                      onSelected: (_) => setState(() {
                        _payment = p;
                        _payPicked = true;
                      }),
                    ),
                ]),
                if (_held && ways.length > 1) ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, children: [
                    for (final w in ways)
                      ChoiceChip(
                        key: ValueKey('c2c-seat-way-${w.key}'),
                        label: Text(w.label),
                        selected: _way == w,
                        onSelected: (_) => setState(() => _way = w),
                      ),
                  ]),
                ],
                if (_inApp && info != null)
                  Text(
                    _held
                        ? 'Paid now from $payFrom'
                              '${info.duesTotal > 0 ? ', with ${c2cMoney(info.duesTotal, x.currency)} owed' : ''}'
                              '${x.instant ? '' : '; back in full if the driver declines'}.'
                        : 'Paid in the app after the trip.',
                    key: const ValueKey('c2c-seat-pay-note'),
                    style: t.textTheme.bodySmall?.copyWith(color: look.muted),
                  ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: Text('Total', style: t.textTheme.titleMedium)),
                  Text(c2cMoney(total, x.currency),
                      key: const ValueKey('c2c-seat-total'),
                      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ]),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(problem, key: const ValueKey('c2c-seat-problem'),
                      style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                ),
              SizedBox(
                height: 52,
                width: double.infinity,
                child: BusyButton.filled(
                  key: const ValueKey('c2c-seat-book'),
                  onPressed: problem == null ? _book : null,
                  child: Text(c2cBookButton(_seats, total, instant: x.instant, parcel: _parcel, currency: x.currency)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---- On the rider's trip page -----------------------------------------------------------------------------

/// The driver of a seat booking's trip and, once booked, who else rides.
class C2cSeatDriverCard extends ConsumerWidget {
  const C2cSeatDriverCard({super.key, required this.booking, this.actions});
  final C2cBooking booking;
  final Widget? actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final trip = ref.watch(c2cRiderTripProvider(booking.tripId!)).value;
    final others = booking.status.withDriver || booking.status == C2cStatus.completed
        ? ref.watch(c2cCoridersProvider(booking.id)).value ?? const []
        : const <({String name, double? rating, String pickup, int seats})>[];
    return C2cBox(
      key: const ValueKey('c2c-seat-driver'),
      color: Colors.transparent,
      border: look.line,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          C2cAvatar(initials: c2cInitials(trip?.driverName ?? 'Driver'), size: 48),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(trip?.driverLine ?? 'Your driver', style: t.textTheme.titleMedium),
              if (trip != null && trip.carLine.isNotEmpty)
                Text(trip.carLine, style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
            ]),
          ),
        ]),
        if (booking.passengerNames.length > 1) ...[
          const SizedBox(height: 8),
          Text('Riding: ${booking.passengerNames.join(', ')}', style: t.textTheme.bodySmall),
        ],
        if (others.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Riding with you', style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
          Text(
            [
              for (final o in others)
                '${o.name}${o.rating == null ? '' : ' ${o.rating!.toStringAsFixed(1)}'} (${o.pickup})',
            ].join(' · '),
            key: const ValueKey('c2c-seat-coriders'),
            style: t.textTheme.bodyMedium,
          ),
        ],
        if (actions != null) ...[const SizedBox(height: 8), actions!],
      ]),
    );
  }
}

/// A seat request waiting for the driver: when it lapses, Chat, Cancel.
class C2cSeatRequestedView extends ConsumerWidget {
  const C2cSeatRequestedView({super.key, required this.booking, required this.onCancel});
  final C2cBooking booking;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    final until = b.expiresAt;
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            C2cBanner(
              key: const ValueKey('c2c-seat-requested-banner'),
              icon: Icons.hourglass_top,
              title: 'Waiting for the driver',
              line: until == null
                  ? 'The driver approves each rider.'
                  : 'The driver answers by ${c2cClock(until)}; if not, the request lapses'
                        '${b.payStatus == 'held' ? ' and the fare held comes back' : ''}.',
              fill: look.box,
              ink: look.onBox,
            ),
            const SizedBox(height: 12),
            Text(c2cLeaveText(b.leaveAt), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            C2cIconLine(icon: Icons.trip_origin, color: look.accent, text: b.pickupLine),
            C2cIconLine(icon: Icons.location_on, color: look.drop, text: b.dropLine),
            Text('${c2cBookingKind(b)} · ${c2cMoney(b.price, b.currency)} · ${c2cRiderPayLabel(b)}',
                style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
            const SizedBox(height: 12),
            C2cSeatDriverCard(
              booking: b,
              actions: OutlinedButton.icon(
                key: const ValueKey('c2c-seat-request-chat'),
                onPressed: () => openC2cChat(context, b.id),
                icon: const Icon(Icons.chat),
                label: const Text('Chat'),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(
          height: 52,
          width: double.infinity,
          child: OutlinedButton(
            key: const ValueKey('c2c-seat-request-cancel'),
            style: OutlinedButton.styleFrom(foregroundColor: look.drop, side: BorderSide(color: look.drop)),
            onPressed: onCancel,
            child: const Text('Cancel request'),
          ),
        ),
      ),
    ]);
  }
}
