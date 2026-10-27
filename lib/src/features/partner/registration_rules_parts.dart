// Partner registration rules on the driver's side (0305): the modal for a
// Submit the server refused (Citizens only, Business registration, Driver
// permit), with its way to the step that fixes it, and the "Before you
// submit" checklist on the Service documents step.

import 'package:flutter/material.dart';

import '../../core/document_text.dart' show IdDocType;
import '../../core/partner_onboarding.dart' show OnboardingStep;
import '../../core/registration_rules.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/rule_chip.dart';

IconData _ruleIcon(RegRule r) => switch (r) {
      RegRule.citizensOnly => Icons.flag,
      RegRule.businessRegistration => Icons.domain,
      _ => Icons.badge,
    };

/// The modal for a refused Submit: what the rule needs, "Not submitted", and
/// the action ("Change type", "Add company", "Upload") or OK. The step to
/// open, or null for OK.
Future<OnboardingStep?> showSubmitRefused(
  BuildContext context,
  RuleProblem problem, {
  IdDocType? idType,
  String idNumber = '',
}) {
  final r = submitRefusal(problem, idType: idType, idNumber: idNumber);
  return showAppDialog<OnboardingStep>(
    id: 'partner.submit-refused',
    context: context,
    builder: (c) => SubmitRefusedDialog(refusal: r),
  );
}

class SubmitRefusedDialog extends StatelessWidget {
  const SubmitRefusedDialog({super.key, required this.refusal});
  final SubmitRefusal refusal;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = refusal;
    return AlertDialog(
      key: const ValueKey('submit-refused'),
      icon: Icon(_ruleIcon(r.rule), size: 36, color: t.colorScheme.primary),
      title: Text(r.title, key: const ValueKey('submit-refused-title')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: [
          Text(r.body, key: const ValueKey('submit-refused-body')),
          const RuleChip(label: 'Not submitted', tone: RuleTone.bad, icon: Icons.block),
          Text(r.note, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
      actions: [
        TextButton(
          key: const ValueKey('submit-refused-action'),
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => Navigator.pop(context, r.step),
          child: Text(r.action),
        ),
        FilledButton(
          key: const ValueKey('submit-refused-ok'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

RuleTone _tone(CheckState s) => switch (s) {
      CheckState.done => RuleTone.ok,
      CheckState.needed => RuleTone.bad,
      CheckState.later => RuleTone.wait,
      CheckState.notNeeded => RuleTone.none,
    };

/// "Before you submit": each rule the server checks, Done / Needed / Later /
/// Not needed. "Needed" stops the submission, "Later" only pauses that
/// service. With anything needed, [onFix] opens the first one's step and
/// [onSubmitAnyway] sends it all the same (the server answers with the
/// reason); else [submit] is the usual button.
class SubmitChecklist extends StatelessWidget {
  const SubmitChecklist({
    super.key,
    required this.lead,
    required this.rows,
    required this.submit,
    required this.onFix,
    required this.onSubmitAnyway,
    this.enabled = true,
  });

  final String lead;
  final List<ChecklistRow> rows;
  final Widget submit;
  final ValueChanged<OnboardingStep> onFix;
  final VoidCallback onSubmitAnyway;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final needed = [for (final r in rows) if (r.state == CheckState.needed) r];
    final (badBg, badFg) = ruleToneColors(RuleTone.bad, t.brightness);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        key: const ValueKey('submit-checklist'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Before you submit', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(lead, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            for (final r in rows)
              RuleRow(
                key: ValueKey('checklist-${r.name}'),
                name: r.name,
                detail: r.detail,
                chip: r.state.label,
                tone: _tone(r.state),
              ),
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 18, color: t.colorScheme.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('"Needed" items stop the submission. "Later" items only pause that service until you '
                    'add them.'),
              ),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      if (needed.isEmpty)
        submit
      else ...[
        Container(
          key: const ValueKey('checklist-needed'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: badBg, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(Icons.error, color: badFg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${needed.length} needed before you can submit',
                style: t.textTheme.titleSmall?.copyWith(color: badFg),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('checklist-fix'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: !enabled || needed.first.step == null ? null : () => onFix(needed.first.step!),
          child: const Text('Fix the first one'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const ValueKey('checklist-submit-anyway'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: enabled ? onSubmitAnyway : null,
          child: const Text('Submit anyway'),
        ),
        const SizedBox(height: 6),
        Text(
          'Submit anyway sends it; the server answers with the reason.',
          textAlign: TextAlign.center,
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ],
    ]);
  }
}
