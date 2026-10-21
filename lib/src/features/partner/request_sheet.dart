import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
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
import '../../core/rider_rating.dart';
import '../../data/city_ride_repository.dart';
import '../../widgets/rider_badge.dart';
import '../../widgets/place_type_badge.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show mutedTextColor;
import '../../widgets/ride_map.dart';
import '../ride/confirm_parts.dart' show accentFill, confirmAccent;
import '../../widgets/net_image.dart';
import 'direct_booking_badge.dart';
import 'stand_order_label.dart';
import 'my_ride_badges.dart';
import '../ride/promo_parts.dart' show PromoAppliedIcon, rideHasPromo;
import '../ride/freight_parts.dart' show FreightCargoView;
import '../ride/pet_parts.dart' show RidePetsView;
import '../ride/assistance_parts.dart' show OptionChargesLine, RideAssistanceView;
import '../../core/ride_option_settings.dart' show RideOptionKind;

/// A new ride request on a phone, as inDrive's: a sheet up from the bottom
/// with the route on a map ("Ride request" over it, the time and distance
/// to the pickup and of the trip beside A and B), the rider, the fare and
/// both ends, a countdown line, then "Accept for …", the fare offers
/// ("Offer your fare": three steps up and a pencil for any amount) and Skip.
/// The request map's zoom buttons show from this width (beside the chips).
const requestMapZoomMinWidth = 280.0;

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
    this.starred = false,
    this.driverId,
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

  /// My Ride: the request carries the driver's gold star, and the driver's
  /// account id (for "for you first" while the favourites window runs).
  final bool starred;
  final String? driverId;

  /// An accept or offer is on its way: every action waits.
  final bool busy;

  /// inDrive's chip colours: the way to the pickup, and the trip.
  static const toPickup = Color(0xFF4A90E2);
  static const trip = Color(0xFF2E9E5B);

  @override
  ConsumerState<RideRequestSheet> createState() => _RideRequestSheetState();
}

class _RideRequestSheetState extends ConsumerState<RideRequestSheet> {
  /// The signed-in driver's account id (what a GET.now booking names);
  /// null when it can't be read.
  String? get _driverId {
    try {
      return ref.read(currentUserIdProvider);
    } catch (_) {
      return null;
    }
  }

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

  /// "13 min" or "1 h 19 min".
  static String _minutes(num m) => m < 60 ? '${m.round()} min' : formatDuration(m);

