// User teams (migration 0358) — Admin › People › Team changes. Members ask to
// move to a different team lead with a reason; an admin approves (the referral
// moves to the new lead) or rejects, and the requester is pushed either way.
// Every decision is in the audit log (the server's).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/team_changes_repository.dart';
import '../../../widgets/app_notice.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';

const teamChangesPage = 'admin-team-changes';

bool canEditTeamChanges(WidgetRef ref) =>
    (ref.watch(adminAccessProvider).value ?? AdminAccess.none).canEdit(const [teamChangesPage]);

class TeamChangesScreen extends ConsumerWidget {
  const TeamChangesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = canEditTeamChanges(ref);
    return Scaffold(
      appBar: AppBar(title: const Text('Team changes')),
      body: AsyncView<List<TeamChangeRequest>>(
        value: ref.watch(teamChangesPendingProvider),
        onRetry: () => ref.invalidate(teamChangesPendingProvider),
        data: (requests) => requests.isEmpty
            ? const EmptyState(
                icon: Icons.inbox_outlined,
                title: 'No pending requests',
                message: 'Team change requests waiting for review appear here.',
              )
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(teamChangesPendingProvider),
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: requests.length,
                  itemBuilder: (context, i) => ResponsiveCenter(
                    maxWidth: 760,
                    child: _RequestCard(request: requests[i], canEdit: canEdit),
                  ),
                ),
              ),
      ),
    );
  }
}

class _RequestCard extends ConsumerStatefulWidget {
  const _RequestCard({required this.request, required this.canEdit});
  final TeamChangeRequest request;
  final bool canEdit;

  @override
  ConsumerState<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends ConsumerState<_RequestCard> {
  final _note = TextEditingController();
  bool _busy = false;
  bool _rejecting = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _decide(String action) async {
    setState(() => _busy = true);
    try {
      await ref.read(teamChangesRepositoryProvider).decide(
            widget.request.id,
            action,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      ref.invalidate(teamChangesPendingProvider);
      if (!mounted) return;
      unawaited(showAppNotice(
        id: 'notice.team-change',
        context: context,
        message: action == 'approve' ? 'Approved. The member moved teams.' : 'Rejected.',
        kind: NoticeKind.success,
      ));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      unawaited(showAppNotice(
        id: 'notice.team-change',
        context: context,
        message: "Couldn't save. Try again.",
        kind: NoticeKind.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final r = widget.request;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.requesterName, style: t.textTheme.titleMedium),
            if (r.requesterPhone != null)
              Text(r.requesterPhone!, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 10),
            Row(
              children: [
                Flexible(child: _leadChip(context, 'From', r.fromLeadName ?? 'No team')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward, size: 18, color: cs.onSurfaceVariant),
                ),
                Flexible(child: _leadChip(context, 'To', r.toLeadName)),
              ],
            ),
            const SizedBox(height: 10),
            Text('Reason', style: t.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text(r.reason, style: t.textTheme.bodyMedium),
            if (r.createdAt != null) ...[
              const SizedBox(height: 8),
              Text('Requested ${_ago(r.createdAt!)}',
                  style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ],
            if (widget.canEdit) ...[
              const Divider(height: 24),
              if (_rejecting) ...[
                TextField(
                  controller: _note,
                  enabled: !_busy,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Reason for the member (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _rejecting = false),
                      child: const Text('Back'),
                    ),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
                      onPressed: _busy ? null : () => _decide('reject'),
                      child: _busy ? _spinner() : const Text('Reject'),
                    ),
                  ],
                ),
              ] else
                Row(
                  children: [
                    OutlinedButton(
                      key: ValueKey('team-change-reject-${r.id}'),
                      style: OutlinedButton.styleFrom(foregroundColor: cs.error, side: BorderSide(color: cs.error)),
                      onPressed: _busy ? null : () => setState(() => _rejecting = true),
                      child: const Text('Reject'),
                    ),
                    const Spacer(),
                    FilledButton(
                      key: ValueKey('team-change-approve-${r.id}'),
                      onPressed: _busy ? null : () => _decide('approve'),
                      child: _busy ? _spinner() : const Text('Approve'),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _spinner() => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));

  Widget _leadChip(BuildContext context, String label, String name) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        Text(name, style: t.textTheme.bodyLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }

  String _ago(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }
}
