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
import '../partner/ride_extras_parts.dart' show RideExtrasSettingsTile;
import '../safety/voice_protection_card.dart';
import 'app_icon_screen.dart';
import 'blocked_drivers_screen.dart';
import 'change_pin_screen.dart';
import 'map_settings_card.dart';
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
                  Text(
                    'Appearance',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(color: mutedTextColor(Theme.of(context))),
                  ),
                  const SizedBox(height: 8),
                  // The card's width, no tick, one line each: "System" never
                  // breaks in two at large text.
                  SegmentedButton<ThemeMode>(
                    expandedInsets: EdgeInsets.zero,
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, label: _OneLine('System')),
                      ButtonSegment(value: ThemeMode.light, label: _OneLine('Light')),
                      ButtonSegment(value: ThemeMode.dark, label: _OneLine('Dark')),
                    ],
                    selected: {mode},
                    onSelectionChanged: (v) => ref.read(themeModeProvider.notifier).set(v.first),
                  ),
                ]),
              ),
            ),
            // The home map: cars near me and the overlays (0322).
            const MapSettingsCard(),
            const AppIconTile(),
            // Admin → App Settings → Permissions can hide it (0196).
            if (ref.watch(permissionRulesProvider).value?.showPermissionsCard ?? true) const PermissionsCard(),
            // The switch alone here; the whole story is on the Safety page.
            const VoiceProtectionCard(compact: true),
            const NavigationAppCard(),
            // Riders: the drivers they blocked (0311).
            const BlockedDriversTile(),
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
            // Partners: the extras they take (0253).
            const RideExtrasSettingsTile(),
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

/// A segment's label on one line, shrunk to fit rather than broken.
class _OneLine extends StatelessWidget {
  const _OneLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));
}
