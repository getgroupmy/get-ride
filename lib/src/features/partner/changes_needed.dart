// "Changes needed" (0289): the Drive tab when an admin sent the application
// back. Every line the admin checked, grouped as in the application, says
// Approved, Rejected: <reason> or Changed by admin: <note>; tapping one opens
// a sheet with the note, the value before and after an admin's edit, and the
// fix (Retake photo / Upload again / Edit / Change services), which opens
// that registration step. "Send for review again" unlocks once every
// rejected line is fixed (the server marks a line fixed when what it holds
// changes).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/partner_review.dart';
import '../../data/models.dart';
import '../../data/partner_review_repository.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

class ChangesNeededPanel extends ConsumerWidget {
  const ChangesNeededPanel({super.key, required this.partner});

  final Partner partner;

  void _refresh(WidgetRef ref) {
    ref.invalidate(myReviewItemsProvider(partner.id));
    ref.invalidate(partnerProvider);
  }

  Future<void> _open(BuildContext context, WidgetRef ref, ReviewItem item) async {
    final fix = await showAppSheet<String>(
      id: 'partner-changes.item',
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => ChangeItemSheet(item: item),
    );
    if (!context.mounted) return;
    if (fix == null) return _refresh(ref);
    await context.push(fix);
    _refresh(ref);
  }

