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
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(dashboardCountsProvider)),
      ],
      body: AsyncView(
        value: ref.watch(dashboardCountsProvider),
        onRetry: () => ref.invalidate(dashboardCountsProvider),
        data: (counts) => GridView(
          padding: const EdgeInsets.all(16),
          // A height that holds the icon, the count and a three-line label at
          // the reader's text size, at any width (not a fixed shape, which
          // clipped the labels on phones and at large text).
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 260,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: dashboardTileHeight(MediaQuery.textScalerOf(context)),
          ),
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
                      // One line, shrunk to fit a narrow tile.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          (counts[key] ?? -1) < 0 ? '—' : '${counts[key]}',
                          maxLines: 1,
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Text(label, maxLines: 3, overflow: TextOverflow.ellipsis),
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

/// A dashboard tile's height: padding, the icon, a gap, the count
/// (headlineMedium, 36 px a line) and three label lines (20 px each), the
/// text parts grown with [scaler].
double dashboardTileHeight(TextScaler scaler) => 32 + 24 + 8 + scaler.scale(36) + scaler.scale(60) + 4;
