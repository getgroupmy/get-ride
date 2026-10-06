/// Admin → Settings → Always ON (Expo `hooks/useAlwaysOn.ts`): the pages on
/// which the screen must never dim or sleep. The admin picks them by their
/// Expo route names (`partner-teksi`, `meter-digital`, …), which both apps
/// share, so each Flutter location is mapped onto the names it stands for.
library;

import '../admin/screens/meterapp/always_on_screen.dart' show normalizeAlwaysOnRoute;

/// The admin page names a Flutter location stands for. A ride screen in
/// Flutter is both Expo's waiting screen and its tracking screen, so it
/// answers to either.
Set<String> alwaysOnRoutesFor(String path) {
  final p = path.split(RegExp(r'[?#]')).first.replaceAll(RegExp(r'/+$'), '');
  final s = p.split('/').where((x) => x.isNotEmpty).toList();
  if (s.isEmpty) return {'index'};
  return switch (s) {
    ['drive'] => {'partner-ehailing'},
    ['drive', 'permit'] => {'partner-teksi'},
    ['drive', 'trip', _] => {'ride-running'},
    ['ride', _] => {'ride-tracking', 'ride-confirm'},
    ['meter'] => {'meter-digital'},
    ['meter', 'vehicle'] => {'vehicle-information'},
    ['meter', 'reader'] => {'obd2-reader'},
    ['wallet', 'scan'] => {'wallet-scan'},
    ['wallet', 'receive'] => {'wallet-show-code'},
    _ => {s.first},
  };
}

/// Whether the screen should stay awake at [path] for the admin's [routes].
bool keepAwakeAt(String path, List<String> routes) {
  final names = alwaysOnRoutesFor(path);
  return routes.any((r) => names.contains(normalizeAlwaysOnRoute(r)));
}

/// Holds the screen awake while the current location is an Always ON page,
/// and lets go the moment it isn't. It only calls [setAwake] on a change, so
/// navigating between two Always ON pages never flickers the lock.
class AlwaysOnController {
  AlwaysOnController({required this.setAwake, required this.loadRoutes});

  final Future<void> Function(bool awake) setAwake;

  /// The admin's pages; the built-in defaults when they can't be read.
  final Future<List<String>> Function() loadRoutes;

  List<String> _routes = const [];
  String _path = '/';
  bool _held = false;
  bool _disposed = false;

  bool get held => _held;

  /// Loads (or reloads) the admin's set and re-applies it.
  Future<void> reload() async {
    final routes = await loadRoutes();
    if (_disposed) return;
    _routes = routes;
    await _apply();
  }

  /// The location changed.
  Future<void> navigated(String path) async {
    _path = path;
    await _apply();
  }

  Future<void> _apply() async {
    final want = keepAwakeAt(_path, _routes);
    if (want == _held || _disposed) return;
    _held = want;
    try {
      await setAwake(want);
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_held) {
      _held = false;
      try {
        await setAwake(false);
      } catch (_) {}
    }
  }
}
