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
    required this.canCredit,
    required this.canEditProfile,
    required this.canVerifyId,
    this.canManageVehicle = false,
    required this.scope,
    required this.docTypes,
  });

  final bool canApprove;
  final bool canUpload;
  final bool canDelete;
  final bool deleteHard;

  /// Whether the approver may add wallet credit to a covered member, paid
  /// from their own GET.wallet (migration 0359). A separate, deliberate grant.
  final bool canCredit;

  /// Whether the approver may edit a covered member's profile fields
  /// (name, email, ID no., nationality, address, status, services) — 0360.
  final bool canEditProfile;

  /// The higher grant to mark a member's ID *verified* (0360); without it the
  /// approver can edit the ID number but not flip verified.
  final bool canVerifyId;

  /// Whether the approver may approve/revoke a driver's access to a covered
  /// member's vehicle (migration 0366). Off by default.
  final bool canManageVehicle;
  final String scope;
  final List<String> docTypes;

  static ApproverGrant fromJson(Map<String, dynamic> j) => ApproverGrant(
        canApprove: j['can_approve'] == true,
        canUpload: j['can_upload'] == true,
        canDelete: j['can_delete'] == true,
        deleteHard: j['delete_hard'] == true,
        canCredit: j['can_credit'] == true,
        canEditProfile: j['can_edit_profile'] == true,
        canVerifyId: j['can_verify_id'] == true,
        canManageVehicle: j['can_manage_vehicle'] == true,
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
    this.status,
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

  /// The review status — 'Pending Review', 'Approved', 'Rejected', 'Expired'.
  /// The inbox only ever lists pending documents; a member's Documents tab
  /// (My Team, 0357) lists every status, and the viewer offers approve/reject
  /// only while it is still pending.
  final String? status;

  bool get isPending => (status ?? 'Pending Review') == 'Pending Review';

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
        status: (j['status'] as String?)?.trim(),
        plate: _plate(j['plate']),
        documentNumber: (j['document_number'] as String?)?.trim(),
        startDate: _date(j['start_date']),
        expiryDate: _date(j['expiry_date']),
        requiresNumber: j['requires_number'] == true,
        requiresStart: j['requires_start'] == true,
        requiresExpiry: j['requires_expiry'] == true,
      );
}

/// One person in the approver's "My Team" list — someone their grant reaches
/// (migration 0357). The card fields only; the member screen loads the rest.
class TeamMember {
  const TeamMember({
    required this.id,
    this.displayId,
    required this.name,
    this.phone,
    this.avatarUrl,
    this.status,
    this.idVerified,
    this.ic,
    this.nationality,
    this.plate,
    this.vehicleLabel,
    this.pendingDocs = 0,
  });

  final String id;
  final String? displayId;
  final String name;
  final String? phone;
  final String? avatarUrl;

  /// The account's lifecycle status (`approved`, `blocked`, …) and ID-check
  /// state, as stored; shown as a chip.
  final String? status;
  final String? idVerified;

  /// The national ID / passport number and nationality, for the card.
  final String? ic;
  final String? nationality;

  /// A representative vehicle (an approved one first): its plate and
  /// "Make Model" label; null when the person has no vehicle on file.
  final String? plate;
  final String? vehicleLabel;

  /// How many of this person's documents are waiting for review right now.
  final int pendingDocs;

