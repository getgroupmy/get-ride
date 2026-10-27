// After a trip: "Rate your driver" — 1–5 stars, tags from the admin's
// lists (0297: "What went well?" or "What went wrong?") and an optional
// comment, saved through rate_ride (migration 0159) the moment a star is
// tapped, as Grab and inDrive do, and again as tags are picked and the
// comment is written; then shown as given with an Edit key while the
// rating window is open.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ride_rating.dart';
import '../data/models.dart';
import '../data/ride_rating_repository.dart';
import 'app_notice.dart';

class RideRatingCard extends ConsumerStatefulWidget {
  const RideRatingCard({super.key, required this.ride, this.now, this.onSkip});
  final RideRequest ride;

  /// Skip, before a star is picked: on the trip screen it goes on to the
  /// trip summary. None on the receipt.
  final VoidCallback? onSkip;

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

  /// Saved from this card at least once: it stays open for a comment, with
  /// "Rating saved" under the stars, instead of folding away.
  bool _savedHere = false;

  /// The comment as last saved, so an unchanged one is not sent again.
  String _sentComment = '';
  Timer? _commentSave;

  /// The tags picked (0297).
  Set<String> _tags = {};
  Timer? _tagSave;

  /// The lists last built with, kept so a send as the card goes needs no ref.
  DriverRatingTags _tagLists = DriverRatingTags.fallback;
  List<String> get _keptTags => keepDriverTags(_tags, _stars, _tagLists);

  /// What this card saved, ahead of the refetch.
  RideRating? _saved;

  /// Read on the first save and kept: a comment sent as the card goes
  /// can't use ref.
  RideRatingRepository? _repoKept;
  RideRatingRepository get _repo {
    final kept = _repoKept;
    if (kept != null) return kept;
    final RideRatingRepository r = ref.read(rideRatingRepositoryProvider);
    _repoKept = r;
    return r;
  }

  @override
  void dispose() {
    _commentSave?.cancel();
    final tagsWaiting = _tagSave?.isActive ?? false;
    _tagSave?.cancel();
    // A comment still being typed, or tags just picked, as the screen goes:
    // sent all the same.
    if (_repoKept != null && _stars != null && (_comment.text.trim() != _sentComment || tagsWaiting)) {
      unawaited(_send(quiet: true));
    }
    _comment.dispose();
    super.dispose();
  }

  void _edit(RideRating? from) => setState(() {
    _editing = true;
    _stars = from?.stars;
    _comment.text = from?.comment ?? '';
    _sentComment = _comment.text.trim();
    _tags = {...?from?.tags};
  });

  void _pick(int stars) {
    setState(() {
      _stars = stars;
      _editing = true;
      // From 4-5 stars to 1-3 (or back): the other list's tags go.
      _tags = keepDriverTags(_tags, stars, _tagLists).toSet();
    });
    _tagSave?.cancel();
    unawaited(_send());
  }

  void _toggleTag(String tag) {
    if (_stars == null) return;
    setState(() => _tags = _tags.contains(tag) ? ({..._tags}..remove(tag)) : {..._tags, tag});
    _tagSave?.cancel();
    _tagSave = Timer(rideRatingTagsSaveAfter, () => unawaited(_send()));
  }

  void _commentChanged(String _) {
    _commentSave?.cancel();
    if (_stars == null) return;
    _commentSave = Timer(rideRatingCommentSaveAfter, () => unawaited(_send()));
  }

