// Admin › Partner Service type › Partner registration (0305): the rules are
// checked by the server on submit and approval, and "Partners affected now"
// lists the partners of this type, pending or approved, that would fail the
// saved rules today, each with its review.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/registration_rules.dart';
import '../../../data/partner_review_repository.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/rule_chip.dart';
import '../people/partner_review_screen.dart' show PartnerReviewScreen;

/// The partners of a type that would fail its rules now; empty when the list
/// can't be read (an older database, or no access).
final partnerRuleFailuresProvider = FutureProvider.autoDispose.family<List<RuleFailure>, String>((ref, type) async {
  try {
    return await ref.watch(partnerReviewRepositoryProvider).ruleFailures(type);
  } catch (_) {
    return const [];
  }
});

/// "Checked by the server on submit and approval", and for a saved type,
/// "Partners affected now: N would fail" opening the list.
class ServerCheckedNote extends ConsumerWidget {
  const ServerCheckedNote({super.key, this.type});

  /// The saved type's name; null for a new one (nobody has it yet).
  final String? type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final name = type?.trim() ?? '';
    final failures = name.isEmpty ? const <RuleFailure>[] : ref.watch(partnerRuleFailuresProvider(name)).value ?? const [];
    return Container(
      key: const ValueKey('pst-server-checked'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.dns_outlined, color: t.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Checked by the server on submit and approval', style: t.textTheme.titleSmall),
              Text("Not only by the app: an old or modified app can't skip these.", style: t.textTheme.bodySmall),
            ]),
          ),
        ]),
        if (failures.isNotEmpty) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('pst-rule-failures'),
            style: TextButton.styleFrom(minimumSize: const Size(0, 44), alignment: Alignment.centerLeft),
            onPressed: () => showRuleFailures(context, name, failures),
            icon: const Icon(Icons.expand_more),
            label: Text('Partners affected now: ${failures.length} would fail'),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          "Turning a rule on doesn't remove anyone already approved; it applies to the next submission or approval.",
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}

/// "Would fail now (N)": each partner, their status and why, and Open review.
Future<void> showRuleFailures(BuildContext context, String type, List<RuleFailure> failures) => showAppSheet<void>(
      id: 'admin-partner-type.rule-failures',
      context: context,
      fitContent: true,
      showDragHandle: true,
      builder: (c) => RuleFailuresSheet(type: type, failures: failures),
    );

class RuleFailuresSheet extends StatelessWidget {
  const RuleFailuresSheet({super.key, required this.type, required this.failures});
  final String type;
  final List<RuleFailure> failures;

  void _open(BuildContext context, String id) {
    final nav = Navigator.of(context, rootNavigator: true);
    Navigator.pop(context);
    nav.push(AppPageRoute<void>(id: 'admin.partner-type-rule-review', builder: (_) => PartnerReviewScreen(id: id)));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        key: const ValueKey('rule-failures-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: Text('Would fail now (${failures.length})', style: t.textTheme.titleLarge)),
            IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          ]),
          Text(
            "Partners with $type, pending or approved, checked against today's rules. Approved ones keep working; "
            "they'd be refused only on their next change.",
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          for (final f in failures)
            Padding(
              key: ValueKey('rule-failure-${f.partnerId}'),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
                    Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(f.name, style: t.textTheme.titleSmall),
                      RuleChip(
                        label: f.status == 'approved' || f.status.startsWith('permit-') ? 'Approved' : 'Pending',
                        tone: f.status == 'approved' || f.status.startsWith('permit-') ? RuleTone.ok : RuleTone.wait,
                      ),
                    ]),
                    Row(children: [
                      Icon(Icons.cancel, size: 16, color: ruleToneColors(RuleTone.bad, t.brightness).$2),
                      const SizedBox(width: 6),
                      Expanded(child: Text(ruleFailureWhy(f), style: t.textTheme.bodySmall)),
                    ]),
                  ]),
                ),
                TextButton(
                  key: ValueKey('rule-failure-open-${f.partnerId}'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => _open(context, f.partnerId),
                  child: const Text('Open review'),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}
