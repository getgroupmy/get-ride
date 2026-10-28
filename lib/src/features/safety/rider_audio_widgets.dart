// Rider audio protection (migration 0315) in the apps: the rider's switch
// on the booking sheet and the Safety page, the line on the rider's ride
// screen while it records, and the driver's "Audio protection on (rider)".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../core/rider_audio.dart';
import '../../data/models.dart';
import '../../data/rider_audio_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/in_app_page.dart';
import '../../widgets/page_style_host.dart';
import '../ride/confirm_parts.dart' show ConfirmSwitch;
import 'rider_audio_controller.dart';
import 'voice_protection_card.dart' show privacyLinkColor;

/// Asks before turning it on: what is recorded, for how long, who can hear
/// it, and that the driver is told. True: turn it on.
Future<bool> confirmRiderAudio(BuildContext context, RiderAudioAt at) async =>
    await showAppDialog<bool>(
      id: 'safety.rider-audio-consent',
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('rider-audio-consent'),
        icon: const Icon(Icons.mic_none),
        title: const Text('Turn on audio protection?'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(riderAudioConsent(at)),
            const SizedBox(height: 8),
            Text(riderAudioPrivacyLine, style: Theme.of(ctx).textTheme.bodySmall),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Not now')),
          FilledButton(
            key: const ValueKey('rider-audio-consent-on'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    ) ==
    true;

Future<void> _toggle(BuildContext context, WidgetRef ref, bool v, RiderAudioAt at) async {
  if (v && !await confirmRiderAudio(context, at)) return;
  await ref.read(riderAudioProvider.notifier).setEnabled(v);
}

/// The "Audio protection" row on the booking sheet (under My Ride): the
/// switch and what it does at this pickup. None where it isn't offered or
/// off the phone apps.
class RiderAudioConfirmRow extends ConsumerWidget {
  const RiderAudioConfirmRow({super.key, required this.lat, required this.lng});

  final double lat, lng;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!riderAudioSupported) return const SizedBox.shrink();
    final s = ref.watch(riderAudioProvider);
    final at = ref.watch(riderAudioAtProvider((lat: _round(lat), lng: _round(lng)))).value;
    if (at == null || !at.enabled) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      key: const ValueKey('rider-audio-row'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, shape: BoxShape.circle),
          child: Icon(Icons.mic_none, size: 18, color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Audio protection', style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text(riderAudioSummary(at), style: t.textTheme.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
          ]),
        ),
        ConfirmSwitch(
          key: const ValueKey('rider-audio-switch'),
          semanticLabel: 'Audio protection',
          value: s.enabled,
          onChanged: !s.loaded ? null : (v) => _toggle(context, ref, v, at),
        ),
      ]),
    );
  }

  // About 100 m: the answer is the same across a pickup's small moves.
  static double _round(double v) => (v * 1000).roundToDouble() / 1000;
}

/// The Safety page's card: the switch, what it means, and the Privacy Notice.
class RiderAudioCard extends ConsumerWidget {
  const RiderAudioCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final s = ref.watch(riderAudioProvider);
    final supported = riderAudioSupported;
    // Where the rider is isn't known here: the Default rule's words. The
    // booking sheet says what holds at the pickup.
    const at = RiderAudioAt.fallback;
    return Card(
      key: const ValueKey('rider-audio-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          BusySwitchListTile(
            key: const ValueKey('rider-audio-safety-switch'),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.mic_none),
            title: const Text('Audio protection'),
            subtitle: Text(supported ? 'Record the trip when you ride' : 'Available in the phone app'),
            value: s.enabled,
            onChanged: !s.loaded || (!supported && !s.enabled) ? null : (v) => _toggle(context, ref, v, at),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'When on, the trip is recorded with your phone\'s microphone once your driver starts it. '
                'Recordings are encrypted, stay on your phone for the hours set where you ride (usually 24), '
                'and are never playable in the app. They are only sent to our team if a ride is reported to '
                'support and an agent asks for them. Your driver sees that audio protection is on.',
                style: t.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(riderAudioPrivacyLine, style: t.textTheme.bodySmall),
              TextButton.icon(
                key: const ValueKey('rider-audio-privacy-link'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: privacyLinkColor(t),
                  textStyle: const TextStyle(decoration: TextDecoration.underline, fontWeight: FontWeight.w600),
                ),
                onPressed: () => openInApp(context, AppConfig.privacyUrl, title: 'Privacy Notice'),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Privacy Notice'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// On the rider's ride screen: "Audio protection recording" while this ride
/// is recorded, or why it isn't.
class RiderAudioTripLine extends ConsumerWidget {
  const RiderAudioTripLine({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(riderAudioProvider);
    final recording = s.recordingRideId == ride.id;
    final why = ride.riderAudio && ride.status == RideStatus.onTrip ? s.error : null;
    if (!recording && why == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      key: const ValueKey('rider-audio-trip-line'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(recording ? Icons.fiber_manual_record : Icons.mic_off_outlined,
            size: 16, color: recording ? t.colorScheme.error : t.colorScheme.outline),
        const SizedBox(width: 6),
        Expanded(child: Text(recording ? 'Audio protection recording' : why!, style: t.textTheme.bodySmall)),
      ]),
    );
  }
}

/// The driver's line on a ride the rider records.
class RiderAudioDriverLine extends StatelessWidget {
  const RiderAudioDriverLine({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context) {
    if (!ride.riderAudio) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      key: const ValueKey('rider-audio-driver-line'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(Icons.mic_none, size: 16, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(riderAudioDriverLine, style: t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}
