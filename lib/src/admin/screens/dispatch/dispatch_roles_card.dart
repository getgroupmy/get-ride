// Users → Edit User (0281): the person's dispatch roles with what each asks
// when they sign in (editable), where they stand, how their profile photo
// was taken, and their latest selfies and IDs (re-check selfies from a new
// phone among them). Nothing when they hold no role and sent nothing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/signin_checks.dart';
import '../../../data/identity_repository.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../signin_checks_review.dart' show checkKindText, checkStatusText;
import 'signin_checks_fields.dart';

final identityPersonProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, id) => ref.watch(identityRepositoryProvider).person(id),
);

String dispatchKindText(Object? kind) => switch (kind) {
  'stand_admin' => 'Stand admin',
  'fleet_owner' => 'Fleet owner',
  'staff' => 'Stand staff',
  _ => '$kind',
};

class DispatchRolesCard extends ConsumerWidget {
  const DispatchRolesCard({super.key, required this.userId, this.page = 'admin-user-edit'});
  final String userId;

  /// The page whose edit access changes the switches.
  final String page;

  Future<void> _edit(BuildContext context, WidgetRef ref, Map<String, dynamic> role) async {
    final asks = await editSignInChecks(
      context,
      name: dispatchKindText(role['kind']),
      current: SignInAsks.fromJson(role['verify']),
    );
    if (asks == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(identityRepositoryProvider).setAsks(userId, '${role['kind']}', asks),
      success: 'Sign-in checks saved.',
    );
    if (ok) ref.invalidate(identityPersonProvider(userId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final value = ref.watch(identityPersonProvider(userId)).value;
    if (value == null) return const SizedBox.shrink();
    final roles = [for (final r in (value['roles'] as List?) ?? const []) if (r is Map) Map<String, dynamic>.from(r)];
    final checks = [for (final c in (value['checks'] as List?) ?? const []) if (c is Map) Map<String, dynamic>.from(c)];
    final photo = value['photo'] is Map ? Map<String, dynamic>.from(value['photo'] as Map) : null;
    if (roles.isEmpty && checks.isEmpty && photo == null) return const SizedBox.shrink();
    final canEdit = ref.watch(pageAccessProvider(page)) == AccessLevel.edit;
    return Card(
      key: const ValueKey('dispatch-roles-card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(roles.isEmpty ? 'Photo and ID checks' : 'Dispatch roles', style: t.textTheme.titleMedium),
            for (final r in roles)
              ListTile(
                key: ValueKey('dispatch-role-${r['kind']}'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  [
                    dispatchKindText(r['kind']),
                    [
                      for (final p in (r['places'] as List?) ?? const [])
                        if (p is Map) '${p['name']}',
                    ].join(', '),
                  ].where((s) => s.isNotEmpty).join(' · '),
                ),
                subtitle: Text(
                  [
                    asksText(SignInAsks.fromJson(r['verify'])) ?? 'Asks nothing when they sign in',
                    ?verifyStatus(r['verify']),
                    if (r['active'] == false) 'Disabled',
                  ].join(' · '),
                ),
                trailing: canEdit
                    ? IconButton(
                        key: ValueKey('dispatch-role-edit-${r['kind']}'),
                        tooltip: 'Sign-in checks',
                        icon: const Icon(Icons.verified_user_outlined),
                        onPressed: () => _edit(context, ref, r),
                      )
                    : null,
              ),
            if (photo != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Profile photo: ${livenessText(photo['liveness'])} · ${dateText(photo['at'])}',
                  key: const ValueKey('profile-photo-liveness'),
                  style: muted,
                ),
              ),
            if (checks.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Latest selfies and IDs', style: t.textTheme.labelLarge),
              for (final c in checks)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(c['kind'] == 'selfie' ? Icons.face_outlined : Icons.badge_outlined),
                  title: Text(checkKindText(c)),
                  subtitle: Text(
                    [
                      if (c['kind'] == 'selfie') livenessText(c['liveness'], c['liveness_detail']),
                      ?rejectReasonText(c['reject_reason'], c['reject_note']),
                      dateText(c['created_at']),
                    ].join(' · '),
                  ),
                  trailing: StatusChip(c['status'] as String?, label: checkStatusText(c['status'])),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => context.push('/admin/documents?kind=signin'),
                  child: const Text('Open in Documents'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
