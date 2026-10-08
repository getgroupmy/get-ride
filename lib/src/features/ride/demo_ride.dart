import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/demo_mode.dart';
import '../../core/format.dart';
import '../../data/app_display_repository.dart';
import '../../providers.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_map.dart';

/// The admin's demo switches (Admin → Display Settings → Demo / Mockup Data).
final demoSettingsProvider = Provider<DemoSettings>((ref) {
  final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
  return DemoSettings.fromSettings(blob);
});

/// The "DEMO" mark on everything the demo shows, so it is never mistaken for
/// a real driver.
class DemoChip extends StatelessWidget {
  const DemoChip({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: const Color(0xFF7C3AED), borderRadius: BorderRadius.circular(6)),
    child: const Text(
      'DEMO',
      style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
    ),
  );
}

/// While a rider searches: "2 drivers are viewing your request", then three
/// demo offers 3, 6 and 9 s in, each gone after [demoOfferLife] unless taken
/// (Expo's `userMockEnabled`). The search screen draws them with the real
/// offers; this only keeps the time.
class DemoOfferTimeline extends ChangeNotifier {
  DemoOfferTimeline(double fare, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _timers.add(Timer(demoViewersAfter, () {
      viewers = true;
      notifyListeners();
    }));
    for (final (after, offer) in demoOffers(fare)) {
      _timers.add(Timer(after, () {
        _shown.add((offer, _clock()));
        notifyListeners();
        _timers.add(Timer(demoOfferLife, () => dismiss(offer)));
      }));
    }
  }

  final DateTime Function() _clock;
  final _timers = <Timer>[];
  final _shown = <(DemoOffer, DateTime)>[];

  /// Whether the "drivers are viewing" line is up.
  bool viewers = false;

  /// The offers on screen, oldest first, with when each arrived.
  List<(DemoOffer, DateTime)> get shown => List.unmodifiable(_shown);

  /// Declined, or lapsed.
  void dismiss(DemoOffer offer) {
    final before = _shown.length;
    _shown.removeWhere((e) => e.$1.id == offer.id);
    if (_shown.length != before) notifyListeners();
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }
}

/// What a demo trip needs to play out.
class DemoTripArgs {
  const DemoTripArgs({
    required this.pickup,
    required this.pickupName,
    required this.drop,
    required this.dropName,
    required this.offer,
    required this.currency,
  });

  final LatLng pickup;
  final String pickupName;
  final LatLng drop;
  final String dropName;
  final DemoOffer offer;
  final String currency;
}

/// A demo trip: nothing is written anywhere. With Admin → Demo → simulated
/// driving on, the demo driver drives to the pickup, waits, and takes the
/// trip (Expo `ride-tracking` simulation); otherwise they stay on their way.
class DemoTripScreen extends ConsumerStatefulWidget {
  const DemoTripScreen({super.key, required this.args, this.tick = const Duration(milliseconds: 500)});

  final DemoTripArgs args;
  final Duration tick;

  @override
  ConsumerState<DemoTripScreen> createState() => _DemoTripScreenState();
}

class _DemoTripScreenState extends ConsumerState<DemoTripScreen> {
  late final LatLng _start = demoDriverStart(widget.args.pickup);
  List<LatLng> _trip = const [];
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _trip = [widget.args.pickup, widget.args.drop];
    ref
        .read(geoServiceProvider)
        .route(widget.args.pickup, widget.args.drop)
        .then((r) {
          if (mounted && r.points.length > 1) setState(() => _trip = r.points);
        })
        .catchError((_) {});
    _timer = Timer.periodic(widget.tick, (_) {
      if (!ref.read(demoSettingsProvider).riderTripSim) return;
      setState(() => _elapsed += widget.tick);
      if (demoPhaseAt(_elapsed).phase == DemoPhase.completed) _timer?.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final a = widget.args;
    final o = a.offer;
    final now = demoPhaseAt(_elapsed);
    final car = switch (now.phase) {
      DemoPhase.arriving => alongRoute([_start, a.pickup], now.progress),
      DemoPhase.arrived => a.pickup,
      DemoPhase.onTrip => alongRoute(_trip, now.progress),
      DemoPhase.completed => a.drop,
    };
    final (title, detail) = switch (now.phase) {
      DemoPhase.arriving => ('Driver is on the way', '${o.name} is heading to ${a.pickupName}'),
      DemoPhase.arrived => ('Driver has arrived', '${o.name} is waiting at ${a.pickupName}'),
      DemoPhase.onTrip => ('On the way', 'Heading to ${a.dropName}'),
      DemoPhase.completed => ('Trip complete', 'You arrived at ${a.dropName}'),
    };
    return Scaffold(
      appBar: AppBar(
        title: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Your ride'), SizedBox(width: 8), DemoChip()]),
      ),
      body: MapSheetLayout(
        map: RideMap(pickup: a.pickup, drop: a.drop, route: _trip, driver: car),
        sheet: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, key: const ValueKey('demo-trip-phase'), style: t.textTheme.headlineSmall),
              Text(detail, style: t.textTheme.bodyMedium),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: CircleAvatar(child: Text(o.name[0])),
                  title: Text(o.name),
                  subtitle: Text('${o.vehicle} · ★ ${o.rating.toStringAsFixed(2)}'),
                  trailing: Text(formatMoney(o.price, a.currency), style: t.textTheme.titleMedium),
                ),
              ),
              Text('This is a demo trip: no driver is coming and nothing is charged.', style: t.textTheme.bodySmall),
              if (now.phase == DemoPhase.completed) ...[
                const SizedBox(height: 12),
                FilledButton(onPressed: () => context.go('/'), child: const Text('Done')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
