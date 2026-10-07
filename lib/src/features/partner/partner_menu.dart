import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/display_logic.dart' show vehicleInfoMenuItemId;
import '../../core/side_menu.dart';
import '../../data/app_display_repository.dart';
import '../../data/obd/obd_session.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_tiles.dart';
import 'driver_online.dart';

/// The driver menu (Expo `PartnerSideSheet`), arranged by Admin → Display
/// Settings → Side Menus → Partner. Vehicle information shows only while an
/// OBD-II reader is actually linked.
Future<void> showPartnerMenu(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => const PartnerMenuSheet(),
);

class PartnerMenuSheet extends ConsumerWidget {
  const PartnerMenuSheet({super.key});

  /// Built-in driver items on this app's screens. Expo's Earnings, Trip
  /// history and Notifications said "coming soon"; Vehicle opens the
  /// vehicles this app does have.
  static bool _builtIn(BuildContext context, WidgetRef ref, String id) {
    const routes = {
      'teksi-ev': '/ev',
      'wallet': '/wallet',
      'vehicle': '/drive/vehicles',
      vehicleInfoMenuItemId: '/meter/vehicle',
      'documents': '/drive/onboarding',
      'support': '/account/support',
      'settings': '/account/settings',
    };
    if (id == 'dashboard') {
      Navigator.pop(context);
      return true;
    }
    if (id == 'sign-out') {
      showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Sign out?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
          ],
        ),
      ).then((ok) {
        if (ok == true) ref.read(authRepositoryProvider).signOut();
      });
      return true;
    }
    final r = routes[id];
    if (r == null) return false;
    final router = GoRouter.of(context);
    Navigator.pop(context);
    openRoute(router, r);
    return true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
    final linked = ref.watch(obdSessionProvider).linked;
    final menu = [
      for (final e in resolveSideMenu(blob, 'partner'))
        if (e.id != vehicleInfoMenuItemId || linked) e,
    ];
    final mode = sideMenuModeButton(blob, 'partner');
    final nav = GoRouter.of(context);
    return SafeArea(
      child: ListView(
        key: const ValueKey('partner-menu'),
        shrinkWrap: true,
        children: [
          for (final e in menu)
            SideMenuTile(
              entry: e,
              color: e.id == 'sign-out' ? Theme.of(context).colorScheme.error : null,
              beforeOpen: () => Navigator.pop(context),
              builtIn: (c, id) => _builtIn(c, ref, id),
            ),
          if (mode != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton.icon(
                key: const ValueKey('menu-passenger-mode'),
                icon: const Icon(Icons.person_outline),
                label: Text(mode.label),
                onPressed: () {
                  if (mode.comingSoon) {
                    showComingSoon(context);
                    return;
                  }
                  // With no tab bar to grey out, the lock on booking a ride
                  // while online lives here.
                  if (ref.read(driverOnlineProvider)) {
                    showInfo(context, 'Go offline to book a ride');
                    return;
                  }
                  Navigator.pop(context);
                  nav.go('/');
                },
              ),
            ),
        ],
      ),
    );
  }
}
