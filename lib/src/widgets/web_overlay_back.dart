// Browser Back closes the open sheet, modal or side menu on the web
// (core/overlay_back.dart): the browser's side of it, and the hooks
// [showAppSheet], [showAppDialog], [showAppGeneralDialog] and the side
// menus use. Off the web none of this does anything.
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

/// A sheet or modal route's entry: [wrap] the route's content (to find the
/// route) and [track] the future its `show…` call returns.
class OverlayRouteBack {
  OverlayRouteBack() {
    _entry = webOverlayBack.open(_close);
  }

  OverlayBackEntry? _entry;
  Route<dynamic>? _route;

  /// [child] as it is off the web; on it, under a lookup of its route.
  Widget wrap(Widget child) => _entry == null ? child : _RouteLookup(back: this, child: child);

  Future<T> track<T>(Future<T> shown) => _entry == null ? shown : shown.whenComplete(() => webOverlayBack.closed(_entry));

  /// A Back: closes the route, and what was opened over it.
  void _close() {
    final r = _route;
    final nav = r?.navigator;
    if (r == null || nav == null || !r.isActive) return;
    if (!r.isCurrent) nav.popUntil((x) => x == r);
    // One that won't close now (unsaved changes) stays open: it gets an
    // entry again before it is asked (and maybe opens its own question).
    if (r.popDisposition == RoutePopDisposition.doNotPop) _entry = webOverlayBack.open(_close);
    nav.maybePop();
  }
}

class _RouteLookup extends StatelessWidget {
  const _RouteLookup({required this.back, required this.child});

  final OverlayRouteBack back;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    back._route ??= ModalRoute.of(context);
    return child;
  }
}
