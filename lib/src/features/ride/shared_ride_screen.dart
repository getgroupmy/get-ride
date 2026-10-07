import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/ride_share.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_map.dart';

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
          ? _SharedRideView(ride: r)
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

class _SharedRideView extends StatelessWidget {
  const _SharedRideView({required this.ride});
  final SharedRide ride;

  @override
  Widget build(BuildContext context) {
    final r = ride;
    final t = Theme.of(context);
    final map = RideMap(
      pickup: r.pickup,
      drop: r.drop,
      stops: [for (final s in r.stops) s.point],
      driver: r.driver,
      driverHeading: r.driverHeading,
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(sharedRideHeadline(r), key: const ValueKey('shared-headline'), style: t.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('${r.passenger}${r.service == null ? '' : ' · ${r.service}'}', style: t.textTheme.bodyMedium),
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
            child: ListTile(
              leading: CircleAvatar(
                backgroundImage: r.driverPhoto == null ? null : NetworkImage(r.driverPhoto!),
                child: r.driverPhoto == null ? const Icon(Icons.person) : null,
              ),
              title: Text(r.driverName!),
              subtitle: Text(
                [
                  if (r.vehicle != null) r.vehicle!,
                  if (r.plate != null) r.plate!,
                  if (r.driverRating != null) '★ ${r.driverRating!.toStringAsFixed(1)}',
                ].join(' · '),
              ),
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
        Text('A read-only view shared by a GET.ride rider. It updates by itself.', style: t.textTheme.bodySmall),
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
