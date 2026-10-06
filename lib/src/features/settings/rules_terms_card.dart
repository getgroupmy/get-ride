import 'package:flutter/material.dart';
import '../../config.dart';
import '../../widgets/in_app_page.dart';

typedef LinkOpener = Future<void> Function(BuildContext context, String url, {String? title});

/// Settings → Rules & terms (Expo `rules-terms.tsx`, whose three rows did
/// nothing when tapped): the Terms of Service and Privacy Notice open on a
/// screen of the app with a back button, and Licenses lists the open-source
/// packages the app ships with.
class RulesTermsCard extends StatelessWidget {
  const RulesTermsCard({super.key, this.open = openInApp});

  final LinkOpener open;

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
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(context, AppConfig.termsUrl, title: 'Terms and conditions'),
          ),
          ListTile(
            key: const ValueKey('privacy-policy'),
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy Policy'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(context, AppConfig.privacyUrl, title: 'Privacy Policy'),
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
