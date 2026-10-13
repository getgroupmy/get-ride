import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/web_build.dart';
import '../../platform/web_page.dart';

/// Reads the deployed build id, or null when it cannot be read.
typedef WebBuildFetcher = Future<String?> Function();

Future<String?> _fetchServedBuild() async {
  try {
    // The query string keeps any cache between here and Vercel out of it.
    final url = Uri.base.resolve('$webBuildPath?t=${DateTime.now().millisecondsSinceEpoch}');
    final r = await http.get(url, headers: const {'cache-control': 'no-cache'}).timeout(const Duration(seconds: 10));
    return r.statusCode == 200 ? parseWebBuild(r.body) : null;
  } catch (_) {
    return null;
  }
}

/// On the website: notices when the site has been deployed again since this
/// tab loaded it, and offers a reload -- or reloads by itself when the tab
/// comes back after a long absence on a screen with nothing to lose (see
/// [decideWebRefresh]). Elsewhere, and on a build without an id, it is just
/// [child].
class WebBuildGate extends StatefulWidget {
  const WebBuildGate({
    super.key,
    required this.child,
    required this.location,
    this.running = webBuildId,
    this.fetchServed,
    this.reload,
    this.enabled = kIsWeb,
  });

  final Widget child;

  /// The current path, read when deciding whether a reload would lose work.
  final String Function() location;

  /// For tests; the defaults are the compiled-in id, /build.json and a page
  /// reload.
  final String running;
  final WebBuildFetcher? fetchServed;
  final VoidCallback? reload;
  final bool enabled;

  @override
  State<WebBuildGate> createState() => _WebBuildGateState();
}

class _WebBuildGateState extends State<WebBuildGate> {
  Timer? _timer;
  void Function()? _stopVisibility;
  DateTime? _hiddenAt;
  bool _checking = false;

  /// The newer build on offer, while the card is up.
  String? _offered;

  /// A build the user said "Later" to: not offered again.
  String? _declined;

  bool get _active => widget.enabled && widget.running.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (!_active) return;
    _timer = Timer.periodic(webBuildCheckEvery, (_) {
      if (!webPageHidden()) unawaited(_check());
    });
    _stopVisibility = onWebPageVisibility(_visibility);
    unawaited(_check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopVisibility?.call();
    super.dispose();
  }

  void _visibility(bool hidden) {
    if (hidden) {
      _hiddenAt = DateTime.now();
      return;
    }
    final away = _hiddenAt == null ? null : DateTime.now().difference(_hiddenAt!);
    _hiddenAt = null;
    unawaited(_check(hiddenFor: away));
  }

  Future<void> _check({Duration? hiddenFor}) async {
    if (_checking) return;
    _checking = true;
    try {
      final served = await (widget.fetchServed ?? _fetchServedBuild)();
      if (!mounted) return;
      final verdict = decideWebRefresh(
        running: widget.running,
        served: served,
        path: widget.location(),
        hiddenFor: hiddenFor,
      );
      switch (verdict) {
        case WebRefresh.none:
          break;
        case WebRefresh.reload:
          _reload();
        case WebRefresh.offer:
          if (served != _declined && served != _offered) setState(() => _offered = served);
      }
    } finally {
      _checking = false;
    }
  }

  void _reload() => (widget.reload ?? reloadWebPage)();

  @override
  Widget build(BuildContext context) {
    if (_offered == null) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: WebBuildCard(
                  onLater: () => setState(() {
                    _declined = _offered;
                    _offered = null;
                  }),
                  onReload: _reload,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "GET.ride has been updated": a reload, or later.
class WebBuildCard extends StatelessWidget {
  const WebBuildCard({super.key, required this.onLater, required this.onReload});

  final VoidCallback onLater;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.refresh, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(child: Text('GET.ride has been updated', style: Theme.of(context).textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 6),
            const Text('Reload this page to get the latest version.'),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onLater, child: const Text('Later')),
                // The theme's filled buttons are full width; this one sits in a row.
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(96, 40)),
                  onPressed: onReload,
                  child: const Text('Reload'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
