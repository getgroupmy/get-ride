import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/ride_draft.dart';
import '../../widgets/page_style_host.dart';

/// "Welcome back": the booking the rider left on the confirm step, offered
/// again as the app opens (ride_draft.dart). True: Continue booking; false:
/// Start over; null: closed without either (the booking stays saved until
/// it runs out).
Future<bool?> showWelcomeBackSheet(BuildContext context, RideDraft draft, {DateTime? now}) =>
    showAppSheet<bool>(
      id: 'home.welcome-back',
      context: context,
      fitContent: true,
      builder: (_) => WelcomeBackSheet(draft: draft, now: now ?? DateTime.now()),
    );

class WelcomeBackSheet extends StatelessWidget {
  const WelcomeBackSheet({super.key, required this.draft, required this.now});

  final RideDraft draft;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final trip = draft.trip;
    final muted = t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant);
    final fare = trip.fare;
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
                      Text(rideDraftLine(draft, now), style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
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
                    end('Pickup', trip.pickup.name, Icon(Icons.circle, size: 12, color: c.primary)),
                    const SizedBox(height: 12),
                    if (trip.stops.isNotEmpty) ...[
                      Text(
                        trip.stops.length == 1 ? '1 stop on the way' : '${trip.stops.length} stops on the way',
                        style: muted,
                      ),
                      const SizedBox(height: 12),
                    ],
                    end('Destination', trip.drop.name, Icon(Icons.square, size: 12, color: c.onSurface)),
                    if (trip.service != null || fare != null || trip.forName != null) ...[
                      const Divider(height: 24),
                      Row(
                        children: [
                          Icon(trip.forName != null ? Icons.person_outline : Icons.directions_car_outlined, color: c.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              [?trip.service, if (trip.forName != null) 'for ${trip.forName}'].join(' · '),
                              style: t.textTheme.bodyMedium,
                            ),
                          ),
                          if (fare != null)
                            Text(
                              formatMoney(fare, draft.currency ?? 'MYR'),
                              style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text('The fare is checked again when you continue.', style: muted),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('welcome-back-continue'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue booking'),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const ValueKey('welcome-back-start-over'),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Start over'),
            ),
          ],
        ),
      ),
    );
  }
}