  /// "Trip\n13 min · 6.0 km" (or "To pickup\n…") standing just above a point's mark, which reaches
  /// [over] above the point (so the chip never covers the pin).
  Marker _chip(LatLng at, Color color, String text, String key, {required double over}) {
    final lift = over + 6;
    return Marker(
      point: at,
      width: 150,
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

  /// The map, built again only when what it shows changes: the countdown
  /// rebuilds the sheet every second, which leaves the map alone.
  Widget? _map0;
  List<Object?>? _map0Deps;
  Widget _cachedMap(BuildContext context) {
    final deps = [widget.request, widget.me, widget.awayKm, _pickup, _drop, _trip, _toPickup];
    if (_map0 == null || !listEquals(deps, _map0Deps)) {
      _map0Deps = deps;
      _map0 = _mapPart(context);
    }
    return _map0!;
  }

  Widget _mapPart(BuildContext context) {
    final r = widget.request;
    final a = _pickup, b = _drop;
    // "Ride request" on a solid band above the map (161), so large text never
    // lands on the tiles or the pickup chip.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const ColoredBox(
        key: ValueKey('request-title-band'),
        color: Color(0xFF151515),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            'Ride request',
            key: ValueKey('request-sheet-title'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
          ),
        ),
      ),
      Expanded(child: LayoutBuilder(builder: (context, box) => Stack(children: [
      Positioned.fill(
        child: RideMap(
          controller: _map,
          pickup: a,
          drop: b,
          driver: widget.me,
          dotPins: true,
          route: _trip,
          framed: [?widget.me, ?a, ?b],
          // Room for the chips standing over the pins (two lines, some 90
          // above the pickup's point), and little below: the pins stand on
          // their points, so on a short map the three spread out (166).
          fitTop: 96,
          fitBottom: 28,
          // Over the car, which near the drop-off used to cover them.
          topMarkers: [
            if (a != null && widget.awayKm != null)
              _chip(
                a,
                RideRequestSheet.toPickup,
                'To pickup\n${_minutes(pickupMinutes(widget.awayKm!))} · ${formatDistance(widget.awayKm)}',
                'request-chip-pickup',
                over: confirmPickupTop,
              ),
            if (b != null && r.distanceKm != null)
              _chip(
                b,
                RideRequestSheet.trip,
                'Trip\n${[if (r.durationMin != null) _minutes(r.durationMin!), formatDistance(r.distanceKm)].join(' · ')}',
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
      // Zoom buttons only where the map has the width for them beside the
      // chips; a narrow pane (a phone on its side) zooms by pinch or wheel.
      if (box.maxWidth >= requestMapZoomMinWidth)
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
    ]))),
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

  Widget _doorLine(BuildContext context, String text, String key) => Padding(
    key: ValueKey(key),
    padding: const EdgeInsets.only(left: 28, top: 2),
    child: Row(children: [
      Icon(Icons.door_front_door_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 4),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600))),
    ]),
  );

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

  /// How long ago the request was made: "37 s ago", "2 min ago" or "just
  /// now" (not time left: that stands on the countdown bar).
  String _age() {
    final made = widget.request.createdAt;
    if (made == null) return 'just now';
    final s = widget.now.difference(made).inSeconds;
    if (s < 5) return 'just now';
    return s < 60 ? '$s s ago' : '${s ~/ 60} min ago';
  }

  Widget _rider(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.request;
    final photo = r.raw['rider_photo'];
    final muted = mutedTextColor(t);
    return SizedBox(
      width: 64,
      child: Column(children: [
        NetAvatar(url: photo is String ? photo : null, radius: 24, fallback: const Icon(Icons.person_outline)),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (r.isForOthers)
              Tooltip(
                message: 'Booked for someone else',
                child: Icon(Icons.group_outlined, key: const ValueKey('request-for-others'), size: 12, color: muted),
              ),
            Flexible(
              child: Text(
                r.firstNameForDrivers,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.labelSmall,
              ),
            ),
          ],
        ),
        if (showRiderStars(r, ref.watch(cityRideConfigProvider).value?.riderRating ?? RiderRatingSettings.standard))
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.star, size: 12, color: Color(0xFFF5A623)),
            Flexible(child: Text(r.riderRating!.toStringAsFixed(1), maxLines: 1, style: t.textTheme.labelSmall)),
          ]),
        // "New" or "Low", and the rider's trips (0269).
        RiderBadgeChip(ride: r, compact: true),
        if (r.riderTrips case final n?)
          Text('$n\u00A0${n == 1 ? 'trip' : 'trips'}',
              key: const ValueKey('request-rider-trips'), maxLines: 1, style: t.textTheme.labelSmall?.copyWith(color: muted)),
        Text(_age(), key: const ValueKey('request-age'), style: t.textTheme.labelSmall?.copyWith(color: muted)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.request;
    final fare = r.effectiveFare;
    final muted = mutedTextColor(t);
    final offer = widget.onOffer;
    final off = widget.busy;
    final h = MediaQuery.sizeOf(context).height;
    final details = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _rider(context),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (r.distanceKm != null)
              Text('~${formatDistance(r.distanceKm)}', style: t.textTheme.bodyMedium?.copyWith(color: muted)),
            Row(children: [
              Flexible(
                child: Text(
                  r.fareText(fare),
                  key: const ValueKey('request-fare'),
                  style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (widget.starred) ...[
                const SizedBox(width: 8),
                MyRideStar(key: ValueKey('my-ride-star-${r.id}'), size: 24),
              ],
              if (rideHasPromo(r)) ...[
                const SizedBox(width: 8),
                PromoAppliedIcon(key: ValueKey('promo-applied-${r.id}'), size: 20),
              ],
            ]),
            MyRideForYouLabel(request: r, me: widget.driverId, clock: () => widget.now),
            DirectBookingLabel(request: r, me: widget.driverId ?? _driverId),
            StandOrderLabel(request: r, me: widget.driverId ?? _driverId),
            // The region's surcharges and taxes, collected on top.
            if (r.chargeLines.isNotEmpty)
              Text(
                [for (final l in r.chargeLines) '+ ${l.label} ${formatMoney(l.amount, r.currency)}'].join(' · '),
                key: const ValueKey('request-charges'),
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
            // What the pets and assistance add; the fare above includes it.
            if (r.optionCharges.isNotEmpty)
              OptionChargesLine(lines: r.optionCharges, money: (v) => formatMoney(v, r.currency)),
            if (widget.raisedFrom case final was?)
              Text(
                'The passenger raised the fare from ${r.fareText(was)} '
                'to ${r.fareText(fare)}.',
                key: const ValueKey('request-alert-raised'),
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w600),
              ),
            _end(context, 'A', RideRequestSheet.toPickup, _place(r.pickupLabel, r.pickupAddress)),
            // The pickup's place type at a Multi-Gate place or airport (0264).
            RidePlaceTypeTag(
              key: const ValueKey('request-pickup-type'),
              typeKey: r.pickupPlaceType,
              padding: const EdgeInsetsDirectional.only(start: 28, top: 4),
            ),
            // The door the rider chose at an airport (0249).
            if (r.pickupDoor case final door?) _doorLine(context, 'Pickup door: $door', 'request-pickup-door'),
            _end(context, 'B', RideRequestSheet.trip, _place(r.dropLabel, null)),
            RidePlaceTypeTag(
              key: const ValueKey('request-drop-type'),
              typeKey: r.dropPlaceType,
              padding: const EdgeInsetsDirectional.only(start: 28, top: 4),
            ),
            if (r.dropDoor case final door?) _doorLine(context, 'Drop-off door: $door', 'request-drop-door'),
            const SizedBox(height: 6),
            Text(
              [
                r.paymentMode,
                '${r.passengers} pax',
                if ((r.luggage ?? 0) > 0) '${r.luggage} ${r.luggage == 1 ? 'bag' : 'bags'}',
                if (r.stops.isNotEmpty) '${r.stops.length} stop${r.stops.length == 1 ? '' : 's'}',
                if (widget.towardDestination) 'Toward your destination',
              ].join(' · '),
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            if (r.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('“${r.note}”', style: t.textTheme.bodySmall),
              ),
            // Freight (0267): what is carried, the size, the options; the
            // photo comes with the request once it is taken.
            if (r.isFreight)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FreightCargoView(request: r, locked: r.status == RideStatus.open),
              ),
            // "Pet with me": the photos come with the ride once it is taken.
            if (r.pets.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: RidePetsView(
                  pets: r.pets,
                  locked: r.status == RideStatus.open,
                  title: r.renamedOption(RideOptionKind.pet),
                ),
              ),
            // "Assistance required": the help before accepting; the rider's
            // note once the ride is taken.
            if (r.assistance case final help?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: RideAssistanceView(
                  assistance: help,
                  locked: r.status == RideStatus.open,
                  title: r.renamedOption(RideOptionKind.assistance),
                ),
              ),
          ]),
        ),
      ]),
    );
    // The time left to answer, running down, with its seconds (as the
    // Offer-sent dialog's "41s"), so the request's age is not read as it.
    final countdown = Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(children: [
        Expanded(
          child: LinearProgressIndicator(
            key: const ValueKey('request-alert-countdown'),
            value: requestAlertProgress(widget.shown),
            minHeight: 3,
            color: confirmAccent,
            backgroundColor: Colors.transparent,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${requestAlertSecondsLeft(widget.shown)}s',
          key: const ValueKey('request-alert-seconds-left'),
          style: t.textTheme.labelMedium?.copyWith(color: muted, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ]),
    );
    final actions = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: RequestAnswerButtons(
        request: r,
        busy: off,
        onAccept: widget.onAccept,
        onSkip: widget.onSkip,
        onOffer: offer,
      ),
    );
    final size = MediaQuery.sizeOf(context);
    // A phone on its side: map, details and buttons side by side, so the
    // fare, pickup and drop-off always show (stacked, the map and buttons
    // left the details no room at all).
    final beside = size.width > size.height && size.height < 500 && size.width >= 600;
    return Material(
      key: const ValueKey('request-alert'),
      color: t.colorScheme.surface,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: h * 0.94),
        child: beside
            ? SizedBox(
                height: h * 0.94,
                child: SafeArea(
                  top: false,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(
                      // The details get the most room: they must show whole.
                      child: LayoutBuilder(
                        // The map at least 220 wide, its zoom buttons only
                        // where there is room beside the chips (they sat on
                        // the trip chip at 203, 140); the fare offers fit
                        // their text in the answers' column or take two rows
                        // (139).
                        builder: (context, c) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          SizedBox(width: math.max(c.maxWidth * 0.24, 220.0), child: _cachedMap(context)),
                          Expanded(child: details),
                          SizedBox(width: c.maxWidth * 0.3, child: SingleChildScrollView(child: actions)),
                        ]),
                      ),
                    ),
                    countdown,
                  ]),
                ),
              )
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // The title band, then a map never shorter than 260: at 200 on
                // a 360x640 phone the car, pickup and drop-off sat on each other.
                SizedBox(
                  height: (h * 0.42).clamp(260.0, 340.0) + MediaQuery.textScalerOf(context).scale(56),
                  child: _cachedMap(context),
                ),
                Flexible(child: details),
                const SizedBox(height: 10),
                countdown,
                SafeArea(top: false, child: actions),
              ]),
      ),
    );
  }
}

