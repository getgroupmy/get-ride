import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import 'support_screen.dart';

final supportMessagesProvider = StreamProvider.autoDispose.family<List<SupportMessage>, String>(
  (ref, ticketId) => ref.watch(accountRepositoryProvider).watchMessages(ticketId),
);

class SupportChatScreen extends ConsumerStatefulWidget {
  const SupportChatScreen({super.key, required this.ticketId});
  final String ticketId;

  @override
  ConsumerState<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends ConsumerState<SupportChatScreen> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    ref.read(accountRepositoryProvider).markTicketRead(widget.ticketId).catchError((_) {});
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final name = ref.read(profileProvider).value?.name;
      await ref.read(accountRepositoryProvider).sendMessage(widget.ticketId, body, senderName: name);
      _text.clear();
      ref.invalidate(ticketsProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Support chat')),
      body: ResponsiveCenter(
        maxWidth: 760,
        padding: EdgeInsets.zero,
        child: Column(children: [
          Expanded(
            child: AsyncView(
              value: ref.watch(supportMessagesProvider(widget.ticketId)),
              data: (msgs) => msgs.isEmpty
                  ? const EmptyState(icon: Icons.forum_outlined, title: 'Say hello 👋',
                      message: 'Tell us what you need help with.')
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: msgs.length,
                      itemBuilder: (_, i) {
                        final m = msgs[msgs.length - 1 - i];
                        final mine = m.fromUser;
                        return Align(
                          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 480),
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: mine ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                if (!mine)
                                  Text(m.senderName ?? 'Support',
                                      style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
                                Text(
                                  m.type == 'text' ? (m.body ?? '') : '[${m.type}] ${m.body ?? m.mediaUrl ?? ''}',
                                  style: TextStyle(color: mine ? t.colorScheme.onPrimary : null),
                                ),
                                const SizedBox(height: 2),
                                Text(formatTime(m.createdAt),
                                    style: t.textTheme.labelSmall?.copyWith(
                                        color: mine ? t.colorScheme.onPrimary.withValues(alpha: 0.7) : null)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    decoration: const InputDecoration(hintText: 'Type a message'),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
