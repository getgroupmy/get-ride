// One partner selfie check from going online (migration 0290): what the
// low-match push opens, and what Documents › Sign-in checks and Edit
// Partner open. The selfie beside the profile photo and ID photo it was
// compared with, why it was asked, the phone, the match with who gave it,
// the live check; and Call partner, Go offline (Change status, 0286), Add to
// watch list, Looked at it, Compare again. The partner went online either
// way: nothing here was a decision.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/online_selfie.dart';
import '../../core/partner_remote_action.dart';
import '../../core/signin_checks.dart';
import '../../data/online_selfie_repository.dart';
import '../../data/partner_remote_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/in_app_page.dart';
import '../../widgets/net_image.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/storage_image.dart';
import '../admin_access.dart';
import '../admin_filters.dart' show phoneCallUri;
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import 'dispatch/selfie_checks_settings.dart' show dispatchSelfiePage;
import 'people/partner_remote_sheet.dart' show remoteRequestError;
import 'people_screens.dart' show adminDialerProvider;
import 'selfie_watch_list.dart';

final onlineSelfieCheckProvider = FutureProvider.autoDispose.family<Map<String, dynamic>?, String>(
  (ref, id) => ref.watch(onlineSelfieRepositoryProvider).check(id),
);

/// Documents › Sign-in checks: the going-online checks ('closer' or 'all').
final onlineSelfieChecksProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, filter) => ref.watch(onlineSelfieRepositoryProvider).list(filter),
);

final onlineSelfieCloserCountProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(onlineSelfieRepositoryProvider).closerCount(),
);

/// Edit Partner: {checks, watch}.
final onlineSelfiePersonProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, uid) => ref.watch(onlineSelfieRepositoryProvider).person(uid),
);

/// Pages whose editors mark a check looked at (the server's admin_table_pages).
const _reviewPages = [
  dispatchSelfiePage,
  'admin-partner-edit',
  'admin-documents',
  'admin-documents-partners',
  'admin-support',
];

/// Pages whose editors may ask for the comparison again (face-compare).
const _comparePages = [
  dispatchSelfiePage,
  'admin-partners',
  'admin-partner-edit',
  'admin-documents',
  'admin-documents-users',
  'admin-documents-partners',
];

void refreshOnlineSelfieChecks(WidgetRef ref) {
  ref.invalidate(onlineSelfieCheckProvider);
  ref.invalidate(onlineSelfieChecksProvider);
  ref.invalidate(onlineSelfieCloserCountProvider);
  ref.invalidate(onlineSelfiePersonProvider);
}

/// The match in the admin's words: "41% match · AWS", "Not checked · …".
String onlineMatchText(Map<String, dynamic> c) => switch (c['face_state']) {
  'pending' => 'Comparing',
  null => '',
  _ => faceMatchText(c['face_state'], c['face_score'], provider: c['face_provider'], reason: c['face_reason']),
};

/// One line about a check, for the lists: "Going online: New phone ·
/// samsung SM-A546E · 41% match · AWS · Live: blinked · 24 Oct 2026, 9:12 AM".
String onlineCheckSubtitle(Map<String, dynamic> c, {bool withName = false}) => [
  if (withName) '${c['name'] ?? c['phone'] ?? 'Partner'}',
  'Going online: ${onlineCheckReasonText(c['reason'])}',
  ?(c['device_model'] as String?),
  if (c['state'] == 'answered') ...[
    onlineMatchText(c),
    livenessText(c['liveness'], c['liveness_detail']),
  ] else
    onlineCheckStateText(c),
  dateText(c['answered_at'] ?? c['created_at']),
].where((s) => s.isNotEmpty).join(' · ');

/// A check in a list; opens its page.
class OnlineCheckTile extends StatelessWidget {
  const OnlineCheckTile({super.key, required this.row, this.withName = true});
  final Map<String, dynamic> row;
  final bool withName;

