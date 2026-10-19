import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../../data/voice_protection_repository.dart';
import '../../widgets/busy.dart';
import 'voice_protection_controller.dart';
import '../../widgets/in_app_page.dart';

/// Link blue that reads on the card in both themes (4.5:1).
Color privacyLinkColor(ThemeData t) =>
    t.brightness == Brightness.dark ? const Color(0xFF7CC4F0) : const Color(0xFF0C6AA6);

/// The VoiceProtection switch and what it means (Expo `app/safety.tsx`).
/// [compact] (Settings): the switch with a one-line summary and "Learn
/// more" to the whole card on the Safety page, where it also lives; the
/// two paragraphs and the Privacy Notice pushed the rest of Settings below
/// the fold on a small phone.
class VoiceProtectionCard extends ConsumerWidget {
  const VoiceProtectionCard({super.key, this.compact = false});

  final bool compact;

  /// Where the whole card is.
  static const safetyPage = '/account/safety';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final s = ref.watch(voiceProtectionProvider);
    final supported = voiceRecordingSupported;
    final toggle = BusySwitchListTile(
      key: const ValueKey('voice-protection-switch'),
      contentPadding: EdgeInsets.zero,
      secondary: const Icon(Icons.mic_none),
      title: const Text('VoiceProtection'),
      subtitle: Text(
        !supported
            ? 'Available in the phone app'
            : compact
            ? 'Records trip audio, kept on your phone for 24 hours'
            : 'Record trip audio while you drive',
      ),
      value: s.enabled,
      onChanged: !s.loaded || (!supported && !s.enabled)
          ? null
          : (v) => ref.read(voiceProtectionProvider.notifier).setEnabled(v),
    );
    if (compact) {
      return Card(
        key: const ValueKey('voice-protection-compact'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              toggle,
              TextButton(
                key: const ValueKey('voice-protection-learn-more'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(44, 44),
                  foregroundColor: privacyLinkColor(t),
                ),
                onPressed: () => context.push(safetyPage),
                child: const Text('Learn more'),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            toggle,
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
                  // A link that looks like one: link colour, underlined, an arrow.
                  TextButton.icon(
                    key: const ValueKey('voice-privacy-link'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      foregroundColor: privacyLinkColor(t),
                      textStyle: const TextStyle(decoration: TextDecoration.underline, fontWeight: FontWeight.w600),
                    ),
                    onPressed: () => openInApp(context, AppConfig.privacyUrl, title: 'Privacy Notice'),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Privacy Notice'),
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
