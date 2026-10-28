import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../core/ride_safety.dart' show ticketReportChip, ticketUrgentOpen, urgentTicketsFirst;
import '../../data/models.dart' show SupportMessage;
import '../../data/realtime_backup.dart';
import '../../features/support/call/call_screen.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/chat_photo.dart';
import '../../widgets/common.dart';
import '../../widgets/net_image.dart';
import '../../widgets/voice_note.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/trip_audio_panel.dart';
import 'support_agents.dart';
import '../../data/live_tables.dart';
import '../../widgets/storage_image.dart';
import '../../data/storage_links.dart';

/// Ticket statuses and the labels the Expo panel shows for them.
const ticketStatusLabels = {
  'open': 'New',
  'in_progress': 'In progress',
  'pending': 'Waiting for reply',
  'closed': 'Resolved',
};

final adminTicketsProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('support_tickets');
  return ref.watch(adminRepositoryProvider).tickets();
});

/// Assigns a ticket to the admin themselves or another support agent (Expo's
/// assign sheet, from the ticket or the pool list). Taking it yourself also
/// moves it to in progress. True when it was reassigned.
Future<bool> assignSupportTicket(
  BuildContext context,
  WidgetRef ref, {
  required String ticketId,
  required String? currentId,
}) async {
  final repo = ref.read(adminRepositoryProvider);
  final meId = ref.read(currentUserIdProvider);
  String? name;
  try {
    name = (await ref.read(profileProvider.future))?.name;
  } catch (_) {
    // Profile unreadable: the ticket is still assigned, as "Support".
  }
  final myName = name ?? 'Support';
  var agents = const <SupportAgent>[];
  try {
    agents = await repo.supportAgents();
  } catch (_) {
    // Roster unreadable (older database): the picker still offers "me".
  }
  if (!context.mounted) return false;
  final pick = await showSupportAgentPicker(context, agents: agents, meId: meId, meName: myName, currentId: currentId);
  if (pick == null || pick.id == currentId || !context.mounted) return false;
  final ok = await runAdminAction(
    context,
    () => pick.id == meId ? repo.assignTicketToMe(ticketId, myName) : repo.assignTicket(ticketId, pick.id, pick.name),
    success: pick.id == meId ? 'Assigned to you' : 'Assigned to ${pick.name}',
  );
  ref.invalidate(adminTicketsProvider);
  return ok;
}

class AdminSupportScreen extends ConsumerStatefulWidget {
  const AdminSupportScreen({super.key});

  @override
  ConsumerState<AdminSupportScreen> createState() => _AdminSupportScreenState();
}

