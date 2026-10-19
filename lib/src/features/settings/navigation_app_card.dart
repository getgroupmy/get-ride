import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:url_launcher/url_launcher.dart';

import '../../core/navigation_app.dart';
import '../../providers.dart';

/// Whether Waze is on this phone: the app's own `waze://` link can be
/// opened (Android and iOS declare the scheme for this). Null where it
/// can't be told (the web, a computer). Overridden in tests.
final wazeInstalledProvider = FutureProvider<bool?>((ref) async {
  if (kIsWeb) return null;
  if (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS) return null;
  try {
    return await canLaunchUrl(Uri.parse('waze://'));
  } catch (_) {
    return null;
  }
});

/// Under Waze: what Navigate does with it. Its link opens the Waze app
/// where installed, else Waze's own website (navigationUri).
const wazeHint = 'Opens Waze if installed, otherwise the Waze website.';

/// Under Waze where the phone says it isn't there.
const wazeNotInstalled = 'Not installed';

bool get _applePlatform =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS);

/// Settings → Navigation app: what the driver's Navigate button opens.
class NavigationAppCard extends ConsumerWidget {
  const NavigationAppCard({super.key, this.apple});

  /// Whether to offer Apple Maps; the platform decides when null.
  final bool? apple;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(navigationAppProvider);
    final waze = ref.watch(wazeInstalledProvider).value;
    final apps = navigationAppsFor(apple: apple ?? _applePlatform);
    final t = Theme.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('Navigation app', style: t.textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('Opened by Navigate on a trip.', style: t.textTheme.bodySmall),
          ),
          for (final app in apps)
            () {
              // Greyed out only where the phone can say Waze is missing.
              final missing = app == NavigationApp.waze && waze == false;
              return ListTile(
                key: ValueKey('nav-app-${app.name}'),
                enabled: !missing,
                leading: Icon(app == NavigationApp.waze ? Icons.navigation_outlined : Icons.map_outlined),
                title: Text(app.label),
                subtitle: app != NavigationApp.waze
                    ? null
                    : Text(
                        missing ? '$wazeNotInstalled. $wazeHint' : wazeHint,
                        key: const ValueKey('nav-app-waze-hint'),
                      ),
                trailing: app == selected ? Icon(Icons.check, color: t.colorScheme.primary) : null,
                selected: app == selected,
                // Neutral in both themes: the tick carries the choice (dark
                // mode painted the whole row in the accent).
                selectedColor: t.colorScheme.onSurface,
                selectedTileColor: Colors.transparent,
                onTap: () => ref.read(navigationAppProvider.notifier).set(app),
              );
            }(),
        ],
      ),
    );
  }
}