  @override
  Widget build(BuildContext context) {
    final c = row;
    final closer = c['closer'] == true;
    final t = Theme.of(context);
    return ListTile(
      key: ValueKey('online-check-${c['id']}'),
      leading: _Thumb(url: c['file_url'] as String?),
      title: Text(withName ? '${c['name'] ?? c['phone'] ?? 'Partner'}' : onlineCheckReasonText(c['reason'])),
      subtitle: Text(onlineCheckSubtitle(c)),
      trailing: closer
          ? DecoratedBox(
              decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  'Needs a closer look',
                  style: t.textTheme.labelSmall?.copyWith(
                    color: t.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          : null,
      onTap: () => context.push('/admin/m/online-selfie-check?id=${c['id']}'),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null || !u.startsWith('http')) return const CircleAvatar(child: Icon(Icons.face_outlined));
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: StorageImage(
        u,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        frameBuilder: boneUntilPainted(width: 48, height: 48),
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      ),
    );
  }
}

/// `/admin/m/online-selfie-check?id=`: the check, from the push or a list.
class OnlineSelfieCheckScreen extends ConsumerWidget {
  const OnlineSelfieCheckScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AdminPage(
    title: 'Selfie check',
    page: dispatchSelfiePage,
    body: AsyncView(
      value: ref.watch(onlineSelfieCheckProvider(id)),
      onRetry: () => ref.invalidate(onlineSelfieCheckProvider(id)),
      data: (c) => c == null
          ? const EmptyState(icon: Icons.search_off, title: 'This check is gone')
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ResponsiveCenter(maxWidth: 820, child: OnlineSelfieCheckView(row: c)),
            ),
    ),
  );
}

