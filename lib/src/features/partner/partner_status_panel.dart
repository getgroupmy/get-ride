// The Drive tab for a partner who cannot take jobs yet: what their account
// status means, the admin's reason for a rejection or block, and what they
// can do about it — finish or update the application, send a rejected one
// back for review, or contact support (migration 0118).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/partner_status.dart';
import '../../data/models.dart';
import '../../data/partner_onboarding_repository.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';

class PartnerStatusPanel extends ConsumerWidget {
  const PartnerStatusPanel({super.key, required this.partner, required this.onOpenApplication});

  final Partner partner;
  final VoidCallback onOpenApplication;

  IconData _icon(PartnerStatusKind k) => switch (k) {
    PartnerStatusKind.incomplete => Icons.assignment_outlined,
    PartnerStatusKind.docsNeeded => Icons.upload_file,
    PartnerStatusKind.rejected => Icons.cancel_outlined,
    PartnerStatusKind.blocked => Icons.block,
    _ => Icons.hourglass_empty,
  };

  Future<void> _resubmit(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Send for review again?'),
        content: const Text(
          'Make sure you have fixed what the admin pointed out and updated your documents. '
          'Your application goes back to the admin to review.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not yet')),
          FilledButton(
            key: const ValueKey('partner-resubmit-confirm'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(partnerOnboardingRepositoryProvider).requestReview();
      ref.invalidate(partnerProvider);
      if (context.mounted) showInfo(context, 'Sent. An admin will review your application again.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final v = partnerStatusView(partner.raw);
    final danger = v.kind == PartnerStatusKind.rejected || v.kind == PartnerStatusKind.blocked;
    final support = OutlinedButton.icon(
      key: const ValueKey('partner-status-support'),
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
      icon: const Icon(Icons.support_agent),
      label: const Text('Contact support'),
      onPressed: () => context.push('/account/support'),
    );
    final actions = <Widget>[
      switch (v.kind) {
        PartnerStatusKind.incomplete => FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: onOpenApplication,
          child: const Text('Continue'),
        ),
        PartnerStatusKind.blocked => support,
        PartnerStatusKind.rejected || PartnerStatusKind.docsNeeded => FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          icon: const Icon(Icons.upload_file),
          onPressed: onOpenApplication,
          label: const Text('Update documents'),
        ),
        _ => OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: onOpenApplication,
          child: const Text('View application'),
        ),
      },
      if (v.canResubmit)
        BusyButton.tonal(
          key: const ValueKey('partner-resubmit'),
          icon: const Icon(Icons.send),
          onPressed: () => _resubmit(context, ref),
          child: const Text('Send for review again'),
        ),
      if (v.kind == PartnerStatusKind.rejected || v.kind == PartnerStatusKind.docsNeeded) support,
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            key: ValueKey('partner-status-${v.kind.name}'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(_icon(v.kind), size: 48, color: danger ? t.colorScheme.error : t.colorScheme.outline),
              const SizedBox(height: 12),
              Text(v.title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                v.message,
                textAlign: TextAlign.center,
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              if (v.reason != null) ...[
                const SizedBox(height: 16),
                Card(
                  key: const ValueKey('partner-status-reason'),
                  color: t.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reason from the admin',
                          style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onErrorContainer),
                        ),
                        const SizedBox(height: 4),
                        Text(v.reason!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onErrorContainer)),
                      ],
                    ),
                  ),
                ),
              ],
              if (v.resubmittedAt != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Sent for review on ${DateFormat('d MMM yyyy, h:mm a').format(v.resubmittedAt!.toLocal())}',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 20),
              for (final a in actions) ...[a, const SizedBox(height: 10)],
            ],
          ),
        ),
      ),
    );
  }
}
