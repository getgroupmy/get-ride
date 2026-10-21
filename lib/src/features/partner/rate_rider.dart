// The driver rates the rider (migration 0269): stars, tags for the stars
// picked, Submit and Skip. On the trip-finished screen, and from trip
// history for 24 hours after the drop-off.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/rider_rating.dart';
import '../../data/city_ride_repository.dart';
import '../../data/models.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

/// The star colour, readable on light and dark cards.
Color riderStarColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFFC53D) : const Color(0xFFB07A00);

class RateRiderForm extends ConsumerStatefulWidget {
  const RateRiderForm({super.key, required this.ride, this.onDone, this.showSkip = true});
  final RideRequest ride;

  /// Called after Submit (true) or Skip (false).
  final ValueChanged<bool>? onDone;
  final bool showSkip;

  @override
  ConsumerState<RateRiderForm> createState() => _RateRiderFormState();
}

class _RateRiderFormState extends ConsumerState<RateRiderForm> {
  int _stars = 0;
  Set<String> _tags = {};

  Future<void> _submit() async {
    try {
      await ref.read(cityRideRepositoryProvider).rateRider(widget.ride.id, _stars, _tags);
      if (!mounted) return;
      showInfo(context, 'Thanks. Your rating was sent.');
      widget.onDone?.call(true);
    } catch (e) {
      if (mounted) showInfo(context, rateRiderError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.ride;
    final name = r.passengerName;
    final star = riderStarColor(context);
    return Column(
      key: const ValueKey('rate-rider'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Rate $name', textAlign: TextAlign.center, style: t.textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(
          '${r.pickupLabel} to ${r.dropLabel} · ${r.fareText(r.effectiveFare)}',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                key: ValueKey('rate-rider-star-$i'),
                tooltip: '$i ${i == 1 ? 'star' : 'stars'}',
                iconSize: 36,
                icon: Icon(i <= _stars ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: i <= _stars ? star : t.colorScheme.outline),
                onPressed: () => setState(() {
                  _stars = i;
                  _tags = keepRiderTags(_tags, i);
                }),
              ),
          ],
        ),
        if (_stars > 0)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final tag in riderTagsFor(_stars))
                FilterChip(
                  key: ValueKey('rate-rider-tag-$tag'),
                  label: Text(tag),
                  selected: _tags.contains(tag),
                  onSelected: (on) => setState(() => on ? _tags = {..._tags, tag} : _tags = {..._tags}..remove(tag)),
                ),
            ],
          ),
        const SizedBox(height: 12),
        BusyButton.filled(
          key: const ValueKey('rate-rider-submit'),
          onPressed: _stars == 0 ? null : _submit,
          child: const Text('Submit'),
        ),
        if (widget.showSkip)
          TextButton(
            key: const ValueKey('rate-rider-skip'),
            onPressed: () => widget.onDone?.call(false),
            child: const Text('Skip'),
          ),
      ],
    );
  }
}

/// On the trip-finished screen: the form in a card, gone after Submit or Skip
/// (a skipped trip can be rated from trip history for 24 hours).
class RateRiderCard extends StatefulWidget {
  const RateRiderCard({super.key, required this.ride, required this.now});
  final RideRequest ride;
  final DateTime now;

  @override
  State<RateRiderCard> createState() => _RateRiderCardState();
}

class _RateRiderCardState extends State<RateRiderCard> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    if (_done || r.riderId == null || !canRateRider(completed: true, completedAt: r.completedAt ?? widget.now, now: widget.now)) {
      return const SizedBox.shrink();
    }
    return Card(
      key: const ValueKey('rate-rider-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: RateRiderForm(ride: r, onDone: (_) => setState(() => _done = true)),
      ),
    );
  }
}

/// From trip history: the form in a sheet.
Future<void> showRateRiderSheet(BuildContext context, RideRequest r) => showAppSheet<void>(
  id: 'driver.rate-rider',
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (c) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(c).bottom),
      child: RateRiderForm(ride: r, showSkip: false, onDone: (_) => Navigator.of(c).pop()),
    ),
  ),
);
