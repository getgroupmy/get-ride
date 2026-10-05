import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation_app.dart';
import '../../providers.dart';

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
            ListTile(
              key: ValueKey('nav-app-${app.name}'),
              leading: Icon(app == NavigationApp.waze ? Icons.navigation_outlined : Icons.map_outlined),
              title: Text(app.label),
              trailing: app == selected ? Icon(Icons.check, color: t.colorScheme.primary) : null,
              selected: app == selected,
              onTap: () => ref.read(navigationAppProvider.notifier).set(app),
            ),
        ],
      ),
    );
  }
}
