// City to City (migration 0306): the settings and the route rules, under
// Services & catalogue; payments, fees and reminders (0309); per-seat trips
// (0310, its own permission page). Commission per service is a tab of Commission.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/city_to_city.dart' show c2cPage;
import '../../../core/city_to_city_seats.dart' show c2cSeatsPage;
import '../../admin_registry.dart';
import 'city_to_city_money_screen.dart';
import 'city_to_city_routes_screen.dart';
import 'city_to_city_seats_screen.dart';
import 'city_to_city_settings_screen.dart';

final cityToCityRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/city-to-city', builder: (_, _) => const CityToCitySettingsScreen()),
  GoRoute(path: '/admin/m/city-to-city-routes', builder: (_, _) => const CityToCityRoutesScreen()),
  GoRoute(path: '/admin/m/city-to-city-money', builder: (_, _) => const CityToCityMoneyScreen()),
  GoRoute(path: cityToCitySeatsPath, builder: (_, _) => const CityToCitySeatsScreen()),
];

const cityToCityEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'City to City',
    subtitle: 'Cancel fee, payment, driving experience, permits by country, where it is offered',
    path: cityToCityPath,
    pages: [c2cPage],
    icon: Icons.alt_route,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'City to City routes and fares',
    subtitle: 'Route rules: the fare card plus an add-on, or a fixed fare, and the suggested range',
    path: cityToCityRoutesPath,
    pages: [c2cPage],
    icon: Icons.route_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'City to City payments, fees and reminders',
    subtitle: 'Driver give-up fee, in-app payment, cancel fees owed, trip reminders',
    path: cityToCityMoneyPath,
    pages: [c2cPage],
    icon: Icons.account_balance_wallet_outlined,
  ),
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'City to City per-seat trips',
    subtitle: 'Trips drivers post: how riders join, seat price, door pickup, women only, repeats, co-riders, parcels',
    path: cityToCitySeatsPath,
    pages: [c2cSeatsPage],
    icon: Icons.event_seat_outlined,
  ),
];
