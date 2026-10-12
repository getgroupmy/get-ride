import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notification_delivery.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../saved_push.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';

/// Trip pushes delivered over the last day (migration 0144), re-read live.
final notificationDeliveryProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('notification_outbox');
  return ref.watch(adminRepositoryProvider).notificationDelivery();
});

final pushHistoryProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('push_notifications');
  return ref.watch(adminRepositoryProvider).pushHistory();
});

/// Notifications kept to send again (`settings_entries`, `push-notification`).
final savedPushesProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('settings_entries');
  return ref.watch(adminRepositoryProvider).savedPushes();
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
  bool _saving = false;

  /// The saved notification being edited in the compose card, if any.
  SavedPush? _editing;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  static const _who = {'all': 'everyone', 'users': 'all passengers', 'partners': 'all partners'};

  void _resetCompose() {
    _title.clear();
    _body.clear();
    _audience = 'all';
    _editing = null;
  }

  /// Stores the compose card as a saved notification (a new one, or the one
  /// being edited). False when nothing was saved.
  Future<bool> _persist() async {
    final values = savedPushValues(
      existing: _editing?.values,
      title: _title.text,
      body: _body.text,
      audience: _audience,
      now: DateTime.now(),
    );
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).savePushTemplate(id: _editing?.id, values: values),
    );
    if (ok) ref.invalidate(savedPushesProvider);
    return ok;
  }

  Future<void> _save() async {
    final problem = validatePushDraft(_title.text, _body.text);
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    final editing = _editing != null;
    setState(() => _saving = true);
    final ok = await _persist();
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _resetCompose();
    });
    if (ok) showInfo(context, editing ? 'Saved notification updated' : 'Notification saved');
  }

  Future<void> _dispatch(String title, String body, String audience) async {
    final r = await ref.read(adminRepositoryProvider).sendPush(title, body, audience);
    if (!mounted) return;
    showInfo(context, pushResultText(r, audience));
    ref.invalidate(pushHistoryProvider);
  }

  Future<void> _send() async {
    final problem = validatePushDraft(_title.text, _body.text);
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    if (!await confirm(context, 'Send notification?',
        'This goes to ${_who[_audience]} immediately and cannot be recalled.',
        ok: 'Send')) {
      return;
    }
    setState(() => _sending = true);
    try {
      // Sending an edited saved notification keeps the edit (Expo did too).
      if (_editing != null && !await _persist()) return;
      await _dispatch(_title.text.trim(), _body.text.trim(), _audience);
      if (mounted) setState(_resetCompose);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _edit(SavedPush p) => setState(() {
        _editing = p;
        _title.text = p.title;
        _body.text = p.body;
        _audience = p.audience;
      });

  Future<void> _resend(SavedPush p) async {
    if (!p.sendable) {
      showInfo(context, 'This notification is missing a title or message.');
      return;
    }
    if (!await confirm(context, 'Send notification?',
        'Send "${p.title}" to ${_who[p.audience]}? It goes out immediately and cannot be recalled.',
        ok: 'Send')) {
      return;
    }
    try {
      await _dispatch(p.title, p.body, p.audience);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(SavedPush p) async {
    if (!await confirm(context, 'Delete saved notification?', 'Delete "${p.title}"? Pushes already sent stay sent.',
        ok: 'Delete')) {
      return;
    }
    if (!mounted) return;
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSavedPush(p.id),
        success: 'Deleted')) {
      if (_editing?.id == p.id && mounted) setState(_resetCompose);
      ref.invalidate(savedPushesProvider);
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
                    Row(children: [
                      Expanded(
                        child: Text(_editing == null ? 'New broadcast' : 'Edit saved notification',
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                      if (_editing != null)
                        TextButton(
                          key: const ValueKey('push-cancel-edit'),
                          onPressed: () => setState(_resetCompose),
                          child: const Text('Cancel edit'),
                        ),
                    ]),
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
                    TextField(
                      key: const ValueKey('push-title'),
                      controller: _title,
                      decoration: const InputDecoration(labelText: 'Title'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('push-body'),
                      controller: _body,
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(labelText: 'Message'),
                    ),
                    const SizedBox(height: 12),
                    Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
                      OutlinedButton.icon(
                        key: const ValueKey('push-save'),
                        onPressed: _sending || _saving ? null : _save,
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: Text(_editing == null ? 'Save for later' : 'Save changes'),
                      ),
                      BusyButton.filled(
                        key: const ValueKey('push-send'),
                        onPressed: _sending || _saving ? null : _send,
                        icon: const Icon(Icons.send),
                        child: const Text('Send'),
                      ),
                    ]),
                  ]),
                ),
              ),
            const SizedBox(height: 16),
            Text('Saved', style: Theme.of(context).textTheme.titleMedium),
            AsyncView(
              value: ref.watch(savedPushesProvider),
              onRetry: () => ref.invalidate(savedPushesProvider),
              data: (saved) => saved.isEmpty
                  ? const EmptyState(
                      icon: Icons.bookmarks_outlined,
                      title: 'No saved notifications',
                      message: 'Save a notification to send it again later.',
                    )
                  : Column(children: [
                      for (final p in saved)
                        ListTile(
                          key: ValueKey('saved-push-${p.id}'),
                          contentPadding: EdgeInsets.zero,
                          selected: _editing?.id == p.id,
                          title: Text(p.title.isEmpty ? '(no title)' : p.title),
                          subtitle: Text('${p.body}\n${pushAudienceLabel(p.audience)}'
                              '${p.updatedAt == null ? '' : ' · ${dateText(p.updatedAt)}'}'),
                          isThreeLine: true,
                          trailing: canEdit
                              ? Row(mainAxisSize: MainAxisSize.min, children: [
                                  IconButton(
                                    key: ValueKey('saved-push-send-${p.id}'),
                                    tooltip: 'Send again',
                                    icon: const Icon(Icons.send_outlined),
                                    onPressed: _sending ? null : () => _resend(p),
                                  ),
                                  IconButton(
                                    key: ValueKey('saved-push-edit-${p.id}'),
                                    tooltip: 'Edit',
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: () => _edit(p),
                                  ),
                                  IconButton(
                                    key: ValueKey('saved-push-delete-${p.id}'),
                                    tooltip: 'Delete',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _delete(p),
                                  ),
                                ])
                              : null,
                        ),
                    ]),
            ),
            const SizedBox(height: 16),
            const DeliveryCard(),
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

/// Trip updates and payment pushes are retried until an app acknowledges
/// them: how many arrived, how fast, and how many gave up (last 24 h).
class DeliveryCard extends ConsumerWidget {
  const DeliveryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('push-delivery'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(notificationDeliveryProvider),
          onRetry: () => ref.invalidate(notificationDeliveryProvider),
          data: (rows) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('Delivery (last 24 h)', style: t.textTheme.titleMedium)),
              Text(deliveryRateText(overallDeliveryRate(rows)),
                  key: const ValueKey('push-delivery-rate'),
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            Text('Trip updates and payment pushes are sent again until the app confirms it has them.',
                style: t.textTheme.bodySmall),
            if (rows.isEmpty)
              const Padding(padding: EdgeInsets.only(top: 12), child: Text('No trip pushes yet.'))
            else
              for (final r in rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${r.label}${r.priority == 'critical' ? ' · critical' : ''}'),
                  subtitle: Text('${r.delivered}/${r.sent} delivered · ${r.pending} retrying · ${r.gaveUp} gave up'
                      ' · acknowledged in ${ackTimeText(r.avgAckSeconds)}'),
                  trailing: Text(deliveryRateText(r.rate),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: (r.rate ?? 1) < 0.9 ? t.colorScheme.error : null,
                      )),
                ),
          ]),
        ),
      ),
    );
  }
}