  static String? _s(Object? v) {
    final t = (v as String?)?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  static TeamMember fromJson(Map<String, dynamic> j) => TeamMember(
        id: j['owner_id'] as String,
        displayId: _s(j['display_id']),
        name: (j['name'] as String?)?.trim().isNotEmpty == true ? (j['name'] as String).trim() : 'User',
        phone: _s(j['phone']),
        avatarUrl: _s(j['avatar_url']),
        status: _s(j['status']),
        idVerified: _s(j['id_verified']),
        ic: _s(j['ic']),
        nationality: _s(j['nationality']),
        plate: _s(j['plate']),
        vehicleLabel: _s(j['vehicle_label']),
        pendingDocs: (j['pending_docs'] as num?)?.toInt() ?? 0,
      );
}

/// One page of covered people plus the cursor to fetch the next page.
class TeamPage {
  const TeamPage({required this.members, required this.hasMore});
  final List<TeamMember> members;
  final bool hasMore;
}

/// A bank or e-wallet from the admin-managed payout list (migration 0361).
class PayoutProvider {
  const PayoutProvider({required this.name, required this.type});
  final String name;
  final String type; // 'bank' | 'ewallet'
}

/// One of a member's vehicles (migration 0364), owned by them or shared to them.
class MemberVehicle {
  const MemberVehicle({
    required this.id,
    this.displayId,
    required this.plate,
    this.make,
    this.model,
    this.year,
    this.color,
    this.status,
    required this.ownerSelf,
    this.ownerName,
    this.ownerIc,
    this.registeredAt,
    this.accessApproval,
    this.accessActive,
  });

  final String id;
  final String? displayId;
  final String plate;
  final String? make;
  final String? model;
  final String? year;
  final String? color;
  final String? status;

  /// True when the member owns it (Registered under this ID); false when they
  /// are only assigned to use it (Allowed to use).
  final bool ownerSelf;
  final String? ownerName;
  final String? ownerIc;
  final String? registeredAt;

  /// For an allowed-to-use vehicle: the assignment's approval and whether it's
  /// active.
  final String? accessApproval;
  final bool? accessActive;

  /// "Perodua Myvi · Silver · 2021" — the parts that are present.
  String get descriptor => [make, model, color, year].where((e) => (e ?? '').trim().isNotEmpty).join(' · ');

  static String? _s(Object? v) {
    final t = (v as String?)?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  static MemberVehicle fromJson(Map<String, dynamic> j) => MemberVehicle(
        id: '${j['id']}',
        displayId: _s(j['display_id']),
        plate: (j['plate'] as String?)?.trim().isNotEmpty == true ? (j['plate'] as String).trim() : '—',
        make: _s(j['make']),
        model: _s(j['model']),
        year: _s(j['year']),
        color: _s(j['color']),
        status: _s(j['status']),
        ownerSelf: j['owner_self'] == true,
        ownerName: _s(j['owner_name']),
        ownerIc: _s(j['owner_ic']),
        registeredAt: _s(j['registered_at']),
        accessApproval: _s(j['access_approval']),
        accessActive: j['access_active'] is bool ? j['access_active'] as bool : null,
      );
}

/// A member's vehicles split into the two lists the Vehicle tab shows.
class MemberVehicles {
  const MemberVehicles({required this.registered, required this.allowed});
  final List<MemberVehicle> registered;
  final List<MemberVehicle> allowed;
}

/// A covered member's driver statistics for a period (migration 0367).
class MemberStats {
  const MemberStats({
    required this.inAppJobs,
    required this.mygigJobs,
    required this.earning,
    this.avgPerKm,
    required this.minutesOnline,
    required this.onlineKm,
    required this.totalKm,
    required this.cancelledByDriver,
    required this.cancelledByUser,
  });
  final int inAppJobs;
  final int mygigJobs;
  final double earning;
  final double? avgPerKm;
  final int minutesOnline;
  final int onlineKm;
  final int totalKm;
  final int cancelledByDriver;
  final int cancelledByUser;

  static int _i(Object? v) => (v as num?)?.round() ?? 0;
  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

