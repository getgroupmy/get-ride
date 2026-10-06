import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../../admin/screens/meterapp/meter_logic.dart';
import '../../core/meter_trip.dart';
import '../../core/escpos.dart';
import '../../core/landscape_stage.dart';
import '../../core/obd.dart';
import '../../core/taxi_meter.dart';
import '../../data/geo_service.dart';
import '../../data/obd/obd_session.dart';
import '../../data/printer/printer_service.dart';
import '../../providers.dart';
import 'landscape_stage.dart';
import 'meter_leave_launcher.dart';
import 'meter_providers.dart';

// The console is deliberately not themed: a white screen on a windscreen
// mount at night is a hazard, so the meter is always the dark instrument it
// replaces (as in the Expo app).
const _bg = Color(0xFF0B0F0E);
const _panel = Color(0xFF151B19);
const _lcd = Color(0xFF7CFF6B);
const _lcdDim = Color(0xFF2E4A2B);
const _amber = Color(0xFFFFC94D);
const _muted = Color(0xFF8A9A94);

/// A fix older than this is not used: repeating it would read as standing
/// still while the car is moving.
const _fixMaxAgeMs = 3000;

/// Meter Digital (Expo `app/meter-digital.tsx`): the in-app taxi meter for
/// TEKSI partners. Bills on the operator's rate card (or the built-in TEKSI
/// tariff) from the vehicle's OBD-II reader where the card allows it, else
/// GPS, with DAY / NIGHT keys, extras, an end-of-hire declaration and a
/// device-local trip log with receipts, printed straight to a mini Wi-Fi
/// thermal printer when one is set up.
///
/// The console is landscape: the device is pinned to landscape while it is in
/// front, and where the platform will not turn (a browser, an iPad in split
/// view) the [LandscapeStage] turns the content instead. Its dialogs live in
/// a navigator inside the stage, so they turn with it.
class MeterScreen extends ConsumerStatefulWidget {
  const MeterScreen({super.key});

  @override
  ConsumerState<MeterScreen> createState() => _MeterScreenState();
}

class _MeterScreenState extends ConsumerState<MeterScreen> with WidgetsBindingObserver {
  MeterState _m = const MeterState();
  MeterPeriod _period = MeterPeriod.day;
  bool _periodTouched = false;
  double _extra = 0;
  int _tab = 0;

  ResolvedMeterProfile _card = resolveMeterProfile(const []);
  AreaInfo? _area;
  bool _areaAsked = false;

  String? _locationProblem;
  MeterFix? _fix;
  StreamSubscription<MeterFix>? _fixes;
  Timer? _tick;

  MeterWaypoint? _pickup;
  bool _ending = false;

  /// START was pressed and the meter is reading the odometer before the
  /// hire opens.
  bool _opening = false;
  List<MeterTrip> _trips = const [];

  int _now() => ref.read(meterClockProvider)();
  MeterProfile get _profile => _card.profile;

  /// Admin → Meter Digital → panels: whether a console panel shows, and
  /// whether it opens. The meter itself is always on.
  MeterPanelAccess _access(String id) => _profile.panels[id] ?? const MeterPanelAccess();

  /// The navigator inside the stage: dialogs and sheets open here so they
  /// are turned with the console.
  final _stageNav = GlobalKey<NavigatorState>();
  BuildContext get _stageContext => _stageNav.currentContext ?? context;

  late final MeterOrientation _orientation;

  /// False while a settings screen is pushed over the console, which gets
  /// the app's own rotation back.
  bool _inFront = true;

