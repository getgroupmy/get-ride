import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../config.dart';
import '../../core/demo_mode.dart';
import '../../core/format.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_map.dart';
import '../ride/demo_ride.dart';
import '../../core/demo/demo_script.dart';
import '../../widgets/page_style_host.dart';
import '../store_review/demo_contact.dart' show openDemoCall, openDemoChat, showDemoSos;
import '../store_review/demo_wallet.dart' show demoWalletProvider;

/// While a driver is online with Admin → Demo → mock incoming requests on:
/// a demo request every 6–14 s, each waiting 30–45 s for an answer (Expo
/// `partnerMockEnabled`). Nothing is written to the database.
class DemoJobFeed extends StatefulWidget {
  const DemoJobFeed({super.key, this.random, this.onShowing});

  final math.Random? random;

  /// A demo request came up (true) or went (false): the Drive screen treats
  /// it as it does a real one (the sheet held down, no "Waiting for
  /// requests…" under it).
  final ValueChanged<bool>? onShowing;

  @override
  State<DemoJobFeed> createState() => _DemoJobFeedState();
}

class _DemoJobFeedState extends State<DemoJobFeed> {
  late final math.Random _rnd = widget.random ?? math.Random();
  Timer? _next;
  Timer? _tick;
  DemoJob? _job;
  DateTime? _shownAt;
  int _count = 0;

  /// The driver's own fare on the request on screen, while the demo
  /// passenger thinks; and their "no".
  double? _offered;
  bool _declined = false;
  Timer? _answer;

  @override
  void initState() {
    super.initState();
    _schedule(demoJobGap(_rnd));
  }

