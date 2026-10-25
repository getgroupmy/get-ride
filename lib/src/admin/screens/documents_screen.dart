import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../../widgets/in_app_page.dart';
import '../../data/live_tables.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/date_boxes.dart';
import '../../core/doc_kinds.dart' show DocOnFile;
import '../../core/signin_checks.dart' show faceMatchText, faceNeedsCloserLook, livenessText, rejectNotes;
import '../../data/identity_repository.dart' show identityRepositoryProvider;
import '../widgets/reject_reason.dart';
import 'doc_fields_section.dart';
import 'online_selfie_check_screen.dart' show onlineSelfieCloserCountProvider;
import 'signin_checks_review.dart';

final adminDocsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, table) async {
    ref.watchAdminLive(table);
    final repo = ref.watch(adminRepositoryProvider);
    final docs = await repo.documents(table);
    // Whose document it is (Expo joined these in). The list still works
    // without them when the lookup fails.
    try {
      final owners = await repo.documentOwners(
        docs.map((d) => d['partner_id']).whereType<String>(),
        table == 'vehicle_documents' ? docs.map((d) => d['vehicle_id']).whereType<String>() : const [],
      );
      final faces = await repo.documentFaceChecks(
        table == 'vehicle_documents' ? 'vehicle_document' : 'provider_document',
        docs.map((d) => '${d['id']}'),
      );
      return [
        for (final d in docs) {...withDocumentOwner(d, owners.partners, owners.vehicles), '_face': faces['${d['id']}']},
      ];
    } catch (_) {
      return docs;
    }
  },
);

/// [d] with `_owner` (the partner's name, else phone) and `_plate` (the
/// vehicle's plate) filled in from the lookups, where known.
Map<String, dynamic> withDocumentOwner(
  Map<String, dynamic> d,
  Map<String, Map<String, dynamic>> partners,
  Map<String, Map<String, dynamic>> vehicles,
) {
  String? text(Object? v) {
    final t = '${v ?? ''}'.trim();
    return t.isEmpty ? null : t;
  }

  final partner = partners['${d['partner_id']}'];
  final vehicle = vehicles['${d['vehicle_id']}'];
  return {
    ...d,
    '_owner': text(partner?['name']) ?? text(partner?['phone']),
    '_plate': text(vehicle?['plate']),
    // What is on file, to check the fields read off the document against.
    '_onFile': DocOnFile(
      name: text(partner?['name']),
      ic: text(partner?['ic']),
      plate: text(vehicle?['plate']),
      chassis: text(vehicle?['vin']),
      engine: text(vehicle?['engine_number']),
      make: text(vehicle?['make']),
      model: text(vehicle?['model']),
      year: text(vehicle?['year']),
      ownerName: text(vehicle?['grant_owner_name']),
    ),
  };
}

/// The list search: document name and number, whose it is, and the plate.
bool documentMatches(Map<String, dynamic> d, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return [d['doc_name'], d['document_number'], d['_owner'], d['_plate']]
      .whereType<Object>()
      .join(' ')
      .toLowerCase()
      .contains(q);
}

/// The detail fields an admin may correct on a document (Expo
/// `DocumentMetadataEditModal`); a blank field is cleared.
Map<String, dynamic> documentEditPatch({
  required String name,
  required String number,
  required String insurer,
  required String country,
  required String start,
  required String expiry,
  required bool pwd,
}) {
  String? t(String s) => s.trim().isEmpty ? null : s.trim();
  return {
    'doc_name': t(name),
    'document_number': t(number),
    'insurance_provider_name': t(insurer),
    'issuance_country': t(country),
    'start_date': t(start),
    'expiry_date': t(expiry),
    'is_pwd': pwd,
  };
}

/// A yyyy-mm-dd date, or blank. Null when it is fine.
String? documentDateError(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t) || DateTime.tryParse(t) == null) return 'Use YYYY-MM-DD';
  return null;
}

/// A document's face match against the person's live selfie (0288), or
/// null when the document has no photo of them.
Map<String, dynamic>? documentFace(Map<String, dynamic> d) =>
    d['_face'] is Map ? Map<String, dynamic>.from(d['_face'] as Map) : null;

/// Whether [d]'s face match needs a closer look (low score, faces differ,
/// no face, no live selfie).
bool documentNeedsCloserLook(Map<String, dynamic> d) {
  final f = documentFace(d);
  return f != null && faceNeedsCloserLook(f['state'], f['score'], reason: f['reason']);
}

/// The face match line: "82% match · AWS", "Not checked · No live selfie yet",
/// "Checking…" while the server works on it.
String documentFaceText(Map<String, dynamic> f) => f['state'] == 'pending'
    ? 'Checking the face match…'
    : faceMatchText(f['state'], f['score'], provider: f['provider'], reason: f['reason']);

