import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../data/voice_protection_repository.dart';
import 'voice_protection_controller.dart';
import '../../widgets/in_app_page.dart';

/// The VoiceProtection switch and what it means (Expo `app/safety.tsx`).
class VoiceProtectionCard extends ConsumerWidget {
  const VoiceProtectionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final s = ref.watch(voiceProtectionProvider);
    final supported = voiceRecordingSupported;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const ValueKey('voice-protection-switch'),
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.mic_none),
              title: const Text('VoiceProtection'),
              subtitle: Text(supported ? 'Record trip audio while you drive' : 'Available in the phone app'),
              value: s.enabled,
              onChanged: !s.loaded || (!supported && !s.enabled)
                  ? null
                  : (v) => ref.read(voiceProtectionProvider.notifier).setEnabled(v),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'When on, trip audio is recorded with your phone\'s microphone once a ride starts. Recordings stay '
                    'privately on your phone for 24 hours and are never accessible to you. They are only sent to our '
                    'team if a ride is reported to support and an agent asks for them.',
                    style: t.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'By turning this on, you and your passengers agree to the processing of personal data for '
                    'VoiceProtection, in line with the Privacy Notice.',
                    style: t.textTheme.bodySmall,
                  ),
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => openInApp(context, AppConfig.privacyUrl, title: 'Privacy Notice'),
                    child: const Text('Privacy Notice'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
