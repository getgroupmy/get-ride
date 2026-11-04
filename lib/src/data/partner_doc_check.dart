import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admin/screens/people/people_data.dart';
import '../admin/screens/people/people_logic.dart';
import '../core/partner_doc_check.dart';
import '../core/partner_onboarding.dart';
import '../core/vehicle_onboarding.dart';
import '../providers.dart' show partnerProvider;
import 'live_tables.dart';

/// The document issues for [partner] in one service mode: the admin's
/// required-document rules (partner types, service area; per-vehicle
/// documents left out) against the partner's own `provider_documents`.
/// Throws when anything cannot be read; callers decide whether that blocks.
Future<List<DocIssue>> loadPartnerDocIssues(
  PeopleRepository people,
  Map<String, dynamic> partner, {
  required bool teksi,
  DateTime? now,
}) async {
  final partnerId = '${partner['id'] ?? ''}';
  if (partnerId.isEmpty) return const [];
  final results = await Future.wait<Object>([
    people.partnerTypes(),
    people.requiredDocuments(),
    people.documentTypes(),
    people.providerDocuments(partnerId),
  ]);
  final typeEntries = results[0] as List<({String id, Map<String, dynamic> values})>;
  final requiredDocs = results[1] as List<({String id, Map<String, dynamic> values})>;
  final docTypes = results[2] as List<({String id, Map<String, dynamic> values})>;
  final uploads = results[3] as List<Map<String, dynamic>>;
  final docs = requiredDocsFor(
    requiredDocuments: requiredDocs,
    partnerTypeValues: typeEntries.map((e) => e.values),
    partnerTypes: partnerTypesForMode(parseStringList(partner['partner_types']), teksi: teksi),
    area: ServiceArea.fromRow(partner),
    vehicleTypeIds: vehicleDocTypeIds(docTypes),
  );
  return partnerDocIssues(docs, uploads, now: now);
}

/// Each partner-type service's readiness for [partner], judged on that one
/// type's own required documents (per-service enabling). Reuses the same
/// resolution as [loadPartnerDocIssues], scoped to each type on its own.
/// Throws when anything cannot be read; callers decide whether that matters.
Future<List<ServiceReadiness>> loadServiceReadiness(
  PeopleRepository people,
  Map<String, dynamic> partner, {
  DateTime? now,
}) async {
  final partnerId = '${partner['id'] ?? ''}';
  if (partnerId.isEmpty) return const [];
  final results = await Future.wait<Object>([
    people.partnerTypes(),
    people.requiredDocuments(),
    people.documentTypes(),
    people.providerDocuments(partnerId),
  ]);
  final typeEntries = results[0] as List<({String id, Map<String, dynamic> values})>;
  final requiredDocs = results[1] as List<({String id, Map<String, dynamic> values})>;
  final docTypes = results[2] as List<({String id, Map<String, dynamic> values})>;
  final uploads = results[3] as List<Map<String, dynamic>>;
  final area = ServiceArea.fromRow(partner);
  final vehTypeIds = vehicleDocTypeIds(docTypes);
  final typeValues = [for (final e in typeEntries) e.values];
  final docsByType = <String, List<RequiredDoc>>{
    for (final t in parseStringList(partner['partner_types']))
      t: requiredDocsFor(
        requiredDocuments: requiredDocs,
        partnerTypeValues: typeValues,
        partnerTypes: [t],
        area: area,
        vehicleTypeIds: vehTypeIds,
      ),
  };
  return serviceReadiness(docsByType, uploads, now: now);
}

/// The current driver's per-service readiness, refreshed as their documents
/// are approved (automatic enabling) and when their partner row changes.
/// Empty — never an error — when it can't be read, so a surface that shows it
/// just shows nothing rather than breaking the screen.
final serviceReadinessProvider = FutureProvider.autoDispose<List<ServiceReadiness>>((ref) async {
  ref.watchLive('provider_documents');
  try {
    final partner = await ref.watch(partnerProvider.future);
    if (partner == null) return const [];
    return await loadServiceReadiness(ref.watch(peopleRepositoryProvider), partner.raw);
  } catch (_) {
    return const [];
  }
});

/// The check as the Drive screen calls it; tests replace it.
typedef PartnerDocCheck = Future<List<DocIssue>> Function(Map<String, dynamic> partner, {required bool teksi});

final partnerDocCheckProvider = Provider<PartnerDocCheck>((ref) {
  final people = ref.watch(peopleRepositoryProvider);
  return (partner, {required teksi}) => loadPartnerDocIssues(people, partner, teksi: teksi);
});

/// Admin → Partner Type entries, for the Drive screen's service modes and
/// the "vehicle required" check. Empty when unreadable.
final partnerTypeEntriesProvider = FutureProvider.autoDispose<List<({String id, Map<String, dynamic> values})>>((ref) async {
  ref.watchLive('settings_entries');
  try {
    return await ref.watch(peopleRepositoryProvider).partnerTypes();
  } catch (_) {
    return const [];
  }
});
