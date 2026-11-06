// Approver (migrations 0349/0350/0351/0353): the app side — the caller's own
// grant (approver_self), their scoped pending-documents inbox
// (approver_pending_documents), the approve/reject and delete actions, and the
// replace-image upload (via the approver-upload edge function). The server
// decides the scope and what is in it; this only asks. The admin side is in
// approvers_repository.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';

/// What the caller may do as an approver; null when they are not one.
class ApproverGrant {
  const ApproverGrant({
    required this.canApprove,
    required this.canUpload,
    required this.canDelete,
    required this.deleteHard,
    required this.scope,
    required this.docTypes,
  });

  final bool canApprove;
  final bool canUpload;
  final bool canDelete;
  final bool deleteHard;
  final String scope;
  final List<String> docTypes;

  static ApproverGrant fromJson(Map<String, dynamic> j) => ApproverGrant(
        canApprove: j['can_approve'] == true,
        canUpload: j['can_upload'] == true,
        canDelete: j['can_delete'] == true,
        deleteHard: j['delete_hard'] == true,
        scope: (j['scope'] as String?) ?? 'referral',
        docTypes: [for (final t in (j['doc_types'] as List? ?? const [])) t as String],
      );
}

/// One pending document the approver may review, from any of the three stores.
class ApproverDoc {
  const ApproverDoc({
    required this.source,
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.ownerPhone,
    required this.docKey,
    required this.docLabel,
    required this.fileUrl,
    required this.fileUrlBack,
    this.plate,
    this.documentNumber,
    this.startDate,
    this.expiryDate,
    this.requiresNumber = false,
    this.requiresStart = false,
    this.requiresExpiry = false,
  });

  /// 'partner' (registration), 'vehicle' (documents & permits) or 'identity'
  /// (user ID / selfie).
  final String source;
  final String id;
  final String ownerId;
  final String ownerName;
  final String? ownerPhone;
  final String docKey;
  final String docLabel;
  final String? fileUrl;
  final String? fileUrlBack;

  /// The vehicle's plate number, for 'vehicle' documents (migration 0356);
  /// null for other sources or when the vehicle has none.
  final String? plate;

  /// The fields the owner captured at upload, shown to the approver. The
  /// dates are stored `yyyy-mm-dd`. Each `requires*` says the document type
  /// asks for that field (so it is shown, and editable with can_upload).
  final String? documentNumber;
  final String? startDate;
  final String? expiryDate;
  final bool requiresNumber;
  final bool requiresStart;
  final bool requiresExpiry;

  /// Whether this document type captures any field an approver can correct.
  /// identity is never editable here (the server refuses it).
  bool get hasCapturedFields =>
      source != 'identity' && (requiresNumber || requiresStart || requiresExpiry);

  static String? _plate(Object? v) {
    final t = (v as String?)?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  static String? _date(Object? v) {
    final s = (v as String?)?.trim();
    if (s == null || s.isEmpty) return null;
    // The RPC returns a full date/timestamp; keep the yyyy-mm-dd the app uses.
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  static ApproverDoc fromJson(Map<String, dynamic> j) => ApproverDoc(
        source: j['source'] as String,
        id: j['doc_pk'] as String,
        ownerId: j['owner_id'] as String,
        ownerName: (j['owner_name'] as String?) ?? 'User',
        ownerPhone: j['owner_phone'] as String?,
        docKey: (j['doc_key'] as String?) ?? '',
        docLabel: (j['doc_label'] as String?) ?? 'Document',
        fileUrl: j['file_url'] as String?,
        fileUrlBack: j['file_url_back'] as String?,
        plate: _plate(j['plate']),
        documentNumber: (j['document_number'] as String?)?.trim(),
        startDate: _date(j['start_date']),
        expiryDate: _date(j['expiry_date']),
        requiresNumber: j['requires_number'] == true,
        requiresStart: j['requires_start'] == true,
        requiresExpiry: j['requires_expiry'] == true,
      );
}

class ApproverInboxRepository {
  ApproverInboxRepository(this._db);
  final SupabaseClient _db;

  /// The caller's own grant, or null when they are not an active approver.
  Future<ApproverGrant?> self() async {
    final r = await _db.rpc('approver_self');
    if (r == null) return null;
    return ApproverGrant.fromJson(Map<String, dynamic>.from(r as Map));
  }

  /// Every pending document in the caller's scope.
  Future<List<ApproverDoc>> pending() async => [
        for (final r in (await _db.rpc('approver_pending_documents') as List))
          ApproverDoc.fromJson(Map<String, dynamic>.from(r as Map)),
      ];

  /// Approve or reject [doc]. [action] is 'approve' or 'reject'; a reject needs
  /// a [note]. The server re-checks the scope and permission before writing.
  Future<void> review(ApproverDoc doc, String action, {String? note}) async {
    await _db.rpc('approver_review_document', params: {
      'p_source': doc.source,
      'p_id': doc.id,
      'p_action': action,
      'p_note': note,
    });
  }

  /// Delete [doc]: a soft "send back for re-upload", or a permanent removal
  /// when the grant is delete_hard. The server decides soft vs hard and
  /// re-checks the scope and permission before writing.
  Future<void> remove(ApproverDoc doc, {String? note}) async {
    await _db.rpc('approver_delete_document', params: {
      'p_source': doc.source,
      'p_id': doc.id,
      'p_note': note,
    });
  }

  /// Correct the fields [doc]'s type captures (document number, start and
  /// expiry date). Only the fields the type requires are written; the server
  /// (with can_upload) re-checks the scope, refuses a past expiry, and leaves
  /// the image and the Pending Review status alone. Dates are `yyyy-mm-dd`.
  Future<void> editFields(ApproverDoc doc, {String? documentNumber, String? startDate, String? expiryDate}) async {
    await _db.rpc('approver_edit_document', params: {
      'p_source': doc.source,
      'p_id': doc.id,
      'p_document_number': documentNumber,
      'p_start': startDate,
      'p_expiry': expiryDate,
    });
  }

  /// Replace [doc]'s image with [bytes] (via the approver-upload edge
  /// function, which authorises and does the privileged storage write), then
  /// the document reopens for review. Throws on a non-2xx response.
  Future<void> replaceImage(ApproverDoc doc, {required Uint8List bytes, required String contentType}) async {
    await _db.functions.invoke('approver-upload', body: {
      'source': doc.source,
      'id': doc.id,
      'contentType': contentType,
      'data': base64Encode(bytes),
    });
  }
}

final approverInboxRepositoryProvider = Provider((ref) => ApproverInboxRepository(ref.watch(supabaseProvider)));

/// The caller's grant. Null (not an approver) on a legacy local-PIN session or
/// where migration 0349 is not applied yet — the RPC error is swallowed so the
/// menu simply hides the row.
final approverSelfProvider = FutureProvider.autoDispose<ApproverGrant?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  try {
    return await ref.watch(approverInboxRepositoryProvider).self();
  } catch (_) {
    return null;
  }
});

/// Whether the caller is an active approver (drives the side-menu row).
final isApproverProvider = Provider.autoDispose<bool>((ref) => ref.watch(approverSelfProvider).value != null);

/// The caller's pending-documents inbox.
final approverPendingProvider = FutureProvider.autoDispose<List<ApproverDoc>>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const <ApproverDoc>[];
  return ref.watch(approverInboxRepositoryProvider).pending();
});
