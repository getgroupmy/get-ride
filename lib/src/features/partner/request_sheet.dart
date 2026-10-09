import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/format.dart';
import '../../core/request_alert.dart';
import '../../core/request_viewers.dart' show requestViewHeartbeat;
import '../../core/ride_bidding.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/ride_map.dart';
import '../ride/confirm_parts.dart' show confirmAccent;
import '../../widgets/net_image.dart';

/// A new ride request on a phone, as inDrive's: a sheet up from the bottom
/// with the route on a map ("Ride request" over it, the time and distance
/// to the pickup and of the trip beside A and B), the rider, the fare and
/// both ends, a countdown line, then "Accept for …", the fare offers
/// ("Offer your fare": three steps up and a pencil for any amount) and Skip.
class RideRequestSheet extends ConsumerStatefulWidget {
  const RideRequestSheet({
    super.key,
    required this.request,
    required this.shown,
    required this.now,
    required this.onAccept,
    required this.onSkip,
    this.me,
    this.awayKm,
    this.onOffer,
    this.raisedFrom,
    this.towardDestination = false,
    this.busy = false,
  });

  final RideRequest request;

  /// How long it has been on screen (the countdown) and the time now (how
  /// long ago it was made).
  final Duration shown;
  final DateTime now;

  final Future<void> Function() onAccept;
  final VoidCallback onSkip;

  /// The driver's position, and how far the pickup is from it.
  final LatLng? me;
  final double? awayKm;

  /// A counter-offer: an amount, or null to type one. Null where the rider
  /// doesn't take offers.
  final Future<void> Function(double? amount)? onOffer;

  /// The fare before the passenger raised it, when they did.
  final double? raisedFrom;
  final bool towardDestination;

  /// An accept or offer is on its way: every action waits.
  final bool busy;

  /// inDrive's chip colours: the way to the pickup, and the trip.
  static const toPickup = Color(0xFF4A90E2);
  static const trip = Color(0xFF2E9E5B);

  @override
  ConsumerState<RideRequestSheet> createState() => _RideRequestSheetState();
}

class _RideRequestSheetState extends ConsumerState<RideRequestSheet> {
  final _map = MapController();
  List<LatLng> _toPickup = const [];
  List<LatLng> _trip = const [];

  LatLng? get _pickup {
    final r = widget.request;
    return r.pickupLat == null || r.pickupLng == null ? null : LatLng(r.pickupLat!, r.pickupLng!);
  }

  LatLng? get _drop {
    final r = widget.request;
    return r.dropLat == null || r.dropLng == null ? null : LatLng(r.dropLat!, r.dropLng!);
  }

  /// "Still looking at it", for the rider's "drivers are viewing" bar.
  Timer? _seen;

  @override
  void initState() {
    super.initState();
    unawaited(_routes());
    _markViewed();
    _seen = Timer.periodic(requestViewHeartbeat, (_) => _markViewed());
  }

  void _markViewed() {
    final id = widget.request.id;
    if (id.startsWith('demo')) return;
    try {
      unawaited(ref.read(rideRepositoryProvider).markViewed(id).catchError((_) {}));
    } catch (_) {
      // A test double without it.
    }
  }

  @override
  void dispose() {
    _seen?.cancel();
    _map.dispose();
    super.dispose();
  }

  /// The roads to the pickup and on to the drop-off; straight lines until
  /// (or unless) the router answers.
  Future<void> _routes() async {
    final a = _pickup, b = _drop, me = widget.me;
    setState(() {
      _toPickup = [?me, ?a];
      _trip = [?a, ?b];
    });
    final geo = ref.read(geoServiceProvider);
    try {
      final legs = await Future.wait([
        if (me != null && a != null) geo.route(me, a) else Future.value(null),
        if (a != null && b != null) geo.route(a, b) else Future.value(null),
      ]);
      if (!mounted) return;
      setState(() {
        if (legs[0] case final RouteInfo l when l.points.length > 1) _toPickup = l.points;
        if (legs[1] case final RouteInfo l when l.points.length > 1) _trip = l.points;
      });
    } catch (_) {}
  }

  void _zoom(double by) {
    try {
      final c = _map.camera;
      _map.move(c.center, (c.zoom + by).clamp(3, 18));
    } catch (_) {}
  }

  /// "13 min." or "1 h 19 min.", as inDrive's chips.
  static String _minutes(num m) => m < 60 ? '${m.round()} min.' : '${formatDuration(m)}.';

