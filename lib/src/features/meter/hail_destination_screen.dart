import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../admin/screens/meterapp/meter_logic.dart';
import '../../core/street_hail.dart';
import '../../data/geo_service.dart';
import '../../providers.dart';
import '../../widgets/ride_map.dart';
import '../ride/place_search.dart';

/// What the destination screen needs from the meter: where the hail was
/// taken and the card the hire will be billed on, to quote it.
class HailDestinationArgs {
  const HailDestinationArgs({
    required this.origin,
    required this.rates,
    required this.currency,
    this.multiplier = 1,
    this.current,
  });

  final LatLng? origin;
  final MeterRates rates;
  final String currency;
  final double multiplier;
  final HailDestination? current;
}

/// A street hail's destination (Expo `partner-teksi.tsx`): searched for, or
/// tapped on the map, with the route from here and what the meter's card
/// would charge for it. Pops the [HailDestination], or nothing.
class HailDestinationScreen extends ConsumerStatefulWidget {
  const HailDestinationScreen({super.key, required this.args});
  final HailDestinationArgs args;

  @override
  ConsumerState<HailDestinationScreen> createState() => _HailDestinationScreenState();
}

class _HailDestinationScreenState extends ConsumerState<HailDestinationScreen> {
  HailDestination? _dest;
  List<LatLng> _route = const [];
  bool _busy = false;

  /// The last place asked for; an older answer arriving late is dropped.
  LatLng? _asked;

  @override
  void initState() {
    super.initState();
    _dest = widget.args.current;
  }

  Future<void> _search() async {
    final pick = await showPlaceSearch(context, title: 'Where to?', near: widget.args.origin);
    final place = pick?.place;
    if (place != null && mounted) await _choose(place.point, place: place);
  }

  Future<void> _choose(LatLng at, {Place? place}) async {
    _asked = at;
    setState(() => _busy = true);
    final geo = ref.read(geoServiceProvider);
    final origin = widget.args.origin;
    Place? named = place;
    RouteInfo? route;
    try {
      named ??= await geo.reverse(at);
    } catch (_) {}
    if (origin != null) {
      try {
        route = await geo.route(origin, at);
      } catch (_) {}
    }
    if (!mounted || _asked != at) return;
    setState(() {
      _busy = false;
      _route = route?.points ?? const [];
      _dest = HailDestination(
        name: named?.name ?? '${at.latitude.toStringAsFixed(5)}, ${at.longitude.toStringAsFixed(5)}',
        address: named?.address,
        latitude: at.latitude,
        longitude: at.longitude,
        routeKm: route != null && route.distanceKm > 0 ? route.distanceKm : null,
        routeMin: route != null && route.distanceKm > 0 ? route.durationMin : null,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = _dest;
    final estimate = d == null ? null : hailEstimate(widget.args.rates, d, multiplier: widget.args.multiplier);
    return Scaffold(
      appBar: AppBar(title: const Text('Destination')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: OutlinedButton.icon(
              key: const ValueKey('hail-search'),
              onPressed: _search,
              icon: const Icon(Icons.search),
              label: const Align(alignment: Alignment.centerLeft, child: Text('Where to?')),
            ),
          ),
          Expanded(
            child: RideMap(
              pickup: widget.args.origin,
              drop: d == null ? null : LatLng(d.latitude, d.longitude),
              route: _route,
              onTap: (p) => _choose(p),
            ),
          ),
          Material(
            elevation: 4,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: d == null
                    ? Text(
                        _busy ? 'Finding the route…' : 'Search, or tap the map where the passenger is going.',
                        style: t.textTheme.bodyLarge,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(d.name, style: t.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (d.address != null && d.address != d.name)
                            Text(
                              d.address!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.textTheme.bodySmall,
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _busy ? 'Finding the route…' : describeHailRoute(d),
                                  key: const ValueKey('hail-route'),
                                ),
                              ),
                              Text(
                                estimate == null
                                    ? 'No estimate'
                                    : 'Est. ${widget.args.currency} ${estimate.toStringAsFixed(2)}',
                                key: const ValueKey('hail-estimate'),
                                style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                          Text('The meter bills what it measures; this is a quote.', style: t.textTheme.bodySmall),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            key: const ValueKey('hail-set'),
                            onPressed: _busy ? null : () => context.pop(d),
                            icon: const Icon(Icons.flag_outlined),
                            label: const Text('Set destination'),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
