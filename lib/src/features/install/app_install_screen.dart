// getride.my/install/<ios|android>: what a tester opens (or scans from
// Admin → App Release) to install the latest build directly. Public, like a
// shared ride: a tester installing the app has no account in it yet.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_builds.dart';
import '../../widgets/app_build_widgets.dart';

class AppInstallScreen extends ConsumerWidget {
  const AppInstallScreen({super.key, required this.platform});

  final String platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ios = platform == 'ios';
    final other = ios ? 'android' : 'ios';
    final wide = MediaQuery.sizeOf(context).width >= 720;

    if (!appBuildPlatforms.contains(platform)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Install GET.ride')),
        body: const Center(child: Text('There is no build for that platform.')),
      );
    }

    final build = ref.watch(appBuildProvider(platform));
    return Scaffold(
      appBar: AppBar(title: Text('GET.ride for ${ios ? 'iPhone' : 'Android'}')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                AppInstallHeader(platform: platform),
                const SizedBox(height: 24),
                build.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Column(
                    children: [
                      Text(
                        "Couldn't load the latest build.",
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => ref.invalidate(appBuildProvider(platform)),
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                  data: (b) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (b.available) ...[
                        Text(appBuildSummary(b), textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
                        const SizedBox(height: 16),
                        if (b.installable) AppInstallButton(app: b),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        appInstallHint(b),
                        key: const ValueKey('app-install-hint'),
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (b.available) ...[const SizedBox(height: 8), AppDownloadButton(app: b)],
                      // On a computer: the phone scans this page's own address.
                      if (wide && b.installable) ...[
                        const SizedBox(height: 24),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                            child: QrImageView(
                              data: appInstallPageUrl(platform),
                              size: 180,
                              backgroundColor: Colors.white,
                              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                              dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.square,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'On a computer? Scan this with the ${ios ? 'iPhone' : 'Android phone'}.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () => context.go('/install/$other'),
                  child: Text('Looking for ${other == 'ios' ? 'iPhone' : 'Android'}?'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
