/// Which build of the website this tab is running, and what to do when the
/// site has been deployed again since it was opened.
///
/// A tab left open across a deploy keeps running the code it loaded, against
/// a backend that may have moved on. Each deploy (deploy-web.yml) compiles
/// its commit into the app as WEB_BUILD_ID and serves the same id at
/// /build.json, so the tab can tell when it is behind and reload.
library;

import 'dart:convert';

/// The build this tab is running. Empty outside a deployed website (a local
/// `flutter run`, the phone apps), where nothing is checked.
const webBuildId = String.fromEnvironment('WEB_BUILD_ID');

/// The path the deployed build id is served at.
const webBuildPath = '/build.json';

/// How often an open tab asks; also asked whenever it comes back into view.
const webBuildCheckEvery = Duration(minutes: 5);

/// A tab hidden at least this long reloads by itself when it is shown again;
/// anything shorter gets a card instead, since the user may be mid-task.
const webBuildIdleReload = Duration(minutes: 30);

/// The served build id in [body] (`{"build": "<id>"}`), or null when it is
/// not one (a 404 page, the app's index.html, an empty file). Pure.
String? parseWebBuild(String body) {
  try {
    final v = jsonDecode(body);
    if (v is! Map) return null;
    final id = v['build'];
    return id is String && id.trim().isNotEmpty ? id.trim() : null;
  } catch (_) {
    return null;
  }
}

/// Screens whose state a reload would lose and that the app cannot restore:
/// a running meter, a call, a half-filled onboarding, an admin editor, a
/// message being typed. Never reloaded without the user's say-so. Pure.
bool reloadWouldLoseWork(String path) {
  if (path == '/meter' || path.startsWith('/meter/')) return true;
  if (path.startsWith('/call/') || path.startsWith('/ride-call/')) return true;
  if (path.startsWith('/drive/onboarding')) return true;
  if (path.startsWith('/admin')) return true;
  return path.endsWith('/chat');
}

enum WebRefresh {
  /// Up to date, or nothing to compare.
  none,

  /// Behind: offer a reload.
  offer,

  /// Behind, and the tab is coming back after a long absence on a screen
  /// with nothing to lose: reload now.
  reload,
}

/// What to do now that [served] is the deployed build and [running] is this
/// tab's. [hiddenFor] is how long the tab was out of view, when it has just
/// come back into view; null otherwise. Pure.
WebRefresh decideWebRefresh({
  required String running,
  required String? served,
  required String path,
  Duration? hiddenFor,
}) {
  if (running.isEmpty || served == null || served == running) return WebRefresh.none;
  if (hiddenFor != null && hiddenFor >= webBuildIdleReload && !reloadWouldLoseWork(path)) {
    return WebRefresh.reload;
  }
  return WebRefresh.offer;
}
