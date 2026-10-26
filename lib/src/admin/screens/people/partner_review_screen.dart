// Admin › Partners › Review application (0289): every detail and document
// of one partner application as a line the admin approves, rejects (a
// reason is required) or edits (the new value and a note; the value is
// written to the real column). Face match and liveness show where a line
// has the person's photo. Then "Send back to driver" (the driver sees each
// note on "Changes needed"), or "Approve application" once every line is
// approved or edited, which approves the partner and their vehicle together.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/partner_review.dart';
import '../../../core/signin_checks.dart' show faceNeedsCloserLook, livenessText, rejectNotes;
import '../../../core/partner_registration.dart' show closerLookReasonText;
import '../../../data/partner_review_repository.dart';
import '../../../providers.dart' show currentUserIdProvider;
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/date_boxes.dart';
import '../../../widgets/in_app_page.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_filters.dart' show partnerFilters;
import '../../admin_providers.dart';
import '../people_screens.dart' show adminPartnersProvider;
import '../../widgets/admin_widgets.dart';
import '../../widgets/reject_reason.dart';
import '../documents_screen.dart' show documentFaceText;
import 'people_data.dart';
import 'people_logic.dart' show partnerTypeOptions;

/// The admin's edit: the new value and the note for the driver.
typedef ReviewEditResult = ({Object? value, String note});

/// The application and the Partner Service types an edit picks from.
typedef ReviewPageData = ({ReviewApplication? app, List<String> types});

final partnerReviewProvider = FutureProvider.autoDispose.family<ReviewPageData, String>((ref, id) async {
  final app = await ref.watch(partnerReviewRepositoryProvider).application(id);
  var types = const <String>[];
  try {
    types = partnerTypeOptions((await ref.watch(peopleRepositoryProvider).partnerTypes()).map((e) => e.values));
  } catch (_) {}
  return (app: app, types: types);
});

/// `/admin/m/partner-review?id=<partner id>`.
class PartnerReviewScreen extends ConsumerWidget {
  const PartnerReviewScreen({super.key, required this.id});
  final String id;

  /// The Partners pages' Edit Partner access covers it.
  static const page = 'admin-partner-edit';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(partnerReviewProvider(id));
    if (!v.hasValue) {
      return AdminPage(
        title: 'Review application',
        page: page,
        body: AsyncView(value: v, onRetry: () => ref.invalidate(partnerReviewProvider(id)), data: (_) => const SizedBox()),
      );
    }
    final data = v.requireValue;
    final app = data.app;
    if (app == null) {
      return AdminPage(
        title: 'Partner not found',
        page: page,
        body: EmptyState(icon: Icons.person_off_outlined, title: "We couldn't find a partner with ID $id."),
      );
    }
    return _ReviewBody(app: app, types: data.types, refreshing: v.isLoading);
  }
}

class _ReviewBody extends ConsumerWidget {
  const _ReviewBody({required this.app, required this.types, required this.refreshing});
  final ReviewApplication app;
  final List<String> types;
  final bool refreshing;

  PartnerReviewRepository _repo(WidgetRef ref) => ref.read(partnerReviewRepositoryProvider);

