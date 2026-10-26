// The driver rates the rider (migration 0269): stars, saved the moment one
// is tapped, then tags for the stars picked, saved as they are ticked. On
// the trip-finished screen, and from trip history for 24 hours after the
// drop-off.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/rider_rating.dart';
import '../../data/city_ride_repository.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/ride_rating_card.dart' show RatingSavedChip;

/// The star colour, readable on light and dark cards.
Color riderStarColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFFC53D) : const Color(0xFFB07A00);

class RateRiderForm extends ConsumerStatefulWidget {
  const RateRiderForm({super.key, required this.ride, this.onDone, this.showSkip = true});
  final RideRequest ride;

  /// Called on Done once rated (true), or on Skip before (false).
  final ValueChanged<bool>? onDone;
  final bool showSkip;

  @override
  ConsumerState<RateRiderForm> createState() => _RateRiderFormState();
}

/// How long after the last tag tick the tags are saved.
const rateRiderTagsSaveAfter = Duration(milliseconds: 600);

class _RateRiderFormState extends ConsumerState<RateRiderForm> {
  int _stars = 0;
  Set<String> _tags = {};
  bool _saved = false;
  bool _busy = false;
  Timer? _tagSave;

  /// The tags as last saved, so unchanged ones are not sent again.
  Set<String> _sentTags = {};
  /// Read on the first save and kept: tags sent as the screen goes can't
  /// use ref.
  CityRideRepository? _repoKept;
  CityRideRepository get _repo {
    final kept = _repoKept;
    if (kept != null) return kept;
    final CityRideRepository r = ref.read(cityRideRepositoryProvider);
    _repoKept = r;
    return r;
  }

  @override
  void dispose() {
    _tagSave?.cancel();
    // Tags still being ticked as the screen goes: sent all the same.
    if (_repoKept != null && _stars > 0 && !_sameTags(_tags, _sentTags)) unawaited(_repoKept!.rateRider(widget.ride.id, _stars, _tags).catchError((_) {}));
    super.dispose();
  }

  static bool _sameTags(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

  void _pick(int stars) {
    setState(() {
      _stars = stars;
      _tags = keepRiderTags(_tags, stars);
    });
    _tagSave?.cancel();
    unawaited(_send());
  }

  void _toggle(String tag, bool on) {
    setState(() => _tags = on ? {..._tags, tag} : ({..._tags}..remove(tag)));
    _tagSave?.cancel();
    _tagSave = Timer(rateRiderTagsSaveAfter, () => unawaited(_send()));
  }

  Future<void> _send() async {
    if (_stars == 0) return;
    final tags = {..._tags};
    setState(() => _busy = true);
    try {
      await _repo.rateRider(widget.ride.id, _stars, tags);
      _sentTags = tags;
      if (mounted) setState(() => _saved = true);
    } catch (e) {
      if (mounted) showInfo(context, rateRiderError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
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
        // Five 52 px targets; on a narrow card the row scales down whole.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  key: ValueKey('rate-rider-star-$i'),
                  tooltip: '$i ${i == 1 ? 'star' : 'stars'}',
                  iconSize: 40,
                  constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
                  icon: Icon(i <= _stars ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: i <= _stars ? star : t.colorScheme.outline),
                  // Saved as it is tapped: leaving the screen keeps it.
                  onPressed: () => _pick(i),
                ),
            ],
          ),
        ),
        Center(
          child: _saved
              ? RatingSavedChip(key: const ValueKey('rate-rider-saved'), busy: _busy)
              : Text('Tap a star. It saves straight away.', style: t.textTheme.bodySmall),
        ),
        const SizedBox(height: 8),
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
                  onSelected: (on) => _toggle(tag, on),
                ),
            ],
          ),
        // From trip history (a sheet): Done once rated. On the trip screen
        // nothing more: it is already saved.
        if (!widget.showSkip && _saved) ...[
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('rate-rider-done'),
            onPressed: () => widget.onDone?.call(true),
            child: const Text('Done'),
          ),
        ],
        if (widget.showSkip && _stars == 0)
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