  Future<void> _resend(BuildContext context, WidgetRef ref) async {
    final ok = await showAppDialog<bool>(
      id: 'partner-changes.resend',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Send for review again?'),
        content: const Text('Your changes go to the admin. Drive stays locked until your application is approved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not yet')),
          FilledButton(
            key: const ValueKey('changes-resend-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(partnerReviewRepositoryProvider).resubmit();
      if (context.mounted) {
        await showNotice(context, title: 'Sent for review', message: 'An admin will check your changes. We will notify you when it is done.');
      }
    } catch (e) {
      if (context.mounted) await showErrorNotice(context, e);
    }
    _refresh(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final items = ref.watch(myReviewItemsProvider(partner.id));
    return AsyncView<List<ReviewItem>>(
      value: items,
      onRetry: () => ref.invalidate(myReviewItemsProvider(partner.id)),
      data: (list) {
        final left = reviewItemsLeft(list);
        return Column(
          key: const ValueKey('partner-status-changesNeeded'),
          children: [
            Expanded(
              child: ResponsiveCenter(
                maxWidth: 560,
                child: ListView(
                  // Room for the Drive page's own buttons, top right.
                  padding: const EdgeInsets.fromLTRB(0, 64, 0, 16),
                  children: [
                    _StateCard(
                      icon: Icons.edit_note,
                      title: 'Changes needed',
                      message: 'An admin checked your application. Tap a line marked below to see why and fix it.',
                    ),
                    const SizedBox(height: 16),
                    for (final (group, lines) in reviewGroups(list, (i) => i.group)) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 6),
                        child: Text(
                          group.label.toUpperCase(),
                          style: t.textTheme.labelMedium?.copyWith(color: mutedTextColor(t), letterSpacing: 1),
                        ),
                      ),
                      for (final i in lines) ...[
                        ChangeLine(item: i, onTap: () => _open(context, ref, i)),
                        const SizedBox(height: 6),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            Material(
              color: t.colorScheme.surface,
              elevation: 2,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: ResponsiveCenter(
                    maxWidth: 560,
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      BusyButton.filled(
                        key: const ValueKey('changes-resend'),
                        icon: const Icon(Icons.send),
                        onPressed: left == 0 ? () => _resend(context, ref) : null,
                        child: const Text('Send for review again'),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        left == 0
                            ? 'Everything rejected is fixed. Admin edits can be kept as they are or changed.'
                            : '$left rejected item(s) left to fix. Admin edits can be kept as they are or changed.',
                        key: const ValueKey('changes-left'),
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                      ),
                      TextButton.icon(
                        key: const ValueKey('partner-status-support'),
                        onPressed: () => context.push('/account/support'),
                        icon: const Icon(Icons.support_agent),
                        label: const Text('Contact support'),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({required this.icon, required this.title, required this.message});
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: c.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
          Icon(icon, size: 28, color: c.onTertiaryContainer),
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: c.onTertiaryContainer)),
          Text(message, style: TextStyle(color: c.onTertiaryContainer)),
        ]),
      ),
    );
  }
}

/// The colour and icon of a line: done (approved or fixed) in the accent,
/// rejected in the error colour, an admin's change in the text colour.
(IconData, Color) _look(ThemeData t, ReviewItem i) {
  final c = t.colorScheme;
  if (i.fixed) return (Icons.task_alt, c.primary);
  return switch (i.state) {
    ReviewState.approved => (Icons.check_circle, c.primary),
    ReviewState.rejected => (Icons.error, c.error),
    ReviewState.edited => (Icons.edit, c.onSurface),
  };
}

/// One line of "Changes needed".
class ChangeLine extends StatelessWidget {
  const ChangeLine({super.key, required this.item, required this.onTap});
  final ReviewItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (icon, color) = _look(t, item);
    final quiet = item.fixed || item.state == ReviewState.approved;
    return Card(
      key: ValueKey('change-${item.key}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: item.blocking ? t.colorScheme.error : t.colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 2, children: [
                Text(item.label, style: t.textTheme.titleSmall),
                Text(
                  reviewDriverStatus(item),
                  style: t.textTheme.bodySmall?.copyWith(color: quiet ? mutedTextColor(t) : color),
                ),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}

/// The sheet for one line: the admin's note, before and after for an edit,
/// and the fix. Pops with the step to open, or null.
class ChangeItemSheet extends ConsumerStatefulWidget {
  const ChangeItemSheet({super.key, required this.item});
  final ReviewItem item;

  @override
  ConsumerState<ChangeItemSheet> createState() => _ChangeItemSheetState();
}

class _ChangeItemSheetState extends ConsumerState<ChangeItemSheet> {
  ReviewItem get i => widget.item;

  Future<void> _close() async {
    // Keeping an admin's edit is said once; it never blocks sending.
    if (i.state == ReviewState.edited && i.keptAt == null && !i.fixed) {
      try {
        await ref.read(partnerReviewRepositoryProvider).keep(i.key);
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final fix = reviewFixFor(i.key);
    final route = reviewFixRoute(i.key);
    final rejected = i.state == ReviewState.rejected;
    final tag = switch (i.state) {
      ReviewState.approved => 'Approved',
      ReviewState.rejected => 'Rejected',
      ReviewState.edited => 'Changed by admin',
    };
    final hasBefore = i.state == ReviewState.edited && i.oldValue != null;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          key: const ValueKey('change-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            Text(i.label, style: t.textTheme.titleLarge),
            Align(
              alignment: Alignment.centerLeft,
              child: Chip(
                label: Text(tag),
                backgroundColor: rejected ? c.errorContainer : c.surfaceContainerHighest,
                labelStyle: TextStyle(color: rejected ? c.onErrorContainer : c.onSurface),
                side: BorderSide.none,
              ),
            ),
            if (i.note != null)
              Container(
                key: const ValueKey('change-note'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: rejected ? c.errorContainer : c.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 2, children: [
                  Text("Admin's note",
                      style: t.textTheme.labelMedium?.copyWith(color: rejected ? c.onErrorContainer : c.onSurface)),
                  Text(i.note!, style: TextStyle(color: rejected ? c.onErrorContainer : c.onSurface)),
                ]),
              ),
            if (hasBefore) ...[
              _ValueBox(
                key: const ValueKey('change-before'),
                label: 'You entered',
                value: reviewValueText(i.key, i.oldValue),
                struck: true,
              ),
              _ValueBox(
                key: const ValueKey('change-after'),
                label: 'Now',
                value: reviewValueText(i.key, i.newValue),
                highlight: true,
              ),
            ] else if (i.newValue != null)
              _ValueBox(label: 'Value', value: reviewValueText(i.key, i.newValue)),
            if (i.fixed)
              Row(key: const ValueKey('change-fixed'), children: [
                Icon(Icons.check_circle, color: c.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(fix.photo || fix.label == 'Upload again' ? 'New file added' : 'Changed')),
              ]),
            if (route != null && (rejected || i.state == ReviewState.edited))
              _fixButton(
                primary: rejected && !i.fixed,
                onPressed: () => Navigator.pop(context, route),
                icon: Icon(fix.photo ? Icons.add_a_photo_outlined : (fix.label == 'Upload again' ? Icons.upload_file : Icons.edit_outlined)),
                label: Text(i.fixed ? '${fix.label} again' : fix.label),
              ),
            FilledButton(
              key: const ValueKey('change-close'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _close,
              child: Text(i.state == ReviewState.edited && !i.fixed ? 'Keep and close' : 'Done'),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _fixButton({required bool primary, required VoidCallback onPressed, required Widget icon, required Widget label}) {
  const key = ValueKey('change-fix');
  const size = Size(0, 48);
  return primary
      ? FilledButton.tonalIcon(
          key: key,
          style: FilledButton.styleFrom(minimumSize: size),
          onPressed: onPressed,
          icon: icon,
          label: label,
        )
      : OutlinedButton.icon(
          key: key,
          style: OutlinedButton.styleFrom(minimumSize: size),
          onPressed: onPressed,
          icon: icon,
          label: label,
        );
}

class _ValueBox extends StatelessWidget {
  const _ValueBox({super.key, required this.label, required this.value, this.struck = false, this.highlight = false});
  final String label;
  final String value;
  final bool struck;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: highlight ? c.primary : c.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 2, children: [
        Text(label, style: t.textTheme.labelSmall?.copyWith(color: mutedTextColor(t))),
        Text(
          value,
          style: struck
              ? TextStyle(decoration: TextDecoration.lineThrough, color: mutedTextColor(t))
              : t.textTheme.bodyLarge,
        ),
      ]),
    );
  }
}
