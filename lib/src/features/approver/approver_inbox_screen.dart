import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/screens/meterapp/pick_image.dart' show pickDocumentImage;
import '../../core/document_ai.dart';
import '../../core/secure_screen.dart';
import '../../data/approver_inbox_repository.dart';
import '../../data/document_ai_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/offline_strip.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/storage_image.dart';

/// Side menu → Approvals: the documents waiting for review in this approver's
/// scope (migrations 0349/0350). Tapping a row opens the uploaded image(s); an
/// approver with can_approve decides it there (0351). The server re-checks the
/// scope and permission before writing.
class ApproverInboxScreen extends ConsumerWidget {
  const ApproverInboxScreen({super.key});

  static IconData iconFor(String source) => switch (source) {
        'partner' => Icons.badge_outlined,
        'vehicle' => Icons.directions_car_outlined,
        'identity' => Icons.credit_card_outlined,
        _ => Icons.description_outlined,
      };

  static String sourceLabel(String source) => switch (source) {
        'partner' => 'Partner registration',
        'vehicle' => 'Vehicle document',
        'identity' => 'User ID',
        _ => 'Document',
      };

  /// "Owner · Vehicle document · ABC 1234" — the plate is added for vehicle
  /// documents so the approver can see which car the document belongs to.
  static String ownerLine(ApproverDoc d) => [
        d.ownerName,
        sourceLabel(d.source),
        if (d.source == 'vehicle' && d.plate != null) d.plate!,
      ].join(' · ');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Other people's ID and licence images: keep them out of screenshots and
    // screen recordings while they are on screen (Android fully; iOS hides
    // during recording — a screenshot can't be blocked there).
    return SecureScreen(
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Approvals'),
            bottom: const TabBar(
              tabs: [
                Tab(key: ValueKey('approvals-tab-review'), text: 'To review'),
                Tab(key: ValueKey('approvals-tab-pending'), text: 'Pending Upload'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              _reviewTab(context, ref),
              const _PendingUploadTab(),
            ],
          ),
        ),
      ),
    );
  }

  /// The documents waiting for this approver's review (the original Approvals
  /// list).
  Widget _reviewTab(BuildContext context, WidgetRef ref) {
    final value = ref.watch(approverPendingProvider);
    return OfflineStrip.over(AsyncView<List<ApproverDoc>>(
      value: value,
      onRetry: () => ref.invalidate(approverPendingProvider),
      data: (docs) => docs.isEmpty
          ? const EmptyState(
              icon: Icons.fact_check_outlined,
              title: 'Nothing to review',
              message: 'Documents waiting for your review appear here, within the scope your admin set.',
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(approverPendingProvider),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: docs.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                itemBuilder: (context, i) {
                  final d = docs[i];
                  final cs = Theme.of(context).colorScheme;
                  return ResponsiveCenter(
                    maxWidth: 760,
                    child: ListTile(
                      key: ValueKey('approver-doc-${d.id}'),
                      leading: CircleAvatar(
                        backgroundColor: cs.surfaceContainerHighest,
                        foregroundColor: cs.onSurfaceVariant,
                        child: Icon(iconFor(d.source)),
                      ),
                      title: Text(d.docLabel, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(ownerLine(d),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openDocument(context, d),
                    ),
                  );
                },
              ),
            ),
    ));
  }

  Future<void> _openDocument(BuildContext context, ApproverDoc d) => openApproverDocument(context, d);
}

/// "Pending Upload" tab (migration 0389): every required document still missing
/// across the people this approver covers, each with a button to nudge the
/// member to upload it and the count / time of the last reminder. Needs
/// can_upload (the RPC returns nothing otherwise, so the tab reads empty).
class _PendingUploadTab extends ConsumerWidget {
  const _PendingUploadTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(approverPendingUploadsProvider);
    return OfflineStrip.over(AsyncView<List<PendingUpload>>(
      value: value,
      onRetry: () => ref.invalidate(approverPendingUploadsProvider),
      data: (items) => items.isEmpty
          ? const EmptyState(
              icon: Icons.cloud_upload_outlined,
              title: 'Nothing pending upload',
              message: 'Required documents your people still need to upload appear here, within '
                  'the scope your admin set. You can nudge each one from this list.',
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(approverPendingUploadsProvider),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
                itemBuilder: (context, i) => ResponsiveCenter(
                  maxWidth: 760,
                  child: _PendingUploadRow(item: items[i]),
                ),
              ),
            ),
    ));
  }
}

