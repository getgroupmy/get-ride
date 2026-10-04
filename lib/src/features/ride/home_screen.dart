import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../config.dart';
import '../../core/fare.dart';
import '../../core/format.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/ride_map.dart';
import 'place_search.dart';
import '../meter/meter_auto_launch.dart';

enum _PinTarget { none, pickup, drop }

/// Rider home: pick pickup + destination, choose a service, book.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  LatLng? _me;
  Place? _here;
  Place? _pickup;
  Place? _drop;
  RouteInfo? _route;
  RideService _service = rideServices.first;
  String _payment = 'Cash';
  final _note = TextEditingController();
  _PinTarget _pinTarget = _PinTarget.none;
  bool _booking = false;
  bool _routing = false;
  RideRequest? _ongoing;

  @override
  void initState() {
    super.initState();
    _locate();
    _checkOngoing();
    // A TEKSI driver whose rate card asks for it lands on the meter, once
    // per launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeAutoLaunchMeter(context, ref);
    });
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _checkOngoing() async {
    try {
      final r = await ref.read(rideRepositoryProvider).ongoingForRider();
      if (mounted) setState(() => _ongoing = r);
    } catch (_) {}
  }

  Future<void> _locate() async {
    final p = await currentPosition();
    if (p == null || !mounted) return;
    setState(() => _me = p);
    final place = await ref.read(geoServiceProvider).reverse(p);
    if (!mounted) return;
    setState(() {
      _here = place;
      _pickup ??= place;
    });
    _updateRoute();
  }

  Future<void> _updateRoute() async {
    final a = _pickup, b = _drop;
    if (a == null || b == null) {
      setState(() => _route = null);
      return;
    }
    setState(() => _routing = true);
    final r = await ref.read(geoServiceProvider).route(a.point, b.point);
    if (mounted) {
      setState(() {
        _route = r;
        _routing = false;
      });
    }
  }

  Future<void> _choose(_PinTarget target) async {
    final pick = await showPlaceSearch(
      context,
      title: target == _PinTarget.pickup ? 'Pickup' : 'Where to?',
      near: _me ?? _pickup?.point,
      current: _here,
    );
    if (pick == null || !mounted) return;
    if (pick.pickOnMap) {
      setState(() => _pinTarget = target);
      showInfo(context, 'Tap the map to set the ${target == _PinTarget.pickup ? 'pickup' : 'destination'}');
      return;
    }
    setState(() => target == _PinTarget.pickup ? _pickup = pick.place : _drop = pick.place);
    _updateRoute();
  }

  Future<void> _onMapTap(LatLng p) async {
    final target = _pinTarget;
    if (target == _PinTarget.none) return;
    setState(() => _pinTarget = _PinTarget.none);
    final place = await ref.read(geoServiceProvider).reverse(p);
    if (!mounted) return;
    setState(() => target == _PinTarget.pickup ? _pickup = place : _drop = place);
    _updateRoute();
  }

  double _fareFor(RideService s) =>
      _route == null ? 0 : calculateFare(_route!.distanceKm, _route!.durationMin, multiplier: s.multiplier);

  Future<void> _book() async {
    final a = _pickup, b = _drop, r = _route;
    if (a == null || b == null || r == null) return;
    setState(() => _booking = true);
    try {
      final profile = await ref.read(profileProvider.future);
      final req = await ref.read(rideRepositoryProvider).createRequest(
            service: _service.name,
            pickupName: a.name,
            pickupAddress: a.address,
            pickupLat: a.point.latitude,
            pickupLng: a.point.longitude,
            dropName: b.name,
            dropAddress: b.address,
            dropLat: b.point.latitude,
            dropLng: b.point.longitude,
            distanceKm: r.distanceKm,
            durationMin: r.durationMin.round(),
            fare: _fareFor(_service),
            paymentMode: _payment,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            riderName: profile?.name,
            riderPhone: profile?.phone,
            deviceOs: kIsWeb ? 'web' : defaultTargetPlatform.name,
          );
      if (mounted) context.push('/ride/${req.id}').then((_) => _checkOngoing());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final map = Stack(children: [
      RideMap(
        me: _me,
        pickup: _pickup?.point,
        drop: _drop?.point,
        route: _route?.points ?? const [],
        onTap: _onMapTap,
      ),
      if (_pinTarget != _PinTarget.none)
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: SafeArea(
            child: Material(
              borderRadius: BorderRadius.circular(12),
              elevation: 3,
              child: ListTile(
                leading: const Icon(Icons.touch_app),
                title: Text('Tap the map to set the ${_pinTarget == _PinTarget.pickup ? 'pickup' : 'destination'}'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _pinTarget = _PinTarget.none),
                ),
              ),
            ),
          ),
        ),
      Positioned(
        right: 16,
        bottom: wide ? 16 : null,
        top: wide ? null : 16,
        child: SafeArea(
          child: FloatingActionButton.small(
            heroTag: 'locate',
            onPressed: _locate,
            child: const Icon(Icons.my_location),
          ),
        ),
      ),
    ]);

    final panel = _BookingPanel(
      ongoing: _ongoing,
      pickup: _pickup,
      drop: _drop,
      route: _route,
      routing: _routing,
      service: _service,
      payment: _payment,
      note: _note,
      booking: _booking,
      fareFor: _fareFor,
      onPickup: () => _choose(_PinTarget.pickup),
      onDrop: () => _choose(_PinTarget.drop),
      onSwap: () {
        setState(() {
          final t = _pickup;
          _pickup = _drop;
          _drop = t;
        });
        _updateRoute();
      },
      onService: (s) => setState(() => _service = s),
      onPayment: (p) => setState(() => _payment = p),
      onBook: _book,
      onOpenOngoing: () => context.push('/ride/${_ongoing!.id}').then((_) => _checkOngoing()),
    );

    if (wide) {
      return Scaffold(
        body: Row(children: [
          SizedBox(width: 420, child: SafeArea(child: SingleChildScrollView(child: panel))),
          const VerticalDivider(width: 1),
          Expanded(child: map),
        ]),
      );
    }
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: map),
        DraggableScrollableSheet(
          initialChildSize: 0.45,
          minChildSize: 0.22,
          maxChildSize: 0.92,
          builder: (context, scroll) => Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: SingleChildScrollView(
              controller: scroll,
              child: Column(children: [
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                panel,
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _BookingPanel extends StatelessWidget {
  const _BookingPanel({
    required this.ongoing,
    required this.pickup,
    required this.drop,
    required this.route,
    required this.routing,
    required this.service,
    required this.payment,
    required this.note,
    required this.booking,
    required this.fareFor,
    required this.onPickup,
    required this.onDrop,
    required this.onSwap,
    required this.onService,
    required this.onPayment,
    required this.onBook,
    required this.onOpenOngoing,
  });

  final RideRequest? ongoing;
  final Place? pickup;
  final Place? drop;
  final RouteInfo? route;
  final bool routing;
  final RideService service;
  final String payment;
  final TextEditingController note;
  final bool booking;
  final double Function(RideService) fareFor;
  final VoidCallback onPickup, onDrop, onSwap, onBook, onOpenOngoing;
  final ValueChanged<RideService> onService;
  final ValueChanged<String> onPayment;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (ongoing != null) ...[
          Card(
            color: t.colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.local_taxi),
              title: Text(ongoing!.status.label),
              subtitle: Text('${ongoing!.pickupLabel} → ${ongoing!.dropLabel}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenOngoing,
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text('Where are you going?', style: t.textTheme.titleLarge),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            ListTile(
              leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
              title: Text(pickup?.name ?? 'Set pickup'),
              subtitle: pickup == null
                  ? null
                  : Text(pickup!.address, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: onPickup,
            ),
            Row(children: [
              const Expanded(child: Divider(indent: 56)),
              IconButton(tooltip: 'Swap', icon: const Icon(Icons.swap_vert), onPressed: onSwap),
            ]),
            ListTile(
              leading: Icon(Icons.location_on, color: Colors.red.shade700),
              title: Text(drop?.name ?? 'Where to?'),
              subtitle:
                  drop == null ? null : Text(drop!.address, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: onDrop,
            ),
          ]),
        ),
        if (routing) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
        if (route != null && !routing) ...[
          const SizedBox(height: 12),
          Text('${formatDistance(route!.distanceKm)} · ${formatDuration(route!.durationMin)}',
              style: t.textTheme.bodyMedium),
          const SizedBox(height: 8),
          for (final s in rideServices)
            Card(
              color: s == service ? t.colorScheme.secondaryContainer : null,
              child: ListTile(
                leading: Icon(s.name == 'Teksi' ? Icons.local_taxi : Icons.directions_car),
                title: Text(s.name),
                subtitle: Text('${s.description} · ${s.seats} seats'),
                trailing: Text(formatMoney(fareFor(s), AppConfig.currency),
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                onTap: () => onService(s),
              ),
            ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'Cash', icon: Icon(Icons.payments_outlined), label: Text('Cash')),
              ButtonSegment(
                  value: 'Get Pay', icon: Icon(Icons.account_balance_wallet_outlined), label: Text('Wallet')),
            ],
            selected: {payment},
            onSelectionChanged: (v) => onPayment(v.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            decoration: const InputDecoration(labelText: 'Note to driver (optional)'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: booking || ongoing != null ? null : onBook,
            child: booking
                ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(ongoing != null
                    ? 'You already have a ride in progress'
                    : 'Book ${service.name} · ${formatMoney(fareFor(service), AppConfig.currency)}'),
          ),
        ],
      ]),
    );
  }
}
