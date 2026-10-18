// After a trip: "Rate your driver" — 1–5 stars and an optional comment,
// saved through rate_ride (migration 0159), then shown as given with an Edit
// key while the rating window is open.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ride_rating.dart';
import '../data/models.dart';
import '../data/ride_rating_repository.dart';

class RideRatingCard extends ConsumerStatefulWidget {
  const RideRatingCard({super.key, required this.ride, this.now});
  final RideRequest ride;

  /// The clock, for tests.
  final DateTime Function()? now;

  @override
  ConsumerState<RideRatingCard> createState() => _RideRatingCardState();
}

class _RideRatingCardState extends ConsumerState<RideRatingCard> {
  final _comment = TextEditingController();
  int? _stars;
  bool _editing = false;
  bool _busy = false;

  /// What this card saved, ahead of the refetch.
  RideRating? _saved;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  void _edit(RideRating? from) => setState(() {
    _editing = true;
    _stars = from?.stars;
    _comment.text = from?.comment ?? '';
  });

  Future<void> _save() async {
    final stars = _stars;
    if (!validStars(stars) || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ref.read(rideRatingRepositoryProvider).rate(widget.ride.id, stars!, comment: _comment.text);
      if (!mounted) return;
      switch (res) {
        case RatingSaved(:final rating):
          setState(() {
            _saved = rating;
            _editing = false;
          });
          ref.invalidate(myRideRatingProvider((requestId: widget.ride.id, riderId: widget.ride.riderId ?? '')));
          messenger.showSnackBar(const SnackBar(content: Text('Thanks — your rating is saved.')));
        case RatingUnavailable():
          messenger.showSnackBar(const SnackBar(content: Text('Ratings aren\'t available yet.')));
      }
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(rideRatingError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    // Shown on the passenger's screens only (the server checks the caller
    // is the ride's passenger).
    final rider = r.riderId;
    if (r.status != RideStatus.completed || rider == null) return const SizedBox.shrink();
    final open = canRateRide(completed: true, completedAt: r.completedAt, now: (widget.now ?? DateTime.now)());
    final saved = _saved ?? ref.watch(myRideRatingProvider((requestId: r.id, riderId: rider))).value;
    if (saved == null && !open) return const SizedBox.shrink();
    final t = Theme.of(context);
    final name = (r.partnerName ?? '').trim();
    final title = name.isEmpty ? 'Rate your driver' : 'Rate $name';

    if (saved != null && !_editing) {
      return Card(
        key: const ValueKey('ride-rating-saved'),
        child: ListTile(
          leading: Icon(Icons.star_rounded, color: _starColor(t)),
          title: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Your rating '),
              _Stars(value: saved.stars, size: 18, color: _starColor(t)),
            ],
          ),
          subtitle: saved.comment == null ? null : Text(saved.comment!, maxLines: 3, overflow: TextOverflow.ellipsis),
          trailing: open
              ? TextButton(
                  key: const ValueKey('ride-rating-edit'),
                  onPressed: () => _edit(saved),
                  child: const Text('Edit'),
                )
              : null,
        ),
      );
    }

    final stars = _stars;
    return Card(
      key: const ValueKey('ride-rating-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('How was your trip?', style: t.textTheme.bodySmall),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    key: ValueKey('rate-star-$i'),
                    tooltip: '$i star${i == 1 ? '' : 's'}',
                    iconSize: 36,
                    onPressed: _busy ? null : () => setState(() => _stars = i),
                    icon: Icon(
                      stars != null && i <= stars ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: stars != null && i <= stars ? _starColor(t) : t.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            Center(child: Text(starsLabel(stars ?? 0), style: t.textTheme.labelLarge)),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('ride-rating-comment'),
              controller: _comment,
              enabled: !_busy,
              maxLength: rideRatingCommentMax,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: 'Comment (optional)',
                hintText: 'Anything your driver should know?',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            // Full width, as the app's filled buttons are.
            FilledButton(
              key: const ValueKey('ride-rating-submit'),
              onPressed: validStars(stars) && !_busy ? _save : null,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Submit rating'),
            ),
            if (_editing && saved != null)
              TextButton(
                key: const ValueKey('ride-rating-cancel'),
                onPressed: _busy ? null : () => setState(() => _editing = false),
                child: const Text('Cancel'),
              ),
          ],
        ),
      ),
    );
  }
}

Color _starColor(ThemeData t) => t.brightness == Brightness.dark ? const Color(0xFFFFC94D) : const Color(0xFFE0A100);

class _Stars extends StatelessWidget {
  const _Stars({required this.value, required this.size, required this.color});
  final int value;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 1; i <= 5; i++)
        Icon(i <= value ? Icons.star_rounded : Icons.star_outline_rounded, size: size, color: color),
    ],
  );
}
