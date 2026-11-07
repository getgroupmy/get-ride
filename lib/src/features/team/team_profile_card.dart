import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/team_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/page_style_host.dart';

/// The "Team" card on the Profile screen (migration 0358). Shows "Join a team"
/// when the member is not on one, or the lead + "View members" / "Change team"
/// when they are. Hidden while the status is loading or unavailable (a legacy
/// local-PIN session, or before 0358 is applied).
class TeamProfileCard extends ConsumerWidget {
  const TeamProfileCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(teamSelfProvider).value;
    if (status == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;

    final rows = <Widget>[];
    if (!status.onTeam) {
      rows.add(ListTile(
        key: const ValueKey('team-join'),
        leading: Icon(Icons.group_add_outlined, color: muted),
        title: const Text('Join a team'),
        subtitle: Text('Enter a team-mate’s referral code', style: TextStyle(color: muted)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openJoin(context),
      ));
    } else {
      rows.add(ListTile(
        dense: true,
        leading: Icon(Icons.groups_2_outlined, color: muted),
        title: Text('Team lead', style: TextStyle(color: muted)),
        subtitle: Text(status.leadName ?? 'Your team', style: t.textTheme.bodyLarge),
      ));
      if (status.pending case final p?) {
        rows.add(ListTile(
          key: const ValueKey('team-pending'),
          leading: Icon(Icons.hourglass_top_outlined, color: t.colorScheme.tertiary),
          title: Text('Change to ${p.toName}'),
          subtitle: Text('Waiting for admin review', style: TextStyle(color: muted)),
        ));
      }
      rows.add(ListTile(
        key: const ValueKey('team-members'),
        leading: Icon(Icons.people_outline, color: muted),
        title: const Text('View members'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/team/members'),
      ));
      // Only one change request may be pending at a time.
      if (status.pending == null) {
        rows.add(ListTile(
          key: const ValueKey('team-change'),
          leading: Icon(Icons.swap_horiz_outlined, color: muted),
          title: const Text('Change team'),
          subtitle: Text('Needs admin approval', style: TextStyle(color: muted)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openChange(context),
        ));
      }
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text('Team', style: t.textTheme.titleSmall),
          ),
          ...rows,
        ],
      ),
    );
  }

  Future<void> _openJoin(BuildContext context) => showAppSheet<void>(
        id: 'team.join',
        context: context,
        isScrollControlled: true,
        builder: (c) => const _TeamCodeSheet(mode: _SheetMode.join),
      );

  Future<void> _openChange(BuildContext context) => showAppSheet<void>(
        id: 'team.change',
        context: context,
        isScrollControlled: true,
        builder: (c) => const _TeamCodeSheet(mode: _SheetMode.change),
      );
}

enum _SheetMode { join, change }

/// The join / change-team sheet: a referral code, plus a reason when changing.
class _TeamCodeSheet extends ConsumerStatefulWidget {
  const _TeamCodeSheet({required this.mode});
  final _SheetMode mode;

  @override
  ConsumerState<_TeamCodeSheet> createState() => _TeamCodeSheetState();
}

class _TeamCodeSheetState extends ConsumerState<_TeamCodeSheet> {
  final _code = TextEditingController();
  final _reason = TextEditingController();
  bool _busy = false;

  bool get _isChange => widget.mode == _SheetMode.change;

  @override
  void dispose() {
    _code.dispose();
    _reason.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _code.text.trim().length >= 4 && (!_isChange || _reason.text.trim().isNotEmpty);

  Future<void> _submit() async {
    final code = _code.text.trim();
    final reason = _reason.text.trim();
    setState(() => _busy = true);
    try {
      final repo = ref.read(teamRepositoryProvider);
      if (_isChange) {
        await repo.requestChange(code: code, reason: reason);
      } else {
        await repo.join(code);
      }
      ref.invalidate(teamSelfProvider);
      ref.invalidate(teamMembersProvider);
      if (!mounted) return;
      Navigator.pop(context);
      unawaited(showAppNotice(
        id: 'notice.team',
        context: context,
        message: _isChange
            ? 'Request sent. An admin will review your team change.'
            : 'You joined the team.',
        kind: NoticeKind.success,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      unawaited(showAppNotice(
        id: 'notice.team',
        context: context,
        message: teamErrorText(e) ?? "Couldn't do that. Try again.",
        kind: NoticeKind.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_isChange ? 'Change team' : 'Join a team', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            _isChange
                ? 'Enter the new team lead’s referral code and why you’re moving. An admin reviews every change.'
                : 'Enter the referral code of the person whose team you’re joining.',
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('team-code-field'),
            controller: _code,
            enabled: !_busy,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            textInputAction: _isChange ? TextInputAction.next : TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Referral code',
              hintText: 'e.g. TEAMALPHA or an 8-character account code',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _isChange || !_canSubmit ? null : _submit(),
          ),
          if (_isChange) ...[
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('team-reason-field'),
              controller: _reason,
              enabled: !_busy,
              minLines: 2,
              maxLines: 4,
              maxLength: 500,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                labelText: 'Reason for the change',
                hintText: 'Tell the admin why you’re moving',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('team-submit'),
            onPressed: (_busy || !_canSubmit) ? null : _submit,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_isChange ? 'Send request' : 'Join team'),
          ),
        ],
      ),
    );
  }
}