  void _reload(WidgetRef ref) => ref.invalidate(partnerReviewProvider(app.partnerId));

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) await showErrorNotice(context, e);
    }
    _reload(ref);
  }

  Future<void> _approve(BuildContext context, WidgetRef ref, ReviewLine l) =>
      _run(context, ref, () => _repo(ref).setItem(partnerId: app.partnerId, line: l, state: ReviewState.approved));

  Future<void> _reject(BuildContext context, WidgetRef ref, ReviewLine l) async {
    final choice = await pickRejectReason(context);
    if (choice == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => _repo(ref).setItem(
        partnerId: app.partnerId,
        line: l,
        state: ReviewState.rejected,
        note: rejectNotes(choice.reason, choice.note),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, ReviewLine l) async {
    final r = await showAppDialog<ReviewEditResult>(
      id: 'admin-partner-review.edit',
      context: context,
      builder: (_) => ReviewEditDialog(line: l, types: types, note: app.items[l.key]?.note),
    );
    if (r == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => _repo(ref).setItem(partnerId: app.partnerId, line: l, state: ReviewState.edited, note: r.note, value: r.value),
    );
  }

  Future<void> _clear(BuildContext context, WidgetRef ref, ReviewLine l) =>
      _run(context, ref, () => _repo(ref).clearItem(partnerId: app.partnerId, line: l));

  /// Opens a line's document and logs the view (0296): Pass, Reject and
  /// Pending unlock once this admin has seen it.
  Future<void> _view(BuildContext context, WidgetRef ref, ReviewLine l, String file) async {
    try {
      await _repo(ref).viewed(partnerId: app.partnerId, key: l.key);
    } catch (e) {
      if (context.mounted) await showErrorNotice(context, e);
      return;
    }
    if (context.mounted) await openStoredFile(context, file, title: l.label);
    _reload(ref);
  }

  String _name(String? id) => id == null ? 'someone' : (app.names[id] ?? 'an admin');

  Future<void> _sendBack(BuildContext context, WidgetRef ref, ReviewTally t) async {
    final ok = await confirm(
      context,
      'Send back to driver?',
      'The driver sees each rejected line with your reason and each edit with your note, fixes what you rejected and '
          'sends it again. ${t.rejected} rejected, ${t.edited} edited.',
      ok: 'Send back',
    );
    if (!ok || !context.mounted) return;
    try {
      await _repo(ref).sendBack(app.partnerId);
      if (context.mounted) {
        await showNotice(context, title: 'Sent back', message: 'The driver has been told what to change.');
      }
    } catch (e) {
      if (context.mounted) await showErrorNotice(context, e);
    }
    _reload(ref);
    ref.invalidate(adminPartnersProvider);
  }

  Future<void> _approveAll(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      'Approve application?',
      app.vehicle == null
          ? 'The partner is approved and can go online.'
          : 'The partner and ${app.vehicle!['plate'] ?? 'their vehicle'} are approved together.',
      ok: 'Approve',
    );
    if (!ok || !context.mounted) return;
    try {
      await _repo(ref).approve(app.partnerId);
      if (context.mounted) await showNotice(context, title: 'Approved', message: 'The driver has been told.');
    } catch (e) {
      if (context.mounted) await showErrorNotice(context, e);
    }
    _reload(ref);
    ref.invalidate(adminPartnersProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canEdit = ref.watch(pageAccessProvider(PartnerReviewScreen.page)) == AccessLevel.edit;
    final p = app.partner;
    final status = app.status;
    final withDriver = status == 'changes-needed';
    final closed = status == 'approved' || status == 'blocked' || status.startsWith('permit-');
    final open = canEdit && !withDriver && !closed;
    final lines = app.lines;
    final tally = reviewTally(lines, app.items);
    String? me;
    try {
      me = ref.watch(currentUserIdProvider);
    } catch (_) {}
    final approvedAt = DateTime.tryParse('${p['approved_at'] ?? ''}')?.toLocal();
    final name = '${p['name'] ?? ''}'.trim();
    final closer = (p['closer_look_reasons'] as List?)?.map((r) => closerLookReasonText('$r')).toList() ?? const [];
    return AdminPage(
      title: 'Review application',
      page: PartnerReviewScreen.page,
      body: ListView(
        key: const ValueKey('partner-review'),
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          if (refreshing) const LinearProgressIndicator(),
          ResponsiveCenter(
            maxWidth: 900,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 6, children: [
                    Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(name.isEmpty ? 'Partner' : name, style: t.textTheme.titleLarge),
                      StatusChip(status, label: partnerFilters[status]),
                      if ('${p['display_id'] ?? ''}'.isNotEmpty) Text('${p['display_id']}', style: t.textTheme.bodySmall),
                    ]),
                    Text(
                      'Open each document first: Approve, Reject and Back to pending unlock once you have viewed '
                      'it, and every view is logged. Each line gets Approve, Reject with a reason, or Edit with a '
                      'note. The driver sees each note against the same line.',
                      style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)),
                    ),
                    Text(tally.summary, key: const ValueKey('review-tally'), style: t.textTheme.labelLarge),
                    if (p['approved_by'] != null && approvedAt != null)
                      Text(
                        'Approved by ${_name('${p['approved_by']}')} · ${dateText(approvedAt.toIso8601String())}',
                        key: const ValueKey('review-approved-by'),
                        style: t.textTheme.bodyMedium,
                      ),
                    if (p['needs_closer_look'] == true && closer.isNotEmpty)
                      _Banner(
                        icon: Icons.report_outlined,
                        color: t.colorScheme.error,
                        text: 'Needs a closer look: ${closer.join('; ')}',
                      ),
                    if (withDriver)
                      _Banner(
                        key: const ValueKey('review-with-driver'),
                        icon: Icons.hourglass_top,
                        color: t.colorScheme.tertiary,
                        text: 'Sent back to the driver. You can review it again once they send it back.',
                      ),
                    if (closed)
                      _Banner(
                        icon: Icons.lock_outline,
                        color: t.colorScheme.outline,
                        text: 'This partner is ${partnerFilters[status]?.toLowerCase() ?? status}. '
                            'Change their status on Partners to review it again.',
                      ),
                    if (p['resubmitted_at'] != null && !withDriver)
                      Text('Sent again by the driver on ${dateText(p['resubmitted_at'])}. Lines they changed are '
                          'marked Not checked yet.'),
                  ]),
                ),
              ),
              for (final (group, list) in reviewGroups(lines, (l) => l.group)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                  child: Text(group.label, style: t.textTheme.titleMedium),
                ),
                for (final l in list)
                  _LineCard(
                    line: l,
                    item: app.items[l.key],
                    face: l.faceKey == null ? null : app.faces[l.faceKey],
                    enabled: open,
                    views: reviewViewsFor(l.key, app.log, me),
                    log: [for (final e in app.log) if (e.itemKey == l.key) e],
                    nameOf: _name,
                    onView: (f) => _view(context, ref, l, f),
                    onApprove: () => _approve(context, ref, l),
                    onReject: () => _reject(context, ref, l),
                    onEdit: () => _edit(context, ref, l),
                    onClear: () => _clear(context, ref, l),
                  ),
              ],
              const SizedBox(height: 16),
              if (open) ...[
                const SizedBox(height: 8),
                BusyButton.tonal(
                  key: const ValueKey('review-send-back'),
                  icon: const Icon(Icons.undo),
                  onPressed: tally.canSendBack ? () => _sendBack(context, ref, tally) : null,
                  child: const Text('Send back to driver'),
                ),
                const SizedBox(height: 8),
                BusyButton.filled(
                  key: const ValueKey('review-approve'),
                  icon: const Icon(Icons.verified),
                  onPressed: tally.canApprove ? () => _approveAll(context, ref) : null,
                  child: Text(app.vehicle == null ? 'Approve application' : 'Approve application and vehicle'),
                ),
                const SizedBox(height: 6),
                Text(
                  tally.canSendBack
                      ? 'Rejected lines go back to the driver to fix.'
                      : tally.canApprove
                          ? 'Every line is approved or edited.'
                          : 'Check every line to approve, or reject one to send it back.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                ),
              ],
              const SizedBox(height: 32),
            ]),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ]);
}