  /// Offer a fare (the driver's counter-offer): the demo passenger takes it
  /// up to 30% over the fare, after a moment; otherwise says no.
  Future<void> _counter(DemoJob job) async {
    final amount = await showAppSheet<double>(
      id: 'partner.demo-counter',
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('Offer your fare'),
            subtitle: Text('${job.passenger} asked ${formatMoney(job.fare, AppConfig.currency)}. Demo: nothing is sent.'),
          ),
          for (final a in demoCounterAmounts(job.fare))
            ListTile(
              key: ValueKey('demo-counter-${a.round()}'),
              leading: const Icon(Icons.sell_outlined),
              title: Text(formatMoney(a, AppConfig.currency)),
              onTap: () => Navigator.pop(c, a),
            ),
        ]),
      ),
    );
    if (amount == null || !mounted || _job?.id != job.id) return;
    _tick?.cancel();
    setState(() {
      _offered = amount;
      _declined = false;
    });
    _answer?.cancel();
    _answer = Timer(demoCounterAnswerAfter, () {
      if (!mounted || _job?.id != job.id) return;
      if (demoPassengerTakes(amount, job.fare)) {
        _accept(job.withFare(amount));
      } else {
        setState(() => _declined = true);
        _answer = Timer(const Duration(seconds: 2), () {
          if (mounted && _job?.id == job.id) _dismiss();
        });
      }
    });
  }

  void _schedule(Duration after) {
    _next?.cancel();
    _next = Timer(after, () {
      if (!mounted) return;
      setState(() {
        _job = demoJob(_rnd, id: 'demo-job-${++_count}');
        _shownAt = DateTime.now();
      });
      widget.onShowing?.call(true);
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        final job = _job, at = _shownAt;
        if (!mounted || job == null || at == null) return;
        if (DateTime.now().difference(at) >= job.timeout) {
          _dismiss();
        } else {
          setState(() {});
        }
      });
    });
  }

  void _dismiss() {
    _tick?.cancel();
    _answer?.cancel();
    setState(() {
      _job = null;
      _offered = null;
      _declined = false;
    });
    widget.onShowing?.call(false);
    _schedule(const Duration(milliseconds: 400));
  }

  Future<void> _accept(DemoJob job) async {
    _tick?.cancel();
    _answer?.cancel();
    setState(() {
      _job = null;
      _offered = null;
      _declined = false;
    });
    widget.onShowing?.call(false);
    await context.push('/drive/demo', extra: job);
    if (mounted) _schedule(demoJobGap(_rnd));
  }

  @override
  void dispose() {
    _next?.cancel();
    _tick?.cancel();
    _answer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = _job, at = _shownAt;
    if (job == null || at == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final left = 1 - DateTime.now().difference(at).inMilliseconds / job.timeout.inMilliseconds;
    return Card(
      key: const ValueKey('demo-job'),
      color: t.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const DemoChip(),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${job.passenger} · ★ ${job.rating.toStringAsFixed(1)}', style: t.textTheme.titleSmall),
                ),
                Text(
                  formatMoney(job.fare, AppConfig.currency),
                  style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('${job.pickupName} to ${job.dropName}', style: t.textTheme.bodyMedium),
            Text(
              '${job.km.toStringAsFixed(1)} km · ${job.minutes} min · ${job.payment} · ${job.pax} pax · ${job.luggage} bags',
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: left.clamp(0.0, 1.0)),
            const SizedBox(height: 8),
            if (_offered case final o?)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _declined
                      ? '${job.passenger} declined ${formatMoney(o, AppConfig.currency)} (demo).'
                      : 'You offered ${formatMoney(o, AppConfig.currency)}. Waiting for ${job.passenger}…',
                  key: const ValueKey('demo-counter-status'),
                  style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            if (_offered == null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const ValueKey('demo-job-counter'),
                  onPressed: () => _counter(job),
                  icon: const Icon(Icons.sell_outlined),
                  label: const Text('Offer a fare'),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: _dismiss, child: const Text('Decline')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('demo-job-accept'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: () => _accept(job),
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _JobPhase { toPickup, atPickup, onTrip, atDrop, done }

/// A demo job on the phone alone. With Admin → Demo → simulated driving on,
/// the car drives itself and arrives on its own; otherwise the driver steps
/// through it.
class DemoJobScreen extends ConsumerStatefulWidget {
  const DemoJobScreen({super.key, required this.job, this.tick = const Duration(milliseconds: 500)});

  final DemoJob job;
  final Duration tick;

  @override
  ConsumerState<DemoJobScreen> createState() => _DemoJobScreenState();
}

class _DemoJobScreenState extends ConsumerState<DemoJobScreen> {
  late final LatLng _start = demoDriverStart(widget.job.pickup);
  List<LatLng> _trip = const [];
  _JobPhase _phase = _JobPhase.toPickup;
  Duration _leg = Duration.zero;
  Timer? _timer;

  bool get _sim => ref.read(demoSettingsProvider).partnerDriveSim;

  @override
  void initState() {
    super.initState();
    _trip = [widget.job.pickup, widget.job.drop];
    ref
        .read(geoServiceProvider)
        .route(widget.job.pickup, widget.job.drop)
        .then((r) {
          if (mounted && r.points.length > 1) setState(() => _trip = r.points);
        })
        .catchError((_) {});
    _timer = Timer.periodic(widget.tick, (_) {
      if (!_sim) return;
      if (_phase == _JobPhase.toPickup || _phase == _JobPhase.onTrip) {
        setState(() {
          _leg += widget.tick;
          if (_phase == _JobPhase.toPickup && _leg >= demoToPickupFor) _go(_JobPhase.atPickup);
          if (_phase == _JobPhase.onTrip && _leg >= demoJobTripFor) _go(_JobPhase.atDrop);
        });
      }
    });
  }

  void _go(_JobPhase p) => setState(() {
    _phase = p;
    _leg = Duration.zero;
  });

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final j = widget.job;
    final sim = ref.watch(demoSettingsProvider).partnerDriveSim;
    double frac(Duration of) => (_leg.inMilliseconds / of.inMilliseconds).clamp(0.0, 1.0);
    final car = switch (_phase) {
      _JobPhase.toPickup => sim ? alongRoute([_start, j.pickup], frac(demoToPickupFor)) : _start,
      _JobPhase.atPickup => j.pickup,
      _JobPhase.onTrip => sim ? alongRoute(_trip, frac(demoJobTripFor)) : j.pickup,
      _JobPhase.atDrop || _JobPhase.done => j.drop,
    };
    final (title, action, next) = switch (_phase) {
      _JobPhase.toPickup => ('Heading to ${j.pickupName}', sim ? null : 'Arrived at pickup', _JobPhase.atPickup),
      _JobPhase.atPickup => ('Waiting for ${j.passenger}', 'Start trip', _JobPhase.onTrip),
      _JobPhase.onTrip => ('Driving to ${j.dropName}', sim ? null : 'Arrived at destination', _JobPhase.atDrop),
      _JobPhase.atDrop => ('Arrived at ${j.dropName}', 'Complete trip', _JobPhase.done),
      _JobPhase.done => ('Trip complete', null, _JobPhase.done),
    };
    return Scaffold(
      appBar: AppBar(
        title: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Demo job'), SizedBox(width: 8), DemoChip()]),
      ),
      body: MapSheetLayout(
        map: RideMap(
          pickup: j.pickup,
          drop: j.drop,
          route: _trip,
          driver: car,
          // Heading to the pickup: the way there too, as the car drives it.
          extraLayers: [
            if (_phase == _JobPhase.toPickup && car != j.pickup)
              PolylineLayer(
                key: const ValueKey('demo-job-to-pickup'),
                polylines: [
                  Polyline(
                    points: [car, j.pickup],
                    color: const Color(0xFF2DABE2),
                    strokeWidth: 4,
                    pattern: StrokePattern.dashed(segments: const [10, 8]),
                  ),
                ],
              ),
          ],
        ),
        // No wider than the other screens' sheets on a desktop.
        sheet: ResponsiveCenter(
          maxWidth: 760,
          padding: EdgeInsets.zero,
          child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, key: const ValueKey('demo-job-phase'), style: t.textTheme.headlineSmall),
              Text(
                '${j.passenger} · ${j.payment} · ${formatMoney(j.fare, AppConfig.currency)}',
                style: t.textTheme.bodyMedium,
              ),
              Text('A demo job: there is no passenger and nothing is paid.', style: t.textTheme.bodySmall),
              // The store review account (0333): chat, call and SOS, simulated.
              if (ref.watch(storeReviewProvider) && _phase != _JobPhase.done) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('demo-job-chat'),
                      onPressed: () => openDemoChat(context, peer: DemoPeer.passenger, name: j.passenger),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Chat'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('demo-job-call'),
                      onPressed: () => openDemoCall(context, name: j.passenger, role: 'Passenger'),
                      icon: const Icon(Icons.call_outlined),
                      label: const Text('Call'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const ValueKey('demo-job-sos'),
                    tooltip: 'SOS · Emergency',
                    style: IconButton.styleFrom(backgroundColor: const Color(0xFFE53935), foregroundColor: Colors.white),
                    onPressed: () => showDemoSos(context, ref),
                    icon: const Icon(Icons.sos),
                  ),
                ]),
              ],
              const SizedBox(height: 12),
              if (action != null)
                FilledButton(
                  key: const ValueKey('demo-job-next'),
                  onPressed: () {
                    // The store review account's fare goes to its demo GET.credit (0333).
                    if (next == _JobPhase.done && ref.read(storeReviewProvider)) {
                      ref.read(demoWalletProvider.notifier).earn(j.fare, 'Demo job: ${j.pickupName} to ${j.dropName}');
                    }
                    _go(next);
                  },
                  child: Text(action),
                ),
              if (_phase == _JobPhase.done)
                FilledButton(onPressed: () => context.pop(), child: const Text('Back to Drive')),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
