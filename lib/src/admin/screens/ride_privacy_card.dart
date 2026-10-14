// Admin → App Settings → Open requests (migration 0195): while a request is
// open, drivers see the area, distance, fare and the rider's first name and
// rating; whether they also see the rider's photo is this switch.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

final ridePrivacyPhotoProvider = FutureProvider.autoDispose<bool>((ref) async {
  final r = await ref.watch(supabaseProvider).rpc('ride_privacy_config');
  return r is! Map || r['showRiderPhoto'] != false;
});

class RidePrivacyCard extends ConsumerWidget {
  const RidePrivacyCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('ride-privacy-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(ridePrivacyPhotoProvider),
          onRetry: () => ref.invalidate(ridePrivacyPhotoProvider),
          data: (photo) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Open requests', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                'Until a driver accepts, drivers see the area, distance, fare and the rider\'s first name and rating. '
                'Phone numbers, the trip code and who a ride was booked for stay hidden until then.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              SwitchListTile(
                key: const ValueKey('ride-privacy-photo'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Show the rider\'s photo'),
                subtitle: const Text('On an open request, before a driver accepts.'),
                value: photo,
                onChanged: canEdit
                    ? (v) async {
                        final ok = await runAdminAction(
                          context,
                          () => ref
                              .read(supabaseProvider)
                              .rpc(
                                'set_ride_privacy_config',
                                params: {
                                  'p_config': {'showRiderPhoto': v},
                                },
                              ),
                          success: 'Saved',
                        );
                        if (ok) ref.invalidate(ridePrivacyPhotoProvider);
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
