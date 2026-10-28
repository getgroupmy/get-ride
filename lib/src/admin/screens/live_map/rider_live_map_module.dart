// Admin › Settings › Rider live map (migration 0322): what riders may see on
// the home map (cars near me, busy areas, my people, team), by region.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/rider_live_map.dart' show riderLiveMapPage;
import '../../admin_registry.dart';
import 'rider_live_map_screen.dart';

const riderLiveMapPath = '/admin/m/rider-live-map';

final riderLiveMapRoutes = <RouteBase>[
  GoRoute(path: riderLiveMapPath, builder: (_, _) => const RiderLiveMapScreen()),
];

const riderLiveMapEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Meter & app',
    title: 'Rider live map',
    subtitle: 'Cars near me, busy areas, my people and team on the rider\'s home map, by region',
    path: riderLiveMapPath,
    pages: [riderLiveMapPage],
    icon: Icons.hive_outlined,
  ),
];
