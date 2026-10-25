import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../core/dial_countries.dart';
import '../providers.dart';

/// The phone screen's countries from Admin › Country / States / Cities'
/// phone rules (migration 0292; anyone may read them), Blocked ones left
/// out. Empty when they can't be read (offline, a database without 0292),
/// so the built-in list stays.
final phoneRuleCountriesProvider = FutureProvider<List<DialCountry>>((ref) async {
  final db = ref.watch(supabaseProvider);
  try {
    final results = await Future.wait([
      db.from('country_phone_rules').select('iso, dial_code, access').order('iso', ascending: true),
      db.from('countries').select('name, iso:values->>isoCode').order('name', ascending: true),
    ]).timeout(const Duration(seconds: 10));
    final names = <String, String>{
      for (final c in results[1])
        if ('${c['iso'] ?? ''}'.length == 2) '${c['iso']}'.toUpperCase(): '${c['name']}',
    };
    return dialCountriesFromRules(
      [for (final r in results[0]) Map<String, dynamic>.from(r)],
      names,
      first: dialCountryFor(AppConfig.defaultDialCode).code,
    );
  } catch (_) {
    return const [];
  }
});
