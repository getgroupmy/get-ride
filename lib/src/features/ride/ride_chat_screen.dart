import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../core/format.dart';
import '../../core/ride_chat.dart';
import '../../core/ble_chat.dart';
import '../../core/ride_chat_outbox.dart';
import '../../data/models.dart';
import '../../data/photo_picker.dart';
import '../../data/reliability_repository.dart';
import '../../data/ble_chat.dart';
import '../../data/ride_chat_outbox.dart';
import '../../data/ride_chat_repository.dart';
import '../../data/voice_recorder.dart';
import '../../providers.dart';
import '../../widgets/chat_photo.dart';
import '../../widgets/common.dart';
import '../../widgets/net_image.dart';
import '../../widgets/voice_note.dart';
import '../../widgets/voice_note_composer.dart';
import '../partner/partner_trip_screen.dart' show tripFixProvider;
import 'ride_call_screen.dart' show RideCallButton;
import 'ride_tracking_screen.dart' show rideStreamProvider;
import '../../widgets/chip_button.dart';

/// Opens a link outside the app (overridden in tests).
final rideChatLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// The chat's app bar: a two-line name and the role under it.
const rideChatToolbarHeight = 76.0;

/// The in-app chat between a ride's rider and its driver, from either side.
/// It takes messages while the ride is running and is read-only after.
class RideChatScreen extends ConsumerStatefulWidget {
  const RideChatScreen({super.key, required this.requestId});
  final String requestId;

  @override
  ConsumerState<RideChatScreen> createState() => _RideChatScreenState();
}

class _RideChatScreenState extends ConsumerState<RideChatScreen> with VoiceNoteComposer {
  final _text = TextEditingController();
  bool _sending = false;

  /// Whether the box has something to send: Send while it has, the
  /// microphone while it hasn't.
  bool _hasText = false;

  /// My side of the ride, as last built.
  RideChatRole? _role;

  /// Messages already marked read from this screen, so a re-read of the
  /// thread doesn't ask again.
  final _marked = <String>{};

