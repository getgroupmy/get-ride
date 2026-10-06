import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/admin_providers.dart';
import '../../core/referral.dart';
import '../../core/side_menu.dart';
import '../../data/app_display_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_tiles.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  /// The built-in rider menu items (Expo `MenuSideSheet`), on this app's
  /// screens. Expo's City, Freight and Notifications only went home.
  static bool _builtIn(BuildContext context, WidgetRef ref, String id) {
    const routes = {
      'teksi-ev': '/ev',
      'city': '/',
      'request-history': '/trips',
      'freight': '/',
      'wallet': '/wallet',
      'notifications': '/',
      'safety': '/account/safety',
      'settings': '/account/settings',
      'user-guide': '/account/guide',
      'support': '/account/support',
    };
    if (id == 'logout') {
      ref.read(authRepositoryProvider).signOut();
      return true;
    }
    final r = routes[id];
    if (r == null) return false;
    openAppRoute(context, r);
    return true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final profile = ref.watch(profileProvider);
    final isAdmin = ref.watch(adminAccessProvider).value?.isAdmin ?? false;
    final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
    final menu = resolveSideMenu(blob, 'user');
    final mode = sideMenuModeButton(blob, 'user');
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(children: [
        ResponsiveCenter(
          maxWidth: 760,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AsyncView(
              value: profile,
              onRetry: () => ref.invalidate(profileProvider),
              data: (p) => Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: CircleAvatar(
                    radius: 28,
                    backgroundImage: p?.avatarUrl != null ? NetworkImage(p!.avatarUrl!) : null,
                    child: p?.avatarUrl == null ? const Icon(Icons.person, size: 28) : null,
                  ),
                  title: Text(p?.name ?? 'Add your name', style: t.textTheme.titleLarge),
                  subtitle: Text([p?.phone, p?.displayId].whereType<String>().join(' · ')),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => context.go('/account/edit'),
                ),
              ),
            ),
            if (profile.value != null)
              Card(
                child: ListTile(
                  key: const ValueKey('account-referral'),
                  leading: const Icon(Icons.card_giftcard),
                  title: const Text('Invite friends'),
                  subtitle: Text(
                    'Your code ${referralCodeFor(userId: profile.value!.id, explicitCode: profile.value!.referralCode)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/account/referral'),
                ),
              ),
            Card(
              child: Column(children: [
                for (final e in menu)
                  if (e.id != 'logout')
                    SideMenuTile(entry: e, builtIn: (context, id) => _builtIn(context, ref, id)),
                // Flutter's own rows, which the Expo menu does not list.
                ListTile(
                  leading: const Icon(Icons.contact_emergency_outlined),
                  title: const Text('Emergency contacts'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/account/emergency'),
                ),
                if (mode != null)
                  ListTile(
                    key: const ValueKey('menu-partner-mode'),
                    leading: const Icon(Icons.local_taxi_outlined),
                    title: Text(mode.label),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => mode.comingSoon ? showComingSoon(context) : context.go('/drive'),
                  ),
                if (isAdmin)
                  ListTile(
                    leading: const Icon(Icons.admin_panel_settings_outlined),
                    title: const Text('Admin panel'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.go('/admin'),
                  ),
              ]),
            ),
            for (final e in menu)
              if (e.id == 'logout')
                Card(
                  child: SideMenuTile(
                    entry: e,
                    color: t.colorScheme.error,
                    builtIn: (context, id) => _builtIn(context, ref, id),
                  ),
                ),
          ]),
        ),
      ]),
    );
  }
}
