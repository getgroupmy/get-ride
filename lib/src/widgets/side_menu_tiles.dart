import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/inbox.dart' show inboxBadgeText;
import '../core/side_menu.dart';
import '../data/notifications_repository.dart' show unreadNotificationsProvider;
import 'common.dart' show mutedTextColor;
import 'side_menu_style.dart';
import 'page_style_host.dart';

/// Expo icon names (the admin's custom-item picker) as Material icons.
const _expoIcons = <String, IconData>{
  'Bell': Icons.notifications_outlined,
  'BookOpen': Icons.menu_book_outlined,
  'Car': Icons.directions_car_outlined,
  'Clock': Icons.schedule,
  'FileText': Icons.description_outlined,
  'Gift': Icons.card_giftcard,
  'HelpCircle': Icons.help_outline,
  'Heart': Icons.favorite_border,
  'Mail': Icons.mail_outline,
  'MapPin': Icons.place_outlined,
  'MessageCircle': Icons.chat_bubble_outline,
  'Phone': Icons.phone_outlined,
  'Settings': Icons.settings_outlined,
  'Shield': Icons.shield_outlined,
  'Star': Icons.star_border,
  'Tag': Icons.sell_outlined,
  'User': Icons.person_outline,
  'Wallet': Icons.account_balance_wallet_outlined,
};

const _builtInIcons = <String, IconData>{
  'teksi-ev': Icons.electric_car_outlined,
  'city': Icons.directions_car_outlined,
  'request-history': Icons.schedule,
  'scheduled-rides': Icons.event_outlined,
  'my-ride': Icons.favorite_border,
  'my-qr': Icons.qr_code_2,
  'freight': Icons.local_shipping_outlined,
  'wallet': Icons.account_balance_wallet_outlined,
  'notifications': Icons.notifications_outlined,
  'safety': Icons.gpp_good_outlined,
  'settings': Icons.settings_outlined,
  'user-guide': Icons.menu_book_outlined,
  'support': Icons.forum_outlined,
  'help-assistant': Icons.live_help_outlined,
  'logout': Icons.logout,
  'sign-out': Icons.logout,
  'dashboard': Icons.dashboard_outlined,
  'my-ride-code': Icons.qr_code_2,
  'earnings': Icons.payments_outlined,
  'trip-history': Icons.schedule,
  'vehicle': Icons.directions_car_outlined,
  'vehicle-information': Icons.speed,
  'documents': Icons.description_outlined,
  'emergency-contacts': Icons.contact_emergency_outlined,
  'invite-friends': Icons.card_giftcard,
};

IconData menuIcon(MenuEntry e) => (e.custom ? _expoIcons[e.iconName] : _builtInIcons[e.id]) ?? Icons.star_border;

/// Opens a Flutter route: tab roots and their pages through the shell, the
/// rest on top.
void openAppRoute(BuildContext context, String route) => openRoute(GoRouter.of(context), route);

void openRoute(GoRouter router, String route) {
  const shell = ['/', '/trips', '/wallet', '/drive', '/account'];
  final inShell = shell.any((r) => route == r || (r != '/' && r != '/drive' && route.startsWith('$r/')));
  inShell ? router.go(route) : router.push(route);
}

/// Built-in rider rows whose service has no page yet.
const homeLinkedComingSoon = {'city', 'freight'};

Future<void> showComingSoon(BuildContext context) => showAppDialog<void>(id: 'side-menu-tiles.open-route',
  context: context,
  builder: (c) => AlertDialog(
    key: const ValueKey('menu-coming-soon'),
    title: const Text(comingSoonTitle),
    content: const Text(comingSoonBody),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
  ),
);

/// One menu row. [builtIn] runs a built-in item's own action when the admin
/// gave it no link of its own; it answers false when the item has none here,
/// which shows "coming soon".
class SideMenuTile extends StatelessWidget {
  const SideMenuTile({
    super.key,
    required this.entry,
    required this.builtIn,
    this.color,
    this.beforeOpen,
    this.plain = false,
  });

  final MenuEntry entry;
  final bool Function(BuildContext context, String id) builtIn;
  final Color? color;

  /// The side menu's look (Expo `MenuSideSheet`): a grey outline icon and
  /// the label, no chevron.
  final bool plain;

  /// Runs before navigating, e.g. to close the sheet the menu is in.
  final VoidCallback? beforeOpen;

  void _tap(BuildContext context) {
    if (entry.comingSoon) {
      showComingSoon(context);
      return;
    }
    final route = entry.route;
    // A built-in service with no page yet, linked home (Expo's City and
    // Freight): "coming soon", not a jump to home (or, on a desktop, Drive).
    if (route == '/' && !entry.custom && homeLinkedComingSoon.contains(entry.id)) {
      showComingSoon(context);
      return;
    }
    if (route != null) {
      final router = GoRouter.of(context);
      beforeOpen?.call();
      openRoute(router, route);
      return;
    }
    // A link the admin set that has no screen here, or a custom item without
    // one: nothing to open.
    if (entry.custom || entry.overridden || !builtIn(context, entry.id)) showComingSoon(context);
  }

  /// The built-in Notifications row carries its unread count.
  bool get _counts => !entry.custom && !entry.comingSoon && entry.id == notificationsMenuItemId;

  @override
  Widget build(BuildContext context) {
    if (plain) {
      return SideMenuRow(
        key: ValueKey('menu-${entry.id}'),
        icon: menuIcon(entry),
        label: entry.label,
        color: color,
        trailing: entry.comingSoon
            ? Text('Soon', style: TextStyle(fontSize: 12, color: SideMenuColors.of(context).muted))
            : _counts
            ? const UnreadNotificationsBadge()
            : null,
        onTap: () => _tap(context),
      );
    }
    return ListTile(
      key: ValueKey('menu-${entry.id}'),
      leading: Icon(menuIcon(entry), color: color),
      title: Text(entry.label, style: color == null ? null : TextStyle(color: color)),
      trailing: entry.comingSoon
          // On the chip's own fill, so "Soon" reads (4.5:1) on it.
          ? Chip(
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              label: Text(
                'Soon',
                style: TextStyle(
                  color: mutedTextColor(
                    Theme.of(context),
                    background: Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
            )
          : _counts
          ? const Row(
              mainAxisSize: MainAxisSize.min,
              children: [UnreadNotificationsBadge(), Icon(Icons.chevron_right)],
            )
          : const Icon(Icons.chevron_right),
      onTap: () => _tap(context),
    );
  }
}

/// The built-in Notifications menu item's id (rider and driver menus).
const notificationsMenuItemId = 'notifications';

/// The unread count on the Notifications row; nothing when all are read.
class UnreadNotificationsBadge extends ConsumerWidget {
  const UnreadNotificationsBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationsProvider);
    if (unread == 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('menu-notifications-badge'),
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: cs.error, borderRadius: BorderRadius.circular(11)),
      child: Text(
        inboxBadgeText(unread),
        textAlign: TextAlign.center,
        style: TextStyle(color: cs.onError, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}
