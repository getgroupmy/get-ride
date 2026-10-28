// On a driver's Partners sheet (migration 0311): their trip reports and the
// riders who blocked them, with the review flag and Mark reviewed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../data/ride_safety_repository.dart';
import '../../../widgets/busy.dart';
import '../../widgets/admin_widgets.dart';

class DriverSafetyPanel extends ConsumerWidget {
  const DriverSafetyPanel({super.key, required this.partnerUserId, required this.canEdit});

  /// The partner's sign-in id (partners.auth_user_id).
  final String partnerUserId;
  final bool canEdit;

  Future<void> _review(BuildContext context, WidgetRef ref) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(rideSafetyRepositoryProvider).markBlocksReviewed(partnerUserId),
      success: 'Marked reviewed. Blocks are counted afresh from now.',
    );
    if (ok) {
      ref.invalidate(adminDriverSafetyProvider(partnerUserId));
      ref.invalidate(adminDriverSafetyFlagsProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(adminDriverSafetyProvider(partnerUserId)).value;
    // Nothing to show, or a database before 0311.
    if (d == null || (d.reports.isEmpty && d.blocks.isEmpty)) return const SizedBox.shrink();
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Column(
      key: const ValueKey('driver-safety-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        if (d.flagged)
          Container(
            key: const ValueKey('driver-block-flag'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.flag, color: c.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Blocked by ${d.blocksSinceReview} riders since the last review (flag at ${d.flagRiders}).',
                  style: TextStyle(color: c.onErrorContainer),
                ),
              ),
              if (canEdit)
                BusyButton.text(
                  key: const ValueKey('driver-block-review'),
                  onPressed: () => _review(context, ref),
                  child: const Text('Mark reviewed'),
                ),
            ]),
          ),
        if (d.reports.isNotEmpty) ...[
          Text('Trip reports (${d.reports.length})', style: t.textTheme.titleSmall),
          for (final r in d.reports.take(10))
            ListTile(
              key: ValueKey('driver-report-${r.ticketId}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(r.urgent ? Icons.priority_high : Icons.flag_outlined, color: r.urgent ? c.error : null),
              title: Text('${r.number == null ? '' : '#${r.number} · '}${r.category}${r.urgent ? ' · urgent' : ''}'),
              subtitle: Text([r.rider ?? 'Rider', formatDateTime(r.at), r.status].join(' · ')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/admin/support/${r.ticketId}'),
            ),
        ],
        if (d.blocks.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Blocked by ${d.blocks.length} ${d.blocks.length == 1 ? 'rider' : 'riders'}', style: t.textTheme.titleSmall),
          for (final b in d.blocks.take(10))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('${b.rider ?? 'Rider'} · ${formatDateTime(b.at)}${b.source == 'report' ? ' · with a report' : ''}',
                  style: t.textTheme.bodyMedium),
            ),
        ],
      ],
    );
  }
}
