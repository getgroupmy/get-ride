// The trip card's shared cases (supabase/functions/_shared/trip_card_cases.json):
// the phone's builder (lib/src/core/trip_card.dart) must give each case the
// card written there. The server's copy (_shared/trip_card.ts, which moves
// the card while the app is closed) is held to the same cases by
// trip_card_test.ts, so the two say the same thing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_card.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:latlong2/latlong.dart';

void main() {
  final file = File('supabase/functions/_shared/trip_card_cases.json');
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final now = DateTime.parse(data['now'] as String);
  final base = data['base'] as Map<String, dynamic>;
  // The cases' clock times are in UTC, as the phone shows them in UTC.
  final utc = now.toLocal().timeZoneOffset == Duration.zero;

  for (final c in (data['cases'] as List).cast<Map<String, dynamic>>()) {
    final name = c['name'] as String;
    test(name, () {
      final r = RideRequest({...base, ...(c['extra'] as Map<String, dynamic>)});
      final eta = tripEta(r);
      final card = buildTripCard(
        r,
        asDriver: c['asDriver'] == true,
        now: now,
        eta: eta,
        fraction: tripStageFraction(r, kmLeft: eta?.km),
      );
      final want = c['expect'] as Map<String, dynamic>?;
      if (want == null) {
        expect(card, isNull);
        return;
      }
      expect(card, isNotNull);
      final got = card!.toPlatform(light: const TripCardColors(), dark: const TripCardColors())..remove('colors');
      final raw = (c['extra'] as Map)['total_due'] ?? base['total_due'];
      if (r.totalDue != null) expect(r.totalDue, closeTo((raw as num).toDouble(), 1e-9), reason: 'the amount due');
      expect(got.keys.toSet(), want.keys.toSet());
      for (final key in want.keys) {
        if (key == 'progress') {
          expect(got[key] as double, closeTo((want[key] as num).toDouble(), 1e-9), reason: key);
        } else if (!utc && got[key] is String && RegExp(r'\d:\d\d').hasMatch(want[key] as String)) {
          // A clock time on a phone set to another zone.
          continue;
        } else {
          expect(jsonEncode(got[key]), jsonEncode(want[key]), reason: key);
        }
      }
    });
  }

  test('distances are counted as the server counts them', () {
    // trip_card_test.ts: Mid Valley to KLCC is 5.853 km.
    expect(const Distance()(const LatLng(3.118, 101.677), const LatLng(3.1579, 101.7116)), 5853);
  });
}
