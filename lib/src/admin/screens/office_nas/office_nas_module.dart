// Office NAS (migration 0318 and the other NAS batches): one page under
// Security & integrations, its tabs in office_nas_screen.dart.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/office_nas.dart' show officeNasPage, officeNasPath;
import '../../admin_registry.dart';
import 'office_nas_screen.dart';

final officeNasRoutes = <RouteBase>[
  GoRoute(path: officeNasPath, builder: (_, s) => OfficeNasScreen(initialTab: s.uri.queryParameters['tab'])),
];

const officeNasEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Security & integrations',
    title: 'Office NAS',
    subtitle: 'Backups, uptime and the other services on the office NAS',
    path: officeNasPath,
    pages: [officeNasPage],
    icon: Icons.dns_outlined,
  ),
];
