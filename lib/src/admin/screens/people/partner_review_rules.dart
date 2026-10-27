// Admin › Partners › Review application: the partner registration rules the
// server checks again on Approve (0305). A failed rule blocks the approval
// ("Can't approve: …"); the admin asks the partner for the documents, or
// approves anyway with a written reason, recorded with their name and the
// failed rules and shown as "Approved with override".
import 'package:flutter/material.dart';

import '../../../core/registration_rules.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/rule_chip.dart';
import '../../widgets/admin_widgets.dart' show dateText;

/// The red banner over the review while rules fail: the first rule in the
/// title, every failure listed, and the two ways on.
class RulesBlockedBanner extends StatelessWidget {
  const RulesBlockedBanner({super.key, required this.failed, this.onAsk, this.onOverride});
  final List<RuleProblem> failed;
  final BusyAction? onAsk;
  final BusyAction? onOverride;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (bg, fg) = ruleToneColors(RuleTone.bad, t.brightness);
    return Container(
      key: const ValueKey('review-rules-blocked'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 8, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.block, color: fg),
          const SizedBox(width: 8),
          Expanded(child: Text(approveBlockedTitle(failed), style: t.textTheme.titleSmall?.copyWith(color: fg))),
        ]),
        Text('The server checked the partner registration rules again and these failed:',
            style: t.textTheme.bodyMedium?.copyWith(color: fg)),
        for (final p in failed)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.cancel, size: 18, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: '${p.rule.label} (${p.type}). ', style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: p.message),
                ]),
                style: t.textTheme.bodyMedium?.copyWith(color: fg),
              ),
            ),
          ]),
        if (onAsk != null || onOverride != null)
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (onAsk != null)
              BusyButton.filled(
                key: const ValueKey('review-rules-ask'),
                onPressed: onAsk,
                icon: const Icon(Icons.mail_outline),
                child: const Text('Ask partner for documents'),
              ),
            if (onOverride != null)
              BusyButton.tonal(
                key: const ValueKey('review-rules-override'),
                onPressed: onOverride,
                icon: const Icon(Icons.gavel),
                child: const Text('Approve anyway (override)'),
              ),
          ]),
      ]),
    );
  }
}

/// "Override: reason needed": the admin's reason, or null when cancelled.
Future<String?> askOverrideReason(BuildContext context) => showAppDialog<String>(
      id: 'admin-partner-review.override',
      context: context,
      builder: (_) => const OverrideReasonDialog(),
    );

class OverrideReasonDialog extends StatefulWidget {
  const OverrideReasonDialog({super.key});

  @override
  State<OverrideReasonDialog> createState() => _OverrideReasonDialogState();
}

class _OverrideReasonDialogState extends State<OverrideReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _reason.text.trim();
    return AlertDialog(
      key: const ValueKey('review-override-dialog'),
      title: const Text('Override: reason needed'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Why approve without these? This is saved with your name and the failed rules.'),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('review-override-reason'),
            controller: _reason,
            minLines: 3,
            maxLines: 6,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Reason',
              hintText: 'SSM certificate received by email, ticket #4821. Partner will upload it this week.',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('review-override-confirm'),
          onPressed: text.isEmpty ? null : () => Navigator.pop(context, text),
          child: const Text('Record override and approve'),
        ),
      ],
    );
  }
}

/// "Approved with override": when, by whom, which rules were skipped, and
/// the reason.
class OverrideNote extends StatelessWidget {
  const OverrideNote({super.key, required this.entry, required this.adminName});
  final RuleOverride entry;
  final String adminName;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (bg, fg) = ruleToneColors(RuleTone.wait, t.brightness);
    final o = entry;
    final when = o.at == null ? '' : '${dateText(o.at!.toIso8601String())} ';
    return Container(
      key: const ValueKey('review-override-note'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.verified, color: fg),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
            Text('Approved with override', style: t.textTheme.titleSmall?.copyWith(color: fg)),
            Text(
              'Recorded ${when}by $adminName: ${o.skipped.isEmpty ? 'the rules' : o.skipped} skipped. Reason saved.',
              style: t.textTheme.bodyMedium?.copyWith(color: fg),
            ),
            Text('Reason: ${o.reason}', style: t.textTheme.bodyMedium?.copyWith(color: fg)),
          ]),
        ),
      ]),
    );
  }
}

RuleTone _chipTone(String chip) => switch (chip) {
      'Passed' => RuleTone.ok,
      'Failed' => RuleTone.bad,
      'Overridden' || 'Paused' => RuleTone.wait,
      _ => RuleTone.none,
    };

/// "Partner registration rules": each rule once, Passed / Failed /
/// Overridden / Paused / Not set.
class ReviewRulesCard extends StatelessWidget {
  const ReviewRulesCard({super.key, required this.checks, this.overridden = false});
  final List<RuleProblem> checks;
  final bool overridden;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('review-rules-card'),
      margin: const EdgeInsets.only(top: 16),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: t.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Partner registration rules', style: t.textTheme.titleSmall),
          for (final r in reviewRuleRows(checks, overridden: overridden))
            RuleRow(
              key: ValueKey('review-rule-${r.rule.key}'),
              name: r.label,
              detail: r.detail,
              chip: r.chip,
              tone: _chipTone(r.chip),
            ),
        ]),
      ),
    );
  }
}
