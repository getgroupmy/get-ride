import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/team_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/net_image.dart';
import '../../widgets/offline_strip.dart';
import '../../widgets/plate_chip.dart';

/// Profile → Team → View members (migration 0358): the caller's team-mates,
/// the lead first, each with their name and car plate. In-app chat with a
/// member is coming in a later phase.
class TeamMembersScreen extends ConsumerWidget {
  const TeamMembersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(teamMembersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Team members')),
      body: OfflineStrip.over(AsyncView<List<TeamMemberRow>>(
        value: value,
        onRetry: () => ref.invalidate(teamMembersProvider),
        data: (members) => members.isEmpty
            ? const EmptyState(
                icon: Icons.groups_outlined,
                title: 'No team yet',
                message: 'Join a team from your profile to see its members here.',
              )
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(teamMembersProvider),
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: members.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                  itemBuilder: (context, i) => ResponsiveCenter(
                    maxWidth: 760,
                    child: _MemberTile(member: members[i]),
                  ),
                ),
              ),
      )),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member});
  final TeamMemberRow member;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tag = member.isLead ? 'Team lead' : (member.isMe ? 'You' : null);
    return ListTile(
      key: ValueKey('team-member-${member.id}'),
      leading: NetAvatar(url: member.avatarUrl, radius: 22, fallback: const Icon(Icons.person)),
      title: Row(
        children: [
          Flexible(child: Text(member.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (tag != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: t.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(tag,
                  style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSecondaryContainer)),
            ),
          ],
        ],
      ),
      subtitle: member.plate == null
          ? Text('No vehicle on file',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: PlateChip(plate: member.plate!, fontSize: 15),
              ),
            ),
      trailing: member.isMe
          ? null
          : IconButton(
              key: ValueKey('team-chat-${member.id}'),
              icon: const Icon(Icons.chat_bubble_outline),
              tooltip: 'Chat',
              onPressed: () => showInfo(context, 'In-app chat with team members is coming soon.'),
            ),
    );
  }
}
