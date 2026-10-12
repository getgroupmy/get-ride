// Trip safety signals (reliability Phase D4): lib/src/core/trip_safety.dart
// and the widgets in lib/src/widgets/trip_safety.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/reliability_settings.dart';
import 'package:get_ride/src/core/trip_safety.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/reliability_repository.dart';
import 'package:get_ride/src/data/trip_safety_repository.dart';
import 'package:get_ride/src/widgets/trip_safety.dart';

class _Repo implements TripSafetyRepository {
  final oks = <String>[];
  final reports = <String>[];
  final answers = <(String, LostItemStatus, String?)>[];
  Object? refuse;

  @override
  Future<void> ok(String requestId) async => oks.add(requestId);

  @override
  Future<void> reportLostItem(String requestId, String description) async {
    if (refuse != null) throw refuse!;
    reports.add(description);
  }

  @override
  Future<void> respondLostItem(String itemId, LostItemStatus status, {String? note}) async =>
      answers.add((itemId, status, note));

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

RideRequest _ride(String status, {Map<String, dynamic> extra = const {}}) =>
    RideRequest({'id': 'r1', 'rider_id': 'u1', 'partner_id': 'd1', 'status': status, ...extra});

Widget _app(Brightness b, Widget child, List overrides) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    theme: appTheme(b),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  group('settings', () {
    test('all off until turned on; numbers clamped; kept beside the other switches', () {
      expect(SafetySettings.fromValues(null), const SafetySettings());
      final s = SafetySettings.fromValues({
        'safety_separation': 'true',
        'safety_far_apart_m': 9,
        'safety_separation_min': '99',
      });
      expect(s.separation, isTrue);
      expect(s.startCheck, isFalse);
      expect(s.farApartM, SafetySettings.minFarApart);
      expect(s.separationMin, SafetySettings.maxSeparation);
      expect(SafetySettings.fromValues(s.toValues()), s);

      final r = const ReliabilitySettings(rideCache: false).withSafety(s);
      expect(r.rideCache, isFalse);
      expect(ReliabilitySettings.fromValues(r.toValues()), r);
      expect(r.withSwitch('chat_outbox', false).safety, s, reason: 'flipping another switch keeps these');
    });
  });

  group('the passenger\'s question', () {
    final t0 = DateTime.utc(2026, 10, 12, 9);

    test('the latest unanswered flag, only while the trip is on', () {
      expect(safetyAsk(onTrip: true), isNull);
      expect(safetyAsk(onTrip: true, startFlagAt: t0), SafetyAsk.startCheck);
      expect(safetyAsk(onTrip: false, startFlagAt: t0), isNull);
      expect(safetyAsk(onTrip: true, startFlagAt: t0, ackAt: t0.add(const Duration(minutes: 1))), isNull);
      expect(
        safetyAsk(
          onTrip: true,
          startFlagAt: t0,
          ackAt: t0.add(const Duration(minutes: 1)),
          separatedAt: t0.add(const Duration(minutes: 9)),
        ),
        SafetyAsk.separation,
        reason: 'answering the start check doesn\'t answer a later separation',
      );
    });
  });

  group('lost items', () {
    final now = DateTime.utc(2026, 10, 12, 9);

    test('for 7 days after a completed trip, with the switch on', () {
      bool can({bool enabled = true, bool completed = true, Duration ago = const Duration(days: 1)}) =>
          canReportLostItem(enabled: enabled, completed: completed, completedAt: now.subtract(ago), now: now);
      expect(can(), isTrue);
      expect(can(enabled: false), isFalse);
      expect(can(completed: false), isFalse);
      expect(can(ago: const Duration(days: 8)), isFalse);
    });

    test('rows, statuses, text and refusals', () {
      final i = LostItem.fromRow({
        'id': 'i1',
        'request_id': 'r1',
        'description': 'Umbrella',
        'status': 'not_found',
        'driver_note': ' ',
      });
      expect(i.status, LostItemStatus.notFound);
      expect(i.status.db, 'not_found');
      expect(i.driverNote, isNull);
      expect(cleanLostItemText(' x '), isNull);
      expect(cleanLostItemText(' Umbrella '), 'Umbrella');
      expect(cleanLostItemText('a' * 600)!.length, 500);
      expect(lostItemError(Exception('too_late')), contains('too late'));
    });

    test('the admin\'s summary', () {
      expect(const TripSafetySummary().describe(7), contains('No trips flagged'));
      final s = TripSafetySummary.fromRow([
        {'start_flags': 1, 'separations': 2, 'answered_ok': 3, 'lost_open': 1, 'lost_found': 4},
      ]);
      expect(s.describe(7), contains('1 started away from the passenger · 2 apart mid-trip'));
      expect(s.describe(7), contains('1 lost items waiting · 4 found'));
    });
  });

