/// The rider's identity details on Edit profile (Expo `app/edit-profile.tsx`
/// Identity section): country, a photo of their passport or ID, and the
/// number and address as printed on it. Admins verify them from the user
/// screens; `id_verified` itself stays admin-only (migration 0087).
library;

import '../admin/screens/commerce/countries.dart';

/// `<user id>/id_<ms>.<ext>` in the `ID_Image` bucket: the uploader's own
/// folder, which is all migration 0095 lets a non-admin write to.
String idImageStoragePath(String userId, String ext, DateTime now) => '$userId/id_${now.millisecondsSinceEpoch}.$ext';

/// An ID number as typed, tidied: trimmed, upper-cased, inner runs of
/// whitespace collapsed to one space.
String normalizeIdNumber(String raw) => raw.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');

/// The `profiles` columns the Identity section writes. A blank field clears
/// its column, as Expo's save did.
Map<String, String?> identityPatch({required String country, required String idNumber, required String address}) {
  String? v(String s) => s.trim().isEmpty ? null : s.trim();
  return {'nationality': v(country), 'ic': v(normalizeIdNumber(idNumber)), 'address': v(address)};
}

/// Country names for the picker (the same `country-state-city` names Expo
/// stored), filtered by [query], case-insensitively.
List<String> searchCountries(String query) {
  final q = query.trim().toLowerCase();
  final all = worldCountryCurrencies.keys.toList()..sort();
  return q.isEmpty ? all : all.where((c) => c.toLowerCase().contains(q)).toList();
}