/// One member + missing document, with the nudge button. Seeds its reminder
/// count / time from the row and updates them on each nudge, so the list need
/// not reload after a reminder.
class _PendingUploadRow extends ConsumerStatefulWidget {
  const _PendingUploadRow({required this.item});
  final PendingUpload item;

  @override
  ConsumerState<_PendingUploadRow> createState() => _PendingUploadRowState();
}

class _PendingUploadRowState extends ConsumerState<_PendingUploadRow> {
  bool _busy = false;
  late int _count = widget.item.sentCount;
  late DateTime? _lastSentAt = widget.item.lastSentAt;

  Future<void> _send() async {
    final item = widget.item;
    setState(() => _busy = true);
    try {
      final stat = await ref.read(approverInboxRepositoryProvider).requestDocumentUpload(
            item.memberId, item.source, item.docKey, label: item.name,
          );
      if (!mounted) return;
      setState(() {
        _count = stat.count;
        _lastSentAt = stat.lastSentAt;
      });
      unawaited(showAppNotice(
        id: 'notice.approver-doc-request', context: context,
        message: 'Upload request sent to ${item.memberName}.', kind: NoticeKind.success));
    } catch (e) {
      if (!mounted) return;
      final m = e.toString();
      unawaited(showAppNotice(
        id: 'notice.approver-doc-request', context: context,
        message: m.contains('not_allowed') || m.contains('not_authorized')
            ? "You can't request uploads for this member."
            : (m.contains('out_of_scope') ? "This member isn't in your scope." : "Couldn't send the request. Try again."),
        kind: NoticeKind.error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// "09 Nov 2026, 18:52" from a local DateTime.
  static String _fmtDateTime(DateTime t) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${_two(t.day)} ${m[t.month - 1]} ${t.year}, ${_two(t.hour)}:${_two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final item = widget.item;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: cs.surfaceContainerHighest,
            foregroundColor: cs.onSurfaceVariant,
            child: const Icon(Icons.badge_outlined),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.memberName, style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(item.name, style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                if (_count > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      'Requested $_count×${_lastSentAt != null ? ' · last ${_fmtDateTime(_lastSentAt!)}' : ''}',
                      key: ValueKey('pending-upload-count-${item.memberId}-${item.docKey}'),
                      style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: ValueKey('pending-upload-notify-${item.memberId}-${item.docKey}'),
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _busy ? null : _send,
            icon: _busy
                ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.notifications_active_outlined, size: 16),
            label: Text(_count > 0 ? 'Notify again' : 'Notify'),
          ),
        ],
      ),
    );
  }
}

/// Opens the shared document viewer for [doc]. [onChanged] runs after a
/// successful approve / reject / edit / replace / delete, on top of the inbox
/// refresh — the My Team member screen uses it to reload that person's docs.
Future<void> openApproverDocument(BuildContext context, ApproverDoc doc, {VoidCallback? onChanged}) =>
    showAppDialog<void>(
      id: 'approver.document',
      context: context,
      builder: (c) => ApproverDocumentViewer(doc: doc, onChanged: onChanged),
    );

/// The uploaded image(s) for one document, with approve / reject for an
/// approver who may decide it.
class ApproverDocumentViewer extends ConsumerStatefulWidget {
  const ApproverDocumentViewer({super.key, required this.doc, this.onChanged});

  final ApproverDoc doc;
  final VoidCallback? onChanged;

  @override
  ConsumerState<ApproverDocumentViewer> createState() => _DocumentViewerState();
}

enum _ViewerMode { none, reject, delete, edit }

class _DocumentViewerState extends ConsumerState<ApproverDocumentViewer> {
  final _reason = TextEditingController();
  final _deleteNote = TextEditingController();
  late final _number = TextEditingController(text: widget.doc.documentNumber ?? '');
  late final _start = TextEditingController(text: widget.doc.startDate ?? '');
  late final _expiry = TextEditingController(text: widget.doc.expiryDate ?? '');
  bool _busy = false;
  _ViewerMode _mode = _ViewerMode.none;