  @override
  void initState() {
    super.initState();
    _orientation = ref.read(meterOrientationProvider);
    _orientation.lockLandscape();
    WidgetsBinding.instance.addObserver(this);
    _startSensors();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    // The saved OBD-II reader, if any: a dongle serves one client, so the
    // meter joins the shared session rather than opening its own link.
    Future.microtask(() => ref.read(obdSessionProvider.notifier).ensureConnected());
    ref.read(meterTripsStoreProvider).load().then((t) {
      if (mounted) setState(() => _trips = t);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground can drop the lock.
    if (state == AppLifecycleState.resumed && _inFront) _orientation.lockLandscape();
  }

  /// Opens a settings screen over the console, in the app's own rotation,
  /// and pins landscape again on the way back.
  Future<void> _openSettings(String path) async {
    _inFront = false;
    await _orientation.release();
    if (!mounted) return;
    await context.push(path);
    _inFront = true;
    await _orientation.lockLandscape();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _orientation.release();
    _tick?.cancel();
    _fixes?.cancel();
    super.dispose();
  }

  Future<void> _startSensors() async {
    final location = ref.read(meterLocationProvider);
    final problem = await location.prepare();
    if (!mounted) return;
    setState(() => _locationProblem = problem);
    if (problem != null) return;
    _fixes = location.fixes().listen((f) {
      if (!mounted) return;
      setState(() => _fix = f);
      if (!_areaAsked) _lookUpArea(f);
    }, onError: (Object e) {
      if (mounted) setState(() => _locationProblem = 'Lost the location feed ($e).');
    });
  }

  /// The rate card is resolved off the first fix's geography, and only while
  /// no hire is open: a card is frozen for the life of a hire.
  Future<void> _lookUpArea(MeterFix f) async {
    _areaAsked = true;
    final area = await ref.read(geoServiceProvider).reverseArea(LatLng(f.latitude, f.longitude));
    if (!mounted || area == null) return;
    setState(() => _area = area);
    // The launch decision resolves its card for where the meter last ran.
    unawaited(ref
        .read(meterLaunchStoreProvider)
        .saveGeo((country: area.country, state: area.state, city: area.city, suburb: area.suburb))
        .catchError((_) {}));
    _resolveCard();
  }

  void _resolveCard() {
    if (_m.hasHire) return;
    final cards = ref.read(meterCardsProvider).value ?? const [];
    final next = resolveMeterProfile(
      cards,
      country: _area?.country,
      state: _area?.state,
      city: _area?.city,
      suburb: _area?.suburb,
    );
    setState(() {
      _card = next;
      if (!_periodTouched) {
        _period = isNightPeriod(DateTime.fromMillisecondsSinceEpoch(_now()),
                startHour: next.profile.nightStartHour, endHour: next.profile.nightEndHour)
            ? MeterPeriod.night
            : MeterPeriod.day;
      }
    });
  }

  MeterFix? get _freshFix {
    final f = _fix;
    if (f == null) return null;
    return _now() - f.at <= _fixMaxAgeMs ? f : null;
  }

  void _onTick() {
    if (!mounted) return;
    if (!_m.running) return setState(() {});
    // The card takes a sensor away at the source: a GPS-only card never
    // bills on the reader, an OBD-only card never on the phone's GPS.
    final sources = allowedMeterSources(_profile.sourceMode);
    final f = sources.gps ? _freshFix : null;
    final obd = ref.read(obdSessionProvider);
    final useObd = sources.obd && obd.linked;
    setState(() {
      _m = applyMeterSample(
        _m,
        MeterSample(
          at: _now(),
          obdSpeedKmh: useObd ? obd.telemetry['speed'] : null,
          obdUpdatedAt: useObd ? obd.lastUpdate : null,
          gpsSpeedKmh: f?.speedKmh,
          gpsPoint: f == null ? null : MeterPoint(f.latitude, f.longitude, accuracyM: f.accuracyM),
        ),
        flagDistanceM: _profile.rates.flagDistanceM,
      );
    });
  }

  // ---- Keys --------------------------------------------------------------------

  bool get _obdLinked => ref.read(obdSessionProvider).linked;

  String? get _startBlock =>
      meterStartBlock(_profile, obdLinked: _obdLinked, locationProblem: _locationProblem);

  Future<void> _start() async {
    final block = _startBlock;
    if (block != null) return _explain('Cannot start the meter', block);
    if (_m.hasHire) {
      // Resuming from a pause is never gated.
      setState(() => _m = startMeter(_m, _now()));
      return;
    }
    // The pickup odometer is read before the fare opens: once the car moves,
    // a late answer is no longer the pickup reading.
    double? odometer;
    if (meterReadsOdometerBeforeStart(_profile, _obdLinked)) {
      setState(() => _opening = true);
      odometer = await _readOdometer();
      if (!mounted) return;
      setState(() => _opening = false);
      final gate = meterOdometerGate(_profile, odometer, _obdLinked);
      if (!gate.canStart) return _explain('Cannot start the meter', gate.reason ?? '');
    }
    final now = _now();
    setState(() => _m = startMeter(_m, now));
    _pickup = _waypoint(now).withOdometer(odometer);
    _nameEnd(_pickup!, (named) {
      if (_pickup?.at == named.at) _pickup = named;
    });
  }

  /// The odometer (PID A6), asked a few times: one unanswered command is an
  /// adapter busy with the sweep, not a car without an odometer. A car that
  /// answers NO DATA does not publish one, and is not asked again.
  Future<double?> _readOdometer() async {
    final session = ref.read(obdSessionProvider.notifier);
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final raw = await session.request(odometerPid.command);
        if (raw == null) return null;
        final km = decodePid(raw, odometerPid);
        if (km != null) return km;
        if (isElmError(raw)) return null;
      } catch (_) {}
    }
    return null;
  }

