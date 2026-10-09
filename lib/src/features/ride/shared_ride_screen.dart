import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/live_eta.dart';
import '../../core/ride_share.dart';
import '../../core/sos.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_map.dart';
import '../../widgets/net_image.dart';

/// Dials a number from the shared page's SOS: the phone app, overridden in
/// tests.
final sharedRideDialerProvider = Provider<Future<void> Function(String number)>(
  (ref) => (number) async {
    await launchUrl(Uri(scheme: 'tel', path: number));
  },
);

/// Sends a ride's share link: the system share sheet, overridden in tests.
final rideSharerProvider = Provider<Future<void> Function(String text)>(
  (ref) => (text) async {
    try {
      await SharePlus.instance.share(ShareParams(text: text, subject: 'GET.ride trip'));
    } catch (_) {
      // No share sheet (some desktops): the link goes on the clipboard.
      await Clipboard.setData(ClipboardData(text: text));
    }
  },
);

/// The rider shares the ride: the link is made on first share (0108).
Future<void> shareRide(BuildContext context, WidgetRef ref, RideRequest r) async {
  try {
    final token = await ref.read(rideRepositoryProvider).shareToken(r.id);
    await ref.read(rideSharerProvider)(rideShareMessage(r, rideShareUrl(token)));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// What a share link opens (`getride.my/share/<token>`): the ride read-only,
/// with the map, for anyone, signed in or not. Re-read every
/// [rideShareRefresh], since a visitor has no realtime feed.
class SharedRideScreen extends ConsumerStatefulWidget {
  const SharedRideScreen({super.key, required this.token});
  final String token;

  @override
  ConsumerState<SharedRideScreen> createState() => _SharedRideScreenState();
}

class _SharedRideScreenState extends ConsumerState<SharedRideScreen> {
  SharedRide? _ride;
  bool _loaded = false;
  bool _failed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(rideShareRefresh, (_) {
      // A finished ride no longer moves.
      if (_ride == null || _ride!.status.isOngoing) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await ref.read(rideRepositoryProvider).sharedRide(widget.token);
      if (!mounted) return;
      setState(() {
        _ride = r;
        _loaded = true;
        _failed = false;
      });
    } catch (_) {
      // Keep what is on screen; say so only when there is nothing yet.
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _ride;
    return Scaffold(
      appBar: AppBar(title: const Text('Shared ride'), automaticallyImplyLeading: false),
      body: r != null
          ? _SharedRideView(ride: r, url: rideShareUrl(widget.token))
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: !_loaded && !_failed
                    ? const CircularProgressIndicator()
                    : Text(
                        _failed && !_loaded
                            ? "Couldn't load this ride. Check your connection."
                            : 'This link has expired or is not valid.',
                        key: const ValueKey('shared-ride-missing'),
                        textAlign: TextAlign.center,
                      ),
              ),
            ),
    );
  }
}

class _SharedRideView extends ConsumerWidget {
  const _SharedRideView({required this.ride, required this.url});
  final SharedRide ride;
  final String url;

  /// Call the emergency number, or send the trip (where the car is, the
  /// driver, plate and car) to whoever can help.
  Future<void> _sos(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const ValueKey('shared-sos-call'),
            leading: const Icon(Icons.call),
            title: const Text('Call $emergencyNumber'),
            subtitle: const Text('Police, ambulance and fire'),
            onTap: () => Navigator.pop(c, 'call'),
          ),
          ListTile(
            key: const ValueKey('shared-sos-send'),
            leading: const Icon(Icons.sms_outlined),
            title: const Text('Send an emergency alert'),
            subtitle: const Text('The car\'s location, driver, plate and car'),
            onTap: () => Navigator.pop(c, 'send'),
          ),
        ]),
      ),
    );
    if (choice == 'call') {
      await ref.read(sharedRideDialerProvider)(emergencyNumber);
    } else if (choice == 'send') {
      await ref.read(rideSharerProvider)(sharedRideSosText(ride, url: url));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ride;
    final t = Theme.of(context);
    final car = sharedRideCar(r);
    final map = Stack(
      fit: StackFit.expand,
      children: [
        _SharedRideMap(ride: r),
        // While the ride is on the go, an SOS floats over the map, low on
        // the right, above the sheet.
        if (r.status.isOngoing)
          Builder(
            builder: (context) => MapBottomInset.listen(
              context,
              (inset) => Stack(children: [
                Positioned(
                  right: 12,
                  bottom: mapAttributionClearance + inset,
                  child: FloatingActionButton(
                    key: const ValueKey('shared-sos'),
                    heroTag: null,
                    tooltip: 'SOS · Emergency',
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    onPressed: () => _sos(context, ref),
                    child: const Icon(Icons.sos, size: 30),
                  ),
                ),
              ]),
            ),
          ),
      ],
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(sharedRideHeadline(r), key: const ValueKey('shared-headline'), style: t.textTheme.titleLarge),
        if (r.tripCode != null) ...[
          const SizedBox(height: 12),
          Card(
            color: t.colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.pin_outlined),
              title: const Text('Trip code'),
              subtitle: const Text('Tell the driver this code at pickup.'),
              trailing: Text(
                r.tripCode!,
                key: const ValueKey('shared-trip-code'),
                style: t.textTheme.headlineSmall?.copyWith(letterSpacing: 4),
              ),
            ),
          ),
        ],
        if (r.driverName != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: NetAvatar(url: r.driverPhoto, fallback: const Icon(Icons.person)),
                  title: Text(r.driverName!),
                  subtitle: r.driverRating == null ? null : Text('★ ${r.driverRating!.toStringAsFixed(1)}'),
                ),
                // The car to look out for: plate, make and model, colour.
                if (r.plate != null || car != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        if (r.plate != null)
                          Container(
                            key: const ValueKey('shared-plate'),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: t.colorScheme.outline),
                            ),
                            child: Text(
                              r.plate!.toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                        if (r.plate != null && car != null) const SizedBox(width: 12),
                        if (car != null)
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(car, key: const ValueKey('shared-car'), style: t.textTheme.titleMedium),
                                if (r.vehicleColor != null)
                                  Row(children: [
                                    Container(
                                      width: 12,
                                      height: 12,
                                      margin: const EdgeInsets.only(right: 6),
                                      decoration: BoxDecoration(
                                        color: carColour(r.vehicleColor!) ?? Colors.transparent,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: t.colorScheme.outline),
                                      ),
                                    ),
                                    Text('Colour: ${r.vehicleColor}', style: t.textTheme.bodySmall),
                                  ]),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
                title: Text(r.pickupName),
                subtitle: r.pickupAddress == null ? null : Text(r.pickupAddress!),
              ),
              for (final s in r.stops) ListTile(leading: const Icon(Icons.more_vert), title: Text(s.name), dense: true),
              ListTile(
                leading: Icon(Icons.location_on, color: Colors.red.shade700),
                title: Text(r.dropName),
                subtitle: r.dropAddress == null ? null : Text(r.dropAddress!),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            if (r.distanceKm != null) Text(formatDistance(r.distanceKm!)),
            if (r.durationMin != null) Text(formatDuration(r.durationMin!)),
            if (r.fare != null) Text(formatMoney(r.fare!, r.currency), style: t.textTheme.titleMedium),
            if (r.paymentMode != null) Text(r.paymentMode!),
          ],
        ),
        if (r.driverSeenAt != null && r.driver != null) ...[
          const SizedBox(height: 8),
          Text('Driver location updated ${formatTime(r.driverSeenAt!)}', style: t.textTheme.bodySmall),
        ],
        const SizedBox(height: 16),
        Text(
          'A read-only view shared by ${r.sharedBy ?? 'a GET.ride rider'}. It updates by itself.',
          key: const ValueKey('shared-by'),
          style: t.textTheme.bodySmall,
        ),
      ],
    );
    const pad = EdgeInsets.all(16);
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 900) {
          return Row(
            children: [
              SizedBox(
                width: 420,
                child: SingleChildScrollView(padding: pad, child: details),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: map),
            ],
          );
        }
        return MapSheetLayout(
          map: map,
          sheet: Padding(padding: pad, child: details),
        );
      },
    );
  }
}

