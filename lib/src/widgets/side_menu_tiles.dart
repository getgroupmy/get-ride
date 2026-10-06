import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/side_menu.dart';

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
  'city': Icons.local_taxi_outlined,
  'request-history': Icons.history,
  'freight': Icons.local_shipping_outlined,
  'wallet': Icons.account_balance_wallet_outlined,
  'notifications': Icons.notifications_outlined,
  'safety': Icons.health_and_safety_outlined,
  'settings': Icons.settings_outlined,
  'user-guide': Icons.menu_book_outlined,
  'support': Icons.support_agent,
  'logout': Icons.logout,
  'sign-out': Icons.logout,
  'dashboard': Icons.dashboard_outlined,
  'earnings': Icons.payments_outlined,
  'trip-history': Icons.history,
  'vehicle': Icons.directions_car_outlined,
  'vehicle-information': Icons.speed,
  'documents': Icons.description_outlined,
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

Future<void> showComingSoon(BuildContext context) => showDialog<void>(
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
  const SideMenuTile({super.key, required this.entry, required this.builtIn, this.color, this.beforeOpen});

  final MenuEntry entry;
  final bool Function(BuildContext context, String id) builtIn;
  final Color? color;

  /// Runs before navigating, e.g. to close the sheet the menu is in.
  final VoidCallback? beforeOpen;

  void _tap(BuildContext context) {
    if (entry.comingSoon) {
      showComingSoon(context);
      return;
    }
    final route = entry.route;
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

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('menu-${entry.id}'),
    leading: Icon(menuIcon(entry), color: color),
    title: Text(entry.label, style: color == null ? null : TextStyle(color: color)),
    trailing: entry.comingSoon ? const Chip(label: Text('Soon')) : const Icon(Icons.chevron_right),
    onTap: () => _tap(context),
  );
}
