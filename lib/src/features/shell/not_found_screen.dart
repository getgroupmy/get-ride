import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/common.dart';

/// The router's error page ([GoRouter.errorBuilder]).
Widget notFoundPage(BuildContext context, GoRouterState state) => NotFoundScreen(location: state.uri.path);

/// What a link to no page in this app shows (the router's error page): an
/// old or mistyped address, with a way home rather than a dead end.
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key, this.location});

  /// The address that was asked for, shown so a wrong link can be reported.
  final String? location;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final path = (location ?? '').trim();
    return Scaffold(
      key: const ValueKey('not-found'),
      appBar: AppBar(title: const Text('Page not found')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ResponsiveCenter(
            maxWidth: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.explore_off_outlined, size: 64, color: t.colorScheme.primary),
                const SizedBox(height: 16),
                Text("We couldn't find that page", textAlign: TextAlign.center, style: t.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'The link may be old or mistyped. Everything else is where you left it.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                if (path.isNotEmpty && path != '/') ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    path,
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const ValueKey('not-found-home'),
                  onPressed: () => context.go('/'),
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('Go to home'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
