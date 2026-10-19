import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/inbox.dart';
import '../../data/notifications_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_tiles.dart' show openAppRoute;
import '../../widgets/offline_strip.dart';

/// Side menu -> Notifications: what this account was sent, newest first, for
/// the mode the app is in plus the account's own business (inboxFor). A tap
/// marks it read and opens what it is about, as tapping the push would.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key, this.now});

  /// Clock override for tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(notificationsProvider);
    final mode = ref.watch(appModeProvider);
    final items = inboxFor(value.value ?? const [], mode);
    final rows = groupInbox(items);
    final anyUnread = items.any((i) => i.unread);
    NotificationsRepository repo() => ref.read(notificationsRepositoryProvider);

    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't update. Try again.")));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (anyUnread)
            TextButton(
              key: const ValueKey('notifications-read-all'),
              // A button in the app bar: the theme's accent and button label
              // style, not the bar's title ink (it read as a label in dark).
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.primary,
                textStyle: Theme.of(context).textTheme.labelLarge,
              ),
              onPressed: () => run(
                () => repo().markRead([
                  for (final i in items)
                    if (i.unread) i.id,
                ]),
              ),
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: OfflineStrip.over(AsyncView<List<InboxItem>>(
        value: value,
        onRetry: () => ref.invalidate(notificationsProvider),
        data: (_) => items.isEmpty
            ? const EmptyState(
                icon: Icons.notifications_none,
                title: 'No notifications yet',
                message: 'Ride updates, approvals, GET.coin transfers and news from GET.ride appear here.',
              )
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(notificationsProvider),
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    final item = row.latest;
                    return ResponsiveCenter(
                      maxWidth: 760,
                      child: Dismissible(
                        key: ValueKey('notification-${item.id}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.onErrorContainer),
                        ),
                        onDismissed: (_) => unawaited(run(() => repo().delete(row.ids))),
                        child: InboxTile(
                          item: item,
                          count: row.count,
                          rowUnread: row.unread,
                          now: now ?? DateTime.now(),
                          onTap: () {
                            if (row.unread) unawaited(run(() => repo().markRead(row.unreadIds)));
                            final route = item.route;
                            if (route != null) openAppRoute(context, route);
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
      )),
    );
  }
}

/// One row: an icon for what it is about, the title (bold while unread),
/// the text, when, and an unread dot.
class InboxTile extends StatelessWidget {
  const InboxTile({super.key, required this.item, required this.now, required this.onTap, this.count = 1, this.rowUnread});

  final InboxItem item;

  /// How many identical notifications this row stands for (×3).
  final int count;

  /// Whether any of them is unread; [item]'s own state when null.
  final bool? rowUnread;
  bool get unread => rowUnread ?? item.unread;
  final DateTime now;
  final VoidCallback onTap;

  static IconData iconFor(InboxIcon icon) => switch (icon) {
    InboxIcon.ride => Icons.local_taxi_outlined,
    InboxIcon.wallet => Icons.account_balance_wallet_outlined,
    InboxIcon.approval => Icons.verified_outlined,
    InboxIcon.safety => Icons.shield_outlined,
    InboxIcon.broadcast => Icons.campaign_outlined,
    InboxIcon.other => Icons.notifications_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return ListTile(
      key: ValueKey('notification-tile-${item.id}'),
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: unread ? cs.primaryContainer : cs.surfaceContainerHighest,
        foregroundColor: unread ? cs.onPrimaryContainer : cs.onSurfaceVariant,
        child: Icon(iconFor(inboxIconFor(item.kind))),
      ),
      title: Text.rich(
        TextSpan(children: [
          TextSpan(text: item.title),
          if (count > 1)
            TextSpan(
              text: '  ×$count',
              semanticsLabel: ', $count times',
              style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
            ),
        ]),
        key: ValueKey('notification-title-${item.id}'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontWeight: unread ? FontWeight.w700 : FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(inboxBodyText(item.body), maxLines: 3, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(inboxWhen(item.createdAt, now), style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
      trailing: unread
          ? Container(
              key: ValueKey('notification-unread-${item.id}'),
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
            )
          : null,
      isThreeLine: true,
    );
  }
}
