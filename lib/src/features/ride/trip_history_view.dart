// The request history list, for one side of the person (core/trip_history.dart):
// Trips on the user side, Drive → Trip history on the partner side. Chips
// filter by status; older requests load a page at a time.
import '../../core/rider_rating.dart' show canRateRider;
import '../partner/rate_rider.dart' show showRateRiderSheet;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart' show formatMoney;
import '../../core/region_time.dart';
import '../../core/ride_cancel.dart' show cancelledLine;
import '../../core/trip_history.dart';
import '../../data/models.dart';
import '../../data/trip_history_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/edge_fade_scroll.dart';

class TripHistoryView extends ConsumerStatefulWidget {
  const TripHistoryView({super.key, required this.role});

  final TripHistoryRole role;

  @override
  ConsumerState<TripHistoryView> createState() => _TripHistoryViewState();
}

class _TripHistoryViewState extends ConsumerState<TripHistoryView> {
  var _filter = TripHistoryFilter.all;
  final _rows = <RideRequest>[];
  bool _loading = false;
  bool _more = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    _rows.clear();
    _more = true;
    await _load();
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final filter = _filter;
    try {
      final page = await ref
          .read(tripHistoryRepositoryProvider)
          .page(widget.role, filter: filter, before: _rows.isEmpty ? null : _rows.last.createdAt);
      if (!mounted || filter != _filter) return;
      setState(() {
        _rows.addAll(page);
        _more = page.length >= tripHistoryPageSize;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _pick(TripHistoryFilter f) {
    if (f == _filter) return;
    setState(() => _filter = f);
    unawaited(_reload());
  }

  /// A driver's completed trip in its first 24 hours: "Rate rider" under it
  /// (after a Skip on the trip-finished screen, 0269).
  Widget _withRateRider(RideRequest r, bool partner, Widget tile) {
    if (!partner || r.riderId == null ||
        !canRateRider(completed: r.status == RideStatus.completed, completedAt: r.completedAt, now: DateTime.now())) {
      return tile;
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      tile,
      Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: TextButton.icon(
            key: ValueKey('trip-rate-rider-${r.id}'),
            icon: const Icon(Icons.star_outline_rounded),
            label: const Text('Rate rider'),
            onPressed: () => showRateRiderSheet(context, r),
          ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final partner = widget.role == TripHistoryRole.partner;
    // Scrolls sideways with a fade at the edge with more, so a cut-off
    // "Cancelled" reads as more to come.
    final chips = EdgeFadeScroll(
      key: const ValueKey('trip-filters'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        spacing: 8,
        children: [
          for (final f in TripHistoryFilter.values)
            ChoiceChip(
              key: ValueKey('trip-filter-${f.name}'),
              label: Text(f.label),
              selected: f == _filter,
              onSelected: (_) => _pick(f),
            ),
        ],
      ),
    );
    final Widget body;
    if (_rows.isEmpty && _loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_rows.isEmpty && _error != null) {
      body = ListView(
        children: [
          EmptyState(
            icon: Icons.cloud_off_outlined,
            title: "Couldn't load your trips",
            message: errorText(_error!),
            action: OutlinedButton(onPressed: () => unawaited(_reload()), child: const Text('Try again')),
          ),
        ],
      );
    } else if (_rows.isEmpty) {
      body = ListView(
        children: [
          EmptyState(
            icon: partner ? Icons.drive_eta_outlined : Icons.receipt_long,
            title: _filter == TripHistoryFilter.all ? 'No trips yet' : 'No ${_filter.label.toLowerCase()} trips',
            message: partner ? 'Trips you drive will show up here.' : 'Rides you book will show up here.',
          ),
        ],
      );
    } else {
      body = ListView.builder(
        itemCount: _rows.length + 1,
        itemBuilder: (_, i) {
          if (i == _rows.length) {
            if (!_more) return const SizedBox(height: 24);
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : OutlinedButton(
                        key: const ValueKey('trip-history-more'),
                        onPressed: () => unawaited(_load()),
                        child: const Text('Load more'),
                      ),
              ),
            );
          }
          final r = _rows[i];
          return ResponsiveCenter(
            maxWidth: 760,
            child: Card(
              key: ValueKey('trip-${r.id}'),
              child: _withRateRider(r, partner, ListTile(
                leading: Icon(partner ? Icons.drive_eta : Icons.local_taxi),
                // Pickup and drop-off on lines of their own, so a phone shows
                // where the trip went, not just where it began.
                title: Text(r.pickupLabel, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('to ${r.dropLabel}', maxLines: 2, overflow: TextOverflow.ellipsis),
                    // Two lines at large (and bold) text rather than cut.
                    Text(
                      formatInZone(r.createdAt, r.timezone),
                      key: ValueKey('trip-date-${r.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // Who cancelled and why ("Cancelled by you · Drivers are
                    // too far away"), wrapping at large text.
                    Text(
                      [
                        tripStatusLine(r, asRider: !partner),
                        // A promo settled on the trip (0242).
                        ?tripListPromo(r),
                      ].join(' · '),
                      key: ValueKey('trip-status-${r.id}'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                isThreeLine: true,
                // A trip never billed says so under its status, not in the
                // fare's place: "Not charged" there was wider than a fare and
                // cut the date at large (and bold) text.
                trailing: tripListFare(r) == notChargedLabel
                    ? null
                    : Text(
                        tripListFare(r),
                        key: ValueKey('trip-fare-${r.id}'),
                        style: r.status.isFinished && r.status != RideStatus.completed
                            ? TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)
                            : null,
                      ),
                onTap: () => context.push(tripHistoryRoute(widget.role, r)),
              )),
            ),
          );
        },
      );
    }
    return Column(
      children: [
        chips,
        Expanded(
          child: RefreshIndicator(onRefresh: _reload, child: body),
        ),
      ],
    );
  }
}

/// A trip row's status line: the status (for a cancelled ride, who
/// cancelled and why, [cancelledLine]), then "Not charged" where the fare
/// was never billed.
String tripStatusLine(RideRequest r, {required bool asRider}) {
  final status = cancelledLine(r, asRider: asRider) ?? r.status.label;
  return tripListFare(r) == notChargedLabel ? '$status · $notChargedLabel' : status;
}

/// What a cancelled or expired trip's row shows for its fare.
const notChargedLabel = 'Not charged';

/// The amount a trip row shows: the fare with two decimals on every row
/// (RM4.00, RM57.00), or "Not charged" for a trip that was cancelled or
/// expired, whose quoted fare was never billed.
String tripListFare(RideRequest r) {
  if (r.status == RideStatus.cancelled || r.status == RideStatus.expired) return notChargedLabel;
  return formatMoney(r.effectiveFare, r.currency);
}

/// "Promo RIDE5 −RM5.00" on a completed trip a promo was settled on, else null.
String? tripListPromo(RideRequest r) =>
    r.status == RideStatus.completed && r.promoDiscount > 0
        ? 'Promo ${r.promo?.code ?? ''} −${formatMoney(r.promoDiscount, r.currency)}'.replaceAll('  ', ' ')
        : null;
