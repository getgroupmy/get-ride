import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show routerProvider;
import 'package:get_ride/src/providers.dart' show supabaseProvider;
import 'package:get_ride/src/widgets/side_menu_tiles.dart' show driveShellPages, routeInShell;
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Every page path in [routes], with whether it sits inside a shell.
Map<String, bool> _paths(List<RouteBase> routes, {String parent = '', bool inShell = false}) {
  final out = <String, bool>{};
  for (final r in routes) {
    if (r is GoRoute) {
      final path = r.path.startsWith('/') ? r.path : '$parent/${r.path}';
      out[path] = inShell;
      out.addAll(_paths(r.routes, parent: path, inShell: inShell));
    } else if (r is ShellRouteBase) {
      out.addAll(_paths(r.routes, parent: parent, inShell: true));
    }
  }
  return out;
}

/// Every page path in [routes] under the tabbed shell (the rail on a wide
/// screen).
Set<String> _tabbed(List<RouteBase> routes, {String parent = '', bool tabbed = false}) {
  final out = <String>{};
  for (final r in routes) {
    if (r is GoRoute) {
      final path = r.path.startsWith('/') ? r.path : '$parent/${r.path}';
      if (tabbed) out.add(path);
      out.addAll(_tabbed(r.routes, parent: path, tabbed: tabbed));
    } else if (r is StatefulShellRoute) {
      for (final b in r.branches) {
        out.addAll(_tabbed(b.routes, parent: parent, tabbed: true));
      }
    } else if (r is ShellRouteBase) {
      out.addAll(_tabbed(r.routes, parent: parent, tabbed: tabbed));
    }
  }
  return out;
}

void main() {
  test("the driver's own pages sit in the tabbed shell, beside the rail, as /account's do", () {
    final container = ProviderContainer(
      overrides: [
        supabaseProvider.overrideWithValue(
          SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)),
        ),
      ],
    );
    addTearDown(container.dispose);
    final tabbed = _tabbed(container.read(routerProvider).configuration.routes);
    expect(tabbed, containsAll(['/account/settings', '/wallet/history', '/trips']));
    expect(tabbed, containsAll(driveShellPages));
    expect(tabbed, contains('/drive/history/:id'));
    // A trip, the vehicles and sign-up still stand over the shell.
    for (final p in ['/drive/trip/:id', '/drive/vehicles', '/drive/onboarding']) {
      expect(tabbed, isNot(contains(p)), reason: p);
    }
    // And the menus go to them rather than pushing a second shell.
    for (final p in [...driveShellPages, '/drive/scheduled?tab=mine', '/drive/history/r1', '/account/settings']) {
      expect(routeInShell(p), isTrue, reason: p);
    }
    for (final p in ['/drive/trip/r1', '/drive/vehicles', '/drive/vehicles/new', '/ev', '/ride/r1']) {
      expect(routeInShell(p), isFalse, reason: p);
    }
  });

  test('the meter\'s pages are outside the side-menu shell', () {
    // The meter is outside the shell and pushes these. Pushed from there, a
    // page inside the shell stacks a second copy of the shell over the one
    // below it -- a navigator key clash that showed Vehicle information as a
    // black screen.
    final container = ProviderContainer(
      overrides: [
        supabaseProvider.overrideWithValue(
          SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)),
        ),
      ],
    );
    addTearDown(container.dispose);
    final paths = _paths(container.read(routerProvider).configuration.routes);
    final meter = {
      for (final e in paths.entries)
        if (e.key == '/meter' || e.key.startsWith('/meter/')) e.key: e.value,
    };
    expect(meter.keys, containsAll(['/meter', '/meter/reader', '/meter/printer', '/meter/vehicle']));
    for (final e in meter.entries) {
      expect(e.value, isFalse, reason: '${e.key} is inside a shell');
    }
  });
}