  @override
  void dispose() {
    _reason.dispose();
    _deleteNote.dispose();
    _number.dispose();
    _start.dispose();
    _expiry.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String ok) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(approverPendingProvider);
      widget.onChanged?.call();
      if (!mounted) return;
      Navigator.pop(context);
      unawaited(showAppNotice(id: 'notice.approver', context: context, message: ok, kind: NoticeKind.success));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      unawaited(showAppNotice(
        id: 'notice.approver',
        context: context,
        message: "Couldn't save. Try again.",
        kind: NoticeKind.error,
      ));
    }
  }

  Future<void> _review(String action, {String? note}) => _run(
        () => ref.read(approverInboxRepositoryProvider).review(widget.doc, action, note: note),
        action == 'approve' ? 'Approved.' : 'Rejected.',
      );

  Future<void> _delete(bool hard, {String? note}) => _run(
        () => ref.read(approverInboxRepositoryProvider).remove(widget.doc, note: note),
        hard ? 'Deleted.' : 'Sent back for re-upload.',
      );

  Future<void> _saveFields() async {
    final doc = widget.doc;
    await _run(
      () => ref.read(approverInboxRepositoryProvider).editFields(
            doc,
            documentNumber: doc.requiresNumber ? _number.text.trim() : null,
            startDate: doc.requiresStart ? _start.text.trim() : null,
            expiryDate: doc.requiresExpiry ? _expiry.text.trim() : null,
          ),
      'Details saved.',
    );
  }

  /// Which editable captured field a read-vs-stored row maps to, or null when
  /// it is not one the approver can correct here (identity-check rows, Country,
  /// or a document type that does not capture that field).
  ({String kind, bool required})? _editableFor(DocReadRow r) {
    final doc = widget.doc;
    if (doc.source != 'partner' && doc.source != 'vehicle') return null;
    return switch (r.field) {
      'Document no.' => (kind: 'number', required: doc.requiresNumber),
      'Start date' => (kind: 'start', required: doc.requiresStart),
      'Expiry' => (kind: 'expiry', required: doc.requiresExpiry),
      _ => null,
    };
  }

  /// Apply what the scan read for one field to the stored value (the "Fix"
  /// button on a differing read-vs-stored row). The edit RPC rewrites every
  /// captured field the type requires, so the other fields are resent at their
  /// current stored values and only this one changes. Stays on the sheet and
  /// refreshes the detail rather than closing it (unlike a save).
  Future<void> _fixField(DocDetail detail, DocReadRow r) async {
    final doc = widget.doc;
    final val = r.read;
    final map = _editableFor(r);
    if (val == null || map == null || !map.required) return;
    setState(() => _busy = true);
    try {
      await ref.read(approverInboxRepositoryProvider).editFields(
            doc,
            documentNumber: doc.requiresNumber ? (map.kind == 'number' ? val : detail.documentNumber) : null,
            startDate: doc.requiresStart ? (map.kind == 'start' ? val : detail.startDate) : null,
            expiryDate: doc.requiresExpiry ? (map.kind == 'expiry' ? val : detail.expiryDate) : null,
          );
      if (!mounted) return;
      // Keep the edit controllers in step, so opening Edit shows the new value.
      if (map.kind == 'number') _number.text = val;
      if (map.kind == 'start') _start.text = val;
      if (map.kind == 'expiry') _expiry.text = val;
      ref.invalidate(approverDocumentDetailProvider((source: doc.source, id: doc.id)));
      widget.onChanged?.call();
      setState(() => _busy = false);
      unawaited(showAppNotice(
        id: 'notice.approver', context: context,
        message: 'Updated ${r.field} to what the document reads.', kind: NoticeKind.success));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final m = e.toString();
      unawaited(showAppNotice(
        id: 'notice.approver', context: context,
        message: m.contains('APPROVER_EXPIRED')
            ? "The document reads an expiry in the past — it can't be applied."
            : "Couldn't apply that. Try again.",
        kind: NoticeKind.error));
    }
  }

  /// Re-scan the document to re-read the captured fields: capture or pick a
  /// photo, run the same AI reader the upload form uses, and fill in what it
  /// reads (overwriting, since a rescan is a correction). The approver still
  /// checks the values before saving.
  Future<void> _rescan() async {
    final picked = await pickDocumentImage(context);
    if (picked == null || !mounted) return;
    final doc = widget.doc;
    setState(() => _busy = true);
    try {
      final repo = ref.read(documentAiRepositoryProvider);
      final url = await repo.prepare(picked.bytes, picked.name);
      final outcome = url == null
          ? (result: null, reason: 'image_too_large')
          : await repo.verify(docAiRequestBody(
              frontDataUrl: url,
              docName: doc.docLabel,
              documentNumber: doc.requiresNumber ? _number.text : null,
              startDate: doc.requiresStart ? _start.text : null,
              expiryDate: doc.requiresExpiry ? _expiry.text : null,
            ));
      if (!mounted) return;
      final r = outcome.result;
      if (r == null) {
        setState(() => _busy = false);
        unawaited(showAppNotice(
          id: 'notice.approver',
          context: context,
          message: docAiUnavailableText(outcome.reason),
          kind: NoticeKind.error,
        ));
        return;
      }
      final fill = docAiAutofill(
        r,
        requireDocumentNumber: doc.requiresNumber,
        requireStartDate: doc.requiresStart,
        requireExpiryDate: doc.requiresExpiry,
        requireInsuranceProvider: false,
        pwdFlag: false,
        // Empty "current" values so the scan fills every required field,
        // replacing whatever was captured before (this is a correction).
        documentNumber: '',
        startDate: '',
        expiryDate: '',
        insurerId: null,
        isPwd: false,
        insurers: const [],
      );
      setState(() {
        _busy = false;
        if (fill.documentNumber != null) _number.text = fill.documentNumber!;
        if (fill.startDate != null) _start.text = fill.startDate!;
        if (fill.expiryDate != null) _expiry.text = fill.expiryDate!;
      });
      unawaited(showAppNotice(
        id: 'notice.approver',
        context: context,
        message: fill.filled.isEmpty
            ? "The document was read but nothing matched. Check the fields and type them if needed."
            : 'Read from the document. Check the fields before saving.',
        kind: fill.filled.isEmpty ? NoticeKind.info : NoticeKind.success,
      ));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      unawaited(showAppNotice(
        id: 'notice.approver',
        context: context,
        message: "Couldn't read the document. Type the details instead.",
        kind: NoticeKind.error,
      ));
    }
  }

  Future<void> _replace() async {
    final picked = await pickDocumentImage(context);
    if (picked == null || !mounted) return;
    await _run(
      () => ref.read(approverInboxRepositoryProvider).replaceImage(
            widget.doc,
            bytes: picked.bytes,
            contentType: picked.contentType,
          ),
      'Image replaced.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final grant = ref.watch(approverSelfProvider).value;
    final canApprove = grant?.canApprove ?? false;
    final canDelete = grant?.canDelete ?? false;
    final canUpload = grant?.canUpload ?? false;
    final deleteHard = grant?.deleteHard ?? false;
    final doc = widget.doc;
    final urls = [
      if ((doc.fileUrl ?? '').isNotEmpty) doc.fileUrl!,
      if ((doc.fileUrlBack ?? '').isNotEmpty) doc.fileUrlBack!,
    ];
    return SecureScreen(
      child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(doc.docLabel, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text(ApproverInboxScreen.ownerLine(doc),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('approver-document-close'),
                    icon: const Icon(Icons.close),
                    onPressed: _busy ? null : () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                children: [
                  if (urls.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text('No image was uploaded for this document.',
                          textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                    ),
                  for (final url in urls)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: InteractiveViewer(
                          child: StorageImage(
                            url,
                            fit: BoxFit.contain,
                            loadingBuilder: (c, child, progress) => progress == null
                                ? child
                                : const Padding(
                                    padding: EdgeInsets.all(32),
                                    child: Center(child: CircularProgressIndicator()),
                                  ),
                            errorBuilder: (c, _, _) => Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text("Couldn't load this image.",
                                  textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (doc.hasCapturedFields && _mode != _ViewerMode.edit) _capturedSummary(context, doc, cs),
                  if (_mode != _ViewerMode.edit) _richDetail(context, cs),
                ],
              ),
            ),
            _actions(context, canApprove, canDelete, canUpload, deleteHard, cs),
          ],
        ),
      ),
    ),
    );
  }

  Widget _spinnerOr(String label) => _busy
      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
      : Text(label);

  /// A coloured status pill for a document that is no longer pending.
  Widget _statusLine(BuildContext context, String status, ColorScheme cs) {
    final (bg, fg, icon) = switch (status) {
      'Approved' => (cs.primaryContainer, cs.onPrimaryContainer, Icons.check_circle_outline),
      'Rejected' => (cs.errorContainer, cs.onErrorContainer, Icons.cancel_outlined),
      _ => (cs.surfaceContainerHighest, cs.onSurfaceVariant, Icons.schedule_outlined),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 8),
          Text(status, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: fg)),
        ],
      ),
    );
  }

  /// The rich detail (migration 0365): read-vs-stored, AI verification, the
  /// face check and status/history. Each section shows only when it has data,
  /// so a plain document with none of this simply shows nothing extra.
  Widget _richDetail(BuildContext context, ColorScheme cs) {
    final detail = ref.watch(approverDocumentDetailProvider((source: widget.doc.source, id: widget.doc.id))).value;
    if (detail == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final sections = <Widget>[];

    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
          child: Text(t, style: text.labelMedium?.copyWith(color: cs.onSurfaceVariant, letterSpacing: 0.5)),
        );
    Widget chip(String label, {bool good = false, bool neutral = false}) {
      final bg = good ? Colors.green.withValues(alpha: 0.15) : (neutral ? cs.surfaceContainerHighest : cs.surfaceContainerHighest);
      final fg = good ? Colors.green.shade800 : cs.onSurface;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(label, style: text.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
      );
    }

    // Read-from-document vs stored. A differing row that maps to an editable
    // captured field gets a "Fix" button that writes the read value into it.
    if (detail.read.isNotEmpty) {
      sections.add(header('READ FROM DOCUMENT VS STORED'));
      for (final r in detail.read) {
        final canFix = !r.match && r.read != null && (_editableFor(r)?.required ?? false);
        sections.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 92, child: Text(r.field, style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.read ?? '—', style: text.bodyMedium),
                    // The stored value only matters when it differs from the read.
                    if (!r.match)
                      Text('stored: ${r.stored ?? '—'}',
                          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (r.match)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check, size: 15, color: Colors.green.shade700),
                  const SizedBox(width: 2),
                  Text('match', style: text.labelMedium?.copyWith(color: Colors.green.shade800, fontWeight: FontWeight.w600)),
                ])
              else if (canFix)
                TextButton(
                  key: ValueKey('doc-fix-${_editableFor(r)!.kind}'),
                  onPressed: _busy ? null : () => _fixField(detail, r),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Fix'),
                )
              else
                Text('differs', style: text.labelMedium?.copyWith(color: cs.error, fontWeight: FontWeight.w600)),
            ],
          ),
        ));
      }
    }

    // AI verification.
    final ai = detail.ai;
    if (ai != null) {
      sections.add(header('AI VERIFICATION'));
      final chips = <Widget>[
        if (ai.genuine != null) chip(ai.genuine! ? 'Genuine' : 'Not genuine', good: ai.genuine!),
        if (ai.matches != null && (ai.detectedTitle ?? '').isNotEmpty)
          chip('${ai.matches! ? 'Matches' : 'Does not match'} "${ai.detectedTitle}"', good: ai.matches!),
        if ((ai.confidence ?? '').isNotEmpty) chip('Confidence ${ai.confidence}', neutral: true),
        if ((ai.country ?? '').isNotEmpty) chip('Country ${ai.country}', neutral: true),
      ];
      if (chips.isNotEmpty) sections.add(Wrap(spacing: 8, runSpacing: 8, children: chips));
    }

    // Face check.
    final face = detail.face;
    if (face != null) {
      sections.add(header('FACE CHECK'));
      final scoreTxt = face.score == null ? '' : ' · ${face.score!.toStringAsFixed(2)}';
      sections.add(Align(
        alignment: Alignment.centerLeft,
        child: chip(
          (face.ok == true ? 'Portrait matches selfie' : (face.reason ?? face.label ?? 'Face check')) + scoreTxt,
          good: face.ok == true,
          neutral: face.ok != true,
        ),
      ));
    }

    // Status & history.
    final rows = <Widget>[];
    void hrow(String label, String? value, {Color? valueColor}) {
      if ((value ?? '').trim().isEmpty) return;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(label, style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
            Flexible(
              child: Text(value!, textAlign: TextAlign.end,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: valueColor)),
            ),
          ],
        ),
      ));
    }

    final statusColor = switch (detail.status) {
      'Approved' => Colors.green.shade800,
      'Rejected' => cs.error,
      _ => null,
    };
    hrow('Status', detail.status, valueColor: statusColor);
    hrow('Reviewer notes', detail.reviewerNotes);
    hrow('Changed by', detail.changedBy);
    hrow('Uploaded', _fmtDay(detail.uploadedAt));
    hrow('Reviewed', _fmtDay(detail.reviewedAt));
    if (rows.isNotEmpty) {
      sections.add(header('STATUS & HISTORY'));
      sections.addAll(rows);
    }

    if (sections.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections);
  }

  /// "2026-10-12T…" → "12 Oct 2026"; null/blank → null.
  static String? _fmtDay(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final d = DateTime.tryParse(raw);
    if (d == null) return raw.length >= 10 ? raw.substring(0, 10) : raw;
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month - 1]} ${d.year}';
  }

  /// The fields the owner captured, read-only, so an approver can check them
  /// against the image before approving. A missing required field, or a
  /// past-dated expiry, is flagged.
  Widget _capturedSummary(BuildContext context, ApproverDoc doc, ColorScheme cs) {
    final rows = <Widget>[];
    void row(String label, String? value, {String? warn}) {
      final shown = (value ?? '').trim();
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: Text(
                shown.isEmpty ? 'Not provided' : shown,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: shown.isEmpty ? cs.error : null,
                      fontStyle: shown.isEmpty ? FontStyle.italic : null,
                    ),
              ),
            ),
            if (warn != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(warn, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.error)),
              ),
          ],
        ),
      ));
    }

    if (doc.requiresNumber) row('Document number', doc.documentNumber);
    if (doc.requiresStart) {
      row('Start date', doc.startDate == null ? null : formatStoredDateForUser(doc.startDate));
    }
    if (doc.requiresExpiry) {
      final d = DateTime.tryParse(doc.expiryDate ?? '');
      final past = d != null && d.isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));
      row('Expiry date', doc.expiryDate == null ? null : formatStoredDateForUser(doc.expiryDate),
          warn: past ? 'Expired' : null);
    }

    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  Widget _actions(BuildContext context, bool canApprove, bool canDelete, bool canUpload, bool deleteHard, ColorScheme cs) {
    final pad = const EdgeInsets.fromLTRB(20, 8, 20, 16);
    if (!canApprove && !canDelete && !canUpload) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Text('You can view these documents; your admin has not granted a review action.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      );
    }

    if (_mode == _ViewerMode.reject) {
      final reason = _reason.text.trim();
      return Padding(
        padding: pad,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('approver-reject-reason'),
              controller: _reason,
              enabled: !_busy,
              minLines: 2,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Tell the owner why, so they can fix it',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton(onPressed: _busy ? null : () => setState(() => _mode = _ViewerMode.none), child: const Text('Back')),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('approver-reject-confirm'),
                  style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
                  onPressed: (_busy || reason.isEmpty) ? null : () => _review('reject', note: reason),
                  child: _spinnerOr('Reject'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (_mode == _ViewerMode.delete) {
      final note = _deleteNote.text.trim();
      return Padding(
        padding: pad,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              deleteHard
                  ? 'Permanently delete this document? This cannot be undone.'
                  : 'Remove this upload and ask the owner to send a new one?',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('approver-delete-note'),
              controller: _deleteNote,
              enabled: !_busy,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: deleteHard ? 'Note (optional)' : 'Reason for the owner (optional)',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton(onPressed: _busy ? null : () => setState(() => _mode = _ViewerMode.none), child: const Text('Back')),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('approver-delete-confirm'),
                  style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
                  onPressed: _busy ? null : () => _delete(deleteHard, note: note.isEmpty ? null : note),
                  child: _spinnerOr(deleteHard ? 'Delete' : 'Send back'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (_mode == _ViewerMode.edit) {
      final doc = widget.doc;
      return Padding(
        padding: pad,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('approver-edit-rescan'),
              onPressed: _busy ? null : _rescan,
              icon: const Icon(Icons.document_scanner_outlined, size: 18),
              label: const Text('Rescan to capture'),
            ),
            const SizedBox(height: 12),
            if (doc.requiresNumber) ...[
              TextField(
                key: const ValueKey('approver-edit-number'),
                controller: _number,
                enabled: !_busy,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Document number', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
            ],
            if (doc.requiresStart) ...[
              DateBoxesField(
                key: const ValueKey('approver-edit-start'),
                label: 'Start date',
                controller: _start,
                isRequired: true,
                enabled: !_busy,
              ),
              const SizedBox(height: 10),
            ],
            if (doc.requiresExpiry) ...[
              DateBoxesField(
                key: const ValueKey('approver-edit-expiry'),
                label: 'Expiry date',
                controller: _expiry,
                isRequired: true,
                enabled: !_busy,
                // An expired document can't be accepted — the server refuses it too.
                firstDate: DateTime.now(),
                beforeFirstText: 'That date is in the past. Use the renewed document.',
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                TextButton(onPressed: _busy ? null : () => setState(() => _mode = _ViewerMode.none), child: const Text('Back')),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('approver-edit-save'),
                  onPressed: _busy ? null : _saveFields,
                  child: _spinnerOr('Save'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final pending = widget.doc.isPending;
    return Padding(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A document that is already decided shows its status; approve /
          // reject / edit no longer apply, but replace / delete still can.
          if (!pending && (widget.doc.status ?? '').isNotEmpty) ...[
            _statusLine(context, widget.doc.status!, cs),
            const SizedBox(height: 10),
          ],
          if (canApprove && pending)
            FilledButton(
              key: const ValueKey('approver-approve'),
              onPressed: _busy ? null : () => _review('approve'),
              child: _spinnerOr('Approve'),
            ),
          if (canApprove && pending) const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (canApprove && pending)
                OutlinedButton(
                  key: const ValueKey('approver-reject'),
                  style: OutlinedButton.styleFrom(foregroundColor: cs.error, side: BorderSide(color: cs.error)),
                  onPressed: _busy ? null : () => setState(() => _mode = _ViewerMode.reject),
                  child: const Text('Reject'),
                ),
              if (canUpload && widget.doc.hasCapturedFields && pending)
                OutlinedButton.icon(
                  key: const ValueKey('approver-edit-fields'),
                  onPressed: _busy ? null : () => setState(() => _mode = _ViewerMode.edit),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit details'),
                ),
              if (canUpload)
                OutlinedButton.icon(
                  key: const ValueKey('approver-replace'),
                  onPressed: _busy ? null : _replace,
                  icon: const Icon(Icons.upload_outlined, size: 18),
                  label: const Text('Replace image'),
                ),
              if (canDelete)
                OutlinedButton.icon(
                  key: const ValueKey('approver-delete'),
                  style: OutlinedButton.styleFrom(foregroundColor: cs.error, side: BorderSide(color: cs.error)),
                  onPressed: _busy ? null : () => setState(() => _mode = _ViewerMode.delete),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(deleteHard ? 'Delete' : 'Send back'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
