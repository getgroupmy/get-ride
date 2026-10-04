import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../admin/screens/meterapp/meter_logic.dart';
import '../core/meter_auto_launch.dart';

/// What the launch decision needs to know without waiting on the network
/// (Expo `saveMeterGeo` / the cached rate cards): where the last meter
/// session ran, and the rate cards as last fetched. A meter has to keep
/// working with no signal, so it keeps its cards on the device.
class MeterLaunchStore {
  static const geoKey = 'meter_geo_v1';
  static const cardsKey = 'meter_cards_v1';

  Future<void> saveGeo(MeterGeo geo) async => (await SharedPreferences.getInstance()).setString(
        geoKey,
        jsonEncode({'country': geo.country, 'state': geo.state, 'city': geo.city, 'suburb': geo.suburb}),
      );

  Future<MeterGeo?> readGeo() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(geoKey);
      if (raw == null) return null;
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      String? s(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
      return (country: s(m['country']), state: s(m['state']), city: s(m['city']), suburb: s(m['suburb']));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCards(List<MeterProfile> cards) async => (await SharedPreferences.getInstance()).setString(
        cardsKey,
        jsonEncode([for (final c in cards) {...meterProfileToRow(c), 'id': c.id}]),
      );

  Future<List<MeterProfile>> readCards() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(cardsKey);
      if (raw == null) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((r) => normalizeMeterProfile(Map<String, dynamic>.from(r)))
          .whereType<MeterProfile>()
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
