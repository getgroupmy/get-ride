// Security & integrations: session history, fraud tracing, IP access, API keys, eLife, fare AI, backend diagnostics.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../admin_registry.dart';
import 'api_keys_screens.dart';
import 'backend_screen.dart';
import 'elife_screen.dart';
import 'fare_ai_request_screen.dart';
import 'fare_ai_screens.dart';
import 'ip_access_screen.dart';
import '../messaging_screen.dart';
import 'session_history_screen.dart';
import 'trace_fraud_screen.dart';

/// `settings_entries` categories owned by these screens. None: every screen
/// here stores its data in a dedicated table (`ip_access_rules`,
/// `user_sessions`, `fare_ai_*`, …) or an `app_settings` row
/// (`api_providers`, `elife_api_connection`, `fare_ai_provider`).
const securityOwnedCategories = <String>{};

final securityRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/session-history', builder: (_, _) => const AdminSessionHistoryScreen()),
  GoRoute(path: '/admin/m/trace-fraud', builder: (_, _) => const AdminTraceFraudScreen()),
  GoRoute(path: '/admin/m/messaging', builder: (_, _) => const AdminMessagingScreen()),
  GoRoute(path: '/admin/m/ip-access', builder: (_, _) => const AdminIpAccessScreen()),
  GoRoute(path: '/admin/m/api-keys', builder: (_, _) => const AdminApiProvidersScreen()),
  GoRoute(
    path: '/admin/m/api-keys-services',
    builder: (_, s) => AdminApiServicesScreen(providerId: s.uri.queryParameters['providerId'] ?? ''),
  ),
  GoRoute(
    path: '/admin/m/api-keys-keys',
    builder: (_, s) => AdminApiKeysScreen(
      providerId: s.uri.queryParameters['providerId'] ?? '',
      serviceId: s.uri.queryParameters['serviceId'] ?? '',
    ),
  ),
  GoRoute(path: '/admin/m/api-elife', builder: (_, _) => const AdminElifeScreen()),
  GoRoute(path: '/admin/m/fare-ai', builder: (_, _) => const AdminFareAiScreen()),
  GoRoute(path: '/admin/m/fare-ai-logs', builder: (_, _) => const AdminFareAiLogsScreen()),
  GoRoute(path: '/admin/m/fare-ai-request', builder: (_, _) => const AdminFareAiRequestScreen()),
  GoRoute(path: '/admin/m/backend', builder: (_, _) => const AdminBackendScreen()),
];

const _section = 'Security & integrations';

const securityEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: _section,
    title: 'Session & location history',
    subtitle: 'Devices, networks, location trails and shared-device flags',
    path: '/admin/m/session-history',
    pages: ['admin-session-history'],
    icon: Icons.devices_other,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'Trace fraud',
    subtitle: 'Shared devices, IP clusters, fake trips, collusion and promo abuse',
    path: '/admin/m/trace-fraud',
    pages: ['admin-trace-fraud'],
    icon: Icons.policy_outlined,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'IP whitelist / blacklist',
    subtitle: 'Allow (skip PIN) or block devices by public IP',
    path: '/admin/m/ip-access',
    pages: ['admin-settings-ip-access'],
    icon: Icons.public,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'API providers & keys',
    subtitle: 'Mapping / geocoding / AI services and their rotating keys',
    path: '/admin/m/api-keys',
    pages: ['admin-settings-api-keys'],
    icon: Icons.vpn_key_outlined,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'API services',
    subtitle: 'Services of one provider',
    path: '/admin/m/api-keys-services',
    pages: ['admin-settings-api-keys-services', 'admin-settings-api-keys'],
    listed: false,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'API keys',
    subtitle: 'Keys of one service',
    path: '/admin/m/api-keys-keys',
    pages: ['admin-settings-api-keys-keys', 'admin-settings-api-keys'],
    listed: false,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'Elife connection',
    subtitle: 'Fleet & Ride Management API credentials and health',
    path: '/admin/m/api-elife',
    pages: ['admin-settings-api-elife', 'admin-settings-api-keys'],
    icon: Icons.power_outlined,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'Fare AI provider',
    subtitle: 'AI route estimation provider, keys and retry policy',
    path: '/admin/m/fare-ai',
    pages: ['admin-settings-fare-ai'],
    icon: Icons.psychology_outlined,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'Fare AI response log',
    subtitle: 'Every AI fare estimate attempt',
    path: '/admin/m/fare-ai-logs',
    pages: ['admin-settings-fare-ai-logs', 'admin-settings-fare-ai'],
    listed: false,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'Fare AI request & format',
    subtitle: 'What the fare AI is asked, and a test run',
    path: '/admin/m/fare-ai-request',
    pages: ['admin-settings-fare-ai'],
    listed: false,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'SMS / WhatsApp',
    subtitle: 'Which device sends & receives OTP, marketing, support calls & messages',
    path: '/admin/m/messaging',
    pages: [messagingPage],
    icon: Icons.sms_outlined,
  ),
  AdminScreenEntry(
    section: _section,
    title: 'Backend',
    subtitle: 'Configured Supabase host and reachability',
    path: '/admin/m/backend',
    pages: ['admin-settings-supabase'],
    icon: Icons.dns_outlined,
  ),
];
