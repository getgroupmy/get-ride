import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';

typedef LinkLauncher = Future<bool> Function(Uri uri);

Future<bool> _openExternal(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

/// Settings → Rules & terms (Expo `rules-terms.tsx`, whose three rows did
/// nothing when tapped): the Terms of Service and Privacy Notice open in the
/// browser, and Licenses lists the open-source packages the app ships with.
class RulesTermsCard extends StatelessWidget {
  const RulesTermsCard({super.key, this.launch = _openExternal});

  final LinkLauncher launch;

  Future<void> _open(BuildContext context, String url) async {
    var ok = false;
    try {
      ok = await launch(Uri.parse(url));
    } catch (_) {}
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Rules & terms', style: Theme.of(context).textTheme.titleSmall),
          ),
          ListTile(
            key: const ValueKey('terms-of-service'),
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('Terms and conditions'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _open(context, AppConfig.termsUrl),
          ),
          ListTile(
            key: const ValueKey('privacy-policy'),
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy Policy'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _open(context, AppConfig.privacyUrl),
          ),
          ListTile(
            key: const ValueKey('licenses'),
            leading: const Icon(Icons.description_outlined),
            title: const Text('Licenses'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'GET.ride',
              applicationVersion: AppConfig.appVersion,
            ),
          ),
        ],
      ),
    );
  }
}
