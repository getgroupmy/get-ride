// Geography: countries/states/cities, airport areas, multi-gate places.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../admin_registry.dart';
import 'airport_areas_screen.dart';
import 'geo_logic.dart';
import 'multi_gate_screens.dart';
import 'regions_screen.dart';

final geoRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/country-states-cities', builder: (_, _) => const AdminRegionsScreen()),
  GoRoute(path: '/admin/m/airport-areas', builder: (_, _) => const AdminAirportAreasScreen()),
  GoRoute(path: '/admin/m/multi-gate-places', builder: (_, _) => const AdminMultiGatePlacesScreen()),
  GoRoute(
    path: '/admin/m/multi-gate-place-gates',
    builder: (_, s) => AdminMultiGateGatesScreen(
      placeId: s.uri.queryParameters['placeId'] ?? '',
      parentKey: (s.uri.queryParameters['parentKey'] ?? '').isEmpty
          ? multiGatePlacesKey
          : s.uri.queryParameters['parentKey']!,
    ),
  ),
];

const geoEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Geography',
    title: 'Countries, states & cities',
    subtitle: 'Regions, per-region services, bidding and geofences',
    path: '/admin/m/country-states-cities',
    pages: [regionsPage],
    icon: Icons.public,
  ),
  AdminScreenEntry(
    section: 'Geography',
    title: 'Airport areas',
    subtitle: 'Airports, their assigned place, geofence and gates',
    path: '/admin/m/airport-areas',
    pages: [airportAreasPage],
    icon: Icons.flight,
  ),
  AdminScreenEntry(
    section: 'Geography',
    title: 'Multi-gate places',
    subtitle: 'Malls, stations and venues with several pickup / drop gates',
    path: '/admin/m/multi-gate-places',
    pages: [multiGatePlacesPage],
    icon: Icons.door_front_door_outlined,
  ),
  AdminScreenEntry(
    section: 'Geography',
    title: 'Place gates',
    subtitle: 'Gates of a multi-gate place or airport',
    path: '/admin/m/multi-gate-place-gates',
    pages: [multiGateGatesPage, multiGatePlacesPage, airportAreasPage],
    icon: Icons.door_front_door_outlined,
    listed: false,
  ),
];
