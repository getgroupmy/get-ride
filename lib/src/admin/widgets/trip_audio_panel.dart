import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/voice_protection.dart';
import '../../data/voice_protection_repository.dart';
import '../../providers.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import 'admin_widgets.dart';
import '../../widgets/in_app_page.dart';

/// Trip recordings, inside a support ticket (the user's: Expo
/// `AdminTripAudioPanel`) or on a ride's page (the driver's VoiceProtection
/// and the rider's audio protection, migration 0315). The audio lives on the
/// phone that recorded it: an agent *requests* a recording, the phone
/// uploads it, and it can then be played from a one-hour link.
class TripAudioPanel extends ConsumerStatefulWidget {
  const TripAudioPanel({super.key, required String this.profileId, required String this.ticketId, required this.canEdit})
    : rideId = null;

  /// A ride's recordings, whoever's phone made them.
  const TripAudioPanel.forRide({super.key, required String this.rideId, required this.canEdit})
    : profileId = null,
      ticketId = null;

  final String? profileId;
  final String? rideId;
  final String? ticketId;
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
    final ride = widget.rideId;
    _unwatch = ride != null ? _repo.watchRide(ride, _load) : _repo.watch(widget.profileId!, _load);
  }

  @override
  void dispose() {
    final stop = _unwatch;
    if (stop != null) unawaited(stop());
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ride = widget.rideId;
      final list = ride != null ? await _repo.forRide(ride) : await _repo.forProfile(widget.profileId!);
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
      if (!mounted) return;
      await openStoredFile(context, url, title: 'Trip recording');
    } catch (e) {
      if (mounted) {
        unawaited(showAppNotice(
          id: 'notice.admin-trip-audio',
          context: context,
          message: 'Could not open: $e',
          kind: NoticeKind.error,
        ));
      }
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
      title: Text(widget.rideId != null ? 'Trip audio' : 'Trip audio (VoiceProtection)'),
      subtitle: Text(
        count == null
            ? (_error == null ? 'Loading…' : 'Could not load recordings')
            : count == 0
            ? 'No recordings'
            : '$count recording${count == 1 ? '' : 's'}',
      ),
      children: [
        if (list != null && list.isEmpty)
          ListTile(
            dense: true,
            title: Text(
              widget.rideId != null
                  ? 'No recordings of this ride. Neither the driver nor the rider had audio protection on.'
                  : 'This user has no trip recordings. VoiceProtection may be off on their phone.',
            ),
          ),
        for (final r in list ?? const <VoiceRecording>[]) _row(r, recordingState(r, now)),
      ],
    );
  }

  Widget _row(VoiceRecording r, RecordingState s) {
    final busy = _busyId == r.id;
    final Widget? action = switch (s) {
      RecordingState.uploaded => BusyButton.text(
        onPressed: busy ? null : () => _play(r),
        icon: const Icon(Icons.play_arrow),
        child: const Text('Play'),
      ),
      RecordingState.onDevice when widget.canEdit => BusyButton.text(

        onPressed: busy ? null : () => _request(r),
        child: const Text('Request'),
      ),
      _ => null,
    };
    return ListTile(
      dense: true,
      title: Text(r.rideLabel ?? r.rideId ?? 'Trip'),
      subtitle: Text(
        '${r.byRider ? "Rider's phone" : "Driver's phone"} · '
        '${dateText(r.recordedAt.toIso8601String())} · ${formatRecordingDuration(r.durationSec)}'
        ' · ${recordingStateLabel(s)}',
      ),
      trailing: action,
    );
  }
}