  static MemberStats fromJson(Map<String, dynamic> j) => MemberStats(
        inAppJobs: _i(j['in_app_jobs']),
        mygigJobs: _i(j['mygig_jobs']),
        earning: _d(j['earning']),
        avgPerKm: j['avg_per_km'] == null ? null : _d(j['avg_per_km']),
        minutesOnline: _i(j['minutes_online']),
        onlineKm: _i(j['online_km']),
        totalKm: _i(j['total_km']),
        cancelledByDriver: _i(j['cancelled_by_driver']),
        cancelledByUser: _i(j['cancelled_by_user']),
      );
}

/// A driver who can drive a vehicle (migration 0366).
class VehicleDriver {
  const VehicleDriver({
    required this.assignmentId,
    required this.name,
    this.driverNo,
    required this.state, // 'active' | 'pending' | 'revoked'
  });
  final String assignmentId;
  final String name;
  final String? driverNo;
  final String state;
}

/// One of a vehicle's documents, for the Vehicle detail sheet (migration 0366).
class VehicleDoc {
  const VehicleDoc({required this.id, required this.name, this.status, this.expiry, this.provider, this.hasFile = false});
  final String id;
  final String name;
  final String? status;
  final String? expiry;
  final String? provider;
  final bool hasFile;
}

/// The Vehicle detail sheet payload (migration 0366).
class VehicleDetail {
  const VehicleDetail({
    required this.id,
    required this.plate,
    this.descriptor,
    this.status,
    this.ownerName,
    this.canManage = false,
    this.drivers = const [],
    this.documents = const [],
  });
  final String id;
  final String plate;
  final String? descriptor;
  final String? status;
  final String? ownerName;
  final bool canManage;
  final List<VehicleDriver> drivers;
  final List<VehicleDoc> documents;

  static String? _s(Object? v) {
    final t = '${v ?? ''}'.trim();
    return t.isEmpty || t == 'null' ? null : t;
  }

  static VehicleDetail fromJson(Map<String, dynamic> j) {
    final parts = [j['make'], j['model'], j['color'], j['year']]
        .map((e) => '${e ?? ''}'.trim())
        .where((e) => e.isNotEmpty)
        .join(' · ');
    return VehicleDetail(
      id: '${j['id']}',
      plate: _s(j['plate']) ?? '—',
      descriptor: parts.isEmpty ? null : parts,
      status: _s(j['status']),
      ownerName: _s(j['owner_name']),
      canManage: j['can_manage'] == true,
      drivers: [
        for (final e in (j['drivers'] as List? ?? const []))
          VehicleDriver(
            assignmentId: '${(e as Map)['assignment_id']}',
            name: '${e['name'] ?? 'User'}',
            driverNo: _s(e['driver_no']),
            state: '${e['state'] ?? 'active'}',
          ),
      ],
      documents: [
        for (final e in (j['documents'] as List? ?? const []))
          VehicleDoc(
            id: '${(e as Map)['id']}',
            name: '${e['doc_name'] ?? 'Document'}',
            status: _s(e['status']),
            expiry: _s(e['expiry_date']),
            provider: _s(e['provider']),
            hasFile: e['has_file'] == true,
          ),
      ],
    );
  }
}

/// One row of the read-from-document vs stored table (migration 0365).
class DocReadRow {
  const DocReadRow({required this.field, this.read, this.stored, required this.match});
  final String field;
  final String? read;
  final String? stored;
  final bool match;
}

/// The AI verification summary for a document (migration 0365).
class DocAi {
  const DocAi({this.genuine, this.matches, this.detectedTitle, this.confidence, this.country});
  final bool? genuine;
  final bool? matches;
  final String? detectedTitle;
  final String? confidence; // kept as read (e.g. "0.96")
  final String? country;
}

/// The face-check summary for a document (migration 0365).
class DocFace {
  const DocFace({this.ok, this.score, this.label, this.reason});
  final bool? ok;
  final double? score;
  final String? label;
  final String? reason;
}

/// The rich detail for one document (migration 0365): everything the document
/// detail sheet shows beyond the image and captured fields.
class DocDetail {
  const DocDetail({
    this.status,
    this.documentNumber,
    this.startDate,
    this.expiryDate,
    this.reviewerNotes,
    this.uploadedAt,
    this.reviewedAt,
    this.changedBy,
    this.ai,
    this.read = const [],
    this.face,
  });

  final String? status;
  final String? documentNumber;
  final String? startDate;
  final String? expiryDate;
  final String? reviewerNotes;
  final String? uploadedAt;
  final String? reviewedAt;
  final String? changedBy;
  final DocAi? ai;
  final List<DocReadRow> read;
  final DocFace? face;