  void _pause() => setState(() => _m = pauseMeter(_m));

  /// END stops the meter at the instant it is pressed; the declaration
  /// follows on a form that cannot be dismissed, only confirmed or resumed.
  Future<void> _end() async {
    final endedAt = _now();
    setState(() {
      _m = pauseMeter(_m);
      _ending = true;
    });
    final details = await showModalBottomSheet<MeterTripDetails>(
      context: _stageContext,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: _panel,
      builder: (_) => _DeclarationSheet(
        initialCharges: _extra,
        fareText: _money(_fareNow),
        step: _profile.extraStep,
      ),
    );
    if (!mounted) return;
    if (details == null) {
      // RESUME HIRE: back in the car, accrual restarts from now, so the
      // seconds spent on the form are never billed.
      setState(() {
        _ending = false;
        _m = startMeter(_m, _now());
      });
      return;
    }
    await _record(details, endedAt);
  }

  Future<void> _record(MeterTripDetails details, int endedAt) async {
    final partner = ref.read(partnerProvider).value;
    final dropoff = _waypoint(endedAt);
    final multiplier = periodMultiplier(_period, _profile.nightMultiplier);
    final trip = buildMeterTrip(
      _m,
      id: const Uuid().v4(),
      endedAt: endedAt,
      fare: meterFare(_m, _profile.rates, multiplier: multiplier),
      details: details,
      rateLabel: _rateLabel,
      period: _period,
      flagFare: _profile.rates.flagFare,
      nightMultiplier: _profile.nightMultiplier,
      currency: _currency,
      cardSurcharge: meterExtraSurcharge(_profile, luggage: details.luggage, passengers: details.pax),
      plate: partner?.plate,
      driver: partner?.name,
      pickup: _pickup,
      dropoff: dropoff,
    );
    final store = ref.read(meterTripsStoreProvider);
    final trips = await store.save(trip);
    if (!mounted) return;
    setState(() {
      _trips = trips;
      _m = const MeterState();
      _extra = 0;
      _pickup = null;
      _ending = false;
      _periodTouched = false;
    });
    _resolveCard();
    // The place names and the drop-off odometer arrive after the record is
    // written (the fare stopped the instant END was pressed); only the ends
    // are ever patched, each change applied to the end as stored.
    Future<void> patch(bool pickup, MeterWaypoint Function(MeterWaypoint) change) async {
      final next = await store.patchEnd(trip.id, pickup: pickup, change: change);
      if (mounted) setState(() => _trips = next);
    }

    for (final (end, isPickup) in [(trip.pickup, true), (trip.dropoff, false)]) {
      if (end == null || end.place != null) continue;
      _nameEnd(end, (named) => patch(isPickup, (stored) => stored.withPlace(named.place)));
    }
    if (meterReadsOdometer(_profile) && _obdLinked) {
      _readOdometer().then((km) {
        if (km != null) patch(false, (stored) => stored.withOdometer(km));
      });
    }
    await _showReceipt(trip);
  }

  MeterWaypoint _waypoint(int at) {
    final f = _freshFix ?? _fix;
    return MeterWaypoint(at: at, latitude: f?.latitude, longitude: f?.longitude);
  }