  /// "13 min.\n6.0 km" standing just above a point's mark, which reaches
  /// [over] above the point (so the chip never covers the pin).
  Marker _chip(LatLng at, Color color, String text, String key, {required double over}) {
    final lift = over + 6;
    return Marker(
      point: at,
      width: 120,
      height: 60 + lift,
      // The box stands on the point, the chip at its foot, [lift] up.
      alignment: Alignment.topCenter,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(bottom: lift),
          child: Container(
            key: ValueKey(key),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
            ),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600, height: 1.2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _mapPart(BuildContext context) {
    final r = widget.request;
    final a = _pickup, b = _drop;
    return Stack(children: [
      Positioned.fill(
        child: RideMap(
          controller: _map,
          pickup: a,
          drop: b,
          driver: widget.me,
          dotPins: true,
          route: _trip,
          framed: [?widget.me, ?a, ?b],
          // Room for "Ride request" and the chips standing over the pins.
          fitTop: 120,
          extraMarkers: [
            if (a != null && widget.awayKm != null)
              _chip(
                a,
                RideRequestSheet.toPickup,
                '${_minutes(pickupMinutes(widget.awayKm!))}\n${formatDistance(widget.awayKm)}',
                'request-chip-pickup',
                over: confirmPickupTop,
              ),
            if (b != null && r.distanceKm != null)
              _chip(
                b,
                RideRequestSheet.trip,
                [if (r.durationMin != null) _minutes(r.durationMin!), formatDistance(r.distanceKm)].join('\n'),
                'request-chip-trip',
                over: confirmDropTop,
              ),
          ],
          // The way to the pickup, dashed blue under the trip's line.
          extraLayers: [
            if (_toPickup.length > 1)
              PolylineLayer(polylines: [
                Polyline(points: _toPickup, color: RideRequestSheet.toPickup, strokeWidth: 4),
              ]),
          ],
        ),
      ),
      // "Ride request" over the map, as inDrive's, on a shade that keeps it
      // legible over any tiles.
      const Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: 64,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x99000000), Color(0x00000000)],
              ),
            ),
          ),
        ),
      ),
      const Positioned(
        top: 12,
        left: 0,
        right: 0,
        child: Text(
          'Ride request',
          key: ValueKey('request-sheet-title'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
          ),
        ),
      ),
      Positioned(
        right: 12,
        top: 0,
        bottom: 0,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          _round(Icons.add, 'Zoom in', () => _zoom(1)),
          const SizedBox(height: 12),
          _round(Icons.remove, 'Zoom out', () => _zoom(-1)),
        ]),
      ),
    ]);
  }

  Widget _round(IconData icon, String tip, VoidCallback onTap) => Material(
    color: const Color(0xCC222222),
    shape: const CircleBorder(),
    child: IconButton(tooltip: tip, color: Colors.white, icon: Icon(icon), onPressed: onTap),
  );

  /// "SkyVille 8 @ Benteng (Old Klang Road, Kuala Lumpur)".
  static String _place(String label, String? address) =>
      address == null || address.trim().isEmpty || address.trim() == label ? label : '$label ($address)';

  Widget _end(BuildContext context, String letter, Color color, String text) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 20,
          height: 20,
          margin: const EdgeInsets.only(top: 1, right: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Text(letter, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
        Expanded(child: Text(text, style: t.textTheme.bodyMedium?.copyWith(height: 1.3))),
      ]),
    );
  }

  /// How long ago the request was made: "37 sec.", "2 min." or "just now".
  String _age() {
    final made = widget.request.createdAt;
    if (made == null) return 'just now';
    final s = widget.now.difference(made).inSeconds;
    if (s < 5) return 'just now';
    return s < 60 ? '$s sec.' : '${s ~/ 60} min.';
  }

  Widget _rider(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.request;
    final photo = r.raw['rider_photo'];
    final muted = t.colorScheme.onSurfaceVariant;
    return SizedBox(
      width: 64,
      child: Column(children: [
        NetAvatar(url: photo is String ? photo : null, radius: 24, fallback: const Icon(Icons.person_outline)),
        const SizedBox(height: 4),
        Text(r.passengerName, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelSmall),
        if (r.riderRating != null)
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.star, size: 12, color: Color(0xFFF5A623)),
            Text(r.riderRating!.toStringAsFixed(2), style: t.textTheme.labelSmall),
          ]),
        Text(_age(), key: const ValueKey('request-age'), style: t.textTheme.labelSmall?.copyWith(color: muted)),
      ]),
    );
  }

  /// Accept, in the app's accent (the rider's "Find a driver" blue), white
  /// on it in light and dark alike.
  ButtonStyle _accent(BuildContext context, {double height = 52}) => FilledButton.styleFrom(
    backgroundColor: confirmAccent,
    foregroundColor: Colors.white,
    disabledBackgroundColor: confirmAccent.withValues(alpha: 0.4),
    disabledForegroundColor: Colors.white70,
    minimumSize: Size.fromHeight(height),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    textStyle: const TextStyle(fontWeight: FontWeight.w700),
  );

  /// The fare offers: the accent as a tint, so Accept stays the one to press.
  ButtonStyle _offerStyle(BuildContext context, {double height = 48}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return FilledButton.styleFrom(
      backgroundColor: confirmAccent.withValues(alpha: dark ? 0.22 : 0.14),
      foregroundColor: dark ? const Color(0xFF7FD0F2) : const Color(0xFF0E6E99),
      minimumSize: Size.fromHeight(height),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontWeight: FontWeight.w700),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.request;
    final fare = r.effectiveFare;
    final muted = t.colorScheme.onSurfaceVariant;
    final offer = widget.onOffer;
    final presets = fare == null ? const <double>[] : counterOfferPresets(fare);
    final off = widget.busy;
    final h = MediaQuery.sizeOf(context).height;
    return Material(
      key: const ValueKey('request-alert'),
      color: t.colorScheme.surface,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: h * 0.94),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: (h * 0.34).clamp(180.0, 320.0), child: _mapPart(context)),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 12, 16, 0),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _rider(context),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (r.distanceKm != null)
                      Text('~${formatDistance(r.distanceKm)}', style: t.textTheme.bodyMedium?.copyWith(color: muted)),
                    Text(
                      r.fareText(fare),
                      key: const ValueKey('request-fare'),
                      style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    // The region's surcharges and taxes, collected on top.
                    if (r.chargeLines.isNotEmpty)
                      Text(
                        [for (final l in r.chargeLines) '+ ${l.label} ${formatMoney(l.amount, r.currency)}'].join(' · '),
                        key: const ValueKey('request-charges'),
                        style: t.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    if (widget.raisedFrom case final was?)
                      Text(
                        'The passenger raised the fare from ${r.fareText(was)} '
                        'to ${r.fareText(fare)}.',
                        key: const ValueKey('request-alert-raised'),
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w600),
                      ),
                    _end(context, 'A', RideRequestSheet.toPickup, _place(r.pickupLabel, r.pickupAddress)),
                    _end(context, 'B', RideRequestSheet.trip, _place(r.dropLabel, null)),
                    const SizedBox(height: 6),
                    Text(
                      [
                        r.paymentMode,
                        '${r.passengers} pax',
                        if ((r.luggage ?? 0) > 0) '${r.luggage} ${r.luggage == 1 ? 'bag' : 'bags'}',
                        if (r.stops.isNotEmpty) '${r.stops.length} stop${r.stops.length == 1 ? '' : 's'}',
                        if (r.isForOthers) 'Booked by ${r.riderName ?? 'another rider'}',
                        if (widget.towardDestination) 'Toward your destination',
                      ].join(' · '),
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    if (r.note != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('“${r.note}”', style: t.textTheme.bodySmall),
                      ),
                  ]),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          // The time left to answer, running down.
          LinearProgressIndicator(
            key: const ValueKey('request-alert-countdown'),
            value: requestAlertProgress(widget.shown),
            minHeight: 3,
            color: confirmAccent,
            backgroundColor: Colors.transparent,
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                BusyButton.filled(
                  key: const ValueKey('request-alert-accept'),
                  style: _accent(context),
                  onPressed: off ? null : widget.onAccept,
                  child: Text('Accept for ${r.fareText(fare)}', style: const TextStyle(fontSize: 17)),
                ),
                if (offer != null && presets.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Offer your fare', textAlign: TextAlign.center, style: t.textTheme.bodyMedium?.copyWith(color: muted)),
                  const SizedBox(height: 8),
                  Row(spacing: 8, children: [
                    for (var i = 0; i < presets.length; i++)
                      Expanded(
                        child: BusyButton.filled(
                          key: ValueKey('request-offer-$i'),
                          style: _offerStyle(context),
                          onPressed: off ? null : () => offer(presets[i]),
                          child: FittedBox(child: Text(r.fareText(presets[i]))),
                        ),
                      ),
                    SizedBox(
                      width: 56,
                      child: BusyButton.filled(
                        key: const ValueKey('request-offer-custom'),
                        style: _offerStyle(context).copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.zero)),
                        onPressed: off ? null : () => offer(null),
                        child: const Icon(Icons.edit_outlined, size: 20),
                      ),
                    ),
                  ]),
                ],
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey('request-alert-decline'),
                  style: FilledButton.styleFrom(
                    backgroundColor: t.colorScheme.surfaceContainerHighest,
                    foregroundColor: t.colorScheme.onSurface,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: off ? null : widget.onSkip,
                  child: const Text('Skip', style: TextStyle(fontSize: 17)),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
