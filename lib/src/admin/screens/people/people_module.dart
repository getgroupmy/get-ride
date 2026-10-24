// People: user/partner/vehicle add & edit forms, user ID documents.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../admin_registry.dart';
import '../dispatch/selfie_checks_settings.dart' show dispatchSelfiePage;
import '../online_selfie_check_screen.dart';
import '../selfie_watch_list.dart';
import 'partner_review_screen.dart';
import 'partner_screens.dart';
import 'user_screens.dart';
import 'vehicle_permits_screen.dart';
import 'vehicle_screens.dart';

String _id(GoRouterState s) => s.uri.queryParameters['id'] ?? '';

final peopleRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/user-edit', builder: (_, s) => UserEditScreen(id: _id(s))),
  GoRoute(path: '/admin/m/user-id-documents', builder: (_, _) => const UserIdDocumentsScreen()),
  GoRoute(path: '/admin/m/partner-add', builder: (_, _) => const PartnerAddScreen()),
  GoRoute(path: '/admin/m/partner-edit', builder: (_, s) => PartnerEditScreen(id: _id(s))),
  GoRoute(path: '/admin/m/partner-review', builder: (_, s) => PartnerReviewScreen(id: _id(s))),
  // The partner selfie check when going online (0290): one check (the
  // low-match push opens it) and the watch list.
  GoRoute(path: '/admin/m/online-selfie-check', builder: (_, s) => OnlineSelfieCheckScreen(id: _id(s))),
  GoRoute(path: '/admin/m/selfie-watch-list', builder: (_, _) => const SelfieWatchListScreen()),
  GoRoute(path: '/admin/m/vehicle-add', builder: (_, _) => const VehicleAddScreen()),
  GoRoute(path: '/admin/m/vehicle-edit', builder: (_, s) => VehicleEditScreen(id: _id(s))),
  GoRoute(
    path: '/admin/m/vehicle-permits',
    builder: (_, s) => VehiclePermitsScreen(initialCountry: s.uri.queryParameters['country']),
  ),
];

// "Add user" (admin-user-add) is intentionally not ported: profiles.id is a
// foreign key to auth.users, and the Expo add flow never reaches the database
// (`upsertUser` skips rows with no existing profile).
const peopleEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'People',
    title: 'Selfie watch list',
    subtitle: 'Partners checked more often when going online, with their rule and the reason',
    path: '/admin/m/selfie-watch-list',
    pages: [dispatchSelfiePage],
    icon: Icons.visibility_outlined,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Selfie check',
    subtitle: 'One selfie from going online, with its match',
    path: '/admin/m/online-selfie-check',
    pages: [dispatchSelfiePage],
    icon: Icons.face_outlined,
    listed: false,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Vehicle permits',
    subtitle: 'Permits per country: upload, bypass, require, plate colours, expiry reminders',
    path: '/admin/m/vehicle-permits',
    pages: [vehiclePermitsPage],
    icon: Icons.verified_user_outlined,
  ),
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
    subtitle: 'Service area, Partner Service types, vehicle and documents',
    path: '/admin/m/partner-edit',
    pages: ['admin-partner-edit'],
    icon: Icons.badge,
    listed: false,
  ),
  AdminScreenEntry(
    section: 'People',
    title: 'Review application',
    subtitle: 'Approve, reject or edit each detail and document, then send back or approve',
    path: '/admin/m/partner-review',
    pages: [PartnerReviewScreen.page],
    icon: Icons.rule,
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
