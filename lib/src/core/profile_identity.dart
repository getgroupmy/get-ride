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

/// Why [email] can't be saved on the profile, or null when it can (empty is
/// fine: it is optional).
String? profileEmailProblem(String email) {
  final e = email.trim();
  if (e.isEmpty) return null;
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e) ? null : 'Enter a valid email address';
}

/// Why [raw] can't be saved as the passport / ID number, or null when it
/// can (empty is fine): letters, digits, spaces, `-` and `/`, 5 to 20 of
/// them not counting the separators.
String? idNumberProblem(String raw) {
  final v = normalizeIdNumber(raw);
  if (v.isEmpty) return null;
  if (!RegExp(r'^[A-Z0-9 /-]+$').hasMatch(v)) return 'Use letters and numbers as printed on your ID';
  final chars = v.replaceAll(RegExp(r'[\s/-]'), '').length;
  if (chars < 5) return 'Too short for a passport or ID number';
  if (chars > 20) return 'Too long for a passport or ID number';
  return null;
}

/// Country names for the picker (the same `country-state-city` names Expo
/// stored), filtered by [query], case-insensitively.
List<String> searchCountries(String query) {
  final q = query.trim().toLowerCase();
  final all = worldCountryCurrencies.keys.toList()..sort();
  return q.isEmpty ? all : all.where((c) => c.toLowerCase().contains(q)).toList();
}