/// Accept, in the app's accent (the rider's "Find a driver" blue), white
/// on it in light and dark alike.
ButtonStyle _acceptStyle(BuildContext context, {double height = 52}) => FilledButton.styleFrom(
  backgroundColor: accentFill,
  foregroundColor: Colors.white,
  disabledBackgroundColor: confirmAccent.withValues(alpha: 0.4),
  disabledForegroundColor: Colors.white70,
  minimumSize: Size.fromHeight(height),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  // The theme's font, not the default (a bare TextStyle lost it).
  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
);

/// The fare offers: the accent as a tint, so Accept stays the one to press.
ButtonStyle _offerStyle(BuildContext context, {double height = 48}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return FilledButton.styleFrom(
    backgroundColor: confirmAccent.withValues(alpha: dark ? 0.22 : 0.14),
    foregroundColor: dark ? const Color(0xFF7FD0F2) : const Color(0xFF0E6E99),
    minimumSize: Size.fromHeight(height),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    // The theme's font, not the default (a bare TextStyle lost it).
  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
  );
}

/// A fare offer's padding either side of its amount.
const requestOfferPad = 8.0;

/// "RM17" for "RM17.00": a whole fare, where its cents don't fit.
String requestOfferShortFare(String label) => label.endsWith('.00') ? label.substring(0, label.length - 3) : label;

