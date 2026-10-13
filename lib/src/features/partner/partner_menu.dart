import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/display_logic.dart'
    show myQrMenuItemId, myRideCodeMenuItemId, vehicleInfoMenuItemId;
import '../../core/side_menu.dart';
import '../../data/app_display_repository.dart';
import '../../data/my_ride_repository.dart' show myRideCodeProvider;
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

/// Whether a driver menu row shows now: Vehicle information only while an
/// OBD-II reader is linked, My Ride code only where the driver has a code
/// (none on a database without My Ride, or while it loads).
bool partnerMenuRowShows(String id, {required bool obdLinked, required bool hasMyRideCode}) => switch (id) {
  vehicleInfoMenuItemId => obdLinked,
  myRideCodeMenuItemId => hasMyRideCode,
  _ => true,
};

/// Built-in driver items on this app's screens; false for one with no
/// screen here ("coming soon"). Expo's Earnings, Trip history, Vehicle and
/// Notifications said "coming soon"; here each opens a page of its own.
/// [close] shuts the menu the row is in first.
bool partnerMenuAction(BuildContext context, WidgetRef ref, String id, {required VoidCallback close}) {
  const routes = {
    'teksi-ev': '/ev',
    'wallet': '/wallet',
    'earnings': '/drive/earnings',
    myQrMenuItemId: '/account/my-qr',
    'vehicle': '/drive/vehicles',
    // The trips page lists the driver's trips beside their rides.
    'trip-history': '/trips',
    vehicleInfoMenuItemId: '/meter/vehicle',
    myRideCodeMenuItemId: '/drive/my-ride',
    'documents': '/drive/onboarding',
    'notifications': '/account/notifications',
    'support': '/account/support',
    'help-assistant': '/account/help',
    'settings': '/account/settings',
  };
  if (id == 'dashboard') {
    final router = GoRouter.of(context);
    close();
    router.go('/drive');
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
  close();
  openRoute(router, r);
  return true;
}

/// The driver menu as a bottom sheet, where there is no side menu (wide
/// screens).
class PartnerMenuSheet extends ConsumerWidget {
  const PartnerMenuSheet({super.key});

  static bool _builtIn(BuildContext context, WidgetRef ref, String id) =>
      partnerMenuAction(context, ref, id, close: () => Navigator.pop(context));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
    final linked = ref.watch(obdSessionProvider).linked;
    final hasCode = ref.watch(myRideCodeProvider).value != null;
    final menu = [
      for (final e in resolveSideMenu(blob, 'partner'))
        if (partnerMenuRowShows(e.id, obdLinked: linked, hasMyRideCode: hasCode)) e,
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
                    showGoOfflineToBook(context);
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
