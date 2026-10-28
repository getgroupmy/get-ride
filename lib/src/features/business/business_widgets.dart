// Shared pieces of the business account pages (migration 0313), in the
// rider app and the admin: a value with − and + buttons, a figure on the
// overview and a status pill.
import 'package:flutter/material.dart';

/// A labelled value with − and + buttons. A null callback: that way is at
/// its limit, or the page is read-only.
class BusinessStepper extends StatelessWidget {
  const BusinessStepper({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.onDown,
    this.onUp,
    this.valueKey,
    this.leading,
  });

  final String label;
  final String? hint;
  final String value;
  final VoidCallback? onDown, onUp;
  final Key? valueKey;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
      if (hint != null) Text(hint!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
    final buttons = Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton.outlined(tooltip: 'Lower $label', icon: const Icon(Icons.remove), onPressed: onDown),
      ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 84),
        child: Text(value, key: valueKey, textAlign: TextAlign.center, style: t.textTheme.titleMedium),
      ),
      IconButton.outlined(tooltip: 'Raise $label', icon: const Icon(Icons.add), onPressed: onUp),
    ]);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // Large text or a narrow phone: the buttons go under the label.
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 360) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [?leading, Expanded(child: text)]),
            Align(alignment: Alignment.centerRight, child: buttons),
          ]);
        }
        return Row(children: [?leading, Expanded(child: text), buttons]);
      }),
    );
  }
}

/// A figure on the overview: a label, the value large, a line under it.
class BusinessFigure extends StatelessWidget {
  const BusinessFigure({super.key, required this.label, required this.value, this.sub, this.valueKey});
  final String label;
  final String value;
  final String? sub;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(value, key: valueKey, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          if (sub != null) Text(sub!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// pending / active / suspended / rejected as a pill.
class BusinessStatusPill extends StatelessWidget {
  const BusinessStatusPill(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final (label, bg, fg) = switch (status) {
      'active' => ('Active', s.primaryContainer, s.onPrimaryContainer),
      'pending' => ('Waiting for approval', s.tertiaryContainer, s.onTertiaryContainer),
      'suspended' => ('Suspended', s.errorContainer, s.onErrorContainer),
      'rejected' => ('Not approved', s.errorContainer, s.onErrorContainer),
      'invited' => ('Invited', s.secondaryContainer, s.onSecondaryContainer),
      _ => (status, s.surfaceContainerHighest, s.onSurface),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg)),
    );
  }
}
