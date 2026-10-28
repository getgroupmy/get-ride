// Premium service rules and GET.Plus (migration 0316), under Services &
// catalogue.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/premium_plus.dart' show premiumPlusPage;
import '../../admin_registry.dart';
import 'premium_plus_screen.dart';

final premiumPlusRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/premium-plus', builder: (_, _) => const PremiumPlusScreen()),
];

const premiumPlusEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Premium and GET.Plus',
    subtitle: 'Premium service rules by region, the GET.Plus rider membership, its members and revenue',
    path: premiumPlusPath,
    pages: [premiumPlusPage],
    icon: Icons.workspace_premium_outlined,
  ),
];
