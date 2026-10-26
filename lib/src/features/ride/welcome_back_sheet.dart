import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/ride_draft.dart';
import '../../core/saved_drafts.dart';
import '../../widgets/page_style_host.dart';

/// "Welcome back": the booking the rider left on the confirm step, offered
/// again as the app opens (ride_draft.dart). True: Continue booking; false:
/// Start over; null: closed without either (the booking stays saved until
/// it runs out).
Future<bool?> showWelcomeBackSheet(BuildContext context, RideDraft draft, {DateTime? now}) =>
    _show(context, WelcomeBackOffer.ride(draft, now ?? DateTime.now()));

/// The same for a Freight move, a Courier parcel or a vehicle being added
/// (saved_drafts.dart).
Future<bool?> showWelcomeBackSaved(BuildContext context, SavedDraft draft, {DateTime? now}) =>
    _show(context, WelcomeBackOffer.saved(draft, now ?? DateTime.now()));

Future<bool?> _show(BuildContext context, WelcomeBackOffer offer) => showAppSheet<bool>(
  id: 'home.welcome-back',
  context: context,
  fitContent: true,
  builder: (_) => WelcomeBackSheet(offer: offer),
);

/// What the sheet shows.
class WelcomeBackOffer {
  const WelcomeBackOffer({
    required this.line,
    required this.go,
    required this.other,
    this.pickup,
    this.drop,
    this.stops = 0,
    this.detail,
    this.icon = Icons.directions_car_outlined,
    this.amount,
    this.note,
  });

  factory WelcomeBackOffer.ride(RideDraft d, DateTime now) {
    final t = d.trip;
    final fare = t.fare;
    final detail = [?t.service, if (t.forName != null) 'for ${t.forName}'].join(' · ');
    return WelcomeBackOffer(
      line: rideDraftLine(d, now),
      go: 'Continue booking',
      other: 'Start over',
      pickup: t.pickup.name,
      drop: t.drop.name,
      stops: t.stops.length,
      detail: detail.isEmpty && fare == null ? null : detail,
      icon: t.forName != null ? Icons.person_outline : Icons.directions_car_outlined,
      amount: fare == null ? null : formatMoney(fare, d.currency ?? 'MYR'),
      note: 'The fare is checked again when you continue.',
    );
  }

  factory WelcomeBackOffer.saved(SavedDraft d, DateTime now) {
    final s = draftSummary(d, now);
    final m = d.data;
    final vehicle = d.kind == SavedDraftKind.vehicle;
    final offer = draftNumber(m['offer']);
    return WelcomeBackOffer(
      line: s.line,
      go: s.go,
      other: s.other,
      pickup: vehicle ? null : draftAddressFromJson(m['pickup'])?.place.name,
      drop: vehicle ? null : draftAddressFromJson(m['drop'])?.place.name,
      detail: s.detail.isEmpty ? null : s.detail,
      icon: switch (d.kind) {
        SavedDraftKind.freight => Icons.local_shipping_outlined,
        SavedDraftKind.courier => Icons.inventory_2_outlined,
        SavedDraftKind.vehicle => Icons.directions_car_outlined,
      },
      amount: offer == null ? null : formatMoney(offer, draftText(m['currency']) ?? 'MYR'),
      note: vehicle ? 'It stays in My vehicles either way.' : 'Prices are checked again when you continue.',
    );
  }

  final String line, go, other;
  final String? pickup, drop, detail, amount, note;
  final int stops;
  final IconData icon;
}

class WelcomeBackSheet extends StatelessWidget {
  const WelcomeBackSheet({super.key, required this.offer});

  final WelcomeBackOffer offer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final o = offer;
    final muted = t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant);
    Widget end(String label, String name, Widget mark) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 4), child: mark),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: muted),
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge),
            ],
          ),
        ),
      ],
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          key: const ValueKey('welcome-back-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: c.primaryContainer,
                  foregroundColor: c.onPrimaryContainer,
                  child: const Icon(Icons.history),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(header: true, child: Text('Welcome back', style: t.textTheme.titleLarge)),
                      Text(o.line, style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: c.outlineVariant),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (o.pickup case final p?) ...[
                      end('Pickup', p, Icon(Icons.circle, size: 12, color: c.primary)),
                      const SizedBox(height: 12),
                    ],
                    if (o.stops > 0) ...[
                      Text(o.stops == 1 ? '1 stop on the way' : '${o.stops} stops on the way', style: muted),
                      const SizedBox(height: 12),
                    ],
                    if (o.drop case final d?) end('Destination', d, Icon(Icons.square, size: 12, color: c.onSurface)),
                    if (o.detail != null || o.amount != null) ...[
                      if (o.pickup != null || o.drop != null) const Divider(height: 24),
                      Row(
                        children: [
                          Icon(o.icon, color: c.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(child: Text(o.detail ?? '', style: t.textTheme.bodyMedium)),
                          if (o.amount case final a?)
                            Text(a, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ],
                    if (o.note case final n?) ...[
                      const SizedBox(height: 10),
                      Text(n, style: muted),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('welcome-back-continue'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(o.go),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const ValueKey('welcome-back-start-over'),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(o.other),
            ),
          ],
        ),
      ),
    );
  }
}
