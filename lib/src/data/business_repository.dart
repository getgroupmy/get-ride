// Business accounts (migration 0313): applying with the SSM document, the
// member's accounts and the "Business: <company>" payment, the company's
// members, rules, approvals and invoices (through the server's functions),
// and Admin › People › Business accounts (the tables admins read, the
// defaults per region and the admin functions).
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/screens/people/people_logic.dart' show contentTypeFor, docFilePath, guessExt;
import '../core/business_accounts.dart';
import '../providers.dart';
import 'doc_photos.dart';

/// An account as Admin › People › Business accounts lists it.
class AdminBusinessAccount {
  const AdminBusinessAccount(this.row, {this.members = 0});

  final Map<String, dynamic> row;
  final int members;

  String get id => '${row['id']}';
  String get name => '${row['name'] ?? ''}';
  String get regNo => '${row['reg_no'] ?? ''}';
  String get status => '${row['status'] ?? ''}';
  String? get statusNote => row['status_note'] as String?;
  String get country => '${row['country'] ?? ''}';
  String get state => '${row['state'] ?? ''}';
  String get city => '${row['city'] ?? ''}';
  String? get address => row['address'] as String?;
  String? get companyType => row['company_type'] as String?;
  String? get documentUrl => row['document_url'] as String?;
  double get walletBalance => (row['wallet_balance'] as num?)?.toDouble() ?? 0;
  DateTime? get createdAt => DateTime.tryParse('${row['created_at']}')?.toLocal();
  String? get applicant => (row['profiles'] is Map ? (row['profiles'] as Map)['name'] : null) as String?;
  String? get applicantPhone => (row['profiles'] is Map ? (row['profiles'] as Map)['phone'] : null) as String?;

  /// The account's own overrides (null: follows the rules).
  BusinessValues get overrides => BusinessValues.fromRow(row);
  BusinessRules get rules => BusinessRules.fromJson({
    'hoursOn': row['hours_on'],
    'hoursFrom': row['hours_from'],
    'hoursUntil': row['hours_until'],
    'noteRequired': row['note_required'],
    'approvalOn': row['approval_on'],
    'approvalOver': row['approval_over'],
    'capOn': row['cap_on'],
    'monthlyCap': row['monthly_cap'],
    'bookersFreight': row['bookers_freight'],
  });

  String get place => [city, state, country].where((s) => s.trim().isNotEmpty).join(', ');
}

class BusinessRepository {
  BusinessRepository(this._db);
  final SupabaseClient _db;

  String? get _uid => _db.auth.currentUser?.id;

