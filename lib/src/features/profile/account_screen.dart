import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/admin_providers.dart';
import '../../core/contact_phone.dart' show formatPhoneDisplay;
import '../../core/referral.dart';
import '../../admin/screens/meterapp/display_logic.dart' show inviteFriendsMenuItemId, scheduledRidesMenuItemId;
import '../../core/side_menu.dart';
import '../partner/partner_mode_picker.dart' show openPartnerMode;
import '../../data/app_display_repository.dart';
import '../../data/scheduled_ride_repository.dart' show scheduledRidesConfigProvider;
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_tiles.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/net_image.dart';
import '../../widgets/page_style_host.dart';

/// The built-in rider menu items (Expo `MenuSideSheet`), on this app's
/// screens; false for one with no screen here ("coming soon"). Expo's City
/// and Freight only went home: here they say "coming soon" (a rider sent to
/// "/" on a desktop could land on the Drive page). [beforeOpen] runs first.
bool riderMenuAction(BuildContext context, WidgetRef ref, String id, {VoidCallback? beforeOpen}) {
  const routes = {
    'teksi-ev': '/ev',
    'request-history': '/trips',
    'scheduled-rides': '/trips/scheduled',
    'my-ride': '/account/my-ride',
    'my-qr': '/account/my-qr',
    'wallet': '/wallet',
    'notifications': '/account/notifications',
    'safety': '/account/safety',
    'settings': '/account/settings',
    'user-guide': '/account/guide',
    'support': '/account/support',
    'help-assistant': '/account/help',
    'emergency-contacts': '/account/emergency',
    'invite-friends': '/account/referral',
  };
  if (id == 'logout') {
    // Asked first, while the menu is still open: a stray tap must not sign out.
    confirmSignOut(context).then((ok) {
      if (!ok) return;
      beforeOpen?.call();
      ref.read(authRepositoryProvider).signOut();
    });
    return true;
  }
  final r = routes[id];
  if (r == null) return false;
  final router = GoRouter.of(context);
  beforeOpen?.call();
  openRoute(router, r);
  return true;
}

/// Whether a rider menu row shows now: Scheduled Request only while
/// scheduled rides are on.
bool riderMenuRowShows(String id, {bool scheduledRides = false}) => id != scheduledRidesMenuItemId || scheduledRides;

/// Asks before signing out; true when the rider confirmed.
Future<bool> confirmSignOut(BuildContext context) async {
  final ok = await showAppDialog<bool>(id: 'account.confirm-sign-out',
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text('You will need your phone number and PIN to sign in again.'),
      actions: [
        TextButton(
          key: const ValueKey('sign-out-cancel'),
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('sign-out-confirm'),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// The rider's account: the same profile card and menu the side menu
/// shows ([RiderMenu]).
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Account')),
    body: ListView(children: const [ResponsiveCenter(maxWidth: 760, child: RiderMenu())]),
  );
}

/// The rider menu: profile, invite, the admin's items and this app's own.
/// [beforeOpen] runs before any of them navigates (closing the side menu).
class RiderMenu extends ConsumerWidget {
  const RiderMenu({super.key, this.beforeOpen});

  final VoidCallback? beforeOpen;

  bool _builtIn(BuildContext context, WidgetRef ref, String id) =>
      riderMenuAction(context, ref, id, beforeOpen: beforeOpen);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final profile = ref.watch(profileProvider);
    final isAdmin = ref.watch(adminAccessProvider).value?.isAdmin ?? false;
    final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
    final scheduled = ref.watch(scheduledRidesConfigProvider).value?.enabled ?? false;
    final menu = [
      for (final e in resolveSideMenu(blob, 'user'))
        if (riderMenuRowShows(e.id, scheduledRides: scheduled)) e,
    ];
    final mode = sideMenuModeButton(blob, 'user');
    void go(String route) {
      final router = GoRouter.of(context);
      beforeOpen?.call();
      router.go(route);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AsyncView(
        value: profile,
        onRetry: () => ref.invalidate(profileProvider),
        data: (p) => Card(
          child: ListTile(
            key: const ValueKey('menu-profile'),
            contentPadding: const EdgeInsets.all(16),
            leading: NetAvatar(url: p?.avatarUrl, radius: 28, fallback: const Icon(Icons.person, size: 28)),
            title: Text(p?.name ?? 'Add your name', style: t.textTheme.titleLarge),
            // Phone and ID side by side, each whole on its own line when
            // large text has no room for both.
            subtitle: Wrap(
              spacing: 12,
              children: [
                for (final s in [p?.phone == null ? null : formatPhoneDisplay(p!.phone), p?.displayId].whereType<String>())
                  Text(s),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => go('/account/profile'),
          ),
        ),
      ),
      if (profile.value != null && menu.any((e) => e.id == inviteFriendsMenuItemId))
        Card(
          child: ListTile(
            key: const ValueKey('account-referral'),
            leading: const Icon(Icons.card_giftcard),
            title: const Text('Invite friends'),
            subtitle: Text(
              'Your code ${referralCodeFor(userId: profile.value!.id, explicitCode: profile.value!.referralCode)}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => go('/account/referral'),
          ),
        ),
      Card(
        child: Column(children: [
          for (final e in menu)
            // Invite friends is the card above, with the rider's code.
            if (e.id != 'logout' && e.id != inviteFriendsMenuItemId)
              SideMenuTile(entry: e, beforeOpen: beforeOpen, builtIn: (context, id) => _builtIn(context, ref, id)),
          if (mode != null)
            ListTile(
              key: const ValueKey('menu-partner-mode'),
              leading: const Icon(Icons.local_taxi_outlined),
              title: Text(mode.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => mode.comingSoon ? showComingSoon(context) : openPartnerMode(context, ref, beforeOpen: beforeOpen),
            ),
          if (isAdmin)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Admin panel'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => go('/admin'),
            ),
        ]),
      ),
      for (final e in menu)
        if (e.id == 'logout')
          Card(
            child: SideMenuTile(
              entry: e,
              color: t.colorScheme.error,
              beforeOpen: beforeOpen,
              builtIn: (context, id) => _builtIn(context, ref, id),
            ),
          ),
      // Also in Settings; here too so it's never hard to find (App Review 5.1.1(v)).
      Card(
        child: ListTile(
          key: const ValueKey('account-delete'),
          leading: Icon(Icons.person_remove_outlined, color: t.colorScheme.error),
          title: Text('Delete account', style: TextStyle(color: t.colorScheme.error)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => go('/account/settings/delete'),
        ),
      ),
    ]);
  }
}
