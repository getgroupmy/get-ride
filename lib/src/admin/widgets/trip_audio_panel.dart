import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/voice_protection.dart';
import '../../data/voice_protection_repository.dart';
import '../../providers.dart';
import 'admin_widgets.dart';

/// The user's VoiceProtection trip recordings, inside a support ticket
/// (Expo `AdminTripAudioPanel`). The audio lives on the user's phone: an
/// agent *requests* a recording, the phone uploads it, and it can then be
/// played from a one-hour link.
class TripAudioPanel extends ConsumerStatefulWidget {
  const TripAudioPanel({super.key, required this.profileId, required this.ticketId, required this.canEdit});

  final String profileId;
  final String ticketId;
  final bool canEdit;

  @override
  ConsumerState<TripAudioPanel> createState() => _TripAudioPanelState();
}

class _TripAudioPanelState extends ConsumerState<TripAudioPanel> {
  late final VoiceProtectionRepository _repo;
  Future<void> Function()? _unwatch;
  List<VoiceRecording>? _recordings;
  String? _busyId;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(voiceProtectionRepositoryProvider);
    _load();
    // Follows the phone answering a request.
    _unwatch = _repo.watch(widget.profileId, _load);
  }

  @override
  void dispose() {
    final stop = _unwatch;
    if (stop != null) unawaited(stop());
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await _repo.forProfile(widget.profileId);
      if (mounted) {
        setState(() {
          _recordings = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _request(VoiceRecording r) async {
    setState(() => _busyId = r.id);
    await runAdminAction(
      context,
      () => _repo.requestUpload(r.id, adminId: ref.read(currentUserIdProvider), ticketId: widget.ticketId),
      success: 'Asked the user\'s phone to upload it',
    );
    if (mounted) setState(() => _busyId = null);
    await _load();
  }

  Future<void> _play(VoiceRecording r) async {
    setState(() => _busyId = r.id);
    try {
      final url = await _repo.signedUrl(r.mediaUrl!);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open: $e')));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _recordings;
    final now = DateTime.now();
    final count = list?.length;
    return ExpansionTile(
      key: const ValueKey('trip-audio-panel'),
      leading: const Icon(Icons.graphic_eq),
      title: const Text('Trip audio (VoiceProtection)'),
      subtitle: Text(
        count == null
            ? (_error == null ? 'Loading…' : 'Could not load recordings')
            : count == 0
            ? 'No recordings'
            : '$count recording${count == 1 ? '' : 's'}',
      ),
      children: [
        if (list != null && list.isEmpty)
          const ListTile(
            dense: true,
            title: Text('This user has no trip recordings. VoiceProtection may be off on their phone.'),
          ),
        for (final r in list ?? const <VoiceRecording>[]) _row(r, recordingState(r, now)),
      ],
    );
  }

  Widget _row(VoiceRecording r, RecordingState s) {
    final busy = _busyId == r.id;
    final Widget? action = switch (s) {
      RecordingState.uploaded => TextButton.icon(
        onPressed: busy ? null : () => _play(r),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Play'),
      ),
      RecordingState.onDevice when widget.canEdit => TextButton(
        onPressed: busy ? null : () => _request(r),
        child: const Text('Request'),
      ),
      _ => null,
    };
    return ListTile(
      dense: true,
      title: Text(r.rideLabel ?? r.rideId ?? 'Trip'),
      subtitle: Text(
        '${dateText(r.recordedAt.toIso8601String())} · ${formatRecordingDuration(r.durationSec)}'
        ' · ${recordingStateLabel(s)}',
      ),
      trailing: action,
    );
  }
}
