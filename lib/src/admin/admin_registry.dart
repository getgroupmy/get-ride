import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'screens/business/business_module.dart';
import 'screens/catalogue/catalogue_module.dart';
import 'screens/city_ride_extras_screen.dart';
import 'screens/city_to_city/city_to_city_module.dart';
import 'screens/commerce/commerce_module.dart';
import 'screens/family/family_module.dart';
import 'screens/geo/geo_module.dart';
import 'screens/help/help_module.dart';
import 'screens/hire_bookings_screen.dart';
import 'screens/live_map/rider_live_map_module.dart';
import 'screens/meterapp/meterapp_module.dart';
import 'screens/mygig/mygig_module.dart';
import 'screens/office_nas/office_nas_module.dart';
import 'screens/people/people_module.dart';
import 'screens/ride_safety/ride_safety_screen.dart';
import 'screens/rider_audio/rider_audio_screen.dart';
import 'screens/premium_plus/premium_plus_module.dart';
import 'screens/security/security_module.dart';

/// A ported admin screen, listed on the Settings hub under [section] and
/// reachable at [path] (always under `/admin/m/`).
class AdminScreenEntry {
  const AdminScreenEntry({
    required this.section,
    required this.title,
    required this.subtitle,
    required this.path,
    required this.pages,
    this.icon = Icons.tune,
    this.listed = true,
  });

  final String section;
  final String title;
  final String subtitle;
  final String path;

  /// Expo page keys that grant access (the first is the canonical one).
  final List<String> pages;
  final IconData icon;

  /// False for screens only reached from another screen (e.g. edit forms).
  final bool listed;
}

/// Section order on the Settings hub.
const adminSections = [
  'Operations',
  'People',
  'Services & catalogue',
  'Payments & commerce',
  'Geography',
  'Meter & app',
  'Security & integrations',
];

/// Every ported screen, in hub order.
final allAdminEntries = <AdminScreenEntry>[
  ...helpEntries,
  ...rideSafetyEntries,
  ...hireBookingsEntries,
  ...mygigAdminEntries,
  ...peopleEntries,
  ...businessEntries,
  ...familyAdminEntries,
  ...catalogueEntries,
  ...cityToCityEntries,
  ...cityRideExtrasEntries,
  ...riderAudioEntries,
  ...premiumPlusEntries,
  ...commerceEntries,
  ...geoEntries,
  ...meterappEntries,
  ...riderLiveMapEntries,
  ...securityEntries,
  ...officeNasEntries,
];

/// Routes of every ported screen (paths under `/admin/m/`).
final allPortedAdminRoutes = <RouteBase>[
  ...helpRoutes,
  ...rideSafetyRoutes,
  ...hireBookingsRoutes,
  ...mygigAdminRoutes,
  ...peopleRoutes,
  ...businessRoutes,
  ...familyAdminRoutes,
  ...catalogueRoutes,
  ...cityToCityRoutes,
  ...cityRideExtrasRoutes,
  ...riderAudioRoutes,
  ...premiumPlusRoutes,
  ...commerceRoutes,
  ...geoRoutes,
  ...meterappRoutes,
  ...riderLiveMapRoutes,
  ...securityRoutes,
  ...officeNasRoutes,
];

/// `settings_entries` categories that have a dedicated ported editor.
const allOwnedCategories = <String>{
  ...catalogueOwnedCategories,
  ...commerceOwnedCategories,
  ...meterappOwnedCategories,
  ...securityOwnedCategories,
  // Saved push notifications: edited on the Push notifications screen.
  'push-notification',
};

/// Generated list categories a dedicated editor has replaced, with where the
/// setting lives now. They are left off the Settings hub; their rows are kept
/// (nothing is deleted) and the list still opens from a direct link.
const replacedCategories = <String, String>{
  // Nothing read it; the dispatch reads each vehicle service's own radius (0160).
  'search-radius': 'Vehicle Services > Search radius',
};
