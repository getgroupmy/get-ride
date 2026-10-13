import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show routerProvider;
import 'package:get_ride/src/providers.dart' show supabaseProvider;
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

void main() {
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
