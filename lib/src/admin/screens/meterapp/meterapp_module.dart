// Meter & app: Meter Digital rate cards, display/mock settings, app settings (icon, splash, theme, start location),
// always-on pages, store releases.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../admin_registry.dart';
import 'always_on_screen.dart';
import 'app_release_screen.dart';
import 'display_screen.dart';
import 'meter_digital_screen.dart';
import 'mock_screen.dart';
import 'site_screen.dart';

final meterappRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/meter-digital', builder: (_, _) => const AdminMeterDigitalScreen()),
  GoRoute(path: '/admin/m/display', builder: (_, _) => const AdminDisplaySettingsScreen()),
  GoRoute(path: '/admin/m/mock', builder: (_, _) => const AdminMockSettingsScreen()),
  GoRoute(path: '/admin/m/site', builder: (_, _) => const AdminSiteSettingsScreen()),
  // App Icon and Splash Screen are sections of App Settings now; their old
  // addresses (bookmarks, the sub-admin page list) still land there.
  GoRoute(path: '/admin/m/app-icon', redirect: (_, _) => '/admin/m/site'),
  GoRoute(path: '/admin/m/splash', redirect: (_, _) => '/admin/m/site'),
  GoRoute(path: '/admin/m/always-on', builder: (_, _) => const AdminAlwaysOnScreen()),
  GoRoute(path: '/admin/m/app-release', builder: (_, _) => const AdminAppReleaseScreen()),
];

const meterappEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Meter & app',
    title: 'Meter Digital Setting',
    subtitle: 'Taxi meter rate cards, sensors, console panels & leave keys',
    path: '/admin/m/meter-digital',
    pages: ['admin-settings-meter-digital'],
    icon: Icons.speed,
  ),
  AdminScreenEntry(
    section: 'Meter & app',
    title: 'Display Settings',
    subtitle: 'Home screen, layout offsets, service boxes & side menus',
    path: '/admin/m/display',
    pages: ['admin-settings-display'],
    icon: Icons.visibility_outlined,
  ),
  AdminScreenEntry(
    section: 'Meter & app',
    title: 'Mock / Simulation',
    subtitle: 'Demo offers, requests and simulated driving',
    path: '/admin/m/mock',
    pages: ['admin-settings-mock'],
    icon: Icons.science_outlined,
  ),
  AdminScreenEntry(
    section: 'Meter & app',
    title: 'App Settings',
    subtitle: 'App icon, splash screen, theme colours & default location — for every user',
    path: '/admin/m/site',
    // The App Icon and Splash Screen pages it absorbed: a sub-admin granted
    // either keeps their access.
    pages: ['admin-settings-site', 'admin-settings-app-icon', 'admin-settings-splash'],
    icon: Icons.language,
  ),
  AdminScreenEntry(
    section: 'Meter & app',
    title: 'Always ON',
    subtitle: 'Keep the screen awake on selected pages',
    path: '/admin/m/always-on',
    pages: ['admin-settings-always-on'],
    icon: Icons.wb_sunny_outlined,
  ),
  AdminScreenEntry(
    section: 'Meter & app',
    title: 'App Release',
    subtitle: 'Build & upload to the App Store and Google Play',
    path: '/admin/m/app-release',
    pages: [appReleasePage],
    icon: Icons.rocket_launch_outlined,
  ),
];

/// `settings_entries` categories these screens own (kept out of the raw
/// "advanced" list): the Always ON config row and the site name/value rows.
const meterappOwnedCategories = <String>{'always-on-pages', 'site-settings'};
