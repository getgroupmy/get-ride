// The ID card's shared cases (supabase/functions/_shared/id_card_cases.json):
// the phone's reader (readCard in lib/src/core/signin_checks.dart) must read
// each case's text as written there. Google Vision's reader in the id-read
// function (_shared/id_read.ts) is held to the same cases by id_read_test.ts,
// so a card reads the same on the phone and on the server.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/signin_checks.dart';

void main() {
  final data = jsonDecode(File('supabase/functions/_shared/id_card_cases.json').readAsStringSync()) as Map<String, dynamic>;

  for (final c in (data['cases'] as List).cast<Map<String, dynamic>>()) {
    test(c['name'] as String, () {
      final r = readCard(c['text'] as String);
      final want = c['expect'] as Map<String, dynamic>;
      expect(r.name, want['name']);
      expect(r.ic, want['ic']);
      expect(r.expiry?.toIso8601String().split('T').first, want['expiry']);
    });
  }
}
