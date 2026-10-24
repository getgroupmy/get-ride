// Admin → Documents → Sign-in checks (migration 0281): the selfies and IDs
// that stand admins, stand staff and fleet owners send before their role
// opens, re-check selfies from a new phone among them. "Waiting for
// approval" first, with its count. Each shows how the selfie was taken
// (live or not checked), what the phone read off the card against the
// profile, the face match score with who gave it (help, never the
// decision; 0283: AWS or the self-hosted server, or why it isn't checked),
// reading the card again with Google Vision, and the decision with a reason
// from the list. 0290: the partners' selfies from going online are listed
// too (why it was asked, the phone, the match, the live check); low matches
// come first as "Needs a closer look", under Waiting and All, and all of them
// under Going online.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/signin_checks.dart';
import '../../data/identity_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart' show formatStoredDateForUser;
import '../../widgets/in_app_page.dart';
import '../../widgets/net_image.dart';
import '../../widgets/storage_image.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/reject_reason.dart';
import 'online_selfie_check_screen.dart';

final signInChecksProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, filter) => ref.watch(identityRepositoryProvider).list(filter),
);

final signInChecksWaitingProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(identityRepositoryProvider).waitingCount(),
);

const _filters = {
  'waiting': 'Waiting for approval',
  'online': 'Going online',
  'approved': 'Approved',
  'rejected': 'Rejected',
  'all': 'All',
};

/// The list search for a going-online check: name, phone and phone model.
bool onlineCheckMatches(Map<String, dynamic> c, String q) {
  final s = q.trim().toLowerCase();
  if (s.isEmpty) return true;
  return [c['name'], c['phone'], c['device_model']].whereType<Object>().join(' ').toLowerCase().contains(s);
}

/// What was sent, in a word.
String checkKindText(Map<String, dynamic> c) => switch ((c['kind'], c['purpose'], c['doc_type'])) {
  ('selfie', 'recheck', _) => 'Selfie: new phone',
  ('selfie', _, _) => 'Selfie',
  ('id', _, 'passport') => 'Passport',
  ('id', _, _) => 'MyKad',
  _ => 'Upload',
};

/// The words a status shows as.
String checkStatusText(Object? s) => switch (s) {
  'Pending Review' => 'Waiting for approval',
  'Approved' => 'Approved',
  'Rejected' => 'Rejected',
  _ => '${s ?? ''}',
};

/// The list search: name, phone, IC and what was read.
bool checkMatches(Map<String, dynamic> c, String q) {
  final s = q.trim().toLowerCase();
  if (s.isEmpty) return true;
  return [c['name'], c['phone'], c['ic'], c['read_name'], c['read_ic']]
      .whereType<Object>()
      .join(' ')
      .toLowerCase()
      .contains(s);
}

void _refresh(WidgetRef ref) {
  ref.invalidate(signInChecksProvider);
  ref.invalidate(signInChecksWaitingProvider);
  refreshOnlineSelfieChecks(ref);
}

class SignInChecksReview extends ConsumerStatefulWidget {
  const SignInChecksReview({super.key});

  @override
  ConsumerState<SignInChecksReview> createState() => _SignInChecksReviewState();
}

