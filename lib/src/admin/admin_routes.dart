import 'package:go_router/go_router.dart';

import 'admin_registry.dart';
import 'admin_shell.dart';
import 'screens/commission_screen.dart';
import 'screens/fare_tariffs_screen.dart';
import 'screens/messaging_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/documents_screen.dart';
import 'screens/people_screens.dart';
import 'screens/promo_codes_screen.dart';
import 'screens/push_screen.dart';
import 'screens/rides_screen.dart';
import 'screens/settings_screens.dart';
import 'screens/sub_admins_screen.dart';
import 'screens/support_screens.dart';

/// `/admin/...` — a separate shell from the passenger/driver app.
final adminRoute = ShellRoute(
  builder: (_, state, child) => AdminShell(location: state.uri.path, child: child),
  routes: [
    GoRoute(path: '/admin', redirect: (_, _) => '/admin/dashboard'),
    GoRoute(path: '/admin/dashboard', builder: (_, _) => const AdminDashboardScreen()),
    GoRoute(
      path: '/admin/users',
      builder: (_, s) => AdminUsersScreen(initialFilter: s.uri.queryParameters['status']),
    ),
    GoRoute(
      path: '/admin/partners',
      builder: (_, s) => AdminPartnersScreen(initialFilter: s.uri.queryParameters['status']),
    ),
    GoRoute(
      path: '/admin/vehicles',
      builder: (_, s) => AdminPartnersScreen(initialFilter: s.uri.queryParameters['status'], vehicles: true),
    ),
    GoRoute(
      path: '/admin/documents',
      builder: (_, s) => AdminDocumentsScreen(vehicle: s.uri.queryParameters['kind'] == 'vehicle'),
    ),
    GoRoute(
      path: '/admin/rides',
      builder: (_, s) => AdminRidesScreen(initialFilter: s.uri.queryParameters['status']),
    ),
    GoRoute(path: '/admin/support', builder: (_, _) => const AdminSupportScreen()),
    GoRoute(
      path: '/admin/support/:ticketId',
      builder: (_, s) => AdminSupportChatScreen(ticketId: s.pathParameters['ticketId']!),
    ),
    GoRoute(path: '/admin/push', builder: (_, _) => const AdminPushScreen()),
    GoRoute(path: '/admin/commission', builder: (_, _) => const AdminCommissionScreen()),
    GoRoute(path: '/admin/fare-tariffs', builder: (_, _) => const AdminFareTariffsScreen()),
    GoRoute(path: '/admin/messaging', builder: (_, _) => const AdminMessagingScreen()),
    GoRoute(
      path: '/admin/sub-admins',
      builder: (_, _) => const AdminSubAdminsScreen(),
      routes: [
        // Pages of their own, so a reload stays on them.
        GoRoute(path: 'grant', builder: (_, _) => const GrantEditorPage()),
        GoRoute(path: ':id/edit', builder: (_, s) => GrantEditorPage(profileId: s.pathParameters['id'])),
      ],
    ),
    GoRoute(path: '/admin/settings', builder: (_, _) => const AdminSettingsScreen()),
    GoRoute(
      path: '/admin/settings/:category',
      builder: (_, s) {
        final q = Map<String, String>.from(s.uri.queryParameters);
        final label = q.remove('_label');
        final key = s.pathParameters['category']!;
        // Promo codes have their own table and editor (0242).
        return key != 'promocode-list' || q.isNotEmpty
            ? AdminCategoryScreen(categoryKey: key, scope: q, parentLabel: label)
            : const AdminPromoCodesScreen();
      },
    ),
    ...allPortedAdminRoutes,
  ],
);