  void _nameEnd(MeterWaypoint end, void Function(MeterWaypoint named) onNamed) {
    if (end.latitude == null || end.longitude == null) return;
    ref.read(geoServiceProvider).reverseArea(LatLng(end.latitude!, end.longitude!)).then((area) {
      final label = area?.label;
      if (label != null && label.isNotEmpty) onNamed(end.withPlace(label));
    });
  }

  /// LEAVE THE METER (Expo's back-key popup): passenger mode or closing the
  /// app, e-hailing here or the operator's dispatch app, or staying put —
  /// what the two keys do is the rate card's (`resolveMeterLeave`).
  Future<void> _offerLeave() async {
    if (!mounted) return;
    final launcher = ref.read(meterLeaveLauncherProvider);
    final keys = resolveMeterLeave(_profile.leave, storePlatformFor(launcher.os));
    final pick = await showDialog<MeterLeaveOption>(
      context: _stageContext,
      useRootNavigator: false,
      builder: (c) => AlertDialog(
        key: const ValueKey('meter-leave'),
        title: const Text('Leave the meter?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final k in [keys.passenger, keys.ehailing])
            ListTile(
              key: ValueKey('meter-leave-${k.key}'),
              leading: Icon(k.key == 'passenger'
                  ? (k.action == 'exit' ? Icons.power_settings_new : Icons.person_outline)
                  : (k.action == 'link' ? Icons.open_in_new : Icons.local_taxi_outlined)),
              title: Text(k.label),
              subtitle: Text(k.hint),
              onTap: () => Navigator.pop(c, k),
            ),
        ]),
        actions: [
          TextButton(
            key: const ValueKey('meter-leave-stay'),
            onPressed: () => Navigator.pop(c),
            child: const Text('STAY ON THE METER'),
          ),
        ],
      ),
    );
    if (pick == null || !mounted) return;
    switch (pick.action) {
      case 'exit':
        final exit = describeMeterExit(launcher.os, launcher.canExit);
        if (!exit.supported) return _explain('Leave the app', exit.note);
        await launcher.exit();
      case 'link':
        final url = pick.url;
        if (url != null && await launcher.open(url)) return;
        final store = pick.store;
        if (store != null && await launcher.open(store)) return;
        if (mounted) _explain('Could not open the app', describeMeterLinkFailure(url ?? store ?? ''));
      default:
        // The in-app screens: passenger mode is home, e-hailing is the drive tab.
        final route = pick.route == '/partner-ehailing' ? '/drive' : (pick.route ?? '/');
        if (mounted) GoRouter.of(context).go(route);
    }
  }

  void _explain(String title, String message) => showDialog<void>(
        context: _stageContext,
        useRootNavigator: false,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );

  Future<void> _showReceipt(MeterTrip trip) => showDialog<void>(
        context: _stageContext,
        useRootNavigator: false,
        builder: (_) => _ReceiptDialog(trip: trip, onSetUpPrinter: () => _openSettings('/meter/printer')),
      );

  // ---- Derived -------------------------------------------------------------------

  String get _currency {
    final c = _profile.currency.trim();
    return c.isEmpty || c.toUpperCase() == 'MYR' ? 'RM' : c;
  }

  String _money(double n) => '$_currency ${n.toStringAsFixed(2)}';

  String get _rateLabel => (_profile.label ?? '').trim().isNotEmpty ? _profile.label!.trim() : _card.scope;

  double get _fareNow => meterFare(_m, _profile.rates, multiplier: periodMultiplier(_period, _profile.nightMultiplier));

  String get _connection {
    final sources = allowedMeterSources(_profile.sourceMode);
    final gps = _locationProblem == null && _freshFix != null;
    final label = describeMeterConnection(
      gps: gps,
      obd: _obdLinked,
      gpsAllowed: sources.gps,
      obdAllowed: sources.obd,
    );
    final acc = _freshFix?.accuracyM;
    return gps && sources.gps && acc != null ? '$label · ±${acc.round()} m' : label;
  }

  // ---- Layout --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    ref.listen(meterCardsProvider, (_, _) => _resolveCard());
    // Keeps the partner loaded: the plate and driver go on every receipt.
    ref.watch(partnerProvider);
    final obd = ref.watch(obdSessionProvider);
    final locked = _m.hasHire || _ending;
    return PopScope(
      // A running or unfinished hire cannot be walked out of, and back from the
      // trip log returns to the meter. Leaving the console is a mode change,
      // so back from the meter itself asks where to (Expo `resolveMeterBack`).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tab != 0) return setState(() => _tab = 0);
        if (locked) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('End the hire before leaving the meter.')));
          return;
        }
        // After the stage's own pop handler has looked for a dialog to
        // close; opening one under it mid-pop would hand it a route that
        // isn't built yet.
        unawaited(Future<void>.delayed(Duration.zero, _offerLeave));
      },
      child: Theme(
        data: ThemeData(brightness: Brightness.dark, colorSchemeSeed: _lcd, scaffoldBackgroundColor: _bg),
        child: ColoredBox(
          color: _bg,
          child: LandscapeStage(
            // Back closes a dialog in the stage before it reaches the meter.
            child: NavigatorPopHandler(
              onPopWithResult: (_) => _stageNav.currentState?.maybePop(),
              child: Navigator(
                key: _stageNav,
                pages: [MaterialPage(key: const ValueKey('console'), child: _scaffold(obd))],
                onDidRemovePage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _scaffold(ObdSessionState obd) => Scaffold(
        appBar: AppBar(
          backgroundColor: _bg,
          toolbarHeight: 44,
          automaticallyImplyLeading: false,
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: const Text('Meter Digital', style: TextStyle(fontSize: 17)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: Text(_connection, style: const TextStyle(color: _muted, fontSize: 12))),
            ),
            if (_access('printer').show)
              IconButton(
                key: const ValueKey('meter-panel-printer'),
                tooltip: 'Receipt printer',
                icon: const Icon(Icons.print_outlined, color: _muted),
                onPressed: _access('printer').tap ? () => _openSettings('/meter/printer') : null,
              ),
            if (obd.linked && _access('obd').show)
              IconButton(
                tooltip: 'Vehicle information',
                icon: const Icon(Icons.directions_car_outlined, color: _muted),
                onPressed: _access('obd').tap ? () => _openSettings('/meter/vehicle') : null,
              ),
            if (_access('obd').show)
              IconButton(
                key: const ValueKey('meter-panel-obd'),
                tooltip: 'OBD-II reader',
                icon: Icon(Icons.settings_input_component, color: obd.linked ? _lcd : _muted),
                onPressed: _access('obd').tap ? () => _openSettings('/meter/reader') : null,
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Row(children: [
            if (_access('trips').show)
              NavigationRail(
                backgroundColor: _panel,
                selectedIndex: _tab,
                labelType: NavigationRailLabelType.all,
                minWidth: 64,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: [
                  const NavigationRailDestination(icon: Icon(Icons.speed), label: Text('Meter')),
                  NavigationRailDestination(
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('Trip log'),
                    disabled: !_access('trips').tap,
                  ),
                ],
              ),
            Expanded(child: _tab == 0 || !_access('trips').tap ? _console() : _tripLog()),
          ]),
        ),
      );

  /// The console is one fixed landscape instrument, laid out at
  /// [meterConsoleLayout] and scaled to the space it is given, so it never
  /// scrolls and never reflows. It ignores the OS font scale: a wound-up
  /// accessibility setting must not push the fare out of its panel.
  Widget _console() {
    final fare = _fareNow;
    final total = meterGrandTotal(fare, [_extra]);
    final status = _m.running
        ? 'HIRED'
        : _m.hasHire
            ? 'STOPPED'
            : 'FOR HIRE';
    final fareBox = _Panel(children: [
      Row(children: [
        Text(_m.running ? '$status · ${describeMeterSource(_m.source)}' : status,
            style: TextStyle(color: _m.running ? _amber : _muted, fontWeight: FontWeight.w700)),
        const Spacer(),
        Flexible(
          child: Text(
            _rateLabel,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      _Readout(label: 'FARE', value: total.toStringAsFixed(2), unit: _currency, large: true),
      Text(_extra > 0 ? 'incl. extras ${_money(_extra)}' : ' ', style: const TextStyle(color: _muted, fontSize: 12)),
    ]);
    final readouts = _Panel(spread: true, children: [
      Row(children: [
        Expanded(child: _Readout(label: 'DISTANCE', value: formatMeterKm(_m.distanceM), unit: 'km')),
        Expanded(child: _Readout(label: 'TIME', value: formatMeterClock(_m.elapsedMs))),
      ]),
      Row(children: [
        Expanded(child: _Readout(label: 'WAITING', value: formatMeterClock(_m.waitingMs), small: true)),
        Expanded(
          child: _Readout(label: 'SPEED', value: _m.speedKmh.toStringAsFixed(0), unit: 'km/h', small: true),
        ),
      ]),
    ]);
    return LayoutBuilder(builder: (context, c) {
      final layout = meterConsoleLayout(c.biggest);
      return Padding(
        padding: const EdgeInsets.all(6),
        child: FittedBox(
          child: SizedBox.fromSize(
            size: layout,
            child: MediaQuery.withNoTextScaling(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  flex: 11,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [fareBox, Expanded(child: readouts)],
                  ),
                ),
                Expanded(flex: 8, child: _keys()),
              ]),
            ),
          ),
        ),
      );
    });
  }

  Widget _keys() {
    final block = _startBlock;
    return _Panel(children: [
      if (block != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(block,
              maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _amber, fontSize: 12)),
        ),
      SegmentedButton<MeterPeriod>(
        segments: [
          const ButtonSegment(value: MeterPeriod.day, label: Text('DAY'), icon: Icon(Icons.wb_sunny_outlined)),
          ButtonSegment(
            value: MeterPeriod.night,
            label: Text('NIGHT +${((_profile.nightMultiplier - 1) * 100).round()}%'),
            icon: const Icon(Icons.nightlight_outlined),
          ),
        ],
        selected: {_period},
        onSelectionChanged: (s) => setState(() {
          _period = s.first;
          _periodTouched = true;
        }),
      ),
      const SizedBox(height: 12),
      Row(children: [
        const Text('EXTRA', style: TextStyle(color: _muted, fontWeight: FontWeight.w600)),
        const Spacer(),
        IconButton.filledTonal(
          tooltip: 'Less extra',
          onPressed: _extra > 0
              ? () => setState(() => _extra = adjustExtra(_extra, -1, step: _profile.extraStep, max: _profile.maxExtra))
              : null,
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 96,
          child: Text(_extra.toStringAsFixed(2),
              textAlign: TextAlign.center, style: _digits(22, _extra > 0 ? _lcd : _lcdDim)),
        ),
        IconButton.filledTonal(
          tooltip: 'More extra',
          onPressed: () =>
              setState(() => _extra = adjustExtra(_extra, 1, step: _profile.extraStep, max: _profile.maxExtra)),
          icon: const Icon(Icons.add),
        ),
      ]),
      const Spacer(),
      SizedBox(
        height: 56,
        child: _m.running
            ? FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _amber, foregroundColor: Colors.black),
                onPressed: _pause,
                icon: const Icon(Icons.pause),
                label: const Text('PAUSE', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              )
            : FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _lcd, foregroundColor: Colors.black),
                onPressed: _ending || _opening ? null : _start,
                icon: const Icon(Icons.play_arrow),
                label: Text(_opening ? 'READING ODOMETER…' : (_m.hasHire ? 'RESUME' : 'START'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
      ),
      if (_m.hasHire) ...[
        const SizedBox(height: 10),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: _ending ? null : _end,
            icon: const Icon(Icons.stop),
            label: const Text('END', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    ]);
  }

  Widget _tripLog() {
    final s = summarizeMeterTrips(_trips);
    if (_trips.isEmpty) {
      return const Center(child: Text('No hires on this device yet.', style: TextStyle(color: _muted)));
    }
    return ListView(padding: const EdgeInsets.all(12), children: [
      _Panel(children: [
        Text('${s.count} hire${s.count == 1 ? '' : 's'} · ${formatMeterDistance(s.distanceM)}',
            style: const TextStyle(color: _muted)),
        Text(_money(s.total), style: _digits(28, _lcd)),
      ]),
      for (final t in _trips)
        Card(
          color: _panel,
          child: ListTile(
            title: Text('${formatDashDate(t.endedAt)} · ${formatDashTime(t.startedAt)}–${formatDashTime(t.endedAt)}'),
            subtitle: Text([
              formatMeterDistance(t.distanceM),
              if (t.pickup != null && t.dropoff != null) '${t.pickup!.label} → ${t.dropoff!.label}',
            ].join(' · ')),
            trailing: Text('${t.currency} ${t.total.toStringAsFixed(2)}', style: _digits(16, _lcd)),
            onTap: () => _showReceipt(t),
          ),
        ),
      const SizedBox(height: 8),
      TextButton.icon(
        onPressed: _m.hasHire ? null : _clearLog,
        icon: const Icon(Icons.delete_outline),
        label: const Text('Clear the trip log'),
      ),
    ]);
  }

  Future<void> _clearLog() async {
    final ok = await showDialog<bool>(
      context: _stageContext,
      useRootNavigator: false,
      builder: (c) => AlertDialog(
        title: const Text('Clear the trip log?'),
        content: const Text('Every hire recorded on this device is removed. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(meterTripsStoreProvider).clear();
    if (mounted) setState(() => _trips = const []);
  }
}

TextStyle _digits(double size, Color color) => TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Courier New', 'Courier'],
      fontSize: size,
      fontWeight: FontWeight.w700,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

class _Panel extends StatelessWidget {
  const _Panel({required this.children, this.spread = false});
  final List<Widget> children;

  /// Spaces the rows evenly down a panel taller than its content.
  final bool spread;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: spread ? MainAxisAlignment.spaceEvenly : MainAxisAlignment.start,
          children: children,
        ),
      );
}

class _Readout extends StatelessWidget {
  const _Readout({required this.label, required this.value, this.unit, this.large = false, this.small = false});
  final String label;
  final String value;
  final String? unit;
  final bool large;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final size = large ? 64.0 : (small ? 22.0 : 30.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: _muted, fontSize: 11, letterSpacing: 1.2)),
      // Shrinks rather than overflowing, and ignores the OS font scale: the
      // fare must stay inside its panel.
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          if (unit != null && large) Text('$unit ', style: _digits(size * 0.35, _muted), textScaler: TextScaler.noScaling),
          Text(value, style: _digits(size, _lcd), textScaler: TextScaler.noScaling),
          if (unit != null && !large) Text(' $unit', style: _digits(size * 0.5, _muted), textScaler: TextScaler.noScaling),
        ]),
      ),
    ]);
  }
}