class _AdminSupportScreenState extends ConsumerState<AdminSupportScreen> {
  String _filter = 'active';
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider);
    final canEdit = ref.watch(moduleAccessProvider('support')) == AccessLevel.edit;
    return AdminPage(
      title: 'Support',
      module: 'support',
      actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(adminTicketsProvider))],
      body: Column(children: [
        FilterBar(
          filters: const {
            'active': 'Active',
            'unassigned': 'Unassigned',
            'mine': 'Assigned to me',
            'closed': 'Resolved',
            'all': 'All',
          },
          selected: _filter,
          onSelected: (f) => setState(() => _filter = f),
          onSearch: (q) => setState(() => _query = q),
          hint: 'Search subject, message, ticket #…',
        ),
        Expanded(
          child: AsyncView(
            value: ref.watch(adminTicketsProvider),
            onRetry: () => ref.invalidate(adminTicketsProvider),
            data: (tickets) {
              final q = _query.trim().toLowerCase();
              final list = tickets.where((t) {
                final status = t['status'] as String? ?? 'open';
                final ok = switch (_filter) {
                  'active' => status != 'closed',
                  'unassigned' => status != 'closed' && t['assigned_admin_id'] == null,
                  'mine' => t['assigned_admin_id'] == me,
                  'closed' => status == 'closed',
                  _ => true,
                };
                if (!ok) return false;
                if (q.isEmpty) return true;
                return '${t['ticket_number']} ${t['subject']} ${t['last_message']}'.toLowerCase().contains(q);
              }).toList();
              // Urgent trip reports still open go on top (0311).
              final sorted = urgentTicketsFirst(list);
              if (list.isEmpty) return const EmptyState(icon: Icons.support_agent, title: 'No tickets');
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: sorted.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = sorted[i];
                  final report = ticketReportChip(t);
                  final unread = (t['unread_admin'] as num?)?.toInt() ?? 0;
                  final assignee = t['assigned_admin_id'] as String?;
                  return ListTile(
                    leading: Badge(
                      isLabelVisible: unread > 0,
                      label: Text('$unread'),
                      child: ticketUrgentOpen(t)
                          ? Icon(Icons.priority_high, key: ValueKey('ticket-urgent-${t['id']}'), color: Theme.of(context).colorScheme.error)
                          : Icon(report == null ? Icons.forum_outlined : Icons.flag_outlined),
                    ),
                    title: Text(ticketTitle(t)),
                    subtitle: Text(
                      [?report, t['last_message'] ?? 'No messages', t['assigned_admin_name'] ?? 'unassigned'].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(dateText(t['last_message_at'] ?? t['created_at'])),
                          const SizedBox(height: 4),
                          StatusChip(ticketStatusLabels[t['status']] ?? '${t['status']}'),
                        ],
                      ),
                      // Assign or reassign without opening the ticket (Expo pool list).
                      if (canEdit && t['status'] != 'closed')
                        IconButton(
                          key: ValueKey('list-assign-${t['id']}'),
                          tooltip: assignee == null ? 'Assign' : 'Reassign',
                          icon: Icon(assignee == null ? Icons.person_add_alt : Icons.swap_horiz),
                          onPressed: () =>
                              assignSupportTicket(context, ref, ticketId: '${t['id']}', currentId: assignee),
                        ),
                    ]),
                    onTap: () => context.go('/admin/support/${t['id']}'),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Admin side of one ticket: thread, reply box, assign + status controls.
class AdminSupportChatScreen extends ConsumerStatefulWidget {
  const AdminSupportChatScreen({super.key, required this.ticketId});
  final String ticketId;

  @override
  ConsumerState<AdminSupportChatScreen> createState() => _AdminSupportChatScreenState();
}

class _AdminSupportChatScreenState extends ConsumerState<AdminSupportChatScreen> {
  final _text = TextEditingController();
  List<Map<String, dynamic>> _messages = [];
  Map<String, dynamic>? _ticket;
  RealtimeChannel? _channel;
  late final _backup = RealtimeBackup(_load);
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
    final db = ref.read(supabaseProvider);
    _channel = db
        .channel('admin_support_${widget.ticketId}_${DateTime.now().microsecondsSinceEpoch}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'support_messages',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'ticket_id', value: widget.ticketId),
          callback: (_) => _load(),
        )
        .subscribe(_backup.onStatus);
  }

  Future<void> _load() async {
    final repo = ref.read(adminRepositoryProvider);
    try {
      final msgs = await repo.ticketMessages(widget.ticketId);
      final tickets = await repo.tickets();
      if (!mounted) return;
      setState(() {
        _messages = msgs;
        _ticket = tickets.where((t) => t['id'] == widget.ticketId).firstOrNull;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  void dispose() {
    _backup.dispose();
    if (_channel != null) unawaited(ref.read(supabaseProvider).removeChannel(_channel!));
    _text.dispose();
    super.dispose();
  }

  String get _myName => ref.read(profileProvider).value?.name ?? 'Support';

  Future<void> _send() async {
    if (_text.text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).replyToTicket(widget.ticketId, _text.text, _myName),
    );
    if (ok) _text.clear();
    if (mounted) setState(() => _sending = false);
    ref.invalidate(adminTicketsProvider);
    await _load();
  }

  /// Assign the ticket to yourself or another support agent ([assignSupportTicket]).
  Future<void> _assign(String? currentId) async {
    if (await assignSupportTicket(context, ref, ticketId: widget.ticketId, currentId: currentId)) await _load();
  }

  @override
  Widget build(BuildContext context) {
    // The ticket's status and assignee as another admin changes them.
    ref.listenAdminLive(const ['support_tickets'], () => unawaited(_load()));
    final t = Theme.of(context);
    final canEdit = ref.watch(moduleAccessProvider('support')) == AccessLevel.edit;
    final ticket = _ticket;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/admin/support')),
        // The subject, with its number under it when it has one (never a
        // lone "#").
        title: ticket == null
            ? const Text('Ticket')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${ticket['subject'] ?? 'Support'}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  if ('${ticket['ticket_number'] ?? ''}'.trim().isNotEmpty)
                    Text('#${ticket['ticket_number']}', style: t.textTheme.labelMedium),
                ],
              ),
        actions: [
          if (canEdit && ticket != null && ticket['profile_id'] != null)
            BusyIconButton(
              key: const ValueKey('ticket-call'),
              tooltip: 'Call customer',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => callUser(
                context,
                ref,
                profileId: '${ticket['profile_id']}',
                ticketId: widget.ticketId,
                agentName: _myName,
              ),
            ),
          // On a phone the words would squeeze the title out: an icon.
          if (canEdit && ticket != null && narrow)
            BusyIconButton(
              key: const ValueKey('ticket-assign'),
              tooltip: ticket['assigned_admin_id'] == null ? 'Assign' : 'Reassign',
              icon: const Icon(Icons.person_add_alt),
              onPressed: () => _assign(ticket['assigned_admin_id'] as String?),
            )
          else if (canEdit && ticket != null)
            BusyButton.text(
              key: const ValueKey('ticket-assign'),
              icon: const Icon(Icons.person_add_alt),
              child: Text(ticket['assigned_admin_id'] == null ? 'Assign' : 'Reassign'),
              onPressed: () => _assign(ticket['assigned_admin_id'] as String?),
            ),
          if (canEdit && ticket != null)
            PopupMenuButton<String>(
              tooltip: 'Status',
              icon: const Icon(Icons.flag_outlined),
              onSelected: (s) async {
                await runAdminAction(
                  context,
                  () => ref.read(adminRepositoryProvider).setTicketStatus(widget.ticketId, s),
                  success: 'Status: ${ticketStatusLabels[s]}',
                );
                ref.invalidate(adminTicketsProvider);
                await _load();
              },
              itemBuilder: (_) => [
                for (final e in ticketStatusLabels.entries)
                  CheckedPopupMenuItem(value: e.key, checked: ticket['status'] == e.key, child: Text(e.value)),
              ],
            ),
        ],
      ),
      body: ResponsiveCenter(
        maxWidth: 820,
        padding: EdgeInsets.zero,
        child: Column(children: [
          if (ticket != null)
            ListTile(
              dense: true,
              leading: StatusChip(ticketStatusLabels[ticket['status']] ?? '${ticket['status']}'),
              title: Text('Assigned: ${ticket['assigned_admin_name'] ?? 'nobody'}'),
              subtitle: Text('Opened ${dateText(ticket['created_at'])}'),
            ),
          // A trip report (0311): its category and the ride.
          if (ticket != null && ticketReportChip(ticket) != null)
            ListTile(
              key: const ValueKey('ticket-report'),
              dense: true,
              leading: Icon(ticket['priority'] == 'urgent' ? Icons.priority_high : Icons.flag_outlined,
                  color: ticket['priority'] == 'urgent' ? t.colorScheme.error : null),
              title: Text('Trip report: ${ticketReportChip(ticket)}'),
              trailing: ticket['request_id'] == null
                  ? null
                  : TextButton(
                      key: const ValueKey('ticket-open-ride'),
                      onPressed: () => context.go('/admin/rides?ride=${ticket['request_id']}'),
                      child: const Text('Open the trip'),
                    ),
            ),
          if (ticket != null && ticket['profile_id'] != null)
            TripAudioPanel(profileId: '${ticket['profile_id']}', ticketId: widget.ticketId, canEdit: canEdit),
          Expanded(
            child: _messages.isEmpty
                ? const EmptyState(icon: Icons.forum_outlined, title: 'No messages yet')
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final m = _messages[_messages.length - 1 - i];
                      final mine = m['sender_role'] == 'admin';
                      final body = m['type'] == 'text' || m['type'] == null
                          ? (m['body'] as String? ?? '')
                          : '[${m['type']}] ${m['body'] ?? m['media_url'] ?? ''}';
                      return Align(
                        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 520),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: mine ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${m['sender_name'] ?? (mine ? 'Support' : 'Customer')} · ${formatTime(DateTime.tryParse('${m['created_at']}'))}',
                                style: t.textTheme.labelSmall?.copyWith(
                                    color: mine ? t.colorScheme.onPrimary.withValues(alpha: 0.75) : null),
                              ),
                              _AdminMedia(
                                message: m,
                                color: mine ? t.colorScheme.onPrimary : t.colorScheme.onSurface,
                                fallback: SelectableText(
                                  body,
                                  style: TextStyle(color: mine ? t.colorScheme.onPrimary : null),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (canEdit)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(hintText: 'Reply to the customer'),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: _sending ? null : _send,
                    icon: _sending ? const BusySpinner(size: 20) : const Icon(Icons.send),
                  ),

                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A support message's photo or voice note, as the customer sees it; any
/// other message is [fallback].
class _AdminMedia extends StatelessWidget {
  const _AdminMedia({required this.message, required this.color, required this.fallback});
  final Map<String, dynamic> message;
  final Color color;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final m = SupportMessage(message);
    final url = m.mediaUrl;
    if (url == null || url.isEmpty) return fallback;
    if (m.type == 'audio') {
      return VoiceNotePlayer(url: () => signedStorageUrl(url), length: m.mediaDuration, color: color);
    }
    if (m.type == 'image') {
      return GestureDetector(
        onTap: () => openPhotoViewer(context, url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
            child: StorageImage(
              url,
              fit: BoxFit.cover,
              frameBuilder: boneUntilPainted(),
              errorBuilder: (_, _, _) => fallback,
            ),
          ),
        ),
      );
    }
    return fallback;
  }
}

/// A ticket's line in the list: "#12 · Lost my phone", or just the subject
/// when it has no number yet (never "#— ·").
String ticketTitle(Map<String, dynamic> t) {
  final no = '${t['ticket_number'] ?? ''}'.trim();
  final subject = '${t['subject'] ?? 'Support'}';
  return no.isEmpty ? subject : '#$no · $subject';
}
