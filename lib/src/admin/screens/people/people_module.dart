// People: user/partner/vehicle add & edit forms, user ID documents.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../admin_registry.dart';
import 'partner_screens.dart';
import 'user_screens.dart';
import 'vehicle_screens.dart';

String _id(GoRouterState s) => s.uri.queryParameters['id'] ?? '';

final peopleRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/user-edit', builder: (_, s) => UserEditScreen(id: _id(s))),
  GoRoute(path: '/admin/m/user-id-documents', builder: (_, _) => const UserIdDocumentsScreen()),
  GoRoute(path: '/admin/m/partner-add', builder: (_, _) => const PartnerAddScreen()),
  GoRoute(path: '/admin/m/partner-edit', builder: (_, s) => PartnerEditScreen(id: _id(s))),
  GoRoute(path: '/admin/m/vehicle-add', builder: (_, _) => const VehicleAddScreen()),
  GoRoute(path: '/admin/m/vehicle-edit', builder: (_, s) => VehicleEditScreen(id: _id(s))),
];

// "Add user" (admin-user-add) is intentionally not ported: profiles.id is a
// foreign key to auth.users, and the Expo add flow never reaches the database
// (`upsertUser` skips rows with no existing profile).
const peopleEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'People',
    title: 'User ID documents',
    subtitle: 'Review uploaded IC / passport images',
    path: '/admin/m/user-id-documents',
    pages: ['admin-documents-users'],
    icon: Icons.badge_outlined,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Add partner',
    subtitle: 'Onboard an existing user as a partner',
    path: '/admin/m/partner-add',
    pages: ['admin-partner-add'],
    icon: Icons.person_add_alt_1_outlined,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Add vehicle',
    subtitle: 'Register a vehicle and its owner',
    path: '/admin/m/vehicle-add',
    pages: ['admin-vehicle-add'],
    icon: Icons.directions_car_outlined,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Edit user',
    subtitle: 'Profile, images and status',
    path: '/admin/m/user-edit',
    pages: ['admin-user-edit'],
    icon: Icons.manage_accounts_outlined,
    listed: false,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Edit partner',
    subtitle: 'Service area, partner types, vehicle and documents',
    path: '/admin/m/partner-edit',
    pages: ['admin-partner-edit'],
    icon: Icons.badge,
    listed: false,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Edit vehicle',
    subtitle: 'Vehicle details, photos, status and permit',
    path: '/admin/m/vehicle-edit',
    pages: ['admin-vehicle-edit'],
    icon: Icons.car_repair_outlined,
    listed: false,
  ),
];
