import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';

final pushHistoryProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('push_notifications');
  return ref.watch(adminRepositoryProvider).pushHistory();
});

class AdminPushScreen extends ConsumerStatefulWidget {
  const AdminPushScreen({super.key});

  @override
  ConsumerState<AdminPushScreen> createState() => _AdminPushScreenState();
}

class _AdminPushScreenState extends ConsumerState<AdminPushScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _audience = 'all';
  bool _sending = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) {
      showInfo(context, 'Add a title and a message.');
      return;
    }
    final who = {'all': 'everyone', 'users': 'all passengers', 'partners': 'all partners'}[_audience];
    if (!await confirm(context, 'Send notification?', 'This goes to $who immediately and cannot be recalled.',
        ok: 'Send')) {
      return;
    }
    setState(() => _sending = true);
    try {
      final r = await ref.read(adminRepositoryProvider).sendPush(_title.text.trim(), _body.text.trim(), _audience);
      if (!mounted) return;
      showInfo(context, 'Sent to ${r['sent'] ?? 0} of ${r['recipients'] ?? 0} devices'
          '${(r['failed'] ?? 0) != 0 ? ' (${r['failed']} failed)' : ''}.');
      _title.clear();
      _body.clear();
      ref.invalidate(pushHistoryProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(moduleAccessProvider('push')) == AccessLevel.edit;
    return AdminPage(
      title: 'Push notifications',
      module: 'push',
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ResponsiveCenter(
          maxWidth: 760,
          padding: EdgeInsets.zero,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (canEdit)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('New broadcast', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'all', label: Text('Everyone')),
                        ButtonSegment(value: 'users', label: Text('Passengers')),
                        ButtonSegment(value: 'partners', label: Text('Partners')),
                      ],
                      selected: {_audience},
                      onSelectionChanged: (v) => setState(() => _audience = v.first),
                    ),
                    const SizedBox(height: 12),
                    TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title')),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _body,
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(labelText: 'Message'),
                    ),
                    const SizedBox(height: 12),
                    BusyButton.filled(
                      onPressed: _sending ? null : _send,
                      icon: const Icon(Icons.send),
                      child: const Text('Send'),

                    ),
                  ]),
                ),
              ),
            const SizedBox(height: 16),
            Text('Recent', style: Theme.of(context).textTheme.titleMedium),
            AsyncView(
              value: ref.watch(pushHistoryProvider),
              onRetry: () => ref.invalidate(pushHistoryProvider),
              data: (rows) => rows.isEmpty
                  ? const EmptyState(icon: Icons.campaign_outlined, title: 'Nothing sent yet')
                  : Column(children: [
                      for (final r in rows)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${r['title']}'),
                          subtitle: Text('${r['body']}\n${dateText(r['created_at'])} · ${r['audience']}'),
                          isThreeLine: true,
                          trailing: Text('${r['sent'] ?? 0}/${r['recipients'] ?? 0}'),
                        ),
                    ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
