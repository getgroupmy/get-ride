import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/busy.dart';
import '../widgets/common.dart';
import '../widgets/loading_skeleton.dart';
import '../widgets/side_menu_style.dart';
import 'admin_access.dart';
import 'admin_providers.dart';
import 'admin_registry.dart';

class _NavItem {
  const _NavItem(this.module, this.icon);
  final String module;
  final IconData icon;
}

const _nav = [
  _NavItem('dashboard', Icons.space_dashboard_outlined),
  _NavItem('users', Icons.people_outline),
  _NavItem('partners', Icons.badge_outlined),
  _NavItem('vehicles', Icons.directions_car_outlined),
  _NavItem('documents', Icons.fact_check_outlined),
  _NavItem('rides', Icons.local_taxi_outlined),
  _NavItem('support', Icons.support_agent),
  _NavItem('push', Icons.campaign_outlined),
  _NavItem('commission', Icons.percent),
  _NavItem('fare-tariffs', Icons.price_change_outlined),
  _NavItem('settings', Icons.tune),
  _NavItem('sub-admins', Icons.admin_panel_settings_outlined),
];

/// Admin panel frame. Shows only the modules the signed-in user holds grants
/// for; settings is shown if any settings page is granted.
class AdminShell extends ConsumerWidget {
  const AdminShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  bool _visible(AdminAccess a, String module) {
    if (module == 'settings') {
      final ported = {for (final e in allAdminEntries) ...e.pages};
      return a.grants.any((g) => g.page == '*' || g.page.startsWith('admin-settings') || ported.contains(g.page));
    }
    return a.canRead(adminModules[module]!.pages);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accessAsync = ref.watch(adminAccessProvider);
    return accessAsync.when(
      loading: () => const Scaffold(body: LoadingSkeletonPage()),
      error: (e, _) => Scaffold(body: EmptyState(icon: Icons.error_outline, title: 'Could not load admin access', message: errorText(e))),
      data: (access) {
        if (!access.isAdmin) return const AdminGate();
        final items = _nav.where((n) => _visible(access, n.module)).toList();
        final current = items.indexWhere((n) => location.startsWith('/admin/${n.module}'));
        void go(int i) => context.go('/admin/${items[i].module}');
        final width = MediaQuery.sizeOf(context).width;

        if (width < 900) {
          return Scaffold(
            // The same side menu look as the user's and the driver's.
            drawer: Drawer(
              key: const ValueKey('admin-side-menu'),
              width: SideMenuStyle.widthFor(width),
              backgroundColor: SideMenuColors.of(context).background,
              shape: const RoundedRectangleBorder(),
              child: Builder(
                builder: (drawer) {
                  final profile = ref.watch(profileProvider).value;
                  return SideMenuFrame(
                    header: SideMenuHeader(
                      name: profile?.name ?? 'Admin',
                      avatarUrl: profile?.avatarUrl,
                      subtitle: Text(
                        'Admin panel',
                        style: TextStyle(fontSize: 14, color: SideMenuColors.of(drawer).muted),
                      ),
                    ),
                    rows: [
                      for (final (i, n) in items.indexed)
                        SideMenuRow(
                          key: ValueKey('admin-menu-${n.module}'),
                          icon: n.icon,
                          label: adminModules[n.module]!.label,
                          selected: i == current,
                          onTap: () {
                            Navigator.pop(drawer);
                            go(i);
                          },
                        ),
                    ],
                    buttonLabel: 'Exit admin',
                    buttonKey: const ValueKey('admin-exit'),
                    onButton: () => context.go('/account'),
                  );
                },
              ),
            ),
            body: Builder(
              builder: (ctx) => AdminDrawerScope(openDrawer: () => Scaffold.of(ctx).openDrawer(), child: child),
            ),
          );
        }

        return Scaffold(
          body: Row(children: [
            NavigationRail(
              extended: width >= 1200,
              selectedIndex: current < 0 ? null : current,
              onDestinationSelected: go,
              labelType: width >= 1200 ? NavigationRailLabelType.none : NavigationRailLabelType.all,
              leading: const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: _AdminTitle()),
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: IconButton(
                      tooltip: 'Exit admin',
                      icon: const Icon(Icons.exit_to_app),
                      onPressed: () => context.go('/account'),
                    ),
                  ),
                ),
              ),
              destinations: [
                for (final n in items)
                  NavigationRailDestination(icon: Icon(n.icon), label: Text(adminModules[n.module]!.label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ]),
        );
      },
    );
  }
}

class _AdminTitle extends StatelessWidget {
  const _AdminTitle();

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        const BrandMark(size: 18),
        Text('Admin', style: Theme.of(context).textTheme.labelMedium),
      ]);
}

/// Shown to signed-in users without any `admin_access` grant. Offers the
/// one-time bootstrap when the project has no admins at all.
class AdminGate extends ConsumerStatefulWidget {
  const AdminGate({super.key});

  @override
  ConsumerState<AdminGate> createState() => _AdminGateState();
}

class _AdminGateState extends ConsumerState<AdminGate> {
  bool _busy = false;

  Future<void> _bootstrap() async {
    setState(() => _busy = true);
    try {
      final ok = await ref.read(adminRepositoryProvider).bootstrap();
      if (!mounted) return;
      if (ok) {
        ref.invalidate(adminAccessProvider);
        showInfo(context, 'You are now the first administrator.');
      } else {
        showInfo(context, 'This project already has administrators. Ask one of them to grant you access.');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Admin'),
          leading: BackButton(onPressed: () => context.go('/account')),
        ),
        body: EmptyState(
          icon: Icons.lock_outline,
          title: 'No admin access',
          message: 'Your account has no admin permissions. An existing administrator can grant them '
              'under Sub-admins. On a brand-new project, the first account to claim it becomes the administrator.',
          action: BusyButton.outlined(
            onPressed: _busy ? null : _bootstrap,

            child: const Text('Claim first-admin access'),
          ),
        ),
      );
}

/// Lets admin pages on phones show a menu button that opens the shell's
/// navigation drawer.
class AdminDrawerScope extends InheritedWidget {
  const AdminDrawerScope({super.key, required this.openDrawer, required super.child});
  final VoidCallback openDrawer;

  static AdminDrawerScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AdminDrawerScope>();

  @override
  bool updateShouldNotify(AdminDrawerScope old) => false;
}
