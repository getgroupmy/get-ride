// Services & catalogue: services, vehicle services, partner types, documents, makes & models, service assignment.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../admin_registry.dart';
import 'assign_service_screens.dart';
import 'catalogue_logic.dart';
import 'document_reading_screen.dart';
import 'document_screens.dart';
import 'driver_service_locks_screen.dart';
import 'make_model_screen.dart';
import 'partner_type_screen.dart';
import 'partner_type_services_screen.dart';
import 'service_order_screen.dart';
import 'services_screens.dart';

/// `settings_entries.category` keys whose screens live in this module, so
/// the generic "More categories (advanced)" raw list can skip them.
/// (`document-type` / `required-documents` normally live in their own
/// tables, but legacy rows can remain in `settings_entries`.)
const catalogueOwnedCategories = <String>{
  serviceSettingsKey,
  vehicleServicesKey,
  partnerTypeKey,
  documentTypeKey,
  requiredDocumentsKey,
};

final catalogueRoutes = <RouteBase>[
  GoRoute(
    path: '/admin/m/service-settings',
    builder: (_, s) => ServiceSettingsScreen(openId: s.uri.queryParameters['highlight']),
  ),
  GoRoute(
    path: '/admin/m/vehicle-services',
    builder: (_, s) => VehicleServicesScreen(openId: s.uri.queryParameters['highlight']),
  ),
  GoRoute(path: serviceOrderPath, builder: (_, _) => const ServiceOrderScreen()),
  GoRoute(path: '/admin/m/partner-type', builder: (_, _) => const PartnerTypeScreen()),
  GoRoute(path: '/admin/m/partner-type-services', builder: (_, _) => const PartnerTypeServicesScreen()),
  GoRoute(path: '/admin/m/driver-service-locks', builder: (_, _) => const DriverServiceLocksScreen()),
  GoRoute(path: '/admin/m/document-type', builder: (_, _) => const DocumentTypeScreen()),
  GoRoute(path: '/admin/m/required-documents', builder: (_, _) => const RequiredDocumentsScreen()),
  GoRoute(path: documentReadingPath, builder: (_, _) => const DocumentReadingScreen()),
  GoRoute(path: '/admin/m/vehicle-make-model', builder: (_, _) => const VehicleMakeModelScreen()),
  GoRoute(path: '/admin/m/assign-service', builder: (_, _) => const AssignServiceScreen()),
  GoRoute(
    path: '/admin/m/assign-service-page',
    builder: (_, s) => AssignServicePageScreen(pageId: s.uri.queryParameters['id'] ?? ''),
  ),
];

const catalogueEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Service Settings',
    subtitle: 'Core service configuration',
    path: '/admin/m/service-settings',
    pages: ['admin-settings-service'],
    icon: Icons.build_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Vehicle Services',
    subtitle: 'Fares, limits and images per vehicle service',
    path: '/admin/m/vehicle-services',
    pages: ['admin-settings-vehicle-services'],
    icon: Icons.layers_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Service order',
    subtitle: 'Which services may take which orders, lowest to highest',
    path: serviceOrderPath,
    pages: ['admin-settings-vehicle-services'],
    icon: Icons.stairs_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Partner Service type',
    subtitle: 'Categories & nested sub-services',
    path: '/admin/m/partner-type',
    pages: ['admin-settings-partner-type'],
    icon: Icons.groups_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Partner Service type services',
    subtitle: 'Which ride services each Partner Service type sees in open requests',
    path: partnerTypeServicesPath,
    pages: [partnerTypeServicesPage, 'admin-settings-partner-type'],
    icon: Icons.rule_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Driver service locks',
    subtitle: 'Keep a service on or off for some drivers, over their own switches',
    path: driverServiceLocksPath,
    pages: [driverServiceLocksPage],
    icon: Icons.lock_outline,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Document Type',
    subtitle: 'Categorize required documents',
    path: '/admin/m/document-type',
    pages: ['admin-settings-document-type'],
    icon: Icons.badge_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Required Documents',
    subtitle: 'Partner onboarding docs',
    path: '/admin/m/required-documents',
    pages: ['admin-settings-required-documents'],
    icon: Icons.fact_check_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Document reading',
    subtitle: 'Who reads document photos, in what order: phone, office NAS, cloud',
    path: documentReadingPath,
    pages: [documentReadingPage],
    icon: Icons.document_scanner_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Vehicle Make & Model',
    subtitle: 'Vehicle types, energy types, makes and models',
    path: '/admin/m/vehicle-make-model',
    pages: ['admin-settings-vehicle-make-model'],
    icon: Icons.directions_car_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Assign Service',
    subtitle: 'Map provider services to app pages',
    path: '/admin/m/assign-service',
    pages: ['admin-settings-assign-service', 'admin-settings-assign-service-page'],
    icon: Icons.link,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Assign Service · Page',
    subtitle: 'Capabilities of one page',
    path: '/admin/m/assign-service-page',
    pages: ['admin-settings-assign-service-page', 'admin-settings-assign-service'],
    icon: Icons.link,
    listed: false,
  ),
];
