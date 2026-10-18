import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/branding_cache.dart' show SharedRead;

void main() {
  test('callers at the same time share one read, and a recent result is reused', () async {
    var now = DateTime(2026);
    final shared = SharedRead<int>(const Duration(minutes: 1), now: () => now);
    var reads = 0;
    final gate = Completer<void>();
    Future<int> fetch() async {
      reads++;
      await gate.future;
      return reads;
    }

    final a = shared.get(fetch, fresh: true);
    final b = shared.get(fetch);
    gate.complete();
    expect(await a, 1);
    expect(await b, 1);
    expect(reads, 1);

    // Recent: reused, unless a fresh one is asked for.
    expect(await shared.get(fetch), 1);
    expect(reads, 1);
    expect(await shared.get(fetch, fresh: true), 2);

    // Too old: read again.
    now = now.add(const Duration(minutes: 2));
    expect(await shared.get(fetch), 3);
  });

  test('a failed read is not kept', () async {
    final shared = SharedRead<int>(const Duration(minutes: 1));
    await expectLater(shared.get(() async => throw StateError('down')), throwsStateError);
    expect(await shared.get(() async => 7), 7);
  });
}
