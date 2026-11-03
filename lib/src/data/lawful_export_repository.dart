// Lawful-request export (migration 0338): reading the data get.ride already
// holds about one user to answer a valid authority request, and the register
// of past requests. Full admins only — the server enforces it; this repository
// is only the two RPC wrappers plus a bounded subject-lookup for the picker.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';
import 'live_tables.dart';

/// One account the admin can pick as the subject of an export.
class LawfulSubject {
  const LawfulSubject({required this.id, this.name, this.phone, this.displayId});

  factory LawfulSubject.fromRow(Map<String, dynamic> r) => LawfulSubject(
    id: '${r['id']}',
    name: (r['name'] as String?)?.trim().isNotEmpty == true ? '${r['name']}' : null,
    phone: (r['phone'] as String?)?.trim().isNotEmpty == true ? '${r['phone']}' : null,
    displayId: (r['display_id'] as String?)?.trim().isNotEmpty == true ? '${r['display_id']}' : null,
  );

  final String id;
  final String? name;
  final String? phone;
  final String? displayId;

  /// A one-line label for the picker.
  String get label {
    final parts = <String>[
      name ?? 'Unnamed',
      if (phone != null) phone!,
      if (displayId != null) displayId!,
    ];
    return parts.join(' · ');
  }
}

/// One row of the register of lawful requests received.
class LawfulRequest {
  LawfulRequest(this.data);
  final Map<String, dynamic> data;

  String get id => '${data['id']}';
  String? get subjectId => data['subject_user_id'] as String?;
  String? get subjectName => (data['subject_name'] as String?)?.trim();
  String? get subjectDisplayId => (data['subject_display_id'] as String?)?.trim();
  String get agency => '${data['agency'] ?? ''}';
  String? get officer => (data['officer'] as String?)?.trim();
  String get reference => '${data['reference'] ?? ''}';
  String get legalBasis => '${data['legal_basis'] ?? ''}';
  DateTime? get requestedAt => DateTime.tryParse('${data['requested_at'] ?? ''}')?.toLocal();
  DateTime? get exportedAt => DateTime.tryParse('${data['exported_at'] ?? ''}')?.toLocal();
}

class LawfulExportRepository {
  LawfulExportRepository(this._db);
  final SupabaseClient _db;

  /// Generates the one-document export for [subjectId] and records the request.
  /// Throws on refusal (not a full admin, blank required field, unknown
  /// subject); the message is the server's.
  Future<Map<String, dynamic>> export({
    required String subjectId,
    required String agency,
    String? officer,
    required String reference,
    required String legalBasis,
    String? notes,
  }) async {
    final r = await _db.rpc(
      'admin_lawful_export',
      params: {
        'p_subject': subjectId,
        'p_agency': agency,
        'p_officer': officer,
        'p_reference': reference,
        'p_legal_basis': legalBasis,
        'p_notes': notes,
      },
    );
    return r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{};
  }

  /// The register of past requests, newest first (the audit trail).
  Future<List<LawfulRequest>> requests() async => [
    for (final r in (await _db.rpc('admin_lawful_requests') as List? ?? const []))
      LawfulRequest(Map<String, dynamic>.from(r as Map)),
  ];

  /// A bounded list of accounts to pick a subject from. The picker searches
  /// this list client-side; an admit acting on a warrant can also match by the
  /// phone or account code printed on it.
  Future<List<LawfulSubject>> candidates({String? search}) async {
    var q = _db.from('profiles').select('id, name, phone, display_id');
    final s = search?.trim() ?? '';
    if (s.isNotEmpty) {
      final like = '%${s.replaceAll(RegExp(r'[%,()]'), '')}%';
      q = q.or('name.ilike.$like,phone.ilike.$like,display_id.ilike.$like');
    }
    final rows = await q.order('created_at', ascending: false).limit(500);
    return [for (final r in rows) LawfulSubject.fromRow(Map<String, dynamic>.from(r as Map))];
  }
}

final lawfulExportRepositoryProvider =
    Provider((ref) => LawfulExportRepository(ref.watch(supabaseProvider)));

/// Recent accounts for the subject picker; empty when they can't be read.
final lawfulExportCandidatesProvider =
    FutureProvider.autoDispose<List<LawfulSubject>>((ref) async {
  ref.watchAdminLive('profiles');
  try {
    return await ref.watch(lawfulExportRepositoryProvider).candidates();
  } catch (_) {
    return const [];
  }
});

/// The register of past lawful requests; empty when it can't be read.
final lawfulRequestsProvider = FutureProvider.autoDispose<List<LawfulRequest>>((ref) async {
  ref.watchAdminLive('profiles');
  try {
    return await ref.watch(lawfulExportRepositoryProvider).requests();
  } catch (_) {
    return const [];
  }
});
