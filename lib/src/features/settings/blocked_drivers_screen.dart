// Settings › Blocked drivers (migration 0311): the drivers the rider blocked,
// each with Unblock. A blocked driver doesn't see the rider's requests and
// isn't told.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ride_safety.dart';
import '../../data/ride_safety_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/net_image.dart';
import '../../widgets/search_select.dart';

/// The way in from Settings.
class BlockedDriversTile extends StatelessWidget {
  const BlockedDriversTile({super.key});

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          key: const ValueKey('blocked-drivers'),
          leading: const Icon(Icons.block),
          title: const Text('Blocked drivers'),
          subtitle: const Text('They don\'t see your requests'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push(blockedDriversPath),
        ),
      );
}

class BlockedDriversScreen extends ConsumerWidget {
  const BlockedDriversScreen({super.key});

  Future<void> _unblock(BuildContext context, WidgetRef ref, BlockedDriver d) async {
    try {
      await ref.read(rideSafetyRepositoryProvider).unblock(d.driverId);
      ref.invalidate(blockedDriversProvider);
      if (context.mounted) showInfo(context, '${d.name} is unblocked.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final settings = ref.watch(rideSafetySettingsProvider).value ?? const RideSafetySettings();
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked drivers')),
      body: AsyncView(
        value: ref.watch(blockedDriversProvider),
        onRetry: () => ref.invalidate(blockedDriversProvider),
        data: (list) => ListView(padding: const EdgeInsets.all(16), children: [
          ResponsiveCenter(
            maxWidth: 560,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                'A driver you block won\'t see your requests and can\'t send you offers. They aren\'t told. '
                'You can block up to ${settings.maxBlocksPerRider} drivers, from a trip\'s receipt.',
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (list.isEmpty)
                const EmptyState(
                  key: ValueKey('blocked-drivers-empty'),
                  icon: Icons.block,
                  title: 'No blocked drivers',
                  message: 'Block a driver from the receipt of a trip with them.',
                )
              else
                ListSearchFilter(
                  count: list.length,
                  hint: 'Search blocked drivers',
                  fieldKey: const ValueKey('blocked-drivers-search'),
                  builder: (context, q) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final d in list)
                      if (q.isEmpty || '${d.name} ${d.vehicle ?? ''}'.toLowerCase().contains(q.toLowerCase()))
                        Card(
                          key: ValueKey('blocked-${d.driverId}'),
                          child: ListTile(
                            leading: d.photo == null
                                ? const CircleAvatar(child: Icon(Icons.person))
                                : NetImage(d.photo!, width: 40, height: 40, circle: true),
                            title: Text(d.name),
                            subtitle: d.subtitle().isEmpty ? null : Text(d.subtitle()),
                            trailing: BusyButton.text(
                              key: ValueKey('unblock-${d.driverId}'),
                              onPressed: () => _unblock(context, ref, d),
                              child: const Text('Unblock'),
                            ),
                          ),
                        ),
                  ]),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
