// Admin › Settings › App Settings › Passenger location check-ins (migration
// 0333): whether passengers may opt in to sharing their approximate
// location with GET.ride safety while the app is closed. Off by default;
// drivers are not affected.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/settings/location_checkins_card.dart' show locationCheckinsConfigProvider;
import '../../../providers.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';

const locationCheckinsWarning =
    'Turning this on means passengers who opt in are tracked when the app is closed. Google Play must be told '
    '(background location declaration) before you turn it on.';

class LocationCheckinsAdminCard extends ConsumerWidget {
  const LocationCheckinsAdminCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('location-checkins-admin'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(locationCheckinsConfigProvider),
          onRetry: () => ref.invalidate(locationCheckinsConfigProvider),
          data: (on) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Passenger location check-ins', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                'Off: passengers share their location in the background only during their own trip. On: each '
                'passenger may also turn on "Share my last location with GET.ride safety when the app is closed" '
                'in Settings (off until they do). Drivers are not affected.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              SwitchListTile(
                key: const ValueKey('location-checkins-admin-switch'),
                contentPadding: EdgeInsets.zero,
                value: on,
                title: const Text('Passenger location check-ins when the app is closed'),
                onChanged: !canEdit
                    ? null
                    : (v) async {
                        final ok = await runAdminAction(
                          context,
                          () => ref
                              .read(supabaseProvider)
                              .rpc('set_location_checkins_config', params: {'p_config': {'passengers': v}}),
                          success: v ? 'Passenger check-ins offered' : 'Passenger check-ins off',
                        );
                        if (ok) ref.invalidate(locationCheckinsConfigProvider);
                      },
              ),
              Container(
                key: const ValueKey('location-checkins-admin-warning'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.warning_amber_outlined, color: t.colorScheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(locationCheckinsWarning, style: TextStyle(color: t.colorScheme.onErrorContainer)),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