class _SignInChecksReviewState extends ConsumerState<SignInChecksReview> {
  String _filter = 'waiting';
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final waiting = ref.watch(signInChecksWaitingProvider).value;
    final closerCount = ref.watch(onlineSelfieCloserCountProvider).value ?? 0;
    final config = ref.watch(identityConfigProvider).value;
    // Going online (0290): those needing a closer look first; all of them
    // under Going online and All. A database before 0290 has none.
    final online = switch (_filter) {
      'online' || 'all' => ref.watch(onlineSelfieChecksProvider('all')).value,
      'waiting' => ref.watch(onlineSelfieChecksProvider('closer')).value,
      _ => null,
    } ?? const <Map<String, dynamic>>[];
    final onlineShown = online.where((c) => onlineCheckMatches(c, _query)).toList();
    final closer = [for (final c in onlineShown) if (c['closer'] == true) c];
    final calm = [for (final c in onlineShown) if (c['closer'] != true) c];
    return Column(
      children: [
        FilterBar(
          filters: {
            for (final e in _filters.entries)
              e.key: switch (e.key) {
                'waiting' when waiting != null => '${e.value} ($waiting)',
                'online' when closerCount > 0 => '${e.value} ($closerCount to look at)',
                _ => e.value,
              },
          },
          selected: _filter,
          onSelected: (f) => setState(() => _filter = f),
          onSearch: (q) => setState(() => _query = q),
          hint: 'Search name, phone or IC…',
        ),
        Expanded(
          child: AsyncView(
            value: ref.watch(signInChecksProvider(_filter == 'online' ? 'waiting' : _filter)),
            onRetry: () => _refresh(ref),
            data: (rows) {
              final list = _filter == 'online'
                  ? const <Map<String, dynamic>>[]
                  : rows.where((c) => checkMatches(c, _query)).toList();
              // Low matches first; then the uploads, the newest first, the
              // calm going-online checks among them.
              final items = <(Map<String, dynamic>, bool)>[
                for (final c in closer) (c, true),
                ...[
                  for (final c in list) (c, false),
                  for (final c in calm) (c, true),
                ]..sort((a, b) => '${b.$1['answered_at'] ?? b.$1['created_at']}'.compareTo(
                      '${a.$1['answered_at'] ?? a.$1['created_at']}',
                    )),
              ];
              if (items.isEmpty) return const EmptyState(icon: Icons.task_alt, title: 'Nothing to show');
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final (c, goingOnline) = items[i];
                  if (goingOnline) return OnlineCheckTile(row: c);
                  final warn = mismatchWarning(c['mismatch']);
                  return ListTile(
                    key: ValueKey('signin-check-${c['id']}'),
                    leading: _Thumb(url: c['file_url'] as String?),
                    title: Text('${c['name'] ?? c['phone'] ?? 'Someone'}'),
                    subtitle: Text(
                      [
                        checkKindText(c),
                        if (c['kind'] == 'selfie') livenessText(c['liveness'], c['liveness_detail']),
                        ?warn,
                        faceMatchText(
                          c['face_state'],
                          c['face_score'],
                          provider: c['face_provider'],
                          reason: c['face_reason'] ?? config?.faceUnusable,
                        ),
                        dateText(c['created_at']),
                      ].where((s) => s.isNotEmpty).join(' · '),
                    ),
                    trailing: StatusChip(c['status'] as String?, label: checkStatusText(c['status'])),
                    onTap: () => showAdminSheet<void>(
                      context,
                      title: '${checkKindText(c)}: ${c['name'] ?? c['phone'] ?? ''}',
                      builder: (_) => SignInCheckSheet(row: c, onChanged: () => _refresh(ref)),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null || !u.startsWith('http')) return const CircleAvatar(child: Icon(Icons.badge_outlined));
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

/// One upload: the photos, the checks, the decision.
class SignInCheckSheet extends ConsumerStatefulWidget {
  const SignInCheckSheet({super.key, required this.row, required this.onChanged});
  final Map<String, dynamic> row;
  final VoidCallback onChanged;

  @override
  ConsumerState<SignInCheckSheet> createState() => _SignInCheckSheetState();
}

class _SignInCheckSheetState extends ConsumerState<SignInCheckSheet> {
  late Map<String, dynamic> _row = widget.row;
  bool _comparing = false;
  bool _reading = false;

  Future<void> _compare() async {
    setState(() => _comparing = true);
    final r = await ref.read(identityRepositoryProvider).compareFaces('${_row['id']}');
    if (!mounted) return;
    setState(() {
      _comparing = false;
      _row = {
        ..._row,
        'face_state': r['state'],
        'face_score': r['score'],
        'face_provider': r['provider'],
        'face_reason': r['reason'],
      };
    });
    final why = faceReasonText(r['reason']);
    if (why != null) showInfo(context, 'Not checked: $why.');
    if (r['fell_back'] == true) showInfo(context, "The self-hosted server didn't answer, so AWS checked it.");
    if (r['state'] == 'error' && r['detail'] != null) showInfo(context, "Couldn't check: ${r['detail']}");
    widget.onChanged();
  }

  Future<void> _readAgain() async {
    setState(() => _reading = true);
    final r = await ref.read(identityRepositoryProvider).readCardWithVision('${_row['id']}');
    if (!mounted) return;
    setState(() {
      _reading = false;
      if (r['state'] == 'read' || r['reason'] == 'nothing_found') {
        _row = {
          ..._row,
          'read_name': r['name'] ?? _row['read_name'],
          'read_ic': r['ic'] ?? _row['read_ic'],
          'read_passport': r['passport'] ?? _row['read_passport'],
          'read_expiry': r['expiry'] ?? _row['read_expiry'],
          'read_source': 'vision',
          if (r['mismatch'] is List) 'mismatch': r['mismatch'],
        };
      }
    });
    showInfo(context, switch (r) {
      {'state': 'read'} => 'Read with Google Vision.',
      {'reason': 'nothing_found'} => 'Google Vision found no name or number on the card.',
      {'reason': 'no_key'} => 'Not read: add a Google Cloud Vision key in Admin, API Keys.',
      {'reason': 'no_photo'} => "Not read: the card's photo couldn't be opened.",
      {'reason': 'too_big'} => "Not read: the card's photo is too big.",
      {'detail': final String d} => "Couldn't read: $d",
      _ => "Couldn't read the card. Try again.",
    });
    widget.onChanged();
  }

  Future<void> _decide(bool approve) async {
    RejectChoice? choice;
    if (!approve) {
      choice = await pickRejectReason(context);
      if (choice == null || !mounted) return;
    }
    final ok = await runAdminAction(
      context,
      () => ref
          .read(identityRepositoryProvider)
          .review('${_row['id']}', approve: approve, reason: choice?.reason, note: choice?.note),
      success: approve ? 'Approved' : 'Rejected',
    );
    if (!ok || !mounted) return;
    widget.onChanged();
    Navigator.pop(context);
  }

  Widget _photo(String label, Object? url) {
    final u = url as String?;
    if (u == null || !u.startsWith('http')) return const SizedBox.shrink();
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            InkWell(
              onTap: () => openStoredFile(context, u, title: label),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: StorageImage(
                  u,
                  height: 180,
                  fit: BoxFit.contain,
                  frameBuilder: boneUntilPainted(height: 180),
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = _row;
    final canEdit = ref.watch(moduleAccessProvider('documents')) == AccessLevel.edit;
    final warn = mismatchWarning(c['mismatch']);
    final selfie = c['kind'] == 'selfie';
    final rejected = c['status'] == 'Rejected' ? rejectReasonText(c['reject_reason'], c['reject_note']) : null;
    final config = ref.watch(identityConfigProvider).value;
    final readBy = readSourceText(c['read_source']);
    return Column(
      key: const ValueKey('signin-check-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [StatusChip(c['status'] as String?, label: checkStatusText(c['status']))]),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: selfie
              ? [_photo('Selfie', c['file_url'])]
              : [_photo('Front', c['file_url']), _photo('Back', c['file_url_back'])],
        ),
        if (warn != null) ...[
          const SizedBox(height: 12),
          DecoratedBox(
            key: const ValueKey('signin-check-mismatch'),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_outlined, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(child: Text(warn)),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        DetailTable({
          'What': checkKindText(c),
          if (selfie) 'Live check': livenessText(c['liveness'], c['liveness_detail']),
          'Name on profile': c['name'],
          'IC on profile': c['ic'],
          if (!selfie) 'Name read': c['read_name'] ?? 'Not read',
          if (!selfie) 'IC read': c['read_ic'] ?? 'Not read',
          if (!selfie && c['read_passport'] != null) 'Passport no. read': c['read_passport'],
          if (!selfie && readBy != null) 'Read by': readBy,
          if (!selfie && c['expiry_date'] != null) 'Expiry': formatStoredDateForUser(c['expiry_date']),
          'Face match': faceMatchText(
            c['face_state'],
            c['face_score'],
            provider: c['face_provider'],
            reason: c['face_reason'] ?? config?.faceUnusable,
          ),
          'Phone': c['phone'],
          'Sent': dateText(c['created_at']),
          if (c['reviewed_at'] != null) 'Reviewed': '${dateText(c['reviewed_at'])} · ${c['reviewer'] ?? ''}',
          'Reason': ?rejected,
        }),
        Wrap(
          spacing: 8,
          children: [
            BusyButton.text(
              key: const ValueKey('signin-check-compare'),
              onPressed: _comparing || !canEdit ? null : _compare,
              icon: const Icon(Icons.face_retouching_natural_outlined),
              child: Text(_comparing ? 'Comparing' : 'Compare selfie with ID'),
            ),
            if (!selfie && canEdit)
              BusyButton.text(
                key: const ValueKey('signin-check-read-again'),
                onPressed: _reading ? null : _readAgain,
                icon: const Icon(Icons.document_scanner_outlined),
                child: Text(_reading ? 'Reading' : 'Read card again (Google Vision)'),
              ),
          ],
        ),
        Text(
          'The face match helps you decide. It never approves on its own.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (canEdit)
          Row(
            children: [
              Expanded(
                // Asks why first, so no spinner behind the list of reasons.
                child: OutlinedButton.icon(
                  key: const ValueKey('signin-check-reject'),
                  icon: const Icon(Icons.close),
                  onPressed: () => _decide(false),
                  label: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: BusyButton.filled(
                  key: const ValueKey('signin-check-approve'),
                  icon: const Icon(Icons.check),
                  onPressed: () => _decide(true),
                  child: const Text('Approve'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
