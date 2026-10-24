// Voice notes in the chats: the player in a message bubble and the bar the
// composer turns into while recording. Both follow the app's light or dark
// theme through the colours they're handed or the colour scheme.
import 'dart:async';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ride_chat.dart' show formatVoiceDuration;
import 'app_notice.dart';

/// Plays one voice note.
abstract class VoicePlayback {
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<void> get completed;
  Future<void> play(String url);
  Future<void> pause();
  Future<void> resume();
  Future<void> dispose();
}

class _DevicePlayback implements VoicePlayback {
  final _p = ap.AudioPlayer();

  @override
  Stream<Duration> get position => _p.onPositionChanged;
  @override
  Stream<Duration> get duration => _p.onDurationChanged;
  @override
  Stream<void> get completed => _p.onPlayerComplete;
  @override
  Future<void> play(String url) => _p.play(ap.UrlSource(url));
  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> resume() => _p.resume();
  @override
  Future<void> dispose() => _p.dispose();
}

/// A new player for each voice note that is played (overridden in tests).
final voicePlaybackFactoryProvider = Provider<VoicePlayback Function()>((ref) => _DevicePlayback.new);

/// The voice note that is playing, so starting one pauses the other.
VoidCallback? _pauseOther;

/// A voice note in a bubble: play / pause, how far it has got, and its
/// length. The player is only made on the first tap, and the file's link is
/// only asked for then ([url]).
class VoiceNotePlayer extends ConsumerStatefulWidget {
  const VoiceNotePlayer({super.key, required this.url, this.length, required this.color});

  final Future<String> Function() url;
  final Duration? length;

  /// The bubble's text colour.
  final Color color;

  @override
  ConsumerState<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends ConsumerState<VoiceNotePlayer> {
  VoicePlayback? _player;
  final _subs = <StreamSubscription<dynamic>>[];
  bool _playing = false;
  bool _loading = false;
  bool _started = false;
  Duration _at = Duration.zero;
  Duration? _length;

  @override
  void initState() {
    super.initState();
    _length = widget.length;
  }

  @override
  void dispose() {
    if (_pauseOther == _pause) _pauseOther = null;
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  void _pause() {
    _player?.pause();
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _toggle() async {
    if (_loading) return;
    if (_playing) return _pause();
    if (_pauseOther != _pause) _pauseOther?.call();
    _pauseOther = _pause;
    if (_started) {
      setState(() => _playing = true);
      await _player!.resume();
      return;
    }
    setState(() => _loading = true);
    try {
      final p = _player ??= ref.read(voicePlaybackFactoryProvider)();
      if (_subs.isEmpty) {
        _subs
          ..add(p.position.listen((d) => mounted ? setState(() => _at = d) : null))
          ..add(p.duration.listen((d) => mounted && d > Duration.zero ? setState(() => _length = d) : null))
          ..add(
            p.completed.listen((_) {
              _started = false;
              if (mounted) {
                setState(() {
                  _playing = false;
                  _at = Duration.zero;
                });
              }
            }),
          );
      }
      await p.play(await widget.url());
      _started = true;
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) {
        unawaited(showAppNotice(
          id: 'notice.voice-note',
          context: context,
          message: "Couldn't play that voice note.",
          kind: NoticeKind.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    final len = _length;
    final progress = len == null || len.inMilliseconds <= 0
        ? 0.0
        : (_at.inMilliseconds / len.inMilliseconds).clamp(0.0, 1.0);
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('voice-note-play'),
            tooltip: _playing ? 'Pause' : 'Play voice note',
            color: c,
            onPressed: _toggle,
            icon: _loading
                ? SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: c))
                : Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 32),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    color: c,
                    backgroundColor: c.withValues(alpha: 0.25),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _playing || _at > Duration.zero
                      ? formatVoiceDuration(_at)
                      : (len == null ? 'Voice note' : formatVoiceDuration(len)),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: c),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The composer while a voice note is being recorded: throw it away, how
/// long it is so far, and send.
class VoiceRecordingBar extends StatelessWidget {
  const VoiceRecordingBar({
    super.key,
    required this.elapsed,
    required this.max,
    required this.onCancel,
    required this.onSend,
  });

  final Duration elapsed;
  final Duration max;
  final VoidCallback? onCancel;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Row(
      key: const ValueKey('voice-recording'),
      children: [
        IconButton(
          key: const ValueKey('voice-cancel'),
          tooltip: 'Delete recording',
          color: cs.error,
          onPressed: onCancel,
          icon: const Icon(Icons.delete_outline),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(24)),
            child: Row(
              children: [
                Icon(Icons.fiber_manual_record, size: 14, color: cs.error),
                const SizedBox(width: 8),
                Text(
                  formatVoiceDuration(elapsed),
                  style: t.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Recording… up to ${formatVoiceDuration(max)}',
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          key: const ValueKey('voice-send'),
          tooltip: 'Send voice note',
          onPressed: onSend,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }
}