// ---- End of hire -------------------------------------------------------------------

/// What the meter cannot measure, declared by the driver (Expo
/// `meterTripDetails`): passengers, luggage, tolls/charges and whether either
/// end was an airport. Confirm is enabled only once everything is answered;
/// the only other way out is RESUME HIRE.
class _DeclarationSheet extends StatefulWidget {
  const _DeclarationSheet({required this.initialCharges, required this.fareText, required this.step});
  final double initialCharges;
  final String fareText;
  final double step;

  @override
  State<_DeclarationSheet> createState() => _DeclarationSheetState();
}

class _DeclarationSheetState extends State<_DeclarationSheet> {
  late MeterTripDetailsDraft _d = MeterTripDetailsDraft(charges: sanitizeCharges(widget.initialCharges));
  late final _charges = TextEditingController(text: chargesToText(widget.initialCharges));

  @override
  void dispose() {
    _charges.dispose();
    super.dispose();
  }

  void _stepCharges(int steps) {
    final next = sanitizeCharges(_d.charges + steps * widget.step);
    setState(() => _d = _d.copyWith(charges: next));
    _charges.text = chargesToText(next);
  }

  Widget _choices<T>(String title, List<T> values, T? selected, String Function(T) label, void Function(T) onPick) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: _muted, fontSize: 12, letterSpacing: 1)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final v in values)
              ChoiceChip(label: Text(label(v)), selected: v == selected, onSelected: (_) => onPick(v)),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final resolved = resolveTripDetails(_d);
    return PopScope(
      canPop: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Hire ended · fare ${widget.fareText}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Declare what the meter cannot measure. Each charge prints on the receipt on its own line.',
                style: TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 14),
            _choices<int>('PASSENGERS', [for (var i = minPax; i <= maxPax; i++) i], _d.pax, (v) => '$v',
                (v) => setState(() => _d = _d.copyWith(pax: v))),
            _choices<int>('LUGGAGE', [for (var i = minLuggage; i <= maxLuggage; i++) i], _d.luggage,
                (v) => v == 0 ? 'None' : '$v', (v) => setState(() => _d = _d.copyWith(luggage: v))),
            _choices<MeterAirport>(
              'AIRPORT',
              MeterAirport.values,
              _d.airport,
              (a) => describeAirportLeg(a) ?? 'No airport',
              (v) => setState(() => _d = _d.copyWith(airport: v)),
            ),
            const Text('TOLLS & OTHER CHARGES', style: TextStyle(color: _muted, fontSize: 12, letterSpacing: 1)),
            const SizedBox(height: 6),
            Row(children: [
              IconButton.filledTonal(
                  tooltip: 'Less', onPressed: () => _stepCharges(-1), icon: const Icon(Icons.remove)),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _charges,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    TextInputFormatter.withFunction(
                      (_, v) => v.copyWith(text: sanitizeChargesText(v.text), selection: TextSelection.collapsed(offset: sanitizeChargesText(v.text).length)),
                    ),
                  ],
                  decoration: const InputDecoration(hintText: '0.00', border: OutlineInputBorder(), isDense: true),
                  onChanged: (t) => setState(() => _d = _d.copyWith(charges: chargesFromText(t))),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(tooltip: 'More', onPressed: () => _stepCharges(1), icon: const Icon(Icons.add)),
            ]),
            const SizedBox(height: 16),
            if (resolved == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(describeMissingTripDetails(_d) ?? '', style: const TextStyle(color: _amber)),
              ),
            FilledButton(
              onPressed: resolved == null ? null : () => Navigator.pop(context, resolved),
              child: const Text('CONFIRM & RECORD'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('RESUME HIRE')),
          ]),
        ),
      ),
    );
  }
}

