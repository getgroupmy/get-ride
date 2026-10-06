import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/support_media.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import 'support_screen.dart';
import '../../widgets/in_app_page.dart';

final supportMessagesProvider = StreamProvider.autoDispose.family<List<SupportMessage>, String>(
  (ref, ticketId) => ref.watch(accountRepositoryProvider).watchMessages(ticketId),
);

/// A picked photo or video for the chat.
typedef SupportAttachment = ({Uint8List bytes, String name});

Future<SupportAttachment?> pickSupportAttachment() async {
  final files = await FilePicker.pickFiles(type: FileType.media);
  final f = files.firstOrNull;
  if (f == null) return null;
  return (bytes: await f.readAsBytes(), name: f.name);
}

class SupportChatScreen extends ConsumerStatefulWidget {
  const SupportChatScreen({super.key, required this.ticketId, this.pickAttachment = pickSupportAttachment});
  final String ticketId;

  /// Photo / video picker (overridden in tests).
  final Future<SupportAttachment?> Function() pickAttachment;

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

  /// Sends a photo or video (Expo's attach button).
  Future<void> _attach() async {
    if (_sending) return;
    final SupportAttachment? file;
    try {
      file = await widget.pickAttachment();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (file == null || !mounted) return;
    final problem = supportMediaProblem(file.name, file.bytes.length);
    if (problem != null) return showInfo(context, problem);
    setState(() => _sending = true);
    try {
      final name = ref.read(profileProvider).value?.name;
      await ref
          .read(accountRepositoryProvider)
          .sendAttachment(widget.ticketId, file.bytes, name: file.name, senderName: name);
      ref.invalidate(ticketsProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _content(SupportMessage m, bool mine, ThemeData t) {
    final fg = mine ? t.colorScheme.onPrimary : null;
    final url = m.mediaUrl;
    if (url != null && url.isNotEmpty && (m.type == 'image' || m.type == 'video')) {
      void open() => openInApp(context, url, title: m.type == 'image' ? 'Photo' : 'Video');
      if (m.type == 'image') {
        return GestureDetector(
          key: ValueKey('support-image-${m.id}'),
          onTap: open,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
              child: Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Text('📷 Photo', style: TextStyle(color: fg)),
              ),
            ),
          ),
        );
      }
      return InkWell(
        key: ValueKey('support-video-${m.id}'),
        onTap: open,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.play_circle_outline, color: fg),
          const SizedBox(width: 6),
          Text('Video · tap to play', style: TextStyle(color: fg)),
        ]),
      );
    }
    return Text(
      m.type == 'text' ? (m.body ?? '') : supportSummary(m.type, m.body),
      style: TextStyle(color: fg),
    );
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
                                _content(m, mine, t),
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
                IconButton(
                  key: const ValueKey('support-attach'),
                  tooltip: 'Send a photo or video',
                  onPressed: _sending ? null : _attach,
                  icon: const Icon(Icons.attach_file),
                ),
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
