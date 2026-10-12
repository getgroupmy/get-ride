// My Ride pieces shared by the My Ride page, the confirm step and the
// searching screen: a favourite driver's row, the picker sheet, the confirm
// step's switch and the searching banner (lib/src/core/my_ride.dart for the
// rules, lib/src/data/my_ride_repository.dart for the server).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/my_ride.dart';
import '../../data/models.dart';
import '../../data/my_ride_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/net_image.dart';
import '../my_qr/direct_booking.dart' show directBookingNamesProvider;
import '../ride/confirm_parts.dart' show ConfirmSwitch;
import '../ride/searching_parts.dart' show SearchBlock;
import 'my_ride_settings.dart';

// ---- Rules ---------------------------------------------------------------------

/// Favourites in the order a rider picks from: available ones first, then
/// online, then nearest, then by name.
List<FavouriteDriver> myRidePickOrder(Iterable<FavouriteDriver> drivers) {
  int rank(FavouriteDriver d) => !d.available ? 2 : (d.online ? 0 : 1);
  final list = drivers.toList();
  list.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    final da = a.distanceKm, db = b.distanceKm;
    if (da != null && db != null && da != db) return da.compareTo(db);
    if (da != null && db == null) return -1;
    if (da == null && db != null) return 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return list;
}

/// Whether [d] may be offered a ride under the rider's [maxKm]: a driver
/// whose distance isn't known stays in, as on the server.
bool withinMyRideLimit(FavouriteDriver d, double? maxKm) =>
    maxKm == null || maxKm <= 0 || d.distanceKm == null || d.distanceKm! <= maxKm;

/// Whether [d] can be picked for a request under [maxKm].
bool myRidePickable(FavouriteDriver d, double? maxKm) => d.available && withinMyRideLimit(d, maxKm);

/// The drivers a booking with My Ride on goes to when the rider hasn't
/// picked: every pickable favourite, online ones first, at most
/// [myRideMaxTargets].
List<String> defaultMyRideTargets(Iterable<FavouriteDriver> drivers, double? maxKm) => [
  for (final d in myRidePickOrder(drivers))
    if (myRidePickable(d, maxKm)) d.driverId,
].take(myRideMaxTargets).toList();

/// "Ali", "Ali and Ben", "Ali, Ben and 2 more"; drivers the list doesn't
/// know count as "1 driver" / "N drivers".
String myRideNames(Iterable<String> ids, Iterable<FavouriteDriver> drivers) {
  final byId = {for (final d in drivers) d.driverId: d.name};
  final all = ids.toList();
  final names = [for (final id in all) ?byId[id]];
  final unknown = all.length - names.length;
  if (names.isEmpty) return unknown == 1 ? '1 driver' : '$unknown drivers';
  final extra = unknown + (names.length > 2 ? names.length - 2 : 0);
  final shown = names.take(2).toList();
  if (extra > 0) return '${shown.join(', ')} and $extra more';
  return shown.length == 2 ? '${shown[0]} and ${shown[1]}' : shown.single;
}

/// "a few seconds", "45 seconds", "5 minutes", "2 hours".
String myRideWait(Duration d) {
  final s = d.inSeconds;
  if (s < 5) return 'a few seconds';
  if (s < 60) return '$s seconds';
  final m = (s / 60).ceil();
  if (m < 60) return m == 1 ? '1 minute' : '$m minutes';
  final h = (m / 60).ceil();
  return h == 1 ? '1 hour' : '$h hours';
}

/// What an [AddFavouriteError] tells the rider, with the wait when the
/// server gave one.
String addFavouriteMessage(AddFavouriteError e, {Duration? retryAfter}) =>
    e == AddFavouriteError.rateLimited && retryAfter != null
    ? 'Too many codes tried. Try again in ${myRideWait(retryAfter)}.'
    : e.message;

/// "Opens to all nearby drivers in 42s".
String myRideOpensIn(Duration left) => 'Opens to all nearby drivers in ${(left.inMilliseconds / 1000).ceil()}s';

const myRideUnavailableMessage = "My Ride isn't available yet. Please check back later.";

// ---- Providers -----------------------------------------------------------------

/// The rider's favourites for booking and searching, with distances to
/// [at]; null when My Ride isn't available or the list can't be read, so a
/// booking never fails over it.
final bookingFavouritesProvider = FutureProvider.autoDispose
    .family<List<FavouriteDriver>?, ({double lat, double lng})?>((ref, at) async {
      try {
        if (ref.watch(currentUserIdProvider) == null) return const [];
        return await ref.watch(myRideRepositoryProvider).favourites(lat: at?.lat, lng: at?.lng);
      } catch (_) {
        return null;
      }
    });

// ---- A favourite's row ------------------------------------------------------------

