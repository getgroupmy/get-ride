import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';

/// Ticket statuses and the labels the Expo panel shows for them.
const ticketStatusLabels = {
  'open': 'New',
  'in_progress': 'In progress',
  'pending': 'Waiting for reply',
  'closed': 'Resolved',
};

final adminTicketsProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepositoryProvider).tickets());

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
    return AdminPage(
      title: 'Support',
      module: 'support',
      actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(adminTicketsProvider))],
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
              if (list.isEmpty) return const EmptyState(icon: Icons.support_agent, title: 'No tickets');
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = list[i];
                  final unread = (t['unread_admin'] as num?)?.toInt() ?? 0;
                  return ListTile(
                    leading: Badge(
                      isLabelVisible: unread > 0,
                      label: Text('$unread'),
                      child: const Icon(Icons.forum_outlined),
                    ),
                    title: Text('#${t['ticket_number'] ?? '—'} · ${t['subject'] ?? 'Support'}'),
                    subtitle: Text(
                      [t['last_message'] ?? 'No messages', t['assigned_admin_name'] ?? 'unassigned'].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(dateText(t['last_message_at'] ?? t['created_at'])),
                        const SizedBox(height: 4),
                        StatusChip(ticketStatusLabels[t['status']] ?? '${t['status']}'),
                      ],
                    ),
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
        .subscribe();
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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final canEdit = ref.watch(moduleAccessProvider('support')) == AccessLevel.edit;
    final ticket = _ticket;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/admin/support')),
        title: Text(ticket == null ? 'Ticket' : '#${ticket['ticket_number'] ?? ''} · ${ticket['subject'] ?? 'Support'}'),
        actions: [
          if (canEdit && ticket != null && ticket['assigned_admin_id'] != ref.read(currentUserIdProvider))
            TextButton.icon(
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Assign to me'),
              onPressed: () async {
                await runAdminAction(
                  context,
                  () => ref.read(adminRepositoryProvider).assignTicketToMe(widget.ticketId, _myName),
                  success: 'Assigned to you',
                );
                ref.invalidate(adminTicketsProvider);
                await _load();
              },
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
                              SelectableText(body, style: TextStyle(color: mine ? t.colorScheme.onPrimary : null)),
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
                  IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}
