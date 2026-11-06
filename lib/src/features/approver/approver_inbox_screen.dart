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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(approverPendingProvider);
    // Other people's ID and licence images: keep them out of screenshots and
    // screen recordings while they are on screen (Android fully; iOS hides
    // during recording — a screenshot can't be blocked there).
    return SecureScreen(
      child: Scaffold(
      appBar: AppBar(title: const Text('Approvals')),
      body: OfflineStrip.over(AsyncView<List<ApproverDoc>>(
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
                        subtitle: Text('${d.ownerName} · ${sourceLabel(d.source)}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openDocument(context, d),
                      ),
                    );
                  },
                ),
              ),
      )),
    ),
    );
  }

  Future<void> _openDocument(BuildContext context, ApproverDoc d) => showAppDialog<void>(
        id: 'approver.document',
        context: context,
        builder: (c) => _DocumentViewer(doc: d),
      );
}

/// The uploaded image(s) for one document, with approve / reject for an
/// approver who may decide it.
class _DocumentViewer extends ConsumerStatefulWidget {
  const _DocumentViewer({required this.doc});

  final ApproverDoc doc;

  @override
  ConsumerState<_DocumentViewer> createState() => _DocumentViewerState();
}

enum _ViewerMode { none, reject, delete, edit }

class _DocumentViewerState extends ConsumerState<_DocumentViewer> {
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
                        Text('${doc.ownerName} · ${ApproverInboxScreen.sourceLabel(doc.source)}',
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

    return Padding(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (canApprove)
            FilledButton(
              key: const ValueKey('approver-approve'),
              onPressed: _busy ? null : () => _review('approve'),
              child: _spinnerOr('Approve'),
            ),
          if (canApprove) const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (canApprove)
                OutlinedButton(
                  key: const ValueKey('approver-reject'),
                  style: OutlinedButton.styleFrom(foregroundColor: cs.error, side: BorderSide(color: cs.error)),
                  onPressed: _busy ? null : () => setState(() => _mode = _ViewerMode.reject),
                  child: const Text('Reject'),
                ),
              if (canUpload && widget.doc.hasCapturedFields)
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
