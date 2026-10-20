// /drive/groups (migration 0251): the stand groups and fleets a driver can
// ask to join, and where they stand in each. A closed or open group's
// request is approved by an admin, a fleet's by its owner.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/dispatch.dart';
import '../../data/dispatch_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/search_select.dart';

final joinableGroupsProvider = FutureProvider.autoDispose<List<({DispatchGroup group, JoinState state})>>(
  (ref) => ref.watch(dispatchRepositoryProvider).joinable(),
);

class StandGroupsScreen extends ConsumerWidget {
  const StandGroupsScreen({super.key});

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() f, String done) async {
    try {
      await f();
      ref.invalidate(joinableGroupsProvider);
      if (context.mounted) showInfo(context, done);
    } catch (e) {
      if (context.mounted) showError(context, "Couldn't do that. Try again.");
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final repo = ref.read(dispatchRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/drive')),
        title: const Text('Stand groups'),
      ),
      body: AsyncView(
        value: ref.watch(joinableGroupsProvider),
        onRetry: () => ref.invalidate(joinableGroupsProvider),
        data: (list) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ResponsiveCenter(
              maxWidth: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Taxi stands, hotels, malls and terminals send their customers to the drivers of a group. Ask to '
                    'join the ones where you work; you get their orders once approved.',
                    style: muted,
                  ),
                  const SizedBox(height: 12),
                  if (list.isEmpty) const EmptyState(icon: Icons.groups_outlined, title: 'No groups to join yet'),
                  ListSearchFilter(
                    count: list.length,
                    hint: 'Search groups',
                    fieldKey: const ValueKey('join-search'),
                    builder: (_, q) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final e in list)
                          if (q.isEmpty || e.group.name.toLowerCase().contains(q.toLowerCase()))
                            Card(
                              key: ValueKey('join-${e.group.id}'),
                              child: ListTile(
                                title: Text(e.group.name),
                                subtitle: Text(
                                  '${e.group.kind.label} · ${e.group.howItWorks}'
                                  '${e.state == JoinState.pending ? '\nWaiting for ${approverOf(e.group.kind)}.' : ''}',
                                ),
                                isThreeLine: e.state == JoinState.pending,
                                trailing: switch (e.state) {
                                  JoinState.none => FilledButton(
                                    key: ValueKey('join-ask-${e.group.id}'),
                                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                                    onPressed: () =>
                                        _run(context, ref, () => repo.askToJoin(e.group.id), 'Asked to join'),
                                    child: const Text('Ask to join'),
                                  ),
                                  JoinState.pending => TextButton(
                                    onPressed: () =>
                                        _run(context, ref, () => repo.leave(e.group.id), 'Request withdrawn'),
                                    child: const Text('Withdraw'),
                                  ),
                                  JoinState.approved => TextButton(
                                    onPressed: () => _run(context, ref, () => repo.leave(e.group.id), 'Left the group'),
                                    child: const Text('Leave'),
                                  ),
                                  JoinState.rejected => Text(e.state.label, style: muted),
                                },
                                leading: Icon(
                                  e.state == JoinState.approved ? Icons.verified_outlined : Icons.groups_outlined,
                                  color: e.state == JoinState.approved ? t.colorScheme.primary : null,
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
