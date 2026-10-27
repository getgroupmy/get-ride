// Reads and writes for the partner application review (migration 0289):
// the admin's page loads every row of one application and decides lines
// through the partner_review_* functions; the driver reads their own lines
// once sent back, keeps an admin's edit and sends the application again.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/partner_registration.dart' show makeModelService;
import '../core/partner_review.dart';
import '../core/vehicle_onboarding.dart' show VehicleServiceOption, vehicleServiceOptions;
import '../providers.dart';

/// Everything one application's review page shows.
class ReviewApplication {
  const ReviewApplication({
    required this.partner,
    this.profile,
    this.vehicle,
    this.providerDocs = const [],
    this.vehicleDocs = const [],
    this.serviceStatuses = const [],
    this.faces = const {},
    this.items = const {},
    this.log = const [],
    this.names = const {},
    this.sameIdAccounts = const [],
    this.serviceNames = const {},
    this.services = const [],
    this.makeModelService = '',
  });

  final Map<String, dynamic> partner;
  final Map<String, dynamic>? profile;
  final Map<String, dynamic>? vehicle;
  final List<Map<String, dynamic>> providerDocs;
  final List<Map<String, dynamic>> vehicleDocs;
  final List<Map<String, dynamic>> serviceStatuses;

  /// document_face_checks rows by `doc_kind:doc_id`.
  final Map<String, Map<String, dynamic>> faces;

  /// The admin's decisions by line key.
  final Map<String, ReviewItem> items;

  /// Every view, decision and return to pending, oldest first (0296).
  final List<ReviewLogEntry> log;

  /// The names of the admins (and driver) in [log] and the approver, by id.
  final Map<String, String> names;

  /// Display ids of other accounts with the same ID number (0299).
  final List<String> sameIdAccounts;

  /// Every Vehicle Services entry's name by id, and those a vehicle can be
  /// set to (the vehicle service line, 0249).
  final Map<String, String> serviceNames;
  final List<VehicleServiceOption> services;

  /// The service the Vehicle Make & Model list sets for the vehicle ('' for none).
  final String makeModelService;

  String get partnerId => '${partner['id']}';
  String get status => '${partner['status'] ?? 'unapproved'}';

  List<ReviewLine> get lines => applicationReviewLines(
        profile: profile,
        partner: partner,
        vehicle: vehicle,
        providerDocs: providerDocs,
        vehicleDocs: vehicleDocs,
        serviceStatuses: serviceStatuses,
        sameIdAccounts: sameIdAccounts,
        serviceNames: serviceNames,
        makeModelService: makeModelService,
      );
}

class PartnerReviewRepository {
  PartnerReviewRepository(this._db);
  final SupabaseClient _db;

  List<Map<String, dynamic>> _rows(Object? v) => List<Map<String, dynamic>>.from(v as List);