/// How the selfie it was matched with was taken.
String documentSelfieText(Map<String, dynamic> f) => f['reason'] == 'no_live_selfie' || f['selfie_url'] == null
    ? 'No live selfie: not checked'
    : livenessText(f['_liveness'] ?? 'passed', f['_liveness_detail']);

/// Expiry wins over a non-rejected status (Expo `computeDisplayStatus`).
String documentDisplayStatus(Map<String, dynamic> d, {DateTime? now}) {
  final status = (d['status'] as String?) ?? 'Pending Review';
  final exp = DateTime.tryParse('${d['expiry_date'] ?? ''}');
  if (exp != null && exp.isBefore(now ?? DateTime.now()) && status != 'Rejected') return 'Expired';
  return status;
}

const _docFilters = {
  'Pending Review': 'To review',
  'Approved': 'Approved',
  'Rejected': 'Rejected',
  'Expired': 'Expired',
  'closer': 'Needs a closer look',
  'all': 'All',
};

class AdminDocumentsScreen extends ConsumerStatefulWidget {
  const AdminDocumentsScreen({super.key, this.vehicle = false, this.signIn = false});
  final bool vehicle;

  /// Opens on the dispatch IDs' selfies and IDs (0281).
  final bool signIn;

  @override
  ConsumerState<AdminDocumentsScreen> createState() => _AdminDocumentsScreenState();
}

class _AdminDocumentsScreenState extends ConsumerState<AdminDocumentsScreen> {
  late String _tab = widget.signIn ? 'signin' : (widget.vehicle ? 'vehicle' : 'partner');
  bool get _vehicle => _tab == 'vehicle';
  String _filter = 'Pending Review';
  String _query = '';

  String get _table => _vehicle ? 'vehicle_documents' : 'provider_documents';

