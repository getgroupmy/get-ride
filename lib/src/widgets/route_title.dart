import 'package:flutter/material.dart';

/// The browser tab's name for an app path: "Trips · GET.ride",
/// "Fare tariffs · Admin · GET.ride", plain "GET.ride" for home and any
/// page without a name of its own. Matched on the longest known prefix,
/// so `/trips/<id>` is a trip and `/drive/vehicles/new` a new vehicle.
String pageTitleFor(String path) {
  const app = 'GET.ride';
  var p = Uri.tryParse(path)?.path ?? path;
  if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
  if (p == '/admin' || p.startsWith('/admin/')) {
    final parts = p.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return 'Admin · $app';
    final page = parts[1].replaceAll(RegExp(r'[-_]+'), ' ');
    return '${page[0].toUpperCase()}${page.substring(1)} · Admin · $app';
  }
  String? best;
  var bestLength = -1;
  for (final e in _titles.entries) {
    final k = e.key;
    final hit = p == k || (k.endsWith('/') ? p.startsWith(k) : p.startsWith('$k/'));
    if (hit && k.length > bestLength) {
      best = e.value;
      bestLength = k.length;
    }
  }
  return best == null ? app : '$best · $app';
}

/// Path (or path prefix ending in `/`) → page name.
const _titles = {
  '/login': 'Sign in',
  '/signup/photo': 'Profile photo',
  '/trips': 'Trips',
  '/trips/': 'Trip',
  '/trips/scheduled': 'Scheduled rides',
  '/ride/': 'Your ride',
  '/wallet': 'Wallet',
  '/wallet/history': 'Transaction history',
  '/wallet/receive': 'Receive',
  '/wallet/scan': 'Scan to pay',
  '/wallet/trade': 'GET.coin',
  '/account': 'Account',
  '/account/profile': 'Profile',
  '/account/profile/edit': 'Edit profile',
  '/account/settings': 'Settings',
  '/account/notifications': 'Notifications',
  '/account/safety': 'Safety',
  '/account/emergency': 'Emergency contacts',
  '/account/support': 'Support',
  '/account/help': 'Help assistant',
  '/account/guide': 'User guide',
  '/account/referral': 'Invite friends',
  '/account/my-ride': 'My Ride',
  '/account/my-qr': 'My QR',
  '/drive': 'Drive',
  '/drive/earnings': 'Earnings',
  '/drive/history': 'Trip history',
  '/drive/permits': 'My permit',
  '/drive/services': 'Services',
  '/drive/my-ride': 'My Ride code',
  '/drive/onboarding': 'Become a partner',
  '/drive/permit': 'Taxi permit',
  '/drive/scheduled': 'Scheduled rides',
  '/drive/statements': 'Statements',
  '/drive/ratings': 'My ratings',
  '/drive/trip/': 'Current trip',
  '/drive/vehicles': 'My vehicles',
  '/drive/vehicles/new': 'Add vehicle',
  '/meter': 'Meter',
  '/meter/printer': 'Printer',
  '/meter/reader': 'OBD reader',
  '/meter/vehicle': 'Vehicle info',
  '/meter/destination': 'Destination',
  '/ev': 'TEKSI EV',
  '/share/': 'Shared ride',
  '/verify/': 'Verify statement',
  '/diagnostics': 'Diagnostics',
};

/// Keeps the browser tab's title on the page shown: re-read from
/// [location] whenever [listenable] (the router) changes. Under the app's
/// own Title, so it wins.
class RouteTitle extends StatelessWidget {
  const RouteTitle({super.key, required this.location, required this.listenable, required this.child});

  final String Function() location;
  final Listenable listenable;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: listenable,
    child: child,
    builder: (context, child) => Title(
      title: pageTitleFor(location()),
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 1),
      child: child!,
    ),
  );
}