/// One line: what it is and says, its photos, face match and liveness, the
/// decision, and Approve / Reject / Edit.
class _LineCard extends StatelessWidget {
  const _LineCard({
    required this.line,
    required this.item,
    required this.face,
    required this.enabled,
    required this.views,
    required this.log,
    required this.nameOf,
    required this.onView,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
    required this.onClear,
  });

  final ReviewLine line;
  final ReviewItem? item;
  final Map<String, dynamic>? face;
  final bool enabled;
  final ReviewViews views;
  final List<ReviewLogEntry> log;
  final String Function(String? id) nameOf;
  final Future<void> Function(String file) onView;
  final BusyAction onApprove, onReject, onEdit, onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final state = item?.fixed == true ? null : item?.state;
    final (icon, color) = switch (state) {
      ReviewState.approved => (Icons.check_circle, c.primary),
      ReviewState.rejected => (Icons.cancel, c.error),
      ReviewState.edited => (Icons.edit, c.onSurface),
      null => (Icons.radio_button_unchecked, c.outline),
    };
    final faceLow = face != null && faceNeedsCloserLook(face!['state'], face!['score'], reason: face!['reason']);
    // A document is decided only once this admin has opened it since it
    // last went back to pending (the server holds the same rule).
    final locked = reviewNeedsView(line) && !views.mine;
    final seen = views.count == 0
        ? null
        : 'Viewed ${views.count == 1 ? 'once' : '${views.count} times'}, last by ${nameOf(views.lastBy)}';
    return Card(
      key: ValueKey('review-line-${line.key}'),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: state == ReviewState.rejected ? c.error : c.outlineVariant),
      ),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 6, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 2, children: [
                Text(line.label, style: t.textTheme.titleSmall),
                if (line.value != null) SelectableText(line.value!, style: t.textTheme.bodyMedium),
                Text(
                  reviewAdminStatus(item),
                  key: ValueKey('review-status-${line.key}'),
                  style: t.textTheme.bodySmall?.copyWith(color: state == null ? mutedTextColor(t) : color),
                ),
                if (reviewNeedsView(line))
                  Text(
                    locked
                        ? (views.count == 0 ? 'Not opened yet: view it to decide' : 'View it again to decide · $seen')
                        : seen!,
                    key: ValueKey('review-views-${line.key}'),
                    style: t.textTheme.bodySmall?.copyWith(color: locked ? c.error : mutedTextColor(t)),
                  ),
                if (item?.state == ReviewState.edited && item?.oldValue != null)
                  Text(
                    'Was ${reviewValueText(line.key, item!.oldValue)}',
                    style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                  ),
              ]),
            ),
          ]),
          if (line.flag != null)
            Row(children: [
              Icon(Icons.flag_outlined, size: 18, color: c.error),
              const SizedBox(width: 6),
              Expanded(child: Text(line.flag!, style: t.textTheme.bodySmall)),
            ]),
          if (face != null || line.liveness != null || line.docStatus != null)
            Wrap(spacing: 8, runSpacing: 4, children: [
              if (face != null)
                Chip(
                  avatar: Icon(Icons.face, size: 18, color: faceLow ? c.error : c.primary),
                  label: Text('Face match: ${documentFaceText(face!)}'),
                  visualDensity: VisualDensity.compact,
                ),
              if (line.key == 'details.photo')
                Chip(
                  avatar: Icon(Icons.verified_user_outlined, size: 18,
                      color: line.liveness == 'passed' ? c.primary : c.error),
                  label: Text(livenessText(line.liveness)),
                  visualDensity: VisualDensity.compact,
                ),
              if (line.docStatus != null)
                Chip(label: Text('Document: ${line.docStatus}'), visualDensity: VisualDensity.compact),
            ]),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final (n, f) in line.files.indexed)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: Text(line.files.length == 1 ? 'View' : 'View ${n + 1}'),
                onPressed: () => onView(f),
              ),
            if (enabled) ...[
              BusyButton.text(
                key: ValueKey('review-approve-${line.key}'),
                icon: const Icon(Icons.check),
                onPressed: locked || state == ReviewState.approved ? null : onApprove,
                child: const Text('Approve'),
              ),
              if (reviewCanReject(line.key))
                BusyButton.text(
                  key: ValueKey('review-reject-${line.key}'),
                  icon: const Icon(Icons.close),
                  onPressed: locked ? null : onReject,
                  child: const Text('Reject'),
                ),
              if (line.edit != ReviewEdit.none)
                BusyButton.text(
                  key: ValueKey('review-edit-${line.key}'),
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: locked ? null : onEdit,
                  child: Text(line.edit == ReviewEdit.note ? 'Add a note' : 'Edit'),
                ),
              if (item != null)
                BusyButton.text(
                  key: ValueKey('review-clear-${line.key}'),
                  icon: const Icon(Icons.undo),
                  onPressed: locked ? null : onClear,
                  child: const Text('Back to pending'),
                ),
            ],
          ]),
          if (log.isNotEmpty)
            ExpansionTile(
              key: ValueKey('review-log-${line.key}'),
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: Text('Log (${log.length})', style: t.textTheme.labelLarge),
              children: [
                for (final e in log.reversed)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${e.label} by ${nameOf(e.actorId)}'),
                    trailing: Text(dateText(e.at.toIso8601String()), style: t.textTheme.bodySmall),
                  ),
              ],
            ),
        ]),
      ),
    );
  }
}

