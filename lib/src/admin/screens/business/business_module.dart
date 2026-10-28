// Admin › People › Business accounts (migration 0313): the applications and
// accounts, one account (approve, suspend, its overrides, wallet and
// invoices) and the defaults per region.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/business_accounts.dart' show businessAccountsPage;
import '../../admin_registry.dart';
import 'business_accounts_screen.dart';
import 'business_defaults_screen.dart';

final businessRoutes = <RouteBase>[
  GoRoute(path: businessAccountsPath, builder: (_, _) => const BusinessAccountsAdminScreen()),
  GoRoute(
    path: businessAccountAdminPath,
    builder: (_, s) => BusinessAccountAdminScreen(id: s.uri.queryParameters['id'] ?? ''),
  ),
  GoRoute(path: businessDefaultsPath, builder: (_, _) => const BusinessDefaultsScreen()),
];

const businessEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'People',
    title: 'Business accounts',
    subtitle: 'Companies that book on account: approve, suspend, overrides, wallet and invoices',
    path: businessAccountsPath,
    pages: [businessAccountsPage],
    icon: Icons.business_center_outlined,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Business account defaults',
    subtitle: 'Credit limit, invoice terms, overdue pause, discount, commission and member limit per region',
    path: businessDefaultsPath,
    pages: [businessAccountsPage],
    icon: Icons.tune,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Business account',
    subtitle: 'One company: status, overrides, members, wallet and invoices',
    path: businessAccountAdminPath,
    pages: [businessAccountsPage],
    icon: Icons.business_outlined,
    listed: false,
  ),
];