/// Answering a request: Accept at the rider's fare, the fare offers (+ the
/// presets and a pencil for another amount) where the rider takes offers,
/// and Skip. The same on the phone's request sheet and the desktop's
/// request over the map.
class RequestAnswerButtons extends StatelessWidget {
  const RequestAnswerButtons({
    super.key,
    required this.request,
    required this.onAccept,
    required this.onSkip,
    this.onOffer,
    this.busy = false,
  });

  final RideRequest request;
  final Future<void> Function() onAccept;
  final VoidCallback onSkip;

  /// An offer of an amount, or null for one the driver types; null where
  /// the rider takes no offers.
  final Future<void> Function(double? amount)? onOffer;

  /// Something is being answered: every button off.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = request;
    final fare = r.effectiveFare;
    final muted = mutedTextColor(t);
    final offer = onOffer;
    final presets = fare == null ? const <double>[] : counterOfferPresets(fare);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BusyButton.filled(
        key: const ValueKey('request-alert-accept'),
        style: _acceptStyle(context),
        onPressed: busy ? null : onAccept,
        child: Text('Accept for ${r.fareText(fare)}', style: const TextStyle(fontSize: 17)),
      ),
      if (offer != null && presets.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Offer your fare', textAlign: TextAlign.center, style: t.textTheme.bodyMedium?.copyWith(color: muted)),
        const SizedBox(height: 8),
        // The fares whole, never shrunk to nothing (three 47-wide boxes in a
        // phone on its side showed no text, 139): one row where they fit,
        // "RM17" for "RM17.00" where that is what fits, else the offers on
        // a row of their own and the pencil under them.
        LayoutBuilder(builder: (context, box) {
          final style = _offerStyle(context).textStyle?.resolve({}) ?? const TextStyle();
          final base = Theme.of(context).textTheme.labelLarge?.merge(style) ?? style;
          final scaler = MediaQuery.textScalerOf(context);
          double width(String text) {
            final tp = TextPainter(
              text: TextSpan(text: text, style: base),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            final w = tp.width;
            tp.dispose();
            return w + 2 * requestOfferPad + 2;
          }
          const pencil = 56.0, gap = 8.0;
          final n = presets.length;
          final full = [for (final p in presets) r.fareText(p)];
          final short = [for (final l in full) requestOfferShortFare(l)];
          bool fits(List<String> labels, double room, int cols) =>
              labels.every((l) => width(l) <= (room - gap * (cols - 1)) / cols);
          // The first that fits: all on one row with the pencil, then the
          // offers on a row of their own, then two a row, then one; each
          // with the whole fare before "RM17" for "RM17.00".
          var together = false;
          var cols = 1;
          var labels = short;
          search:
          for (final (inline, c) in [(true, n), (false, n), (false, 2), (false, 1)]) {
            for (final l in [full, short]) {
              if (fits(l, inline ? box.maxWidth - pencil - gap : box.maxWidth, c)) {
                together = inline;
                cols = c;
                labels = l;
                break search;
              }
            }
          }
          final chipWidth = ((together ? box.maxWidth - pencil - gap : box.maxWidth) - gap * (cols - 1)) / cols - 0.01;
          Widget chip(int i) => BusyButton.filled(
                key: ValueKey('request-offer-$i'),
                style: _offerStyle(context).copyWith(
                  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: requestOfferPad)),
                ),
                onPressed: busy ? null : () => offer(presets[i]),
                child: Semantics(
                  label: 'Offer ${full[i]}',
                  excludeSemantics: true,
                  child: Text(labels[i], maxLines: 1, softWrap: false, overflow: TextOverflow.visible),
                ),
              );
          // Named on the button itself, the tooltip merged into it (119).
          final custom = SizedBox(
            width: together ? pencil : double.infinity,
            height: 48,
            child: Semantics(
              container: true,
              button: true,
              enabled: !busy,
              label: 'Offer another fare',
              onTap: busy ? null : () => offer(null),
              excludeSemantics: true,
              child: IconButton.filled(
              key: const ValueKey('request-offer-custom'),
              tooltip: 'Offer another fare',
              style: _offerStyle(context).copyWith(
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
              ),
              onPressed: busy ? null : () => offer(null),
              icon: const Icon(Icons.edit_outlined, size: 20),
            ),
            ),
          );
          final chips = Wrap(spacing: gap, runSpacing: gap, children: [
            for (var i = 0; i < n; i++) SizedBox(width: chipWidth, child: chip(i)),
            if (together) custom,
          ]);
          return together ? chips : Column(children: [chips, const SizedBox(height: gap), custom]);
        }),
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
        onPressed: busy ? null : onSkip,
        child: const Text('Skip', style: TextStyle(fontSize: 17)),
      ),
    ]);
  }
}