/// The admin's edit: the new value (typed as the line is: text, a date in
/// boxes, a number, the services) and a note for the driver.
class ReviewEditDialog extends StatefulWidget {
  const ReviewEditDialog({super.key, required this.line, required this.types, this.note});
  final ReviewLine line;
  final List<String> types;
  final String? note;

  @override
  State<ReviewEditDialog> createState() => _ReviewEditDialogState();
}

class _ReviewEditDialogState extends State<ReviewEditDialog> {
  ReviewLine get l => widget.line;
  late final _value = TextEditingController(text: l.editValue is String ? l.editValue as String : '');
  late final _note = TextEditingController(text: widget.note ?? '');
  late final Set<String> _types = {...?(l.editValue as List?)?.map((e) => '$e')};
  String? _problem;

  @override
  void dispose() {
    _value.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final note = _note.text.trim();
    Object? value;
    switch (l.edit) {
      case ReviewEdit.services:
        if (_types.isEmpty) return setState(() => _problem = 'Pick at least one Partner Service type.');
        value = [for (final t in widget.types) if (_types.contains(t)) t, for (final t in _types) if (!widget.types.contains(t)) t];
      case ReviewEdit.integer:
        if (int.tryParse(_value.text.trim()) == null) return setState(() => _problem = 'Enter a whole number.');
        value = _value.text.trim();
      case ReviewEdit.note:
        value = _value.text.trim().isEmpty ? null : _value.text.trim();
      default:
        if (_value.text.trim().isEmpty) return setState(() => _problem = 'Enter the new value.');
        value = _value.text.trim();
    }
    if (note.isEmpty) return setState(() => _problem = 'Add a note for the driver.');
    Navigator.pop(context, (value: value, note: note));
  }