  /// Saves the stars and comment as they are now. [quiet]: no word on
  /// screen, the card is going.
  Future<void> _send({bool quiet = false}) async {
    final stars = _stars;
    if (!validStars(stars)) return;
    final comment = _comment.text;
    final tags = _keptTags;
    if (!quiet && mounted) setState(() => _busy = true);
    try {
      final res = await _repo.rate(widget.ride.id, stars!, comment: comment, tags: tags);
      _sentComment = comment.trim();
      if (quiet || !mounted) return;
      switch (res) {
        case RatingSaved(:final rating):
          setState(() {
            _saved = rating;
            _savedHere = true;
          });
          ref.invalidate(myRideRatingProvider((requestId: widget.ride.id, riderId: widget.ride.riderId ?? '')));
        case RatingUnavailable():
          unawaited(showAppNotice(id: 'notice.ride-rating', context: context, message: 'Ratings aren\'t available yet.'));
      }
    } catch (e) {
      if (!quiet && mounted) {
        unawaited(showAppNotice(id: 'notice.ride-rating', context: context, message: rideRatingError(e), kind: NoticeKind.error));
      }
    } finally {
      if (!quiet && mounted) setState(() => _busy = false);
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

    if (saved != null && !_editing && !_savedHere) {
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
          subtitle: saved.comment == null && saved.tags.isEmpty
              ? null
              : Text(
                  [if (saved.tags.isNotEmpty) saved.tags.join(' · '), ?saved.comment].join('\n'),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
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
    final lists = _tagLists = ref.watch(driverRatingTagsProvider).value ?? DriverRatingTags.fallback;
    final shown = lists.forStars(stars);
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
            // All five stars always fit: on a narrow card (320 wide) the row
            // scales down instead of cutting off the fifth.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 1; i <= 5; i++)
                    IconButton(
                      key: ValueKey('rate-star-$i'),
                      tooltip: '$i star${i == 1 ? '' : 's'}',
                      iconSize: 36,
                      // Saved as it is tapped: leaving the screen keeps it.
                      onPressed: () => _pick(i),
                      icon: Icon(
                        stars != null && i <= stars ? Icons.star_rounded : Icons.star_outline_rounded,
                        color: stars != null && i <= stars ? _starColor(t) : t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Center(child: Text(starsLabel(stars ?? 0), style: t.textTheme.labelLarge)),
            const SizedBox(height: 4),
            Center(
              child: _savedHere
                  ? RatingSavedChip(key: const ValueKey('ride-rating-saved-chip'), busy: _busy)
                  : Text('Tap a star. It saves straight away.', style: t.textTheme.bodySmall),
            ),
            if (stars == null && saved == null && widget.onSkip != null)
              Center(
                child: TextButton(
                  key: const ValueKey('ride-rating-skip'),
                  style: TextButton.styleFrom(minimumSize: const Size(120, 48)),
                  onPressed: widget.onSkip,
                  child: const Text('Skip'),
                ),
              ),
            if (stars != null && shown.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(driverTagQuestion(stars), style: t.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                key: const ValueKey('ride-rating-tags'),
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final tag in shown)
                    FilterChip(
                      key: ValueKey('ride-rating-tag-$tag'),
                      label: Text(tag),
                      selected: _tags.contains(tag),
                      onSelected: (_) => _toggleTag(tag),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Tags save a moment after you tap them. Your driver sees totals only, never who.',
                style: t.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('ride-rating-comment'),
              controller: _comment,
              enabled: stars != null,
              maxLength: rideRatingCommentMax,
              maxLines: 3,
              minLines: 1,
              onChanged: _commentChanged,
              onEditingComplete: () {
                _commentSave?.cancel();
                unawaited(_send());
              },
              decoration: const InputDecoration(
                labelText: 'Comment (optional)',
                hintText: 'Anything your driver should know?',
                helperText: 'Saved as you write.',
                border: OutlineInputBorder(),
              ),
            ),
            if (_editing && saved != null && !_savedHere)
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

/// How long after the last keystroke a rating's comment is saved.
const rideRatingCommentSaveAfter = Duration(milliseconds: 1200);

/// How long after the last tap a rating's tags are saved.
const rideRatingTagsSaveAfter = Duration(milliseconds: 600);

/// "Rating saved" with a tick, under the stars: the rider's rating card and
/// the driver's rating of the rider say it alike.
class RatingSavedChip extends StatelessWidget {
  const RatingSavedChip({super.key, this.busy = false});
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Chip(
      avatar: busy
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(Icons.check, size: 18, color: t.colorScheme.onSecondaryContainer),
      label: Text(busy ? 'Saving…' : 'Rating saved'),
      labelStyle: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSecondaryContainer),
      backgroundColor: t.colorScheme.secondaryContainer,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
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
