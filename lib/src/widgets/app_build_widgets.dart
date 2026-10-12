// The latest downloadable build: fetching it from the `app-install` edge
// function, and the Download / Share install link / QR code actions that
// Admin → App Release and the public install page share.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_builds.dart';
import '../core/format.dart';
import '../providers.dart';

/// The latest published build for a platform ('ios' / 'android').
final appBuildProvider = FutureProvider.autoDispose.family<AppBuild, String>((ref, platform) async {
  final res = await ref
      .watch(supabaseProvider)
      .functions
      .invoke('app-install', method: HttpMethod.get, queryParameters: {'platform': platform});
  return AppBuild.fromJson(platform, res.data);
});

/// Sends an install link: the system share sheet, overridden in tests.
final appInstallSharerProvider = Provider<Future<void> Function(String text)>(
  (ref) => (text) async {
    try {
      await SharePlus.instance.share(ShareParams(text: text, subject: 'Install GET.ride'));
    } catch (_) {
      // No share sheet (some desktops): the link goes on the clipboard.
      await Clipboard.setData(ClipboardData(text: text));
    }
  },
);

/// Opens a download or an install link outside the app (the browser hands
/// an APK to Android's installer; Safari reads an itms-services link).
final appLinkOpenerProvider = Provider<Future<bool> Function(String url)>(
  (ref) =>
      (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication, webOnlyWindowName: '_self'),
);

Future<void> _open(BuildContext context, WidgetRef ref, String url) async {
  var ok = false;
  try {
    ok = await ref.read(appLinkOpenerProvider)(url);
  } catch (_) {}
  if (!ok && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not open $url')));
  }
}

/// "1.4.3 (107) · 52.3 MB · 12 Oct 2026 13:20".
String appBuildSummary(AppBuild b) => [
  b.label,
  if (formatBuildSize(b.size).isNotEmpty) formatBuildSize(b.size),
  if (b.createdAt != null) formatDateTime(b.createdAt),
].join(' · ');

/// The QR code a tester scans to open the install page, with its link.
Future<void> showAppInstallQr(BuildContext context, AppBuild b) {
  final url = appInstallPageUrl(b.platform);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Install on ${b.ios ? 'iPhone' : 'Android'}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // White, whatever the theme: a scanner needs dark modules on light.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            // A fixed box: a dialog measures its content, and the QR's own
            // layout builder can't be measured.
            child: SizedBox.square(
              dimension: 220,
              child: QrImageView(
                key: const ValueKey('app-install-qr'),
                data: url,
                size: 220,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(b.label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(url, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Text(
            b.ios
                ? 'Scan with the iPhone camera, then tap Install on the page that opens.'
                : 'Scan with the Android phone, then tap Install on the page that opens.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Link copied')));
            }
          },
          child: const Text('Copy link'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    ),
  );
}

/// The latest build and what can be done with it, for Admin → App Release.
class AppBuildPanel extends ConsumerWidget {
  const AppBuildPanel({super.key, required this.platform});

  final String platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final build = ref.watch(appBuildProvider(platform));
    return build.when(
      loading: () => const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator()),
      error: (e, _) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.error_outline),
        title: const Text("Couldn't load the latest build"),
        subtitle: Text('$e'),
        trailing: IconButton(
          tooltip: 'Try again',
          onPressed: () => ref.invalidate(appBuildProvider(platform)),
          icon: const Icon(Icons.refresh),
        ),
      ),
      data: (b) {
        if (!b.available) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No build to download yet. The next release publishes one here.',
              style: theme.textTheme.bodySmall,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(appBuildSummary(b), key: const ValueKey('app-build-summary'), style: theme.textTheme.bodyMedium),
            if (b.ios && !b.installable) ...[
              const SizedBox(height: 4),
              Text(appInstallHint(b), style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: ValueKey('app-build-download-$platform'),
                  onPressed: () => _open(context, ref, b.downloadUrl!),
                  icon: const Icon(Icons.download_outlined),
                  label: Text('Download .${b.ios ? 'ipa' : 'apk'}'),
                ),
                if (b.installable) ...[
                  OutlinedButton.icon(
                    key: ValueKey('app-build-share-$platform'),
                    onPressed: () => ref.read(appInstallSharerProvider)(appInstallShareText(b)),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share install link'),
                  ),
                  OutlinedButton.icon(
                    key: ValueKey('app-build-qr-$platform'),
                    onPressed: () => showAppInstallQr(context, b),
                    icon: const Icon(Icons.qr_code_2),
                    label: const Text('QR code'),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The install button on the public page: an itms-services link on iPhone,
/// the APK on Android.
class AppInstallButton extends ConsumerWidget {
  const AppInstallButton({super.key, required this.app});

  final AppBuild app;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilledButton.icon(
    key: const ValueKey('app-install-button'),
    onPressed: app.installable && app.installUrl != null ? () => _open(context, ref, app.installUrl!) : null,
    icon: const Icon(Icons.install_mobile),
    label: Text('Install ${app.label}'),
  );
}

/// Downloading the file itself, on the public page.
class AppDownloadButton extends ConsumerWidget {
  const AppDownloadButton({super.key, required this.app});

  final AppBuild app;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
    onPressed: app.downloadUrl == null ? null : () => _open(context, ref, app.downloadUrl!),
    icon: const Icon(Icons.download_outlined),
    label: Text('Download ${app.fileName}'),
  );
}