/// Online / last seen / unavailable, as a small pill.
class MyRideStatusChip extends StatelessWidget {
  const MyRideStatusChip({super.key, required this.driver});
  final FavouriteDriver driver;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final d = driver;
    final (label, bg, fg) = !d.available
        ? ('Unavailable', t.colorScheme.errorContainer, t.colorScheme.onErrorContainer)
        : d.online
        ? (
            'Online',
            dark ? const Color(0xFF14532D) : const Color(0xFFDCFCE7),
            dark ? const Color(0xFFBBF7D0) : const Color(0xFF166534),
          )
        : ((d.lastSeen ?? LastSeen.away).label, t.colorScheme.surfaceContainerHighest, t.colorScheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: t.textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A favourite driver: photo, name, vehicle and plate, rating, online or
/// last seen, and the distance while online. An unavailable one (hidden
/// the rider, or can't take rides) is dimmed.
class FavouriteDriverTile extends StatelessWidget {
  const FavouriteDriverTile({super.key, required this.driver, this.trailing, this.onTap, this.dimmed});
  final FavouriteDriver driver;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Dims the row; defaults to the driver being unavailable.
  final bool? dimmed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = driver;
    final muted = t.colorScheme.onSurfaceVariant;
    final vehicle = [d.vehicleLabel, d.plate].whereType<String>().join(' · ');
    final rating = d.rating;
    final km = d.distanceKm;
    final row = InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            NetAvatar(url: d.avatarUrl, radius: 24, fallback: const Icon(Icons.person)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (vehicle.isNotEmpty)
                    Text(
                      vehicle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      MyRideStatusChip(driver: d),
                      if (rating != null && rating > 0)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star_rounded, size: 16, color: Color(0xFFF59E0B)),
                            const SizedBox(width: 2),
                            Text(rating.toStringAsFixed(1), style: t.textTheme.bodySmall),
                          ],
                        ),
                      if (d.available && d.online && km != null)
                        Text('${_km(km)} away', style: t.textTheme.bodySmall?.copyWith(color: muted)),
                    ],
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
    return (dimmed ?? !d.available) ? Opacity(opacity: 0.6, child: row) : row;
  }
}

String _km(double km) => '${km == km.roundToDouble() ? km.toStringAsFixed(0) : km.toStringAsFixed(1)} km';

// ---- The picker -----------------------------------------------------------------

/// A sheet of [drivers] to tick; the ticked ids, or null when dismissed.
/// Only available ones within [maxKm] can be ticked, at most
/// [myRideMaxTargets] (less [taken], already on the request).
Future<Set<String>?> showMyRidePicker(
  BuildContext context, {
  required List<FavouriteDriver> drivers,
  Set<String> selected = const {},
  double? maxKm,
  String title = 'Offer to your drivers',
  String doneLabel = 'Done',
  int taken = 0,
}) => showModalBottomSheet<Set<String>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => _MyRidePicker(
    drivers: myRidePickOrder(drivers),
    selected: selected,
    maxKm: maxKm,
    title: title,
    doneLabel: doneLabel,
    limit: (myRideMaxTargets - taken).clamp(0, myRideMaxTargets),
  ),
);

class _MyRidePicker extends StatefulWidget {
  const _MyRidePicker({
    required this.drivers,
    required this.selected,
    required this.maxKm,
    required this.title,
    required this.doneLabel,
    required this.limit,
  });
  final List<FavouriteDriver> drivers;
  final Set<String> selected;
  final double? maxKm;
  final String title;
  final String doneLabel;
  final int limit;

  @override
  State<_MyRidePicker> createState() => _MyRidePickerState();
}

