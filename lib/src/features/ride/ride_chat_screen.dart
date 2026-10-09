import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/ride_chat.dart';
import '../../data/models.dart';
import '../../data/ride_chat_repository.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../partner/partner_trip_screen.dart' show tripFixProvider;
import 'ride_tracking_screen.dart' show rideStreamProvider;

/// Opens a link outside the app (overridden in tests).
final rideChatLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// The in-app chat between a ride's rider and its driver, from either side.
/// It takes messages while the ride is running and is read-only after.
class RideChatScreen extends ConsumerStatefulWidget {
  const RideChatScreen({super.key, required this.requestId});
  final String requestId;

  @override
  ConsumerState<RideChatScreen> createState() => _RideChatScreenState();
}

class _RideChatScreenState extends ConsumerState<RideChatScreen> {
  final _text = TextEditingController();
  bool _sending = false;

  /// Messages already marked read from this screen, so a re-read of the
  /// thread doesn't ask again.
  final _marked = <String>{};

  @override
  void initState() {
    super.initState();
    // Fires at once too: a thread the Message badge already loaded is read
    // the moment it is opened.
    ref.listenManual(rideMessagesProvider(widget.requestId), (_, next) {
      final list = next.value;
      if (list != null) _markRead(list);
    }, fireImmediately: true);
  }

  @override
  void dispose() {
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
    await _run((repo) async {
      await repo.sendText(widget.requestId, role, text);
      _text.clear();
    });
  }

  Future<void> _sendQuick(RideChatRole role, String line) =>
      _run((repo) => repo.sendText(widget.requestId, role, line, quick: true));

  Future<void> _shareLocation(RideChatRole role) => _run((repo) async {
    final at = await ref.read(tripFixProvider)();
    if (at == null) {
      if (mounted) showInfo(context, "Couldn't get your location. Check that location is on.");
      return;
    }
    await repo.sendLocation(widget.requestId, role, at.latitude, at.longitude);
  });

  @override
  Widget build(BuildContext context) {
    final ride = ref.watch(rideStreamProvider(widget.requestId));
    final uid = ref.watch(currentUserIdProvider);
    final r = ride.value;
    final role = r == null ? null : rideChatRoleFor(r, uid);
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(peer, key: const ValueKey('ride-chat-peer')),
            if (role != null)
              Text(
                role == RideChatRole.rider ? 'Your driver' : 'Your passenger',
                style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        actions: [
          if (phone != null)
            BusyIconButton(
              key: const ValueKey('ride-chat-call'),
              tooltip: 'Call $peer',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => ref.read(rideChatLauncherProvider)(Uri(scheme: 'tel', path: phone)),
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

  Widget _thread(RideChatRole role) => AsyncView(
    value: ref.watch(rideMessagesProvider(widget.requestId)),
    data: (msgs) {
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
          // Four short lines: all built, scrolled sideways on a narrow phone.
          SingleChildScrollView(
            key: const ValueKey('ride-chat-quick'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Row(
              children: [
                for (final line in rideQuickReplies(role))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      key: ValueKey('quick-$line'),
                      label: Text(line),
                      onPressed: _sending ? null : () => _sendQuick(role, line),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('ride-chat-location'),
                  tooltip: 'Share my location',
                  color: t.colorScheme.primary,
                  onPressed: _sending ? null : () => _shareLocation(role),
                  icon: const Icon(Icons.my_location),
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
                IconButton.filled(
                  key: const ValueKey('ride-chat-send'),
                  tooltip: 'Send',
                  onPressed: _sending ? null : () => _sendText(role),
                  icon: const Icon(Icons.send),
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
  const _Bubble({required this.message, required this.mine, required this.tick, required this.onOpenLocation});
  final RideMessage message;
  final bool mine;
  final RideMessageStatus? tick;
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
                if (tick != null) ...[
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
