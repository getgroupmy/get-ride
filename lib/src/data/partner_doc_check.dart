import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admin/screens/people/people_data.dart';
import '../admin/screens/people/people_logic.dart';
import '../core/partner_doc_check.dart';
import '../core/partner_onboarding.dart';
import '../core/vehicle_onboarding.dart';
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