  /// Tries the messages waiting on this phone again while the chat is open.
  Timer? _retry;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      final has = _text.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    // Fires at once too: a thread the Message badge already loaded is read
    // the moment it is opened.
    ref.listenManual(rideMessagesProvider(widget.requestId), (_, next) {
      final list = next.value;
      if (list != null) {
        _markRead(list);
        // What reached the server another way is no longer waiting; and a
        // thread that loads means there is a connection to send the rest on.
        ref.read(rideChatOutboxProvider.notifier).reconcile(list.map((m) => m.clientMsgId));
        _flush();
      }
    }, fireImmediately: true);
    _retry = Timer.periodic(rideOutboxRetryEvery, (_) => _flush());
    _lifecycle = AppLifecycleListener(onResume: _flush);
  }

  void _flush() => unawaited(ref.read(rideChatOutboxProvider.notifier).flush(requestId: widget.requestId));

  @override
  void dispose() {
    _retry?.cancel();
    _lifecycle?.dispose();
    disposeVoiceNote();
    _text.dispose();
    super.dispose();
  }

  /// Everything addressed to me is read while this screen is open.
  void _markRead(List<RideMessage> list) {
    final ids = rideMessagesToRead(list, ref.read(currentUserIdProvider)).where((id) => !_marked.contains(id)).toList();
    if (ids.isEmpty) return;
    _marked.addAll(ids);
    unawaited(
      ref.read(rideChatRepositoryProvider).mark(ids, RideMessageStatus.read).catchError((_) {
        _marked.removeAll(ids);
      }),
    );
  }

  Future<void> _run(Future<void> Function(RideChatRepository repo) send) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await send(ref.read(rideChatRepositoryProvider));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText(RideChatRole role) async {
    final text = rideMessageText(_text.text);
    if (text == null) {
      if (_text.text.trim().length > rideMessageMaxLength) {
        showInfo(context, 'Keep it under $rideMessageMaxLength characters.');
      }
      return;
    }
    _text.clear();
    await _queue(role, RideMessageType.text, body: text);
  }

  Future<void> _sendQuick(RideChatRole role, String line) => _queue(role, RideMessageType.quick, body: line);

  /// Keeps the message on this phone first, then sends it: with no
  /// connection it waits in the thread (a clock instead of a tick) and goes
  /// out when the connection is back.
  Future<void> _queue(RideChatRole role, RideMessageType type, {String? body, double? lat, double? lng}) async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return;
    final p = PendingRideMessage(
      clientMsgId: const Uuid().v4(),
      requestId: widget.requestId,
      senderId: uid,
      role: role,
      type: type,
      body: body,
      latitude: lat,
      longitude: lng,
      createdAt: DateTime.now(),
    );
    if (!ref.read(reliabilityProvider).chatOutbox) {
      // Admin → Reliability has the outbox off: send now or say it failed.
      try {
        await ref.read(rideChatRepositoryProvider).sendQueued(p);
      } catch (e) {
        if (mounted) showError(context, e);
      }
      return;
    }
    try {
      final sent = await ref.read(rideChatOutboxProvider.notifier).send(p);
      if (!sent && mounted) showInfo(context, 'No connection. It will be sent when you are back online.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _shareLocation(RideChatRole role) => _run((repo) async {
    final at = await ref.read(tripFixProvider)();
    if (at == null) {
      if (mounted) showInfo(context, "Couldn't get your location. Check that location is on.");
      return;
    }
    await _queue(role, RideMessageType.location, lat: at.latitude, lng: at.longitude);
  });

  /// A photo from the gallery or the camera, looked at (and captioned)
  /// before it goes.
  Future<void> _sendPhoto(RideChatRole role) async {
    if (_sending) return;
    final source = await choosePhotoSource(context, camera: ref.read(photoCameraAvailableProvider));
    if (source == null || !mounted) return;
    final PickedPhoto? photo;
    try {
      photo = await ref.read(photoPickerProvider)(source);
    } catch (e) {
      if (mounted) {
        showInfo(
          context,
          source == PhotoSource.camera
              ? "Couldn't open the camera. Check that GET.ride may use it in Settings."
              : "Couldn't open your photos. Check that GET.ride may use them in Settings.",
        );
      }
      return;
    }
    if (photo == null || !mounted) return;
    final problem = ridePhotoProblem(photo.bytes.length);
    if (problem != null) return showInfo(context, problem);
    final caption = await confirmPhoto(context, photo.bytes, maxCaption: rideMessageMaxLength);
    if (caption == null || !mounted) return;
    await _run((repo) => repo.sendPhoto(widget.requestId, role, photo!.bytes, name: photo.name, caption: caption));
  }

  @override
  Future<void> sendVoiceClip(VoiceClip clip) async {
    final role = _role;
    if (role == null) return;
    await _run(
      (repo) => repo.sendVoiceNote(widget.requestId, role, clip.bytes, ext: clip.ext, duration: clip.duration),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ride = ref.watch(rideStreamProvider(widget.requestId));
    final uid = ref.watch(currentUserIdProvider);
    final r = ride.value;
    final role = r == null ? null : rideChatRoleFor(r, uid);
    _role = role;
    final peer = switch (role) {
      RideChatRole.rider => r?.partnerName ?? 'Your driver',
      RideChatRole.partner => r?.passengerName ?? 'Your passenger',
      null => 'Chat',
    };
    final phone = switch (role) {
      RideChatRole.rider => r?.partnerPhone,
      RideChatRole.partner => r?.passengerPhone,
      null => null,
    };
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        // Room for a long name on two lines ("… A/L …", "… Binti …") over
        // the role; the Call button's tooltip and label carry it in full.
        toolbarHeight: rideChatToolbarHeight,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              peer,
              key: const ValueKey('ride-chat-peer'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.appBarTheme.titleTextStyle?.copyWith(fontSize: 18, height: 1.2) ??
                  t.textTheme.titleMedium?.copyWith(height: 1.2),
            ),
            if (role != null)
              Text(
                role == RideChatRole.rider ? 'Your driver' : 'Your passenger',
                style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        actions: [
          // The same call as the trip screens': in the app (long press for
          // the phone), or the passenger's own phone on a ride booked for
          // them.
          if (r != null && role != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: RideCallButton(
                key: const ValueKey('ride-chat-call'),
                ride: r,
                peerName: peer,
                phone: phone,
                compact: true,
              ),
            ),
        ],
      ),
      body: AsyncView(
        value: ride,
        data: (r) => role == null
            ? const EmptyState(
                icon: Icons.lock_outline,
                title: 'Not your ride',
                message: 'Only the passenger and the driver of this ride can chat here.',
              )
            : ResponsiveCenter(
                maxWidth: 760,
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    Expanded(child: _thread(role)),
                    if (rideChatOpen(r.status)) _composer(role) else _closed(t, r),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _thread(RideChatRole role) {
    // Bluetooth chat at the kerb (Phase D3): what came phone to phone, and
    // which of this phone's waiting messages the other phone has.
    final ble = ref.watch(bleChatSessionsProvider)[widget.requestId];
    if (ble == null) return _threadWith(role, const [], const {});
    return ListenableBuilder(
      listenable: Listenable.merge([ble.received, ble.delivered]),
      builder: (_, _) => _threadWith(role, ble.received.value, ble.delivered.value),
    );
  }

  Widget _threadWith(RideChatRole role, List<RideMessage> viaBluetooth, Set<String> deliveredByBluetooth) => AsyncView(
    value: ref.watch(rideMessagesProvider(widget.requestId)),
    data: (sent) {
      final msgs = withBluetoothMessages(
        withPendingMessages(sent, ref.watch(rideChatOutboxProvider), widget.requestId),
        viaBluetooth,
      );
      if (msgs.isEmpty) {
        return EmptyState(
          icon: Icons.forum_outlined,
          title: 'No messages yet',
          message: role == RideChatRole.rider
              ? 'Message your driver about the pickup.'
              : 'Message your passenger about the pickup.',
        );
      }
      final uid = ref.watch(currentUserIdProvider);
      final items = rideChatItems(msgs, DateTime.now());
      return ListView.builder(
        key: const ValueKey('ride-chat-thread'),
        reverse: true,
        padding: const EdgeInsets.all(12),
        itemCount: items.length,
        itemBuilder: (_, i) => switch (items[items.length - 1 - i]) {
          RideChatDay(:final label) => _DaySeparator(label: label),
          RideChatEntry(:final message) => _Bubble(
            message: message,
            mine: message.senderId == uid,
            tick: rideMessageTick(message, uid),
            deliveredByBluetooth: message.pending && deliveredByBluetooth.contains(message.clientMsgId),
            onOpenLocation: (uri) => ref.read(rideChatLauncherProvider)(uri),
          ),
        },
      );
    },
  );

  Widget _composer(RideChatRole role) {
    final t = Theme.of(context);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Four short lines, wrapped onto a second row on a narrow phone
          // so none hides off the edge. Each is an action that sends its
          // line: a button named by it, not a checkbox.
          Padding(
            key: const ValueKey('ride-chat-quick'),
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final line in rideQuickReplies(role))
                    // A button named by its line (the shared action chip).
                    ActionChipButton(
                      key: ValueKey('quick-$line'),
                      label: Text(line),
                      semanticHint: 'Sends this message',
                      onPressed: _sending ? null : () => _sendQuick(role, line),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: recording
                ? VoiceRecordingBar(
                    elapsed: recordElapsed,
                    max: rideVoiceNoteMax,
                    onCancel: cancelVoiceNote,
                    onSend: finishVoiceNote,
                  )
                : Row(
              children: [
                IconButton(
                  key: const ValueKey('ride-chat-location'),
                  tooltip: 'Share my location',
                  color: t.colorScheme.primary,
                  onPressed: _sending ? null : () => _shareLocation(role),
                  icon: const Icon(Icons.my_location),
                ),
                IconButton(
                  key: const ValueKey('ride-chat-photo'),
                  tooltip: 'Send a photo',
                  color: t.colorScheme.primary,
                  onPressed: _sending ? null : () => _sendPhoto(role),
                  icon: const Icon(Icons.photo_camera_outlined),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('ride-chat-input'),
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: rideMessageMaxLength,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    decoration: const InputDecoration(hintText: 'Type a message', counterText: ''),
                    onSubmitted: (_) => _sendText(role),
                  ),
                ),
                const SizedBox(width: 8),
                if (_hasText)
                  IconButton.filled(
                    key: const ValueKey('ride-chat-send'),
                    tooltip: 'Send',
                    onPressed: _sending ? null : () => _sendText(role),
                    icon: const Icon(Icons.send),
                  )
                else
                  IconButton.filled(
                    key: const ValueKey('ride-chat-voice'),
                    tooltip: 'Record a voice note',
                    onPressed: _sending ? null : startVoiceNote,
                    icon: const Icon(Icons.mic_none),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _closed(ThemeData t, RideRequest r) => SafeArea(
    top: false,
    child: Container(
      key: const ValueKey('ride-chat-closed'),
      width: double.infinity,
      color: t.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 18, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(switch (r.status) {
              RideStatus.open => 'The chat opens once a driver accepts the ride.',
              RideStatus.completed => 'This ride has ended. The chat is read-only.',
              RideStatus.cancelled => 'This ride was cancelled. The chat is read-only.',
              _ => 'This ride is over. The chat is read-only.',
            }, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    ),
  );
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Container(
        key: ValueKey('ride-chat-day-$label'),
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
        child: Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.tick,
    required this.onOpenLocation,
    this.deliveredByBluetooth = false,
  });
  final RideMessage message;
  final bool mine;
  final RideMessageStatus? tick;

  /// Still waiting for the server, but the other phone has it over Bluetooth.
  final bool deliveredByBluetooth;
  final void Function(Uri) onOpenLocation;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final fg = mine ? cs.onPrimary : cs.onSurface;
    final faint = fg.withValues(alpha: 0.7);
    final m = message;
    final Widget content;
    if (m.hasLocation) {
      content = InkWell(
        key: ValueKey('ride-location-${m.id}'),
        onTap: () => onOpenLocation(rideLocationUri(m.latitude!, m.longitude!)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.place, color: fg),
            const SizedBox(width: 6),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mine ? 'My location' : 'Shared location',
                    style: t.textTheme.bodyMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
                  ),
                  Text('Tap to open in maps', style: t.textTheme.labelSmall?.copyWith(color: faint)),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (m.type == RideMessageType.image && m.hasMedia) {
      content = _PhotoContent(message: m, color: fg);
    } else if (m.type == RideMessageType.audio && m.hasMedia) {
      content = _VoiceContent(message: m, color: fg);
    } else {
      content = Text(m.body ?? '', style: t.textTheme.bodyMedium?.copyWith(color: fg));
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: ValueKey('ride-message-${m.id}'),
        constraints: const BoxConstraints(maxWidth: 480),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: mine ? cs.primary : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            content,
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatTime(m.createdAt), style: t.textTheme.labelSmall?.copyWith(color: faint)),
                if (m.pending && deliveredByBluetooth) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.bluetooth,
                    key: ValueKey('ble-delivered-${m.id}'),
                    size: 14,
                    color: faint,
                    semanticLabel: 'Delivered by Bluetooth',
                  ),
                ] else if (m.pending) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.schedule,
                    key: ValueKey('pending-${m.id}'),
                    size: 14,
                    color: faint,
                    semanticLabel: 'Waiting for network',
                  ),
                ] else if (m.viaBluetooth) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.bluetooth,
                    key: ValueKey('ble-received-${m.id}'),
                    size: 14,
                    color: faint,
                    semanticLabel: 'Arrived by Bluetooth',
                  ),
                ] else if (tick != null) ...[
                  const SizedBox(width: 4),
                  Icon(
                    tick == RideMessageStatus.sent ? Icons.done : Icons.done_all,
                    key: ValueKey('tick-${tick!.name}-${m.id}'),
                    size: 14,
                    // Read is the only full-strength tick, so it reads in either
                    // theme without a colour of its own.
                    color: tick == RideMessageStatus.read ? fg : faint,
                    semanticLabel: tick!.label,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A sent photo: a thumbnail that opens full screen, and its caption.
class _PhotoContent extends ConsumerWidget {
  const _PhotoContent({required this.message, required this.color});
  final RideMessage message;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = message;
    final url = ref.watch(rideChatMediaUrlProvider(m.mediaPath!));
    final t = Theme.of(context);
    const side = 220.0;
    Widget placeholder(IconData icon) => SizedBox.square(
      dimension: side,
      child: Icon(icon, color: color.withValues(alpha: 0.7), size: 40),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: ValueKey('ride-photo-${m.id}'),
          onTap: url.value == null ? null : () => openPhotoViewer(context, url.value!, caption: m.caption),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: side, maxHeight: side, minWidth: 120, minHeight: 80),
              child: switch (url) {
                AsyncData(:final value) => Image.network(
                  value,
                  fit: BoxFit.cover,
                  frameBuilder: boneUntilPainted(width: side, height: side),
                  errorBuilder: (_, _, _) => placeholder(Icons.broken_image_outlined),
                ),
                AsyncError() => placeholder(Icons.broken_image_outlined),
                _ => const ImageBone(width: side, height: side),
              },
            ),
          ),
        ),
        if (m.caption != null) ...[
          const SizedBox(height: 6),
          Text(m.caption!, style: t.textTheme.bodyMedium?.copyWith(color: color)),
        ],
      ],
    );
  }
}

/// A voice note: play it where it is.
class _VoiceContent extends ConsumerWidget {
  const _VoiceContent({required this.message, required this.color});
  final RideMessage message;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) => VoiceNotePlayer(
    key: ValueKey('ride-voice-${message.id}'),
    url: () => ref.read(rideChatMediaUrlProvider(message.mediaPath!).future),
    length: message.mediaDuration,
    color: color,
  );
}

/// [child] (the Message icon) with the ride chat's unread count on it.
class RideChatBadge extends ConsumerWidget {
  const RideChatBadge({super.key, required this.requestId, required this.child});
  final String requestId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(rideChatUnreadProvider(requestId));
    return Badge(
      key: const ValueKey('ride-chat-badge'),
      isLabelVisible: unread > 0,
      label: Text(unread > 9 ? '9+' : '$unread'),
      child: child,
    );
  }
}
