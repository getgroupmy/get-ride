import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/partner_type_rules.dart';
import 'live_tables.dart';
import '../providers.dart';

/// Asks the server whether the driver may work here (`partner_type_check`,
/// migration 0245): one of their types for the mode ([teksi]: the meter,
/// else e-hailing) is offered at the point, has the permit it needs and a
/// vehicle young enough; and whether street hail is offered here.
typedef PartnerTypeChecker = Future<PartnerTypeCheck> Function({double? lat, double? lng, required bool teksi});

/// How long a check may take before it counts as unanswered.
const partnerTypeCheckTimeout = Duration(seconds: 6);

/// Unanswered (no connection, a database without 0245, a slow reply) is
/// [PartnerTypeCheck.unknown]: the driver is let through, as the other
/// checks before going online do, and the server still decides.
final partnerTypeCheckerProvider = Provider<PartnerTypeChecker>((ref) {
  return ({double? lat, double? lng, required bool teksi}) async {
    try {
      final rows = await ref
          .read(supabaseProvider)
          .rpc('partner_type_check', params: {'p_lat': lat, 'p_lng': lng, 'p_teksi': teksi})
          .timeout(partnerTypeCheckTimeout);
      return PartnerTypeCheck.fromJson(rows);
    } catch (_) {
      return PartnerTypeCheck.unknown;
    }
  };
});

/// The check at a point rounded to about a kilometre, so the Drive screen
/// asks again only when the driver has moved.
typedef PartnerTypeCheckKey = ({double? lat, double? lng, bool teksi});

PartnerTypeCheckKey partnerTypeCheckKey(double? lat, double? lng, {required bool teksi}) => (
      lat: lat == null ? null : (lat * 100).roundToDouble() / 100,
      lng: lng == null ? null : (lng * 100).roundToDouble() / 100,
      teksi: teksi,
    );

final partnerTypeCheckProvider = FutureProvider.autoDispose.family<PartnerTypeCheck, PartnerTypeCheckKey>(
  (ref, k) {
    // An admin's change to the rules (or the driver's) is asked about again.
    ref.watchLive('settings_entries');
    return ref.watch(partnerTypeCheckerProvider)(lat: k.lat, lng: k.lng, teksi: k.teksi);
  },
);