class _MyRidePickerState extends State<_MyRidePicker> {
  late final _pickable = [
    for (final d in widget.drivers)
      if (myRidePickable(d, widget.maxKm)) d.driverId,
  ].take(widget.limit).toList();
  late final Set<String> _on = {
    for (final id in widget.selected)
      if (_pickable.contains(id)) id,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final all = _pickable.isNotEmpty && _on.length == _pickable.length;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: ResponsiveCenter(
        maxWidth: 560,
        child: Column(
          key: const ValueKey('my-ride-picker'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(widget.title, style: t.textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'They see your request first. If none of them takes it, it opens to every driver nearby.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
            if (_pickable.length > 1)
              CheckboxListTile(
                key: const ValueKey('my-ride-pick-all'),
                value: all,
                title: const Text('Select all'),
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (v) => setState(() {
                  _on.clear();
                  if (v == true) _on.addAll(_pickable);
                }),
              ),
            const Divider(height: 1),
            Flexible(child: ListView(shrinkWrap: true, children: [for (final d in widget.drivers) _row(d)])),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                key: const ValueKey('my-ride-pick-done'),
                onPressed: _on.isEmpty ? null : () => Navigator.pop(context, {..._on}),
                child: Text(_on.isEmpty ? 'Pick a driver' : '${widget.doneLabel} (${_on.length})'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(FavouriteDriver d) {
    final pickable = _pickable.contains(d.driverId);
    final farther = d.available && !withinMyRideLimit(d, widget.maxKm);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FavouriteDriverTile(
          key: ValueKey('my-ride-pick-${d.driverId}'),
          driver: d,
          dimmed: !pickable,
          onTap: pickable ? () => _toggle(d.driverId) : null,
          trailing: Checkbox(value: _on.contains(d.driverId), onChanged: pickable ? (_) => _toggle(d.driverId) : null),
        ),
        if (farther)
          Padding(
            padding: const EdgeInsets.fromLTRB(76, 0, 16, 8),
            child: Text(
              'Farther than your ${myRideMaxKmLabel(widget.maxKm)} limit',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  void _toggle(String id) => setState(() => _on.contains(id) ? _on.remove(id) : _on.add(id));
}

// ---- The confirm step ------------------------------------------------------------

/// The confirm step's "My Ride" switch, with the drivers it goes to under
/// it (a tap on them changes the pick).
class MyRideConfirmRow extends StatelessWidget {
  const MyRideConfirmRow({super.key, required this.on, required this.names, required this.onChanged, this.onEdit});
  final bool on;

  /// Who it goes to, while [on].
  final String? names;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    return Row(
      key: const ValueKey('my-ride-row'),
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF4C1D2E) : const Color(0xFFFCE7F3),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.favorite, size: 16, color: dark ? const Color(0xFFF9A8D4) : const Color(0xFFBE185D)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: InkWell(
            key: const ValueKey('my-ride-names'),
            onTap: on ? onEdit : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('My Ride', style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                Text(
                  on && names != null ? 'To $names first · Change' : 'Offer it to your favourite drivers first',
                  style: t.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
        ConfirmSwitch(key: const ValueKey('my-ride-switch'), value: on, onChanged: onChanged),
      ],
    );
  }
}

// ---- While searching ------------------------------------------------------------

/// The searching screen's My Ride banner: who the request is offered to,
/// the countdown to it opening to everybody, "Offer to all nearby" and "Add
/// a driver". When the countdown ends the app opens it itself (once), so
/// nearby drivers hear of it without waiting for the server's tick.
///
/// A GET.now request ([RideRequest.isDirectBooking]) gets its own banner
/// instead: booked directly with one driver, with no countdown (nothing
/// opens it to all by itself) and no "Add a driver"; "Offer to all nearby"
/// stays, as the rider's own choice.
class MyRideSearchBanner extends ConsumerStatefulWidget {
  const MyRideSearchBanner({super.key, required this.ride, required this.now});
  final RideRequest ride;
  final DateTime now;

  @override
  ConsumerState<MyRideSearchBanner> createState() => _MyRideSearchBannerState();
}

class _MyRideSearchBannerState extends ConsumerState<MyRideSearchBanner> {
  bool _autoOffered = false;
  bool _offeredAll = false;
  bool _busy = false;

  /// Targets added here, before the row says so.
  final _added = <String>[];

  RideRequest get _r => widget.ride;

  ({double lat, double lng})? get _at {
    final lat = _r.pickupLat, lng = _r.pickupLng;
    return lat == null || lng == null ? null : (lat: lat, lng: lng);
  }

  List<String> get _targets => {..._r.targetDriverIds, ..._added}.toList();

  bool get _windowOpen => !_offeredAll && _r.myRideWindowOpenAt(widget.now);

  @override
  void didUpdateWidget(covariant MyRideSearchBanner old) {
    super.didUpdateWidget(old);
    _maybeOpenToAll();
  }

  @override
  void initState() {
    super.initState();
    _maybeOpenToAll();
  }

  /// The window ran out and nearby drivers haven't been told yet: tell
  /// them now, once.
  void _maybeOpenToAll() {
    final r = _r;
    if (_autoOffered || _offeredAll || r.status != RideStatus.open || !r.isMyRide || r.isDirectBooking) return;
    if (r.targetedUntil == null || r.fallbackPushedAt != null || r.myRideWindowOpenAt(widget.now)) return;
    _autoOffered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _offeredAll = true);
      unawaited(ref.read(myRideRepositoryProvider).offerToAll(r.id).then((_) {}, onError: (_) {}));
    });
  }

  Future<void> _offerToAll() async {
    setState(() => _busy = true);
    try {
      final out = await ref.read(myRideRepositoryProvider).offerToAll(_r.id);
      if (!mounted) return;
      switch (out) {
        case OfferToAllOutcome.opened || OfferToAllOutcome.alreadyOpen:
          setState(() => _offeredAll = true);
        case OfferToAllOutcome.notOpen:
          showInfo(context, 'This request is no longer open.');
        case OfferToAllOutcome.unavailable:
          showInfo(context, myRideUnavailableMessage);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addDriver(List<FavouriteDriver> favourites) async {
    final taken = _targets.toSet();
    final rest = [
      for (final d in favourites)
        if (!taken.contains(d.driverId)) d,
    ];
    if (!rest.any((d) => myRidePickable(d, _r.myRideMaxKm))) {
      showInfo(context, 'All your available drivers already have this request.');
      return;
    }
    final picked = await showMyRidePicker(
      context,
      drivers: rest,
      maxKm: _r.myRideMaxKm,
      title: 'Add a driver',
      doneLabel: 'Add',
      taken: taken.length,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final now = await ref.read(myRideRepositoryProvider).addTargets(_r.id, picked.toList());
      if (!mounted) return;
      if (now == null) {
        showInfo(context, myRideUnavailableMessage);
        return;
      }
      final added = [
        for (final id in now)
          if (!taken.contains(id)) id,
      ];
      setState(() => _added.addAll(added));
      showInfo(
        context,
        added.isEmpty
            ? "Those drivers can't be offered this ride right now."
            : 'Offered to ${myRideNames(added, favourites)} too.',
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Who a direct request went to: as booked on this phone, else the
  /// rider's favourite of that id, else "your driver".
  String _directName() {
    final r = _r;
    final booked = ref.watch(directBookingNamesProvider)[r.id];
    if (booked != null && booked.trim().isNotEmpty) return booked.trim();
    final id = r.directDriverId;
    final favourites = ref.watch(bookingFavouritesProvider(_at)).value ?? const <FavouriteDriver>[];
    for (final d in favourites) {
      if (d.driverId == id && d.name.trim().isNotEmpty) return d.name.trim();
    }
    return 'your driver';
  }

  Widget _direct(BuildContext context) {
    final t = Theme.of(context);
    final r = _r;
    if (_offeredAll || r.fallbackPushedAt != null) {
      return SearchBlock(
        key: const ValueKey('my-ride-opened'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.groups_outlined, color: t.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text('Now offered to all nearby drivers', style: t.textTheme.bodyMedium)),
          ],
        ),
      );
    }
    final name = _directName();
    return SearchBlock(
      key: const ValueKey('direct-booking-banner'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.qr_code_2, color: t.colorScheme.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('Booked directly with $name', style: t.textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "Only $name gets this request. If they can't take it, offer it to every driver nearby.",
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('direct-offer-all'),
                onPressed: _busy ? null : _offerToAll,
                icon: const Icon(Icons.groups_outlined),
                label: const Text('Offer to all nearby'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (r.isDirectBooking) return _direct(context);
    if (!r.isMyRide) return const SizedBox.shrink();
    final t = Theme.of(context);
    if (!_windowOpen) {
      return SearchBlock(
        key: const ValueKey('my-ride-opened'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.groups_outlined, color: t.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text('Now offered to all nearby drivers', style: t.textTheme.bodyMedium)),
          ],
        ),
      );
    }
    final favourites = ref.watch(bookingFavouritesProvider(_at)).value ?? const <FavouriteDriver>[];
    final left = r.myRideWindowRemainingAt(widget.now) ?? Duration.zero;
    final created = r.createdAt;
    final until = r.targetedUntil!;
    final total = created == null ? null : until.difference(created);
    final progress = total == null || total.inMilliseconds <= 0
        ? null
        : (left.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final dark = t.brightness == Brightness.dark;
    final accent = dark ? const Color(0xFFF9A8D4) : const Color(0xFFBE185D);
    final more = favourites.any((d) => !_targets.contains(d.driverId) && myRidePickable(d, r.myRideMaxKm));
    return SearchBlock(
      key: const ValueKey('my-ride-banner'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.favorite, color: accent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Offered to your drivers: ${myRideNames(_targets, favourites)}',
                  style: t.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: const ValueKey('my-ride-countdown'),
              value: progress,
              minHeight: 6,
              color: accent,
              backgroundColor: t.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 6),
          Text(myRideOpensIn(left), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('my-ride-offer-all'),
                onPressed: _busy ? null : _offerToAll,
                icon: const Icon(Icons.groups_outlined),
                label: const Text('Offer to all nearby'),
              ),
              if (more)
                OutlinedButton.icon(
                  key: const ValueKey('my-ride-add-target'),
                  onPressed: _busy ? null : () => _addDriver(favourites),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Add a driver'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The settings for booking, with the defaults while they load.
MyRideSettings myRideSettingsOf(WidgetRef ref) => ref.watch(myRideSettingsProvider).value ?? const MyRideSettings();