/// A swatch for a colour written as a word; null when it isn't one we know.
Color? carColour(String name) => switch (name.trim().toLowerCase()) {
  'white' || 'putih' => Colors.white,
  'black' || 'hitam' => Colors.black,
  'silver' || 'perak' => const Color(0xFFC0C0C0),
  'grey' || 'gray' || 'kelabu' => Colors.grey,
  'red' || 'merah' => Colors.red,
  'blue' || 'biru' => Colors.blue,
  'green' || 'hijau' => Colors.green,
  'yellow' || 'kuning' => Colors.yellow,
  'orange' || 'oren' || 'jingga' => Colors.orange,
  'brown' || 'coklat' => Colors.brown,
  'gold' || 'emas' => const Color(0xFFD4AF37),
  'purple' || 'ungu' => Colors.purple,
  'maroon' => const Color(0xFF800000),
  'beige' => const Color(0xFFF5F5DC),
  _ => null,
};

/// The shared ride's map: the trip's road (pickup, stops, drop-off) and,
/// while the driver is on the way, their road to the pickup as a second
/// line. On the trip the line starts at the car.
class _SharedRideMap extends ConsumerStatefulWidget {
  const _SharedRideMap({required this.ride});
  final SharedRide ride;

  @override
  ConsumerState<_SharedRideMap> createState() => _SharedRideMapState();
}

