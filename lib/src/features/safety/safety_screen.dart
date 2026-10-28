import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/sos.dart';
import '../../data/geo_service.dart';
import '../../data/models.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../profile/emergency_contacts_screen.dart';
import 'voice_protection_card.dart';
import '../ride/trip_safety_parts.dart' show PassengerCoverCard;
import 'rider_audio_widgets.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/page_style_host.dart';

/// Opens [uri] (overridden in tests).
typedef UriLauncher = Future<bool> Function(Uri uri);

Future<bool> _launch(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Asks to confirm, then opens Messages with an SOS to every emergency
/// contact, carrying the current position when one can be read. With no
/// contacts it offers to add one instead.
Future<void> sendSos(
  BuildContext context,
  List<EmergencyContact> contacts, {
  String? driver,
  String? plate,
  UriLauncher launch = _launch,
  Future<({double lat, double lng})?> Function()? locate,
}) async {
  if (contacts.isEmpty) {
    final add = await showAppDialog<bool>(id: 'safety.no-emergency-contacts',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('No emergency contacts'),
        content: const Text('Add at least one trusted contact before using Emergency SOS.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Add contact'),
          ),
        ],
      ),
    );
    if (add == true && context.mounted) context.go('/account/emergency');
    return;
  }
  final names = contacts.map((c) => c.name).join(', ');
  final ok = await showAppDialog<bool>(id: 'safety.send-sos',
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Send Emergency SOS?'),
      content: Text(
        'We\'ll open Messages to alert ${contacts.length} contact${contacts.length > 1 ? 's' : ''} '
        '($names) with your location.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('sos-confirm'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 40), backgroundColor: Theme.of(c).colorScheme.error),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Send SOS'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final here =
      await (locate ??
          () async {
            final p = await currentPosition();
            return p == null ? null : (lat: p.latitude, lng: p.longitude);
          })();
  final uri = sosSmsUri(
    contacts.map((c) => c.phone).toList(),
    sosMessage(lat: here?.lat, lng: here?.lng, driver: driver, plate: plate),
    ios: _isIos,
  );
  var opened = false;
  try {
    opened = await launch(uri);
  } catch (_) {}
  if (!opened && context.mounted) {
    showInfo(context, "Couldn't open Messages. Please contact your emergency contacts directly.");
  }
}

/// Safety (Expo `app/safety.tsx`): emergency contacts, VoiceProtection and
/// the Emergency SOS button.
class SafetyScreen extends ConsumerWidget {
  const SafetyScreen({super.key, this.launch = _launch, this.locate});

  final UriLauncher launch;
  final Future<({double lat, double lng})?> Function()? locate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final contacts = ref.watch(emergencyContactsProvider);
    final noContacts = contacts.hasValue && (contacts.value ?? const []).isEmpty;
    return Scaffold(
      appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Safety')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.groups_outlined),
                        title: const Text('Emergency contacts'),
                        subtitle: Text(switch (contacts.value?.length) {
                          null => 'They get an SMS with your location when you send an SOS.',
                          0 => 'No contacts yet. Add a trusted contact.',
                          1 => '1 contact gets an SMS with your location when you send an SOS.',
                          final n => '$n contacts get an SMS with your location when you send an SOS.',
                        }),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/account/emergency'),
                      ),
                    ],
                  ),
                ),
                const VoiceProtectionCard(),
                // Passenger cover and permits (0311).
                const PassengerCoverCard(),
                // The rider's side (0315): their phone records their trips.
                const RiderAudioCard(),
                const SizedBox(height: 16),
                // No contacts: greyed, with the reason under it; a tap
                // still offers to add one.
                BusyButton.filled(
                  key: const ValueKey('safety-sos'),
                  style: noContacts
                      ? FilledButton.styleFrom(
                          minimumSize: const Size(0, 56),
                          backgroundColor: t.colorScheme.surfaceContainerHighest,
                          foregroundColor: t.colorScheme.onSurfaceVariant,
                        )
                      : FilledButton.styleFrom(
                          minimumSize: const Size(0, 56),
                          backgroundColor: t.colorScheme.error,
                          foregroundColor: t.colorScheme.onError,
                        ),
                  icon: const Icon(Icons.sos),
                  onPressed: contacts.isLoading
                      ? null
                      : () => sendSos(context, contacts.value ?? const [], launch: launch, locate: locate),
                  child: const Text('Emergency SOS'),
                ),
                if (noContacts) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Add a contact to enable',
                    key: const ValueKey('safety-sos-needs-contact'),
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'In immediate danger, call $emergencyNumber.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