class _ReceiptDialog extends ConsumerStatefulWidget {
  const _ReceiptDialog({required this.trip, required this.onSetUpPrinter});
  final MeterTrip trip;
  final VoidCallback onSetUpPrinter;

  @override
  ConsumerState<_ReceiptDialog> createState() => _ReceiptDialogState();
}

class _ReceiptDialogState extends ConsumerState<_ReceiptDialog> {
  bool _printing = false;
  MeterTrip get trip => widget.trip;

  /// Straight to the saved printer, with no print dialog. With no printer
  /// set up the driver is offered the setup screen; the hire stays on the
  /// roll to print from the trip log afterwards.
  Future<void> _print() async {
    final printer = await ref.read(printerStoreProvider).current();
    if (!mounted) return;
    if (printer == null) {
      final setUp = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (c) => AlertDialog(
          title: const Text('No printer set up'),
          content: const Text('Add a Bluetooth or Wi-Fi receipt printer to print receipts. This receipt stays in the trip log '
              'to print once it is set up, and can be copied as text meanwhile.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Set up printer')),
          ],
        ),
      );
      if (setUp == true && mounted) {
        Navigator.pop(context);
        widget.onSetUpPrinter();
      }
      return;
    }
    setState(() => _printing = true);
    final error = await ref.read(printerServiceProvider).send(printer, buildMeterReceiptEscpos(trip, paper: printer.paper));
    if (!mounted) return;
    setState(() => _printing = false);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error ?? 'Receipt sent to ${printer.name}.')));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Receipt'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (trip.plate != null) Text('Vehicle ${trip.plate}'),
              if (trip.driver != null) Text('Driver ${trip.driver}'),
              const Divider(),
              for (final l in meterReceiptLines(trip))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.label, style: TextStyle(fontWeight: l.strong ? FontWeight.w800 : FontWeight.w400)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(l.value,
                          textAlign: TextAlign.right,
                          style: TextStyle(fontWeight: l.strong ? FontWeight.w800 : FontWeight.w400)),
                    ),
                  ]),
                ),
              const Divider(),
              Text(meterReceiptFooterNote(trip), style: const TextStyle(fontSize: 11, color: _muted)),
            ]),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: meterReceiptText(trip)));
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Receipt copied')));
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
          TextButton.icon(
            onPressed: _printing ? null : _print,
            icon: _printing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.print_outlined),
            label: const Text('Print'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ],
      );
}