  for (final b in Brightness.values) {
    testWidgets('the passenger is asked, says they\'re OK, and the question goes (${b.name})', (tester) async {
      final repo = _Repo();
      var help = 0;
      await tester.pumpWidget(
        _app(
          b,
          SafetyCheckBanner(
            ride: _ride('on_trip', extra: {'separated_at': '2026-10-12T09:00:00Z'}),
            onHelp: () => help++,
          ),
          [tripSafetyRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      expect(find.text('Are you still on your trip?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('safety-help')));
      expect(help, 1);
      await tester.tap(find.byKey(const ValueKey('safety-ok')));
      await tester.pumpAndSettle();
      expect(repo.oks, ['r1']);
      expect(find.byKey(const ValueKey('safety-check')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the passenger reports a lost item (${b.name})', (tester) async {
      final repo = _Repo();
      final done = _ride('completed', extra: {'completed_at': DateTime.now().toUtc().toIso8601String()});
      await tester.pumpWidget(
        _app(b, LostItemCard(ride: done), [
          tripSafetyRepositoryProvider.overrideWithValue(repo),
          reliabilityProvider.overrideWithValue(const ReliabilitySettings(safety: SafetySettings(lostItems: true))),
          rideLostItemsProvider.overrideWith(
            (ref, id) async => const [
              LostItem(
                id: 'i0',
                requestId: 'r1',
                description: 'Phone charger',
                status: LostItemStatus.found,
                driverNote: 'In the glovebox',
              ),
            ],
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Left something behind?'), findsOneWidget);
      expect(find.text('Driver: In the glovebox'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('lost-item-report')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('lost-item-text')), 'Black umbrella');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lost-item-send')));
      await tester.pumpAndSettle();
      expect(repo.reports, ['Black umbrella']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the driver answers a report (${b.name})', (tester) async {
      final repo = _Repo();
      await tester.pumpWidget(
        _app(b, const DriverLostItemsCard(), [
          tripSafetyRepositoryProvider.overrideWithValue(repo),
          driverLostItemsProvider.overrideWith(
            (ref) async => const [
              LostItem(id: 'i1', requestId: 'r1', description: 'Black umbrella'),
              LostItem(id: 'i2', requestId: 'r2', description: 'Scarf', status: LostItemStatus.notFound),
            ],
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('A passenger left something behind'), findsOneWidget, reason: 'answered ones drop off');

      await tester.tap(find.byKey(const ValueKey('driver-lost-found-i1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('driver-lost-note')), 'Back seat, call me');
      await tester.tap(find.byKey(const ValueKey('driver-lost-send')));
      await tester.pumpAndSettle();
      expect(repo.answers.single, ('i1', LostItemStatus.found, 'Back seat, call me'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('switched off, or the window passed: no lost item card', (tester) async {
    await tester.pumpWidget(
      _app(Brightness.light, LostItemCard(ride: _ride('completed', extra: {'completed_at': '2026-01-01T00:00:00Z'})), [
        reliabilityProvider.overrideWithValue(const ReliabilitySettings(safety: SafetySettings(lostItems: true))),
        rideLostItemsProvider.overrideWith((ref, id) async => const <LostItem>[]),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lost-item-card')), findsNothing);
  });
}
