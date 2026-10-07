import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../../data/auth_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../safety/voice_protection_card.dart';
import 'navigation_app_card.dart';
import 'rules_terms_card.dart';
import '../../widgets/side_menu_host.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return Scaffold(
      appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Settings')),
      body: ListView(children: [
        ResponsiveCenter(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Appearance'),
                  const SizedBox(height: 8),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, label: Text('System')),
                      ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                    ],
                    selected: {mode},
                    onSelectionChanged: (v) => ref.read(themeModeProvider.notifier).set(v.first),
                  ),
                ]),
              ),
            ),
            const VoiceProtectionCard(),
            const NavigationAppCard(),
            Card(
              child: ListTile(
                key: const ValueKey('change-phone'),
                leading: const Icon(Icons.phone_iphone),
                title: const Text('Change phone number'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/account/settings/phone'),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.password),
                title: const Text('Change sign-in PIN'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  AuthRepository.pinSetupPending = true;
                  context.go('/login/set-pin?change=1');
                },
              ),
            ),
            const RulesTermsCard(),
            Card(
              child: ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('Backend'),
                subtitle: Text(Uri.parse(AppConfig.supabaseUrl).host),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