  void _open(Map<String, dynamic> d) {
    final canEdit = ref.read(moduleAccessProvider('documents')) == AccessLevel.edit;
    final notes = TextEditingController(text: d['reviewer_notes'] as String?);
    final ai = d['ai_verification'];
    showAdminSheet<void>(
      context,
      title: (d['doc_name'] as String?) ?? 'Document',
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          StatusChip(documentDisplayStatus(d)),
          const Spacer(),
          if (canEdit) ...[
            TextButton.icon(
              key: const ValueKey('doc-edit'),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit details'),
              onPressed: () => _editDetails(ctx, d),
            ),
            IconButton(
              key: const ValueKey('doc-delete'),
              tooltip: 'Delete document',
              icon: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              onPressed: () => _delete(ctx, d),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        DetailTable({
          'Document number': d['document_number'],
          'Detected as': d['detected_document_name'],
          'Issuing country': d['issuance_country'],
          'Insurance provider': d['insurance_provider_name'],
          'Start': d['start_date'] == null ? null : formatStoredDateForUser(d['start_date']),
          'Expiry': d['expiry_date'] == null ? null : formatStoredDateForUser(d['expiry_date']),
          'PWD': d['is_pwd'] == true ? 'Yes' : null,
          'Partner': d['_owner'] ?? d['partner_id'],
          if (_vehicle) 'Vehicle': d['_plate'] ?? d['vehicle_id'],
          'AI verified': d['ai_verified'] == null ? null : (d['ai_verified'] == true ? 'Yes' : 'No'),
          if (documentFace(d) case final f?) ...{
            'Face match': documentFaceText(f),
            'Selfie': documentSelfieText(f),
          },
          'Uploaded': dateText(d['uploaded_at']),
          'Reviewed': dateText(d['reviewed_at']),
        }),
        if (documentNeedsCloserLook(d))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Icon(Icons.report_outlined, color: Theme.of(ctx).colorScheme.error),
              const SizedBox(width: 8),
              const Expanded(child: Text('Needs a closer look: compare the photo with the selfie by eye.')),
            ]),
          ),
        Wrap(spacing: 8, children: [
          if (canEdit && documentFace(d) != null)
            BusyButton.outlined(
              key: const ValueKey('doc-face-again'),
              icon: const Icon(Icons.face_retouching_natural),
              child: const Text('Check again'),
              onPressed: () => _faceAgain(ctx, d),
            ),
          for (final (label, key) in [('View front', 'file_url'), ('View back', 'file_url_back')])
            if ((d[key] as String?)?.startsWith('http') == true)
              OutlinedButton.icon(
                icon: const Icon(Icons.visibility_outlined),
                label: Text(label),
                onPressed: () => openStoredFile(context, d[key] as String),
              ),
        ]),
        // The whole application, line by line (0289).
        if ('${d['partner_id'] ?? ''}'.isNotEmpty &&
            ref.read(pageAccessProvider('admin-partner-edit')) != AccessLevel.none)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('doc-open-review'),
              icon: const Icon(Icons.rule),
              label: const Text('Review the whole application'),
              onPressed: () {
                Navigator.pop(ctx);
                context.push('/admin/m/partner-review?id=${d['partner_id']}');
              },
            ),
          ),
        // Every field printed on it, read and checked (document reading, part 2).
        DocFieldsSection(doc: d),
        if (ai != null) ...[
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('AI verification details'),
            children: [SelectableText(const JsonEncoder.withIndent('  ').convert(ai))],
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: notes,
          enabled: canEdit,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Reviewer notes (shown to the partner)'),
        ),
        const SizedBox(height: 12),
        if (canEdit)
          Row(children: [
            Expanded(
              child: BusyButton.outlined(
                icon: const Icon(Icons.close),
                child: const Text('Reject'),
                onPressed: () => _review(ctx, d, 'Rejected', notes.text),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: BusyButton.filled(
                icon: const Icon(Icons.check),
                child: const Text('Approve'),

                onPressed: () => _review(ctx, d, 'Approved', notes.text),
              ),
            ),
          ]),
      ]),
    );
  }

  /// Compares the document with the person's live selfie again.
  Future<void> _faceAgain(BuildContext sheet, Map<String, dynamic> d) async {
    final r = await ref.read(identityRepositoryProvider).compareDocumentFace(
          _vehicle ? 'vehicle_document' : 'provider_document',
          '${d['id']}',
        );
    if (!sheet.mounted) return;
    ref.invalidate(adminDocsProvider(_table));
    // Not awaited: the button stops spinning while the answer is read.
    unawaited(showNotice(sheet, title: 'Face match', message: documentFaceText(r)));
  }

  Future<void> _editDetails(BuildContext sheet, Map<String, dynamic> d) async {
    String v(String k) => '${d[k] ?? ''}';
    final name = TextEditingController(text: v('doc_name'));
    final number = TextEditingController(text: v('document_number'));
    final insurer = TextEditingController(text: v('insurance_provider_name'));
    final country = TextEditingController(text: v('issuance_country'));
    final start = TextEditingController(text: v('start_date').split('T').first);
    final expiry = TextEditingController(text: v('expiry_date').split('T').first);
    var pwd = d['is_pwd'] == true;
    final patch = await showAppDialog<Map<String, dynamic>>(id: 'admin-documents.edit-details',
      context: sheet,
      builder: (c) => StatefulBuilder(
        builder: (c, set) {
          final startErr = documentDateError(start.text), expiryErr = documentDateError(expiry.text);
          return AlertDialog(
            key: const ValueKey('doc-edit-dialog'),
            title: const Text('Edit document details'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(controller: name, decoration: const InputDecoration(labelText: 'Document name')),
                  TextField(
                    key: const ValueKey('doc-edit-number'),
                    controller: number,
                    decoration: const InputDecoration(labelText: 'Document number'),
                  ),
                  TextField(controller: insurer, decoration: const InputDecoration(labelText: 'Insurance provider')),
                  TextField(controller: country, decoration: const InputDecoration(labelText: 'Issuing country')),
                  // Facts from the document as printed: no limits, so an
                  // expired one can be recorded as it is.
                  DateBoxesField(
                    key: const ValueKey('doc-edit-start'),
                    label: 'Start date',
                    controller: start,
                    onChanged: (_) => set(() {}),
                  ),
                  DateBoxesField(
                    key: const ValueKey('doc-edit-expiry'),
                    label: 'Expiry date',
                    controller: expiry,
                    onChanged: (_) => set(() {}),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('PWD'),
                    value: pwd,
                    onChanged: (x) => set(() => pwd = x),
                  ),
                ]),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
              FilledButton(
                key: const ValueKey('doc-edit-save'),
                onPressed: startErr != null || expiryErr != null
                    ? null
                    : () => Navigator.pop(
                          c,
                          documentEditPatch(
                            name: name.text,
                            number: number.text,
                            insurer: insurer.text,
                            country: country.text,
                            start: start.text,
                            expiry: expiry.text,
                            pwd: pwd,
                          ),
                        ),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (patch == null || !sheet.mounted) return;
    final ok = await runAdminAction(
      sheet,
      () => ref.read(adminRepositoryProvider).updateDocument(_table, d['id'] as String, patch),
      success: 'Document details saved',
    );
    if (ok) {
      ref.invalidate(adminDocsProvider(_table));
      if (sheet.mounted) Navigator.pop(sheet);
    }
  }

  Future<void> _delete(BuildContext sheet, Map<String, dynamic> d) async {
    final whose = [d['_owner'], d['_plate']].whereType<Object>().join(' · ');
    if (!await confirm(
      sheet,
      'Delete this document?',
      '${d['doc_name'] ?? 'The document'}${whose.isEmpty ? '' : ' ($whose)'} is removed. '
          'The partner will need to upload it again. This cannot be undone.',
      ok: 'Delete',
    )) {
      return;
    }
    if (!sheet.mounted) return;
    final ok = await runAdminAction(
      sheet,
      () => ref.read(adminRepositoryProvider).deleteDocument(_table, d['id'] as String),
      success: 'Document deleted',
    );
    if (ok) {
      ref.invalidate(adminDocsProvider(_table));
      if (sheet.mounted) Navigator.pop(sheet);
    }
  }

  Future<void> _review(BuildContext ctx, Map<String, dynamic> d, String status, String notes) async {
    // A rejection says why, from the list (0281); the partner sees it.
    if (status == 'Rejected') {
      final choice = await pickRejectReason(ctx, note: notes);
      if (choice == null || !ctx.mounted) return;
      notes = rejectNotes(choice.reason, choice.note);
    }
    final ok = await runAdminAction(
      ctx,
      () => ref.read(adminRepositoryProvider).reviewDocument(
            _table,
            d['id'] as String,
            status,
            notes.trim().isEmpty ? null : notes.trim(),
          ),
      success: 'Document ${status.toLowerCase()}',
    );
    if (ok) {
      ref.invalidate(adminDocsProvider(_table));
      if (ctx.mounted) Navigator.pop(ctx);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      title: 'Documents',
      module: 'documents',
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'partner', label: Text('Partner documents'), icon: Icon(Icons.badge_outlined)),
                const ButtonSegment(
                  value: 'vehicle',
                  label: Text('Vehicle documents'),
                  icon: Icon(Icons.directions_car_outlined),
                ),
                ButtonSegment(
                  value: 'signin',
                  // Waiting uploads, and going-online selfies that need a
                  // closer look (0290).
                  label: Text(switch ((ref.watch(signInChecksWaitingProvider).value ?? 0) +
                      (ref.watch(onlineSelfieCloserCountProvider).value ?? 0)) {
                    final n when n > 0 => 'Sign-in checks ($n)',
                    _ => 'Sign-in checks',
                  }),
                  icon: const Icon(Icons.verified_user_outlined),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (v) => setState(() => _tab = v.first),
            ),
          ),
        ),
        if (_tab == 'signin') const Expanded(child: SignInChecksReview()) else ...[
        FilterBar(
          filters: _docFilters,
          selected: _filter,
          onSelected: (f) => setState(() => _filter = f),
          onSearch: (q) => setState(() => _query = q),
          hint: _vehicle ? 'Search document, partner or plate…' : 'Search document, number or partner…',
        ),
        Expanded(
          child: AsyncView(
            value: ref.watch(adminDocsProvider(_table)),
            onRetry: () => ref.invalidate(adminDocsProvider(_table)),
            data: (docs) {
              final q = _query.trim().toLowerCase();
              final list = docs.where((d) {
                if (_filter == 'closer') return documentNeedsCloserLook(d) && documentMatches(d, q);
                if (_filter != 'all' && documentDisplayStatus(d) != _filter) return false;
                return documentMatches(d, q);
              }).toList();
              // A low face match first, whatever the filter (stable: newest
              // first within each).
              final ordered = [
                ...list.where(documentNeedsCloserLook),
                ...list.where((d) => !documentNeedsCloserLook(d)),
              ];
              if (list.isEmpty) return const EmptyState(icon: Icons.task_alt, title: 'Nothing to show');
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: ordered.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final d = ordered[i];
                  final face = documentFace(d);
                  final closer = documentNeedsCloserLook(d);
                  return ListTile(
                    key: ValueKey('doc-row-${d['id']}'),
                    leading: Icon(
                      closer ? Icons.report_outlined : Icons.description_outlined,
                      color: closer ? Theme.of(context).colorScheme.error : null,
                    ),
                    title: Text((d['doc_name'] as String?) ?? 'Document'),
                    subtitle: Text([
                      d['_owner'],
                      if (_vehicle) d['_plate'],
                      d['document_number'],
                      if (d['expiry_date'] != null) 'expires ${formatStoredDateForUser(d['expiry_date'])}',
                      dateText(d['uploaded_at']),
                    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ') +
                        (face == null ? '' : '\nFace: ${documentFaceText(face)}')),
                    isThreeLine: face != null,
                    trailing: StatusChip(documentDisplayStatus(d)),
                    onTap: () => _open(d),
                  );
                },
              );
            },
          ),
        ),
        ],
      ]),
    );
  }
}
