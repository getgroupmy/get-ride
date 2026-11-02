import 'package:flutter/material.dart';

import '../../config.dart';
import '../../widgets/in_app_page.dart';
import 'voice_protection_card.dart' show privacyLinkColor;

/// What the passenger reads while their driver's VoiceProtection records the
/// trip (the owner's decision, migration 0335).
const driverRecordingNoticeText = 'Your driver is recording audio for safety';

/// The same for someone following another person's trip (a Family host).
const driverRecordingNoticeOtherText = 'The driver is recording audio for safety';

/// Where "Learn more" goes: the privacy policy's audio section.
String get driverRecordingLearnMoreUrl => '${AppConfig.privacyUrl}#audio';

/// The line on a passenger's trip screen while their driver's phone is
/// recording the trip, and nothing otherwise: the server says when
/// (ride_requests.driver_audio, on only while the trip is under way with
/// that driver), so it goes when recording stops or the trip ends.
class DriverRecordingNotice extends StatelessWidget {
  const DriverRecordingNotice({
    super.key,
    required this.recording,
    this.text = driverRecordingNoticeText,
    this.padding = const EdgeInsets.only(top: 8),
  });

  final bool recording;
  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (!recording) return const SizedBox.shrink();
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Padding(
      key: const ValueKey('driver-recording-notice'),
      padding: padding,
      child: Semantics(
        container: true,
        liveRegion: true,
        label: text,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Row(children: [
            ExcludeSemantics(child: Icon(Icons.fiber_manual_record, size: 14, color: cs.error)),
            const SizedBox(width: 6),
            ExcludeSemantics(child: Icon(Icons.mic_none, size: 18, color: cs.onSurface)),
            const SizedBox(width: 8),
            Expanded(
              child: ExcludeSemantics(
                child: Text(text, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            TextButton(
              key: const ValueKey('driver-recording-learn-more'),
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: privacyLinkColor(t),
              ),
              onPressed: () => openInApp(context, driverRecordingLearnMoreUrl, title: 'Privacy Notice'),
              child: const Text('Learn more'),
            ),
          ]),
        ),
      ),
    );
  }
}
