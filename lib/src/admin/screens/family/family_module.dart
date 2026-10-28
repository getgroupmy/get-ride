// Admin › People › Family (migration 0317): the values by place and the
// Modules and Family matrix; the families, member caps, requests and the
// logged God View look.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/family.dart' show familyAdminPage;
import '../../admin_registry.dart';
import 'family_list_screen.dart';
import 'family_settings_screen.dart';

const familyAdminPath = '/admin/m/family';
const familyAdminListPath = '/admin/m/family-list';

final familyAdminRoutes = <RouteBase>[
  GoRoute(path: familyAdminPath, builder: (_, _) => const FamilySettingsScreen()),
  GoRoute(path: familyAdminListPath, builder: (_, _) => const FamilyListScreen()),
];

const familyAdminEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'People',
    title: 'Family',
    subtitle: 'Members, invites, children, limits, location rule, and the Modules and Family matrix',
    path: familyAdminPath,
    pages: [familyAdminPage],
    icon: Icons.family_restroom,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Families',
    subtitle: 'Every family, member caps, requests for more, and the logged God View look',
    path: familyAdminListPath,
    pages: [familyAdminPage],
    icon: Icons.groups_outlined,
  ),
];
