import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/common.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';

final dashboardCountsProvider = FutureProvider.autoDispose<Map<String, int>>((ref) {
  for (final t in const [
    'profiles',
    'partners',
    'vehicle',
    'ride_requests',
    'provider_documents',
    'vehicle_documents',
    'support_tickets',
  ]) {
    ref.watchAdminLive(t);
  }
  return ref.watch(adminRepositoryProvider).dashboardCounts();
});

class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiles = <(String, String, IconData, String)>[
      ('users', 'Users', Icons.people_outline, '/admin/users'),
      ('partners', 'Partners', Icons.badge_outlined, '/admin/partners'),
      ('partnersPending', 'Partners awaiting approval', Icons.hourglass_top, '/admin/partners?status=unapproved'),
      ('vehicles', 'Vehicles', Icons.directions_car_outlined, '/admin/vehicles'),
      ('ridesOpen', 'Open ride requests', Icons.radar, '/admin/rides?status=open'),
      ('ridesActive', 'Rides in progress', Icons.local_taxi_outlined, '/admin/rides?status=active'),
      ('ridesCompleted', 'Completed rides', Icons.check_circle_outline, '/admin/rides?status=completed'),
      ('providerDocsPending', 'Partner documents to review', Icons.fact_check_outlined, '/admin/documents'),
      ('vehicleDocsPending', 'Vehicle documents to review', Icons.fact_check_outlined, '/admin/documents?kind=vehicle'),
      ('ticketsOpen', 'Open support tickets', Icons.support_agent, '/admin/support'),
    ];
    return AdminPage(
      title: 'Dashboard',
      module: 'dashboard',
      actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(dashboardCountsProvider)),
      ],
      body: AsyncView(
        value: ref.watch(dashboardCountsProvider),
        onRetry: () => ref.invalidate(dashboardCountsProvider),
        data: (counts) => GridView.extent(
          padding: const EdgeInsets.all(16),
          maxCrossAxisExtent: 260,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.6,
          children: [
            for (final (key, label, icon, route) in tiles)
              Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => context.go(route),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(icon, color: Theme.of(context).colorScheme.primary),
                      const Spacer(),
                      Text(
                        (counts[key] ?? -1) < 0 ? '—' : '${counts[key]}',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
