// Browser Back closes the open sheet, modal or side menu on the web
// (core/overlay_back.dart): the browser's side of it, the navigator
// observer that gives every popup route (sheets, dialogs, menus, pickers)
// an entry, and the hook the side menus use. Off the web none of this does
// anything.
//
// Flutter's web engine answers a browser Back by handing the router the
// address of the entry it landed on (`pushRouteInformation`), never as a
// "pop": a [PopScope] or [BackButtonDispatcher] never hears of it, and
// go_router simply goes there, under whatever was open. So each overlay
// gets an entry of its own, pushed through the engine like the router's
// (so the engine's own bookkeeping stays right) with the page's state plus
// a marker, and [_BackObserver] sees the Back before the router does.
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import '../core/overlay_back.dart';

/// The open overlays' browser history entries (switched off off the web).
OverlayBackStack get webOverlayBack => _stack;
OverlayBackStack _stack = OverlayBackStack(_BrowserHistory(), enabled: kIsWeb);

/// Swaps in [stack] (a test's, over a fake history).
@visibleForTesting
set webOverlayBack(OverlayBackStack stack) => _stack = stack;

/// Where the router is, to put its address back after a move that undid a
/// navigation (set by [attachWebOverlayBack]).
RouteInformation Function()? _routerAt;
_BackObserver? _observer;

/// Hooks browser Back in on the web, ahead of the router. Call before the
/// router's widget is first built: the first observer to take a Back wins,
/// and the router's takes every one.
void attachWebOverlayBack(RouteInformation Function() routerAt) {
  _routerAt = routerAt;
  if (!kIsWeb || _observer != null) return;
  WidgetsBinding.instance.addObserver(_observer = _BackObserver());
}

class _BackObserver with WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) => SynchronousFuture(
    webOverlayBack.onPop(overlayMarkerIn(routeInformation.state), _address(routeInformation.uri)),
  );
}

/// [uri]'s path and query, as the browser shows them.
String _address(Uri uri) => '${uri.path.isEmpty ? '/' : uri.path}?${uri.query}';

class _BrowserHistory implements OverlayHistory {
  @override
  String get page => _address(Uri.parse(urlStrategy?.getPath() ?? '/'));

  @override
  Future<void> push(String marker) async {
    final s = urlStrategy;
    if (s == null) return;
    // The engine keeps the router's state under 'state'; the new entry
    // keeps it too, so the router can still read the entry if it lands
    // there some other way (Forward, after a reload).
    final current = s.getState();
    final inner = current is Map ? current['state'] : null;
    await SystemNavigator.routeInformationUpdated(
      uri: Uri.parse(s.getPath()),
      state: <Object?, Object?>{if (inner is Map) ...inner, overlayBackMarkerKey: marker},
    );
  }

  @override
  void go(int delta) => urlStrategy?.go(delta);

  @override
  Future<void> settled() async {
    // Chrome drops an entry pushed while a move back is still on its way:
    // a menu row that closes the menu and opens another page leaves the
    // old address showing. Once the router has reported where it is, put
    // its address back when the browser shows another.
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(Duration.zero);
    final want = _routerAt?.call();
    final s = urlStrategy;
    if (want == null || s == null) return;
    if (_address(want.uri) == _address(Uri.parse(s.getPath()))) return;
    await SystemNavigator.routeInformationUpdated(uri: want.uri, state: want.state);
  }
}

/// The navigator observers that give every popup route (sheets, dialogs,
/// dropdown and popup menus, date and time pickers, search pickers) its
/// own browser history entry, on the web; null off it. One on the router
/// covers its shells' navigators too (go_router hands them its observers).
List<NavigatorObserver>? webOverlayBackObservers() => kIsWeb ? [WebOverlayBackObserver()] : null;

/// Each open popup route's entry, whichever navigator it is on.
final _routeEntries = Expando<OverlayBackEntry>('overlay back');

/// Gives each popup route pushed on its navigator a browser history entry
/// (core/overlay_back.dart): a Back closes the top one, so a menu open
/// over a dialog closes first and the dialog with the next Back. Full
/// pages ([PageRoute]) are left to the router.
class WebOverlayBackObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _track(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _release(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _release(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _release(oldRoute);
    if (newRoute != null) _track(newRoute);
  }

  static void _track(Route<dynamic> route) {
    if (route is! PopupRoute) return;
    if (_routeEntries[route]?.isOpen ?? false) return;
    _routeEntries[route] = webOverlayBack.open(() => _close(route));
  }

  static void _release(Route<dynamic> route) {
    final e = _routeEntries[route];
    if (e == null) return;
    _routeEntries[route] = null;
    webOverlayBack.closed(e);
  }

  /// A Back: closes [route], and what was opened over it.
  static void _close(Route<dynamic> route) {
    final nav = route.navigator;
    if (nav == null || !route.isActive) return;
    if (!route.isCurrent) nav.popUntil((x) => x == route);
    // One that won't close now (unsaved changes) stays open: it gets an
    // entry again before it is asked (and maybe opens its own question).
    if (route.popDisposition == RoutePopDisposition.doNotPop) {
      _routeEntries[route] = webOverlayBack.open(() => _close(route));
    }
    nav.maybePop();
  }
}
