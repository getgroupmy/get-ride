// /dispatch (migration 0251): what a stand admin, stand staff or fleet owner
// sees after signing in to the same app. Staff: the console of their stand.
// Stand admins: the console, their staff and their stand's charges. Fleet
// owners: their fleet. Admins have all of it under Admin → Dispatch.
// Telematics (0255): a fleet owner's fleet vehicles, a stand's orders (stand
// admins, and staff who may see reports).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/dispatch_repository.dart';
import '../../widgets/common.dart';
import 'dispatch_console.dart';
import 'fleet_view.dart';
import 'stand_charges_view.dart';
import 'stand_staff_view.dart';
import 'telematics_tab.dart';

/// The tabs a person's roles give them.
List<String> dispatchTabsFor(DispatchRoles r) => [
  if (r.stands.isNotEmpty) 'Console',
  if (r.standAdmin) 'My staff',
  if (r.standAdmin) 'Charges',
  if (r.fleets.isNotEmpty) 'My fleet',
  if (telematicsScopesFor(r).isNotEmpty) 'Telematics',
];

class DispatchScreen extends ConsumerWidget {
  const DispatchScreen({super.key, this.ticking = true});

  /// The board's waiting ages count up (off in tests).
  final bool ticking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dispatchRolesProvider);
    final roles = async.value ?? DispatchRoles.none;
    final tabs = dispatchTabsFor(roles);
    final back = BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/'));
    if (async.isLoading && async.value == null) {
      return Scaffold(
        appBar: AppBar(leading: back, title: const Text('Dispatch')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (tabs.isEmpty) {
      return Scaffold(
        appBar: AppBar(leading: back, title: const Text('Dispatch')),
        body: const EmptyState(
          icon: Icons.storefront_outlined,
          title: 'No stand or fleet',
          message: 'Your account is not linked to a stand or a fleet. Ask the admin who gave you your ID.',
        ),
      );
    }
    final adminStands = [
      for (final s in roles.stands)
        if (s.isStandAdmin) s,
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          leading: back,
          title: Text(roles.stands.length == 1 ? 'Dispatch · ${roles.stands.first.shortName}' : 'Dispatch'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(dispatchRolesProvider),
            ),
          ],
          bottom: tabs.length < 2 ? null : TabBar(isScrollable: true, tabs: [for (final t in tabs) Tab(text: t)]),
        ),
        body: TabBarView(
          children: [
            for (final t in tabs)
              switch (t) {
                'Console' => DispatchConsole(stands: roles.stands, ticking: ticking),
                'My staff' => StandStaffView(stands: adminStands),
                'Charges' => StandChargesView(stands: adminStands, admin: false),
                'Telematics' => DispatchTelematicsTab(scopes: telematicsScopesFor(roles)),
                _ => FleetView(fleets: roles.fleets),
              },
          ],
        ),
      ),
    );
  }
}