  /// One application with its rows (admin).
  Future<ReviewApplication?> application(String partnerId) async {
    final partner = await _db.from('partners').select().eq('id', partnerId).maybeSingle();
    if (partner == null) return null;
    final uid = '${partner['auth_user_id'] ?? ''}';
    final vehicleId = '${partner['registration_vehicle_id'] ?? ''}';
    final results = await Future.wait<Object?>([
      uid.isEmpty ? Future.value(null) : _db.from('profiles').select().eq('id', uid).maybeSingle(),
      vehicleId.isEmpty ? Future.value(null) : _db.from('vehicle').select().eq('id', vehicleId).maybeSingle(),
      _db.from('provider_documents').select().eq('partner_id', partnerId).order('uploaded_at', ascending: false),
      vehicleId.isEmpty
          ? Future.value(const <Map<String, dynamic>>[])
          : _db.from('vehicle_documents').select().eq('vehicle_id', vehicleId).order('uploaded_at', ascending: false),
      vehicleId.isEmpty
          ? Future.value(const <Map<String, dynamic>>[])
          : _db.from('vehicle_service_status').select().eq('vehicle_id', vehicleId).order('service', ascending: true),
      uid.isEmpty
          ? Future.value(const <Map<String, dynamic>>[])
          : _db.from('document_face_checks').select().eq('user_id', uid).order('checked_at', ascending: false),
      _db.from('partner_review_items').select().eq('partner_id', partnerId).order('decided_at', ascending: true),
      _optional(_db.from('partner_review_log').select().eq('partner_id', partnerId).order('at', ascending: true)),
      uid.isEmpty
          ? Future.value(const <Map<String, dynamic>>[])
          : _optional(_db.rpc('admin_same_ic_accounts', params: {'p_profile': uid})),
      _optional(_db
          .from('settings_entries')
          .select('id, values')
          .eq('category', 'vehicle-services')
          .order('position', ascending: true)
          .order('created_at', ascending: true)),
    ]);
    final vehicle = results[1] as Map<String, dynamic>?;
    final make = '${vehicle?['make'] ?? ''}'.trim(), model = '${vehicle?['model'] ?? ''}'.trim();
    // The make's rows of Vehicle Make & Model, for the service it sets.
    final makeModels = make.isEmpty
        ? const <Map<String, dynamic>>[]
        : _rows(await _optional(_db
            .from('vehicle_make_models')
            .select('make, model, service_id, vehicle_type')
            .eq('status', true)
            .ilike('make', make)
            .order('position', ascending: true)));
    final serviceEntries = [
      for (final r in _rows(results[9] ?? const []))
        (id: '${r['id']}', values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {})),
    ];
    final log = [for (final r in _rows(results[7])) ?ReviewLogEntry.tryParse(r)];
    final ids = {for (final e in log) ?e.actorId, if (partner['approved_by'] != null) '${partner['approved_by']}'};
    var names = const <String, String>{};
    if (ids.isNotEmpty) {
      try {
        names = {
          for (final r in _rows(await _db.from('profiles').select('id, name').inFilter('id', ids.toList())))
            '${r['id']}': '${r['name'] ?? ''}'.trim().isEmpty ? 'An admin' : '${r['name']}'.trim(),
        };
      } catch (_) {}
    }
    return ReviewApplication(
      partner: partner,
      profile: results[0] as Map<String, dynamic>?,
      vehicle: vehicle,
      providerDocs: _rows(results[2]),
      vehicleDocs: _rows(results[3]),
      serviceStatuses: _rows(results[4]),
      faces: {for (final f in _rows(results[5])) '${f['doc_kind']}:${f['doc_id']}': f},
      items: {for (final r in _rows(results[6])) '${r['item_key']}': ReviewItem.fromRow(r)},
      log: log,
      names: names,
      sameIdAccounts: [
        for (final r in _rows(results[8] ?? const []))
          if ('${r['display_id'] ?? ''}'.trim().isNotEmpty) '${r['display_id']}'.trim(),
      ],
      serviceNames: {
        for (final e in serviceEntries)
          if ('${e.values['name'] ?? ''}'.trim().isNotEmpty) e.id: '${e.values['name']}'.trim(),
      },
      services: vehicleServiceOptions(serviceEntries),
      makeModelService: makeModelService(makeModels, make, model),
    );
  }

  /// A read that a database without it (before 0296) answers with nothing.
  Future<Object?> _optional(Future<Object?> read) async {
    try {
      return await read;
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  /// Logs that this admin opened [key]'s document (0296): a line with a
  /// document is decided only once viewed. Quiet on an older database.
  Future<void> viewed({required String partnerId, required String key}) async {
    try {
      await _db.rpc('partner_review_view', params: {'p_partner': partnerId, 'p_key': key});
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' || e.code == '42883') return;
      rethrow;
    }
  }

  /// Approves, rejects (with [note] as the reason) or edits (with [note]
  /// and the new [value], written to the real column) one line.
  Future<void> setItem({
    required String partnerId,
    required ReviewLine line,
    required ReviewState state,
    String? note,
    Object? value,
  }) =>
      _db.rpc('partner_review_set', params: {
        'p_partner': partnerId,
        'p_key': line.key,
        'p_group': line.group.key,
        'p_label': line.label,
        'p_state': state.name,
        'p_note': note,
        'p_value': value,
      });

  /// Forgets the decision on a line (an edit stays where it was written).
  Future<void> clearItem({required String partnerId, required ReviewLine line}) => _db.rpc('partner_review_set', params: {
        'p_partner': partnerId,
        'p_key': line.key,
        'p_group': line.group.key,
        'p_label': line.label,
        'p_state': 'clear',
      });

  /// Sends the application back to the driver ('changes-needed').
  Future<void> sendBack(String partnerId) => _db.rpc('partner_review_send_back', params: {'p_partner': partnerId});

  /// Approves the partner and their registration vehicle together.
  Future<void> approve(String partnerId) => _db.rpc('partner_review_approve', params: {'p_partner': partnerId});

  /// The driver's own lines (only those sent back are readable).
  Future<List<ReviewItem>> myItems(String partnerId) async => [
        for (final r in _rows(await _db
            .from('partner_review_items')
            .select()
            .eq('partner_id', partnerId)
            .order('decided_at', ascending: true)))
          ReviewItem.fromRow(r),
      ];

  /// "Keep and close" on an admin's edit.
  Future<void> keep(String key) => _db.rpc('partner_review_keep', params: {'p_key': key});

  /// "Send for review again".
  Future<void> resubmit() => _db.rpc('partner_review_resubmit');
}

final partnerReviewRepositoryProvider = Provider((ref) => PartnerReviewRepository(ref.watch(supabaseProvider)));

/// The signed-in driver's lines on "Changes needed".
final myReviewItemsProvider = FutureProvider.autoDispose.family<List<ReviewItem>, String>(
  (ref, partnerId) => ref.watch(partnerReviewRepositoryProvider).myItems(partnerId),
);