  static String? _s(Object? v) {
    final t = '${v ?? ''}'.trim();
    return t.isEmpty || t == 'null' ? null : t;
  }

  static DocDetail fromJson(Map<String, dynamic> j) {
    final aiRaw = j['ai'];
    final faceRaw = j['face'];
    return DocDetail(
      status: _s(j['status']),
      documentNumber: _s(j['document_number']),
      startDate: _s(j['start_date']),
      expiryDate: _s(j['expiry_date']),
      reviewerNotes: _s(j['reviewer_notes']),
      uploadedAt: _s(j['uploaded_at']),
      reviewedAt: _s(j['reviewed_at']),
      changedBy: _s(j['changed_by']),
      ai: aiRaw is Map
          ? DocAi(
              genuine: aiRaw['genuine'] is bool ? aiRaw['genuine'] as bool : null,
              matches: aiRaw['matches'] is bool ? aiRaw['matches'] as bool : null,
              detectedTitle: _s(aiRaw['detected_title']),
              confidence: _s(aiRaw['confidence']),
              country: _s(aiRaw['country']),
            )
          : null,
      read: [
        for (final e in (j['read'] as List? ?? const []))
          DocReadRow(
            field: '${(e as Map)['field'] ?? ''}',
            read: _s(e['read']),
            stored: _s(e['stored']),
            match: e['match'] == true,
          ),
      ],
      face: faceRaw is Map
          ? DocFace(
              ok: faceRaw['ok'] is bool ? faceRaw['ok'] as bool : null,
              score: (faceRaw['score'] as num?)?.toDouble(),
              label: _s(faceRaw['label']),
              reason: _s(faceRaw['reason']),
            )
          : null,
    );
  }
}

class ApproverInboxRepository {
  ApproverInboxRepository(this._db);
  final SupabaseClient _db;

  /// Default page size — the list shows a few, then loads more on scroll.
  static const int teamPageSize = 12;

  /// One keyset-paginated, searchable page of the people this approver covers
  /// (migration 0357). Pass [query] to search name / phone / plate / ID, and
  /// the last member of the previous page as [after] to get the next one.
  Future<TeamPage> coveredPartners({String? query, TeamMember? after, int limit = teamPageSize}) async {
    final rows = await _db.rpc('approver_covered_partners', params: {
      'p_query': (query ?? '').trim().isEmpty ? null : query!.trim(),
      'p_after_name': after?.name,
      'p_after_id': after?.id,
      'p_limit': limit,
    }) as List;
    final members = [for (final r in rows) TeamMember.fromJson(Map<String, dynamic>.from(r as Map))];
    return TeamPage(members: members, hasMore: members.length >= limit);
  }

  /// Every document of one covered person, across all three stores and every
  /// status (migration 0357). The server re-checks the scope.
  Future<List<ApproverDoc>> ownerDocuments(String ownerId) async => [
        for (final r in (await _db.rpc('approver_owner_documents', params: {'p_owner': ownerId}) as List))
          ApproverDoc.fromJson(Map<String, dynamic>.from(r as Map)),
      ];

  /// One covered member's GET.wallet balance, for display (migration 0359);
  /// null when the member is out of the approver's scope.
  Future<double?> memberWallet(String memberId) async {
    final r = await _db.rpc('approver_member_wallet', params: {'p_member': memberId});
    return r == null ? null : (r as num).toDouble();
  }

  /// Add [amount] credit to [memberId]'s GET.wallet, paid from the approver's
  /// own GET.wallet and confirmed with [pin] (migration 0359). [requestId]
  /// makes a retried/duplicated submit idempotent (no second charge).
  Future<void> addCredit({
    required String memberId,
    required double amount,
    required String pin,
    required String requestId,
  }) async {
    await _db.rpc('approver_add_credit', params: {
      'p_member': memberId,
      'p_amount': amount,
      'p_pin': pin,
      'p_request_id': requestId,
    });
  }