class OnlineSelfieCheckView extends ConsumerStatefulWidget {
  const OnlineSelfieCheckView({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  ConsumerState<OnlineSelfieCheckView> createState() => _OnlineSelfieCheckViewState();
}

class _OnlineSelfieCheckViewState extends ConsumerState<OnlineSelfieCheckView> {
  bool _comparing = false;

  Map<String, dynamic> get c => widget.row;
  String get _name => '${c['name'] ?? c['phone'] ?? 'Partner'}';

  Future<void> _call() async {
    final uri = phoneCallUri(c['phone']);
    if (uri == null) return;
    final ok = await ref.read(adminDialerProvider)(uri);
    if (!ok && mounted) await showNotice(context, title: 'Call partner', message: 'Call ${c['phone']}');
  }

  Future<void> _goOffline() async {
    final go = await showAppDialog<bool>(
      id: 'admin.online-selfie-go-offline',
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go offline'),
        content: Text(
          "Ask $_name's phone to go offline (Change status). The phone does it and says how it went on Edit Partner.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('selfie-go-offline-yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Go offline'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    try {
      await ref.read(partnerRemoteRepositoryProvider).request('${c['user_id']}', RemoteAction.goOffline);
      if (mounted) {
        await showNotice(context, title: 'Go offline', message: "Asked $_name's phone to go offline.");
      }
    } catch (e) {
      if (mounted) await showNotice(context, title: "Couldn't ask the phone", message: remoteRequestError(e));
    }
  }

  Future<void> _watch() async {
    final changed = await editSelfieWatch(
      context,
      ref,
      userId: '${c['user_id']}',
      name: _name,
      current: WatchEntry.maybe(c['watch']),
      fromCheck: '${c['id']}',
    );
    if (changed) refreshOnlineSelfieChecks(ref);
  }

  Future<void> _lookedAt() async {
    final note = await showAppDialog<String>(
      id: 'admin.online-selfie-looked',
      context: context,
      builder: (_) => const _LookedAtDialog(),
    );
    if (note == null || !mounted) return;
    try {
      await ref.read(onlineSelfieRepositoryProvider).review('${c['id']}', note: note);
      refreshOnlineSelfieChecks(ref);
    } catch (e) {
      if (mounted) await showErrorNotice(context, e, title: "Couldn't save");
    }
  }

  Future<void> _compare() async {
    setState(() => _comparing = true);
    final r = await ref.read(onlineSelfieRepositoryProvider).compareAgain('${c['id']}');
    if (!mounted) return;
    setState(() => _comparing = false);
    refreshOnlineSelfieChecks(ref);
    final why = faceReasonText(r['reason']);
    if (r['state'] == 'error' || why != null) {
      await showNotice(
        context,
        title: 'Compare again',
        message: why != null ? 'Not checked: $why.' : "Couldn't compare: ${r['reason'] ?? r['detail'] ?? 'try again'}.",
      );
    }
  }

  Widget _photo(String label, Object? url, Key key) {
    final u = url as String?;
    final t = Theme.of(context);
    return SizedBox(
      key: key,
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.textTheme.bodySmall),
          const SizedBox(height: 4),
          if (u == null || !u.startsWith('http'))
            Container(
              height: 160,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('None on record', style: t.textTheme.bodySmall),
            )
          else
            InkWell(
              onTap: () => openStoredFile(context, u, title: label),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: StorageImage(
                  u,
                  height: 160,
                  fit: BoxFit.contain,
                  frameBuilder: boneUntilPainted(height: 160),
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final access = ref.watch(adminAccessProvider).value ?? AdminAccess.none;
    final watch = WatchEntry.maybe(c['watch']);
    final closer = c['closer'] == true;
    final answered = c['state'] == 'answered';
    String score(Object? s) => s is num ? '${s.round()}%' : 'Not compared';
    return Column(
      key: const ValueKey('online-selfie-check'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_name, style: t.textTheme.titleLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _Pill(
              onlineCheckStateText(c),
              closer
                  ? (t.colorScheme.errorContainer, t.colorScheme.onErrorContainer)
                  : switch (c['state']) {
                      'due' => (t.colorScheme.tertiaryContainer, t.colorScheme.onTertiaryContainer),
                      'lapsed' => (t.colorScheme.surfaceContainerHighest, t.colorScheme.onSurface),
                      _ => (t.colorScheme.primaryContainer, t.colorScheme.onPrimaryContainer),
                    },
            ),
            if (c['online_now'] == true)
              _Pill('Online now', (t.colorScheme.primaryContainer, t.colorScheme.onPrimaryContainer)),
            if (watch != null)
              _Pill('Watch list: ${watchEntryText(watch)}', (
                t.colorScheme.secondaryContainer,
                t.colorScheme.onSecondaryContainer,
              )),
          ],
        ),
        if (closer) ...[
          const SizedBox(height: 12),
          DecoratedBox(
            key: const ValueKey('online-selfie-closer'),
            decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_outlined, color: t.colorScheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Low selfie match: ${score(c['face_score'])}, below ${c['low_below'] ?? 60}%. '
                      'They went online. Needs a closer look.',
                      style: TextStyle(color: t.colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _photo('Selfie (going online)', c['file_url'], const ValueKey('online-selfie-photo')),
            _photo('Profile photo', c['photo_url'], const ValueKey('online-profile-photo')),
            _photo('ID photo', c['id_url'], const ValueKey('online-id-photo')),
          ],
        ),
        const SizedBox(height: 12),
        DetailTable({
          'Why': onlineCheckReasonText(c['reason']),
          'Phone model': c['device_model'] ?? 'Not known',
          if (answered) 'Match': onlineMatchText(c),
          if (answered && c['face_state'] != 'pending') 'Profile photo match': score(c['photo_score']),
          if (answered && c['face_state'] != 'pending') 'ID photo match': score(c['id_score']),
          if (answered) 'Live check': livenessText(c['liveness'], c['liveness_detail']),
          if (!answered) 'Answer': onlineCheckStateText(c),
          'Asked': dateText(c['created_at']),
          if (c['answered_at'] != null) 'Taken': dateText(c['answered_at']),
          if (c['alerted_at'] != null)
            'Alert':
                '${dateText(c['alerted_at'])} · ${c['alert_sent'] == 1 ? '1 admin' : '${c['alert_sent'] ?? 0} admins'}',
          if (c['reviewed_at'] != null)
            'Looked at': [
              dateText(c['reviewed_at']),
              ?(c['reviewer'] as String?),
              ?(c['review_note'] as String?),
            ].join(' · '),
          'Phone': c['phone'],
        }),
        Text(
          'The face match helps you decide. The partner went online either way.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (phoneCallUri(c['phone']) != null)
              FilledButton.tonalIcon(
                key: const ValueKey('selfie-call'),
                onPressed: _call,
                icon: const Icon(Icons.call_outlined),
                label: const Text('Call partner'),
              ),
            if (access.canEdit(const ['admin-partners', 'admin-partner-edit']))
              FilledButton.tonalIcon(
                key: const ValueKey('selfie-go-offline'),
                onPressed: _goOffline,
                icon: const Icon(Icons.toggle_off_outlined),
                label: const Text('Go offline'),
              ),
            if (access.canEdit(watchListEditPages))
              FilledButton.tonalIcon(
                key: const ValueKey('selfie-watch'),
                onPressed: _watch,
                icon: const Icon(Icons.visibility_outlined),
                label: Text(watch == null ? 'Add to watch list' : 'Change watch list'),
              ),
            if (closer && access.canEdit(_reviewPages))
              OutlinedButton.icon(
                key: const ValueKey('selfie-looked'),
                onPressed: _lookedAt,
                icon: const Icon(Icons.task_alt),
                label: const Text('Looked at it'),
              ),
            if (answered && access.canEdit(_comparePages))
              BusyButton.text(
                key: const ValueKey('selfie-compare'),
                onPressed: _comparing ? null : _compare,
                icon: const Icon(Icons.face_retouching_natural_outlined),
                child: Text(_comparing ? 'Comparing' : 'Compare again'),
              ),
            if (c['partner_id'] != null)
              TextButton.icon(
                key: const ValueKey('selfie-partner'),
                onPressed: () => context.push('/admin/m/partner-edit?id=${c['partner_id']}'),
                icon: const Icon(Icons.person_outline),
                label: const Text('Edit Partner'),
              ),
          ],
        ),
      ],
    );
  }
}

/// Edit Partner: their last selfie checks from going online, and the watch
/// list entry, with Add / Change.
class PartnerSelfieChecksCard extends ConsumerWidget {
  const PartnerSelfieChecksCard({super.key, required this.userId, required this.name});
  final String userId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final v = ref.watch(onlineSelfiePersonProvider(userId));
    final canEdit = canEditWatchList(ref);
    return Card(
      key: const ValueKey('partner-selfie-checks'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: v.when(
          skipLoadingOnReload: true,
          loading: () => const SizedBox(height: 48, child: Center(child: CircularProgressIndicator())),
          error: (_, _) => Text("Couldn't load the selfie checks.", style: muted),
          data: (m) {
            final checks = [
              if (m['checks'] is List)
                for (final c in m['checks'] as List)
                  if (c is Map) Map<String, dynamic>.from(c),
            ];
            final watch = WatchEntry.maybe(m['watch']);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Selfie checks when going online', style: t.textTheme.titleMedium)),
                    if (canEdit)
                      TextButton.icon(
                        key: const ValueKey('partner-selfie-watch'),
                        onPressed: () async {
                          final changed = await editSelfieWatch(
                            context,
                            ref,
                            userId: userId,
                            name: name,
                            current: watch,
                          );
                          if (changed) refreshOnlineSelfieChecks(ref);
                        },
                        icon: const Icon(Icons.visibility_outlined),
                        label: Text(watch == null ? 'Add to watch list' : 'Watch list'),
                      ),
                  ],
                ),
                if (watch != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'On the watch list: ${watchEntryText(watch)}. ${watch.reason}',
                      key: const ValueKey('partner-selfie-watch-text'),
                    ),
                  ),
                if (checks.isEmpty)
                  Text('No selfie checks yet.', style: muted)
                else
                  for (final c in checks) OnlineCheckTile(row: c, withName: false),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.colors);
  final String label;
  final (Color, Color) colors;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: colors.$1, borderRadius: BorderRadius.circular(20)),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colors.$2, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

/// "Looked at it", with an optional note; pops the note ('' for none) or
/// null when cancelled.
class _LookedAtDialog extends StatefulWidget {
  const _LookedAtDialog();

  @override
  State<_LookedAtDialog> createState() => _LookedAtDialogState();
}

class _LookedAtDialogState extends State<_LookedAtDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Looked at it'),
    content: TextField(
      key: const ValueKey('selfie-looked-note'),
      controller: _note,
      maxLength: 500,
      decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'Called them: it is them'),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const ValueKey('selfie-looked-save'),
        onPressed: () => Navigator.pop(context, _note.text),
        child: const Text('Save'),
      ),
    ],
  );
}
