// The route check on the rider's trip (migration 0269, beside 0154's
// checks): the car's live position against the planned route. Off it by
// the admin's metres for their minutes, or stopped too long, the rider is
// asked "Your car has left the planned route" with I'm OK and SOS; no answer
// in time tells their emergency contacts and support (trip_route_report).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/trip_safety.dart';
import '../../data/city_ride_repository.dart';
import '../../data/models.dart';
import '../../data/reliability_repository.dart';
import '../../providers.dart';
import '../../widgets/page_style_host.dart';
import 'ride_tracking_screen.dart' show rideStreamProvider;

/// The planned route of a ride, pickup to drop-off (stops included); empty
/// when the route service can't say (the check then only watches for a
/// car that stopped).
final plannedRouteProvider = FutureProvider.autoDispose.family<List<LatLng>, String>((ref, rideId) async {
  final r = ref.read(rideStreamProvider(rideId)).value;
  if (r == null || r.pickupLat == null || r.pickupLng == null || r.dropLat == null || r.dropLng == null) {
    return const [];
  }
  try {
    final route = await ref.read(geoServiceProvider).route(LatLng(r.pickupLat!, r.pickupLng!), LatLng(r.dropLat!, r.dropLng!));
    return route.points;
  } catch (_) {
    return const [];
  }
});

/// Watches the trip while it is on (nothing on screen until it asks).
class RouteCheckWatcher extends ConsumerStatefulWidget {
  const RouteCheckWatcher({super.key, required this.ride, required this.onSos});
  final RideRequest ride;
  final VoidCallback onSos;

  @override
  ConsumerState<RouteCheckWatcher> createState() => _RouteCheckWatcherState();
}

class _RouteCheckWatcherState extends ConsumerState<RouteCheckWatcher> {
  RouteDeviationDetector? _detector;
  DateTime? _lastFix;
  bool _asking = false;

  void _onRide(RideRequest r) {
    if (r.status != RideStatus.onTrip || _asking) return;
    final lat = r.partnerLiveLat, lng = r.partnerLiveLng, at = r.partnerLiveAt;
    if (lat == null || lng == null || at == null || at == _lastFix) return;
    _lastFix = at;
    final settings = ref.read(reliabilityProvider).safety;
    if (!settings.routeCheck) return;
    final route = ref.read(plannedRouteProvider(r.id)).value;
    if (route == null) return;
    final d = _detector ??= RouteDeviationDetector(route: route, settings: settings);
    final alert = d.add(LatLng(lat, lng), at);
    if (alert != null) unawaited(_ask(r, alert, settings));
  }

  Future<void> _ask(RideRequest r, RouteAlert alert, SafetySettings s) async {
    _asking = true;
    final repo = ref.read(cityRideRepositoryProvider);
    Future<void> report(String answer) async {
      try {
        await repo.routeReport(r.id, alert.kind, answer, offM: alert.offM, lat: r.partnerLiveLat, lng: r.partnerLiveLng);
      } catch (_) {
        // The SOS button is still there.
      }
    }

    unawaited(report('asked'));
    final minutes = alert.kind == RouteAlertKind.offRoute ? s.routeOffMin : s.stoppedMin;
    final answer = await showAppSheet<String>(
      id: 'ride.route-check',
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => RouteCheckSheet(alert: alert, minutes: minutes, wait: routeAnswerWindow(s)),
    );
    _asking = false;
    if (!mounted) return;
    switch (answer) {
      case 'sos':
        unawaited(report('sos'));
        widget.onSos();
      case 'ok':
        unawaited(report('ok'));
      default:
        await report('no_answer');
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
            key: ValueKey('route-check-alerted'),
            content: Text('We told your emergency contacts and GET.ride support.'),
          ));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(rideStreamProvider(widget.ride.id), (_, next) {
      if (next.value case final r?) _onRide(r);
    });
    // Asked for early, so the route is in hand by the first fix.
    ref.watch(plannedRouteProvider(widget.ride.id));
    return const SizedBox.shrink();
  }
}

/// "Your car has left the planned route", I'm OK and SOS, and the time left
/// to answer. Pops 'ok', 'sos', or 'no_answer' when the time runs out.
class RouteCheckSheet extends StatefulWidget {
  const RouteCheckSheet({super.key, required this.alert, required this.minutes, required this.wait});
  final RouteAlert alert;
  final int minutes;
  final Duration wait;

  @override
  State<RouteCheckSheet> createState() => _RouteCheckSheetState();
}

class _RouteCheckSheetState extends State<RouteCheckSheet> {
  late final Timer _timer;
  late int _left = widget.wait.inSeconds;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left--);
      if (_left <= 0) {
        _timer.cancel();
        Navigator.of(context).pop('no_answer');
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final copy = routeAlertCopy(widget.alert, minutes: widget.minutes);
    return SafeArea(
      child: Padding(
        key: const ValueKey('route-check-sheet'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.alt_route, color: t.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(child: Text(copy.title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 6),
            Text(copy.body),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton(
                  key: const ValueKey('route-check-ok'),
                  onPressed: () => Navigator.of(context).pop('ok'),
                  child: const Text('I\'m OK'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('route-check-sos'),
                  style: FilledButton.styleFrom(
                    backgroundColor: t.colorScheme.error,
                    foregroundColor: t.colorScheme.onError,
                  ),
                  onPressed: () => Navigator.of(context).pop('sos'),
                  child: const Text('SOS'),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              'No answer in ${_left.clamp(0, 1 << 20)} s: we tell your emergency contacts and support.',
              key: const ValueKey('route-check-left'),
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
