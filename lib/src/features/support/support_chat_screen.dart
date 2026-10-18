import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/ride_chat.dart' show rideVoiceNoteMax;
import '../../core/support_media.dart';
import '../../data/models.dart';
import '../../data/photo_picker.dart';
import '../../data/voice_recorder.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/chat_photo.dart';
import '../../widgets/common.dart';
import '../../widgets/voice_note.dart';
import '../../widgets/voice_note_composer.dart';
import 'call/call_screen.dart';
import 'support_screen.dart';
import '../../widgets/in_app_page.dart';
import '../../widgets/net_image.dart';
import '../../widgets/storage_image.dart';
import '../../data/storage_links.dart';

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

/// The address of ticket [id] in place of a new chat's [path]
/// (`/account/support/new` → `/account/support/<id>`); null when [path] is
/// no new chat.
String? supportTicketAddress(String path, String id) {
  final suffix = '/$newSupportTicketId';
  if (!path.endsWith(suffix)) return null;
  return '${path.substring(0, path.length - suffix.length)}/$id';
}

class SupportChatScreen extends ConsumerStatefulWidget {
  const SupportChatScreen({super.key, required this.ticketId, this.pickAttachment = pickSupportAttachment});
  final String ticketId;

  /// Photo / video picker (overridden in tests).
  final Future<SupportAttachment?> Function() pickAttachment;

  @override
  ConsumerState<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends ConsumerState<SupportChatScreen> with VoiceNoteComposer {
  final _text = TextEditingController();
  bool _sending = false;

  /// The ticket, once there is one: a new chat gets it with its first message.
  late String? _ticketId = widget.ticketId == newSupportTicketId ? null : widget.ticketId;

  /// The ticket to send to, opened now if this is a new chat.
  Future<String> _ticket() async {
    final id = _ticketId;
    if (id != null) return id;
    final ticket = await ref.read(accountRepositoryProvider).openTicket('Support request');
    if (mounted) setState(() => _ticketId = ticket.id);
    return ticket.id;
  }

  /// Once a new chat has its ticket (after its first message), the address
  /// becomes the ticket's own: a reload, a bookmark or Back finds the
  /// conversation again instead of a blank new chat.
  void _settleAddress() {
    final id = _ticketId;
    if (!mounted || id == null || widget.ticketId != newSupportTicketId) return;
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    final path = router.routeInformationProvider.value.uri.path;
    final next = supportTicketAddress(path, id);
    if (next != null) router.replace(next);
  }

  SupportTicket? _openTicket() {
    final id = _ticketId;
    return id == null
        ? null
        : (ref.watch(ticketsProvider).value ?? const <SupportTicket>[]).where((x) => x.id == id).firstOrNull;
  }

  /// The bar's height for [_title]: room for a subject on two lines and
  /// the status under it, at the phone's text size (null: the usual bar).
  double? _titleHeight(BuildContext context) {
    if (_openTicket() == null) return null;
    final scale = MediaQuery.textScalerOf(context);
    return math.max(kToolbarHeight, scale.scale(16) * 1.35 * 2 + scale.scale(12) * 1.4 + 16);
  }

  Widget _title(BuildContext context) {
    final ticket = _openTicket();
    if (ticket == null) return const Text('Support chat');
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The whole subject where it fits on two lines, the status under it.
        Text(
          supportTicketTitle(ticket),
          key: const ValueKey('support-chat-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: t.textTheme.titleMedium,
        ),
        Text(
          supportStatusLabel(ticket.status),
          key: const ValueKey('support-chat-status'),
          style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
        ),
      ],
    );
  }

  /// Send while the box has text, the microphone while it hasn't.
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      final has = _text.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    if (_ticketId != null) ref.read(accountRepositoryProvider).markTicketRead(_ticketId!).catchError((_) {});
  }

  @override
  void dispose() {
    disposeVoiceNote();
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final name = ref.read(profileProvider).value?.name;
      await ref.read(accountRepositoryProvider).sendMessage(await _ticket(), body, senderName: name);
      _text.clear();
      ref.invalidate(ticketsProvider);
      _settleAddress();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Sends a photo snapped now, or a photo or video from the gallery
  /// (Expo's attach button).
  Future<void> _attach() async {
    if (_sending) return;
    final source = await choosePhotoSource(context, camera: ref.read(photoCameraAvailableProvider));
    if (source == null || !mounted) return;
    final SupportAttachment? file;
    try {
      file = source == PhotoSource.camera
          ? await ref.read(photoPickerProvider)(PhotoSource.camera)
          : await widget.pickAttachment();
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
          .sendAttachment(await _ticket(), file.bytes, name: file.name, senderName: name);
      ref.invalidate(ticketsProvider);
      _settleAddress();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Future<void> sendVoiceClip(VoiceClip clip) async {
    setState(() => _sending = true);
    try {
      final name = ref.read(profileProvider).value?.name;
      await ref
          .read(accountRepositoryProvider)
          .sendVoiceNote(await _ticket(), clip.bytes, ext: clip.ext, duration: clip.duration, senderName: name);
      ref.invalidate(ticketsProvider);
      _settleAddress();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _content(SupportMessage m, bool mine, ThemeData t) {
    final fg = mine ? t.colorScheme.onPrimary : null;
    final url = m.mediaUrl;
    if (url != null && url.isNotEmpty && m.type == 'audio') {
      return VoiceNotePlayer(
        key: ValueKey('support-voice-${m.id}'),
        url: () => signedStorageUrl(url),
        length: m.mediaDuration,
        color: fg ?? t.colorScheme.onSurface,
      );
    }
    if (url != null && url.isNotEmpty && (m.type == 'image' || m.type == 'video')) {
      void open() =>
          m.type == 'image' ? openPhotoViewer(context, url) : openStoredFile(context, url, title: 'Video');
      if (m.type == 'image') {
        return GestureDetector(
          key: ValueKey('support-image-${m.id}'),
          onTap: open,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
              child: StorageImage(
                url,
                fit: BoxFit.cover,
                frameBuilder: boneUntilPainted(),
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
          Flexible(child: Text('Video · tap to play', style: TextStyle(color: fg))),
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
      // The ticket by name ("#4 · Support request") and its status under it.
      appBar: AppBar(toolbarHeight: _titleHeight(context), title: _title(context), actions: [
        BusyIconButton(
          key: const ValueKey('call-support'),
          tooltip: 'Call support',
          icon: const Icon(Icons.call_outlined),
          onPressed: () => callSupport(
            context,
            ref,
            ticketId: _ticketId,
            name: ref.read(profileProvider).value?.name,
          ),
        ),
      ]),
      body: ResponsiveCenter(
        maxWidth: 760,
        padding: EdgeInsets.zero,
        child: Column(children: [
          Expanded(
            child: AsyncView(
              // A new chat has nothing to read yet.
              value: _ticketId == null
                  ? const AsyncData(<SupportMessage>[])
                  : ref.watch(supportMessagesProvider(_ticketId!)),
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
              child: recording
                  ? VoiceRecordingBar(
                      elapsed: recordElapsed,
                      max: rideVoiceNoteMax,
                      onCancel: cancelVoiceNote,
                      onSend: finishVoiceNote,
                    )
                  : Row(children: [
                BusyIconButton(
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
                if (_hasText)
                  IconButton.filled(
                    key: const ValueKey('support-send'),
                    tooltip: 'Send',
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                  )
                else
                  IconButton.filled(
                    key: const ValueKey('support-voice'),
                    tooltip: 'Record a voice note',
                    onPressed: _sending ? null : startVoiceNote,
                    icon: const Icon(Icons.mic_none),
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