  /// A covered member's current editable fields, to pre-fill the edit form
  /// (migration 0360); null when out of scope.
  Future<Map<String, dynamic>?> memberDetail(String memberId) async {
    final r = await _db.rpc('approver_member_detail', params: {'p_member': memberId});
    return r == null ? null : Map<String, dynamic>.from(r as Map);
  }

  /// A covered member's driver statistics for a period (migration 0367).
  /// [period] is 'month' | 'last_month' | 'all'. Null when out of scope.
  Future<MemberStats?> memberStats(String memberId, String period) async {
    final r = await _db.rpc('approver_member_stats', params: {'p_member': memberId, 'p_period': period});
    return r == null ? null : MemberStats.fromJson(Map<String, dynamic>.from(r as Map));
  }

  /// The Vehicle detail sheet for one vehicle (migration 0366): who can drive
  /// it and its documents. Null when out of scope.
  Future<VehicleDetail?> vehicleDetail(String vehicleId) async {
    final r = await _db.rpc('approver_vehicle_detail', params: {'p_vehicle': vehicleId});
    return r == null ? null : VehicleDetail.fromJson(Map<String, dynamic>.from(r as Map));
  }

  /// Approve or revoke a driver's access to a covered member's vehicle
  /// (migration 0366). [action] is 'approve' or 'revoke'; needs can_manage_vehicle.
  Future<void> setVehicleAccess(String assignmentId, String action) async {
    await _db.rpc('approver_set_vehicle_access', params: {'p_assignment': assignmentId, 'p_action': action});
  }

  /// The rich detail for one of a covered member's documents (migration 0365):
  /// read-vs-stored, AI verification, face check and status/history. Null when
  /// out of scope.
  Future<DocDetail?> documentDetail(String source, String id) async {
    final r = await _db.rpc('approver_document_detail', params: {'p_source': source, 'p_id': id});
    return r == null ? null : DocDetail.fromJson(Map<String, dynamic>.from(r as Map));
  }

  /// A covered member's vehicles (migration 0364): the ones registered under
  /// them and the ones they're assigned to use. Null when out of scope.
  Future<MemberVehicles?> memberVehicles(String memberId) async {
    final r = await _db.rpc('approver_member_vehicles', params: {'p_member': memberId});
    if (r == null) return null;
    final m = Map<String, dynamic>.from(r as Map);
    List<MemberVehicle> list(Object? raw) => [
          for (final e in (raw as List? ?? const []))
            MemberVehicle.fromJson(Map<String, dynamic>.from(e as Map)),
        ];
    return MemberVehicles(registered: list(m['registered']), allowed: list(m['allowed']));
  }

  /// Edit a covered member's profile (migration 0360). [fields] carries only
  /// the keys to change: name / email / ic / nationality / address / status /
  /// partner_types (needs can_edit_profile) and id_verified (needs
  /// can_verify_id). The server validates and re-checks the scope.
  Future<void> editProfile(String memberId, Map<String, dynamic> fields) async {
    await _db.rpc('approver_edit_profile', params: {'p_member': memberId, 'p_fields': fields});
  }

  /// Set a covered member's payout account (migration 0361), bank or e-wallet.
  Future<void> setMemberPayout(String memberId,
      {required String provider, required String account, required String holder, required String type}) async {
    await _db.rpc('approver_set_member_payout', params: {
      'p_member': memberId,
      'p_provider': provider,
      'p_account': account,
      'p_holder': holder,
      'p_type': type,
    });
  }

  /// The admin-managed bank / e-wallet list (migration 0361).
  Future<List<PayoutProvider>> payoutProviders() async => [
        for (final r in (await _db.rpc('payout_providers') as List))
          PayoutProvider(
            name: (r as Map)['name'] as String? ?? '',
            type: (r['type'] as String?) == 'ewallet' ? 'ewallet' : 'bank',
          ),
      ];

  /// Propose a new mobile number for a covered member (migration 0362). The
  /// approver cannot change the number silently — this only files a pending
  /// proposal and pushes the member; the MEMBER confirms it through the ordinary
  /// change-number flow. [phone] must be full international format (`+60…`).
  Future<void> proposeMemberPhone(String memberId, String phone) async {
    await _db.rpc('approver_propose_member_phone', params: {'p_member': memberId, 'p_phone': phone});
  }

