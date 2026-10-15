import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/admin_providers.dart' show adminAccessProvider;
import '../../config.dart';
import '../../core/backend_route.dart';
import '../../core/obd_adapters.dart';
import '../../data/obd/obd_session.dart';
import '../../data/permission_rules.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../safety/voice_protection_card.dart';
import 'app_icon_screen.dart';
import 'change_pin_screen.dart';
import 'navigation_app_card.dart';
import 'passkeys_screen.dart';
import 'permissions_card.dart';
import 'rules_terms_card.dart';
import 'show_location_screen.dart';
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
            const AppIconTile(),
            // Admin → App Settings → Permissions can hide it (0196).
            if (ref.watch(permissionRulesProvider).value?.showPermissionsCard ?? true) const PermissionsCard(),
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
                key: const ValueKey('change-pin'),
                leading: const Icon(Icons.password),
                // Expo: "Set PIN" for an account that has none yet.
                title: Text(ref.watch(pinSetProvider).value == false ? 'Set sign-in PIN' : 'Change sign-in PIN'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/account/settings/pin'),
              ),
            ),
            const PasskeysTile(),
            const ShowLocationTile(),
            const ObdReaderSettingsTile(),
            const RulesTermsCard(),
            Card(
              child: ListTile(
                key: const ValueKey('delete-account'),
                leading: Icon(Icons.person_remove_outlined, color: Theme.of(context).colorScheme.error),
                title: Text('Delete account', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/account/settings/delete'),
              ),
            ),
            const BackendSettingsTile(),
          ]),
        ),
      ]),
    );
  }
}

/// Which server the app talks to; shown to admins only.
class BackendSettingsTile extends ConsumerWidget {
  const BackendSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(adminAccessProvider).value?.isAdmin ?? false)) return const SizedBox.shrink();
    return Card(
      child: ListTile(
        key: const ValueKey('settings-backend'),
        leading: const Icon(Icons.storage_outlined),
        title: const Text('Backend'),
        // The second address when this network cannot look up the
        // project's own (core/backend_route.dart).
        subtitle: Text(backendRouteText(AppConfig.supabaseUrl)),
      ),
    );
  }
}

/// The reader the driver saved, for the Settings row.
final savedObdAdapterProvider = FutureProvider.autoDispose<SavedObdAdapter?>(
  (ref) => ref.watch(obdAdapterStoreProvider).current(),
);

/// Settings → OBD-II (CANBus) reader (Expo `settings.tsx`): for partners
/// only, naming the saved reader and opening the reader page, which drivers
/// could otherwise reach only from the meter.
class ObdReaderSettingsTile extends ConsumerWidget {
  const ObdReaderSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(partnerProvider).value == null) return const SizedBox.shrink();
    final saved = ref.watch(savedObdAdapterProvider).value;
    return Card(
      child: ListTile(
        key: const ValueKey('settings-obd-reader'),
        leading: const Icon(Icons.settings_input_component_outlined),
        title: const Text('OBD-II (CANBus) reader'),
        subtitle: Text(saved == null ? 'None set up' : '${saved.name} · ${describeAdapter(saved)}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await context.push('/meter/reader');
          ref.invalidate(savedObdAdapterProvider);
        },
      ),
    );
  }
}