class _SharedRideMapState extends ConsumerState<_SharedRideMap> {
  RouteInfo? _trip;
  String? _tripKey;
  RouteInfo? _approach;
  LatLng? _approachFrom, _approachTo;
  DateTime? _approachAt;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(covariant _SharedRideMap old) {
    super.didUpdateWidget(old);
    _update();
  }

  void _update() {
    final r = widget.ride;
    final pickup = r.pickup, drop = r.drop;
    final via = [for (final s in r.stops) s.point];
    final key = pickup == null || drop == null ? null : [pickup, ...via, drop].join(';');
    if (key != _tripKey) {
      _tripKey = key;
      _trip = null;
      if (pickup != null && drop != null) {
        unawaited(() async {
          try {
            final t = await ref.read(geoServiceProvider).route(pickup, drop, via: via);
            if (mounted && _tripKey == key) setState(() => _trip = t);
          } catch (_) {}
        }());
      }
    }
    // The driver's road to the pickup, only while they are on the way.
    final from = r.status == RideStatus.accepted ? r.driver : null;
    if (from == null || pickup == null) {
      if (_approach != null) setState(() => _approach = null);
      _approachFrom = _approachTo = _approachAt = null;
      return;
    }
    final now = DateTime.now();
    final ahead = _approach == null ? null : routeAhead(_approach!.points, from);
    if (!shouldReroute(
      from: from,
      to: pickup,
      now: now,
      lastFrom: _approachFrom,
      lastTo: _approachTo,
      lastAt: _approachAt,
      offRoute: ahead != null && ahead.offBy > offRouteMetres,
    )) {
      return;
    }
    _approachFrom = from;
    _approachTo = pickup;
    _approachAt = now;
    final seq = ++_seq;
    unawaited(() async {
      try {
        final a = await ref.read(geoServiceProvider).route(from, pickup);
        if (mounted && seq == _seq) setState(() => _approach = a);
      } catch (_) {}
    }());
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final trip = _trip?.points ?? const <LatLng>[];
    final driver = r.driver;
    // On the trip the line runs from the car on; before it, the whole way.
    final tripLine = r.status == RideStatus.onTrip && driver != null && trip.length > 1
        ? routeAhead(trip, driver)?.points ?? trip
        : trip;
    final approach = r.status == RideStatus.accepted && driver != null
        ? (_approach == null ? null : routeAhead(_approach!.points, driver)?.points ?? _approach!.points)
        : null;
    return RideMap(
      pickup: r.pickup,
      drop: r.drop,
      stops: [for (final s in r.stops) s.point],
      driver: driver,
      driverHeading: r.driverHeading,
      route: tripLine,
      extraLayers: [
        if (approach != null && approach.length > 1)
          PolylineLayer(
            key: const ValueKey('shared-approach'),
            polylines: [
              Polyline(
                points: approach,
                color: sharedApproachColour,
                strokeWidth: 4,
                pattern: StrokePattern.dashed(segments: const [10, 6]),
              ),
            ],
          ),
      ],
    );
  }
}

/// The driver's road to the pickup: dashed, darker than the trip's line.
const sharedApproachColour = Color(0xFF1F2A44);