  // ---- Members ----------------------------------------------------------------------------------
  Future<List<BusinessMembership>> myAccounts() async {
    final raw = await _db.rpc('business_my_accounts');
    return [
      if (raw is List)
        for (final r in raw)
          if (r is Map) BusinessMembership.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  Future<BusinessAccountDetail> detail(String accountId) async {
    final raw = await _db.rpc('business_account_detail', params: {'p_account': accountId});
    return BusinessAccountDetail.fromJson(Map<String, dynamic>.from(raw as Map));
  }

  /// Uploads the SSM document to the caller's folder; its URL.
  Future<String> uploadDocument(Uint8List bytes, String fileName) async {
    final uid = _uid;
    if (uid == null) throw StateError('Sign in to apply.');
    final ext = guessExt(fileName);
    final path = docFilePath(uid, 'ssm', 'front', ext);
    final files = _db.storage.from('business-documents');
    await uploadStoredFile(files, path, bytes, contentType: contentTypeFor(ext));
    return files.getPublicUrl(path);
  }

  Future<String> apply({
    required String name,
    required String regNo,
    String? companyType,
    String? address,
    required String country,
    required String state,
    String city = '',
    required String documentUrl,
  }) async =>
      '${await _db.rpc('business_apply', params: {
        'p_name': name,
        'p_reg_no': regNo,
        'p_company_type': companyType,
        'p_address': address,
        'p_country': country,
        'p_state': state,
        'p_city': city,
        'p_document_url': documentUrl,
      })}';

  Future<void> join(String accountId) => _db.rpc('business_join', params: {'p_account': accountId});

  Future<void> leave(String accountId) => _db.rpc('business_leave', params: {'p_account': accountId});

  Future<BusinessCheck> check({
    required String accountId,
    required String service,
    required double fare,
    DateTime? pickupAt,
    String? note,
    bool forOther = false,
    String? payer,
  }) async => BusinessCheck.fromJson(await _db.rpc('business_booking_check', params: {
    'p_account': accountId,
    'p_service': service,
    'p_fare': fare,
    'p_pickup_at': pickupAt?.toUtc().toIso8601String(),
    'p_note': note,
    'p_for_other': forOther,
    'p_payer': payer,
  }));

  Future<void> askApproval({
    required String accountId,
    required double amount,
    required String service,
    String? pickup,
    String? dropoff,
    String? note,
  }) => _db.rpc('business_approval_request', params: {
    'p_account': accountId,
    'p_amount': amount,
    'p_service': service,
    'p_pickup': pickup,
    'p_dropoff': dropoff,
    'p_note': note,
  });

  // ---- The company's Admins -------------------------------------------------------------------------
  Future<void> invite(String accountId, {required String phone, String? name, required BusinessRole role, String? team, double? limit}) =>
      _db.rpc('business_member_invite', params: {
        'p_account': accountId,
        'p_phone': phone,
        'p_name': name,
        'p_role': role.name,
        'p_team': team,
        'p_limit': limit,
      });

  /// [limit] null with [defaultLimit]: back to the account's default.
  Future<void> updateMember(String memberId, {BusinessRole? role, String? team, double? limit, bool defaultLimit = false}) =>
      _db.rpc('business_member_update', params: {
        'p_member': memberId,
        'p_role': role?.name,
        'p_team': team,
        'p_limit': limit,
        'p_default_limit': defaultLimit,
      });

  Future<void> removeMember(String memberId) => _db.rpc('business_member_remove', params: {'p_member': memberId});

  Future<void> setRules(String accountId, BusinessRules rules) =>
      _db.rpc('business_rules_set', params: {'p_account': accountId, 'p_rules': rules.toJson()});

  Future<void> decideApproval(String approvalId, bool approve) =>
      _db.rpc('business_approval_decide', params: {'p_approval': approvalId, 'p_approve': approve});

  Future<BusinessInvoiceFile> invoiceFile(String invoiceId) async => BusinessInvoiceFile.fromJson(
    Map<String, dynamic>.from(await _db.rpc('business_invoice_lines', params: {'p_invoice': invoiceId}) as Map),
  );

  // ---- Admin › People › Business accounts --------------------------------------------------------------
  Future<List<AdminBusinessAccount>> adminAccounts() async {
    final rows = await _db
        .from('business_accounts')
        .select('*, profiles:applied_by(name, phone)')
        .order('created_at', ascending: false)
        .limit(1000);
    final counts = <String, int>{};
    final members = await _db.from('business_members').select('account_id').neq('status', 'removed').limit(20000);
    for (final m in members) {
      counts.update('${m['account_id']}', (v) => v + 1, ifAbsent: () => 1);
    }
    return [for (final r in rows) AdminBusinessAccount(r, members: counts[r['id']] ?? 0)];
  }

  Future<List<BusinessInvoice>> adminInvoices(String accountId) async {
    final rows = await _db
        .from('business_invoices')
        .select()
        .eq('account_id', accountId)
        .order('period_start', ascending: false)
        .limit(60);
    return [for (final r in rows) BusinessInvoice.fromJson(r)];
  }

  Future<List<Map<String, dynamic>>> adminWallet(String accountId) async => List<Map<String, dynamic>>.from(
    await _db
        .from('business_wallet_entries')
        .select()
        .eq('account_id', accountId)
        .order('created_at', ascending: false)
        .limit(50),
  );

  Future<List<BusinessMember>> adminMembers(String accountId) async {
    final rows = await _db
        .from('business_members')
        .select()
        .eq('account_id', accountId)
        .neq('status', 'removed')
        .order('created_at', ascending: true);
    return [
      for (final r in rows)
        BusinessMember.fromJson({
          ...r,
          'monthlyLimit': r['monthly_limit'],
        }),
    ];
  }

  Future<void> setStatus(String accountId, String status, {String? note}) =>
      _db.rpc('admin_business_set_status', params: {'p_account': accountId, 'p_status': status, 'p_note': note});

  /// The company's details and [overrides] (every value sent; null follows the rules).
  Future<void> saveAccount(String accountId, {Map<String, dynamic> details = const {}, BusinessValues? overrides}) =>
      _db.rpc('admin_business_save', params: {
        'p_account': accountId,
        'p': {...details, ...?overrides?.toOverrides()},
      });

  Future<void> adjustWallet(String accountId, double amount, String note) =>
      _db.rpc('admin_business_wallet_adjust', params: {'p_account': accountId, 'p_amount': amount, 'p_note': note});

  Future<void> markPaid(String invoiceId, {String? note}) =>
      _db.rpc('admin_business_invoice_paid', params: {'p_invoice': invoiceId, 'p_note': note});

  Future<int> issueInvoices() async => ((await _db.rpc('admin_business_issue_invoices')) as num?)?.toInt() ?? 0;

  Future<List<BusinessRegionRule>> regionRules() async {
    final rows = await _db
        .from('business_region_rules')
        .select()
        .order('position', ascending: true)
        .order('created_at', ascending: true);
    return [for (final r in rows) BusinessRegionRule.fromRow(r)];
  }

  Future<void> saveRegionRule(BusinessRegionRule r) async {
    final row = r.toRow();
    if (r.id == null) {
      await _db.from('business_region_rules').insert(row);
    } else {
      await _db.from('business_region_rules').update(row).eq('id', r.id!);
    }
  }

  Future<void> deleteRegionRule(String id) => _db.from('business_region_rules').delete().eq('id', id);
}

final businessRepositoryProvider = Provider((ref) => BusinessRepository(ref.watch(supabaseProvider)));

/// The signed-in member's accounts and invitations; empty when signed out
/// or before 0313.
final myBusinessAccountsProvider = FutureProvider<List<BusinessMembership>>((ref) async {
  try {
    if (ref.watch(currentUserIdProvider) == null) return const [];
    return await ref.watch(businessRepositoryProvider).myAccounts();
  } catch (_) {
    return const [];
  }
});

final businessAccountDetailProvider = FutureProvider.autoDispose.family<BusinessAccountDetail, String>(
  (ref, id) => ref.watch(businessRepositoryProvider).detail(id),
);

final adminBusinessAccountsProvider = FutureProvider.autoDispose<List<AdminBusinessAccount>>(
  (ref) => ref.watch(businessRepositoryProvider).adminAccounts(),
);

final businessRegionRulesProvider = FutureProvider.autoDispose<List<BusinessRegionRule>>(
  (ref) => ref.watch(businessRepositoryProvider).regionRules(),
);
