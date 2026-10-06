import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../config.dart';
import '../../core/demo_mode.dart';
import '../../core/format.dart';
import '../../providers.dart';
import '../../widgets/ride_map.dart';
import '../ride/demo_ride.dart';

/// While a driver is online with Admin → Demo → mock incoming requests on:
/// a demo request every 6–14 s, each waiting 30–45 s for an answer (Expo
/// `partnerMockEnabled`). Nothing is written to the database.
class DemoJobFeed extends StatefulWidget {
  const DemoJobFeed({super.key, this.random});

  final math.Random? random;

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

  @override
  void initState() {
    super.initState();
    _schedule(demoJobGap(_rnd));
  }

  void _schedule(Duration after) {
    _next?.cancel();
    _next = Timer(after, () {
      if (!mounted) return;
      setState(() {
        _job = demoJob(_rnd, id: 'demo-job-${++_count}');
        _shownAt = DateTime.now();
      });
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
    setState(() => _job = null);
    _schedule(const Duration(milliseconds: 400));
  }

  Future<void> _accept(DemoJob job) async {
    _tick?.cancel();
    setState(() => _job = null);
    await context.push('/drive/demo', extra: job);
    if (mounted) _schedule(demoJobGap(_rnd));
  }

  @override
  void dispose() {
    _next?.cancel();
    _tick?.cancel();
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
            Text('${job.pickupName} → ${job.dropName}', style: t.textTheme.bodyMedium),
            Text(
              '${job.km.toStringAsFixed(1)} km · ${job.minutes} min · ${job.payment} · ${job.pax} pax · ${job.luggage} bags',
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: left.clamp(0.0, 1.0)),
            const SizedBox(height: 8),
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
      body: Column(
        children: [
          Expanded(
            child: RideMap(pickup: j.pickup, drop: j.drop, route: _trip, driver: car),
          ),
          Padding(
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
                const SizedBox(height: 12),
                if (action != null)
                  FilledButton(key: const ValueKey('demo-job-next'), onPressed: () => _go(next), child: Text(action)),
                if (_phase == _JobPhase.done)
                  FilledButton(onPressed: () => context.pop(), child: const Text('Back to Drive')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
