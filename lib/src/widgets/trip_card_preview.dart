// The trip card as the lock screen shows it (core/trip_card.dart), drawn in
// the app for Admin → Display Settings → Trip card's preview. Its colours
// are App Page Settings' "Trip card · Preview" ([tripCardSurface]), the same
// ones the phone's own card takes.
import 'package:flutter/material.dart';

import '../core/page_styles.dart';
import '../core/trip_card.dart';
import 'page_style_host.dart';

/// [tripCardSurface]'s colours for [b], under [context]'s App Page Settings.
TripCardColors tripCardColorsIn(BuildContext context, Brightness b) {
  final s = SurfaceStyle.of(context, tripCardSurface);
  const d = TripCardColors();
  int c(String key, int fallback) => s.color(key, b)?.toARGB32() ?? fallback;
  return TripCardColors(
    background: c('cardBackground', d.background),
    accent: c('cardAccent', d.accent),
    text: c('cardText', d.text),
    muted: c('cardMuted', d.muted),
  );
}

/// One card, as on the lock screen.
class TripCardView extends StatelessWidget {
  const TripCardView({super.key, required this.card, required this.colors});

  final TripCard card;
  final TripCardColors colors;

  @override
  Widget build(BuildContext context) {
    final bg = Color(colors.background), accent = Color(colors.accent);
    final ink = Color(colors.text), muted = Color(colors.muted);
    final t = Theme.of(context).textTheme;
    final head = card.headline;
    final em = card.emphasis;
    final at = em == null ? -1 : head.indexOf(em);
    return Semantics(
      container: true,
      label: 'Trip card: ${card.headline}',
      child: Container(
        key: ValueKey('trip-card-${card.stage.name}'),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(24)),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'GET.ride',
                    style: t.titleSmall?.copyWith(color: ink, fontWeight: FontWeight.w800),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(card.chip, style: t.labelSmall?.copyWith(color: ink, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(
                children: at < 0
                    ? [TextSpan(text: head)]
                    : [
                        TextSpan(text: head.substring(0, at)),
                        TextSpan(text: em, style: TextStyle(color: accent)),
                        TextSpan(text: head.substring(at + em!.length)),
                      ],
              ),
              style: t.titleLarge?.copyWith(color: ink, fontWeight: FontWeight.w800),
            ),
            if (card.subline.isNotEmpty || card.plate != null) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (card.subline.isNotEmpty) Text(card.subline, style: t.bodySmall?.copyWith(color: muted)),
                  if (card.plate != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(5)),
                      child: Text(
                        card.plate!,
                        style: t.labelSmall?.copyWith(color: Colors.black, fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            _Track(progress: card.progress, accent: accent, rail: muted.withValues(alpha: 0.35), car: ink),
            if (card.footTitle != null) ...[
              const SizedBox(height: 10),
              Text(card.footTitle!, style: t.bodyMedium?.copyWith(color: ink, fontWeight: FontWeight.w700)),
              if (card.footText != null) Text(card.footText!, style: t.bodySmall?.copyWith(color: muted)),
            ],
            if (card.actions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final a in card.actions)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          decoration: BoxDecoration(
                            color: ink.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            a.label,
                            textAlign: TextAlign.center,
                            style: t.labelMedium?.copyWith(color: ink, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The bar, with the car at [progress] and the drop pin at its end.
class _Track extends StatelessWidget {
  const _Track({required this.progress, required this.accent, required this.rail, required this.car});

  final double progress;
  final Color accent, rail, car;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 22,
    child: LayoutBuilder(
      builder: (_, box) {
        final width = (box.maxWidth - 22).clamp(0.0, double.infinity);
        final x = width * progress.clamp(0.0, 1.0);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 22,
              top: 9,
              height: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(color: rail, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Positioned(
              left: 0,
              width: x,
              top: 9,
              height: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Positioned(
              left: (x - 12).clamp(0.0, width),
              top: 0,
              child: Icon(Icons.directions_car_filled, size: 22, color: car),
            ),
            Positioned(right: 0, top: 1, child: Icon(Icons.location_on, size: 20, color: accent)),
          ],
        );
      },
    ),
  );
}

/// Sample cards for the preview: a ride with its driver on the way, and on
/// the trip.
List<TripCard> tripCardSamples() => const [
  TripCard(
    rideId: 'preview',
    stage: TripCardStage.toPickup,
    service: TripCardService.ride,
    isDriver: false,
    chip: '6 min',
    compact: '6 min',
    headline: 'Ali is 6 min away',
    emphasis: '6 min',
    subline: 'Perodua Bezza · Silver',
    driverName: 'Ali',
    car: 'Perodua Bezza · Silver',
    plate: 'WXY 4821',
    progress: 0.25,
    actions: [TripCardAction.call, TripCardAction.chat, TripCardAction.share],
  ),
  TripCard(
    rideId: 'preview',
    stage: TripCardStage.onTrip,
    service: TripCardService.ride,
    isDriver: false,
    chip: 'On trip',
    compact: '4:05',
    headline: 'You will arrive at 4:05 PM',
    emphasis: '4:05 PM',
    subline: '17 min · 9.4 km left',
    footTitle: 'Share your trip',
    footText: 'Family can follow you live',
    progress: 0.6,
    actions: [TripCardAction.share, TripCardAction.sos],
  ),
];

/// The preview sheet: the sample cards in this phone's mode's colours.
class TripCardPreviewSheet extends StatelessWidget {
  const TripCardPreviewSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final colors = tripCardColorsIn(context, t.brightness);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Trip card preview', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'How the card looks on the lock screen. Its colours are under App Page Settings, '
              '"Trip card · Preview". Android draws its own notification and takes the accent colour.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            for (final c in tripCardSamples()) ...[
              const SizedBox(height: 12),
              TripCardView(card: c, colors: colors),
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens [TripCardPreviewSheet].
Future<void> showTripCardPreview(BuildContext context) => showAppSheet<void>(
  id: 'trip-card.preview',
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const TripCardPreviewSheet(),
);