  Widget _field() => switch (l.edit) {
        ReviewEdit.date => DateBoxesField(
            key: const ValueKey('review-edit-date'),
            label: l.label,
            controller: _value,
            firstDate: DateTime(1900),
            lastDate: DateTime(2100),
          ),
        ReviewEdit.services => ListSearchFilter(
            count: widget.types.length,
            hint: 'Search services',
            builder: (_, q) => Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in {...widget.types, ..._types})
                if (q.isEmpty || t.toLowerCase().contains(q.toLowerCase()))
                  FilterChip(
                    key: ValueKey('review-edit-type-$t'),
                    label: Text(t),
                    selected: _types.contains(t),
                    onSelected: (on) => setState(() => on ? _types.add(t) : _types.remove(t)),
                  ),
            ]),
          ),
        _ => TextField(
            key: const ValueKey('review-edit-value'),
            controller: _value,
            keyboardType: l.edit == ReviewEdit.integer ? TextInputType.number : TextInputType.text,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: l.edit == ReviewEdit.note ? 'Value shown to the driver (optional)' : 'New value',
              border: const OutlineInputBorder(),
            ),
          ),
      };

  @override
  Widget build(BuildContext context) => AlertDialog(
        key: const ValueKey('review-edit-dialog'),
        title: Text(l.edit == ReviewEdit.note ? 'Note on ${l.label}' : 'Edit ${l.label}'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (l.value != null && l.edit != ReviewEdit.note)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('Now: ${l.value}', style: Theme.of(context).textTheme.bodySmall),
                ),
              _field(),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('review-edit-note'),
                controller: _note,
                minLines: 2,
                maxLines: 4,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Note for the driver',
                  hintText: 'For example: Changed to match your MyKad.',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_problem != null)
                Text(_problem!, key: const ValueKey('review-edit-problem'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('review-edit-save'), onPressed: _save, child: const Text('Save')),
        ],
      );
}
