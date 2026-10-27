// Earnings → My ratings: the driver's rating and the tags riders picked
// over the last 30 days, as totals only (migration 0297). The riders and
// trips behind them are never shown, nor any flag the admin sees.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ride_rating.dart';
import '../../data/ride_rating_repository.dart';
import '../../widgets/back_or_go_button.dart';
import '../../widgets/common.dart';

/// The days the page counts back.
const driverRatingsDays = 30;

class DriverRatingsScreen extends ConsumerWidget {
  const DriverRatingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totals = ref.watch(myDriverTagTotalsProvider(driverRatingsDays));
    return Scaffold(
      appBar: AppBar(
        leading: const BackOrGoButton(fallback: '/drive/earnings'),
        title: const Text('My ratings'),
      ),
      body: AsyncView<DriverTagTotals>(
        value: totals,
        errorTitle: "Couldn't load your ratings",
        onRetry: () => ref.invalidate(myDriverTagTotalsProvider(driverRatingsDays)),
        data: (d) => _Body(d),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.d);
  final DriverTagTotals d;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final good = dark ? const Color(0xFF5FD3A5) : const Color(0xFF0B7A55);
    final low = dark ? const Color(0xFFF2A86B) : const Color(0xFF9A4A00);
    final muted = mutedTextColor(t);
    return ListView(
      key: const ValueKey('driver-ratings'),
      padding: const EdgeInsets.all(16),
      children: [
        ResponsiveCenter(
          maxWidth: 640,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Text(d.rating == null ? '–' : d.rating!.toStringAsFixed(1),
                        key: const ValueKey('driver-ratings-score'),
                        style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (d.rating != null) _Stars(d.rating!),
                        Text(
                          'From ${d.rated} rated trip${d.rated == 1 ? '' : 's'} · last ${d.days} days',
                          key: const ValueKey('driver-ratings-rated'),
                          style: t.textTheme.bodySmall?.copyWith(color: muted),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              _TagCard(
                key: const ValueKey('driver-ratings-liked'),
                title: 'What riders liked',
                rows: d.liked,
                color: good,
                empty: 'No tags yet.',
              ),
              const SizedBox(height: 14),
              _TagCard(
                key: const ValueKey('driver-ratings-work-on'),
                title: 'To work on',
                rows: d.toWorkOn,
                color: low,
                empty: 'Nothing here. Keep it up.',
              ),
              const SizedBox(height: 14),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.lock_outline, size: 16, color: muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Totals only. Riders and trips behind them are never shown.',
                      style: t.textTheme.bodySmall?.copyWith(color: muted)),
                ),
              ]),
            ],
          ),
        ),
      ],
    );
  }
}

class _Stars extends StatelessWidget {
  const _Stars(this.rating);
  final double rating;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).brightness == Brightness.dark ? const Color(0xFFF5C451) : const Color(0xFFB07800);
    return ExcludeSemantics(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            rating >= i
                ? Icons.star
                : rating >= i - 0.5
                    ? Icons.star_half
                    : Icons.star_border,
            size: 20,
            color: color,
          ),
      ]),
    );
  }
}

class _TagCard extends StatelessWidget {
  const _TagCard({super.key, required this.title, required this.rows, required this.color, required this.empty});
  final String title;
  final List<({String tag, bool low, int n})> rows;
  final Color color;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sorted = [...rows]..sort((a, b) => b.n.compareTo(a.n));
    final max = sorted.isEmpty ? 1 : sorted.first.n.clamp(1, 1 << 30);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (sorted.isEmpty)
            Text(empty, style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)))
          else
            for (final r in sorted)
              Semantics(
                label: '${r.tag}: ${r.n}',
                excludeSemantics: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    SizedBox(width: 128, child: Text(r.tag, style: t.textTheme.bodyMedium)),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: r.n / max,
                          minHeight: 8,
                          color: color,
                          backgroundColor: t.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text('${r.n}',
                          textAlign: TextAlign.right,
                          style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
              ),
        ]),
      ),
    );
  }
}