  /// The caller's own pending phone proposal (migration 0362), or null when
  /// there is none. Shape: {id, proposed_phone, by_name, created_at}.
  Future<Map<String, dynamic>?> myPhoneProposal() async {
    final r = await _db.rpc('member_phone_proposal');
    if (r == null) return null;
    return Map<String, dynamic>.from(r as Map);
  }

  /// The caller declines their own pending phone proposal (migration 0362).
  Future<void> cancelMyPhoneProposal(String id) async {
    await _db.rpc('member_cancel_phone_proposal', params: {'p_id': id});
  }

  /// The caller marks their own pending phone proposal applied (migration 0362),
  /// once their confirmed number already matches the proposed one.
  Future<void> applyMyPhoneProposal(String id) async {
    await _db.rpc('member_apply_phone_proposal', params: {'p_id': id});
  }

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

/// Every document of one covered team member (My Team → member → Documents,
/// migration 0357).
final approverOwnerDocumentsProvider =
    FutureProvider.autoDispose.family<List<ApproverDoc>, String>((ref, ownerId) async {
  if (ref.watch(currentUserIdProvider) == null) return const <ApproverDoc>[];
  return ref.watch(approverInboxRepositoryProvider).ownerDocuments(ownerId);
});

/// One covered member's GET.wallet balance (My Team member screen, 0359);
/// null when out of scope or unavailable.
final approverMemberWalletProvider =
    FutureProvider.autoDispose.family<double?, String>((ref, memberId) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  return ref.watch(approverInboxRepositoryProvider).memberWallet(memberId);
});

/// One covered member's editable profile fields (My Team → Edit profile, 0360).
final approverMemberDetailProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>?, String>((ref, memberId) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  return ref.watch(approverInboxRepositoryProvider).memberDetail(memberId);
});

/// One covered member's vehicles (My Team → Vehicle tab, 0364).
final approverMemberVehiclesProvider =
    FutureProvider.autoDispose.family<MemberVehicles?, String>((ref, memberId) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  return ref.watch(approverInboxRepositoryProvider).memberVehicles(memberId);
});

/// A covered member's driver statistics for a period (My Team → Statistics,
/// 0367), keyed by (member, period).
final approverMemberStatsProvider =
    FutureProvider.autoDispose.family<MemberStats?, ({String member, String period})>((ref, key) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  return ref.watch(approverInboxRepositoryProvider).memberStats(key.member, key.period);
});

/// The Vehicle detail sheet for one vehicle (My Team, 0366).
final approverVehicleDetailProvider =
    FutureProvider.autoDispose.family<VehicleDetail?, String>((ref, vehicleId) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  return ref.watch(approverInboxRepositoryProvider).vehicleDetail(vehicleId);
});

/// The rich detail for one document (My Team → document sheet, 0365), keyed by
/// (source, id). Null (no extra detail) on error or a legacy database.
final approverDocumentDetailProvider =
    FutureProvider.autoDispose.family<DocDetail?, ({String source, String id})>((ref, key) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  try {
    return await ref.watch(approverInboxRepositoryProvider).documentDetail(key.source, key.id);
  } catch (_) {
    return null;
  }
});

/// The admin-managed bank / e-wallet payout list (My Team → Payout, 0361).
final payoutProvidersProvider = FutureProvider.autoDispose<List<PayoutProvider>>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const <PayoutProvider>[];
  return ref.watch(approverInboxRepositoryProvider).payoutProviders();
});

/// The signed-in member's own pending phone proposal (migration 0362), or null
/// when there is none. Drives the "Confirm your new number" banner. The RPC
/// error is swallowed (null) on a legacy session or where 0362 is not applied.
final myPhoneProposalProvider = FutureProvider.autoDispose<Map<String, dynamic>?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  try {
    return await ref.watch(approverInboxRepositoryProvider).myPhoneProposal();
  } catch (_) {
    return null;
  }
});
