import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/inbox.dart';
import '../../core/push_message.dart';
import '../../data/notifications_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/in_app_page.dart' show openInApp;
import '../../widgets/push_message_view.dart';
import '../../widgets/side_menu_tiles.dart' show openAppRoute;

/// Opens a full message's link: an in-app route through the router, an
/// http(s) address inside the app (openInApp). Anything else is ignored.
void openPushMessageLink(BuildContext context, String link) {
  final l = link.trim();
  if (!isSafePushLink(l)) return;
  if (isInAppPushRoute(l)) {
    openAppRoute(context, l);
  } else {
    unawaited(openInApp(context, l));
  }
}

/// The blocks a stored message shows: its own, or when it has none its
/// title and text.
List<PushBlock> pushMessageBlocks(Map<String, dynamic> row) {
  final blocks = decodePushBlocks(row['blocks']);
  if (blocks.isNotEmpty) return blocks;
  final title = '${row['title'] ?? ''}'.trim(), body = '${row['body'] ?? ''}'.trim();
  return [
    if (title.isNotEmpty) PushBlock.heading([PushSpan(title)]),
    if (body.isNotEmpty) PushBlock.paragraph([PushSpan(body)]),
  ];
}

/// Side menu -> Notifications -> an admin push with a full message, or
/// tapping that push (`/account/notifications/<id>`, migration 0279): the
/// picture on top, then the message. Only someone the push reached can read
/// it (push_messages RLS); anyone else sees that it is not there.
class PushMessageScreen extends ConsumerStatefulWidget {
  const PushMessageScreen({super.key, required this.messageId});

  final String messageId;

  @override
  ConsumerState<PushMessageScreen> createState() => _PushMessageScreenState();
}

class _PushMessageScreenState extends ConsumerState<PushMessageScreen> {
  @override
  void initState() {
    super.initState();
    // Opened from the push itself: its row on the notifications page is read.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_markRead()));
  }

  Future<void> _markRead() async {
    try {
      final items = await ref.read(notificationsProvider.future).timeout(const Duration(seconds: 10));
      final ids = [
        for (final InboxItem i in items)
          if (i.unread && i.data['message_id'] == widget.messageId) i.id,
      ];
      if (ids.isNotEmpty) await ref.read(notificationsRepositoryProvider).markRead(ids);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(pushMessageProvider(widget.messageId));
    final row = value.value;
    return Scaffold(
      appBar: AppBar(title: Text(row == null ? 'Notification' : '${row['title'] ?? 'Notification'}')),
      body: AsyncView<Map<String, dynamic>?>(
        value: value,
        onRetry: () => ref.invalidate(pushMessageProvider(widget.messageId)),
        data: (row) => row == null
            ? const EmptyState(
                key: ValueKey('push-message-missing'),
                icon: Icons.notifications_off_outlined,
                title: 'This message is no longer available',
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  ResponsiveCenter(
                    maxWidth: 760,
                    padding: EdgeInsets.zero,
                    child: PushMessageView(
                      key: const ValueKey('push-message-view'),
                      blocks: pushMessageBlocks(row),
                      imageUrl: safePushImageUrl(row['image_url']),
                      onLink: (link) => openPushMessageLink(context, link),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
