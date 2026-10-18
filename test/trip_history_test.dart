// Request history by side (core/trip_history.dart, trip_history_view.dart):
// someone who is both a rider and a partner sees the rides they booked under
// Trips and the trips they drove under Drive → Trip history, never mixed.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_history.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/trip_history_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_history_screen.dart';
import 'package:get_ride/src/features/ride/trips_screen.dart';
import 'package:get_ride/src/data/app_connection.dart';
import 'package:get_ride/src/widgets/offline_strip.dart';

/// One person's requests on both sides, and the reads made.
class _Fake implements TripHistoryRepository {
  _Fake(this.rows);
  final List<RideRequest> rows;
  final reads = <(TripHistoryRole, TripHistoryFilter, DateTime?)>[];

  @override
  Future<List<RideRequest>> page(
    TripHistoryRole role, {
    TripHistoryFilter filter = TripHistoryFilter.all,
    DateTime? before,
    int limit = tripHistoryPageSize,
  }) async {
    reads.add((role, filter, before));
    final mine = rows.where((r) => (role == TripHistoryRole.rider ? r.riderId : r.partnerId) == 'me');
    return mine
        .where((r) => filter.matches(r.status))
        .where((r) => before == null || r.createdAt!.isBefore(before))
        .take(limit)
        .toList();
  }
}

RideRequest _ride(String id, {required String rider, String? partner, String status = 'completed', int day = 1}) =>
    RideRequest({
      'id': id,
      'rider_id': rider,
      'partner_id': partner,
      'status': status,
      'pickup_name': 'From $id',
      'drop_name': 'To $id',
      'ride_fare': 10,
      'created_at': DateTime.utc(2026, 10, day).toIso8601String(),
    });

void main() {
  test('filters by status; expired requests count as cancelled', () {
    expect(TripHistoryFilter.all.statuses, isNull);
    expect(TripHistoryFilter.completed.statuses, ['completed']);
    expect(TripHistoryFilter.cancelled.statuses, ['cancelled', 'expired']);
    expect(TripHistoryFilter.ongoing.statuses, containsAll(['open', 'accepted', 'arrived', 'on_trip']));
    expect(TripHistoryFilter.cancelled.matches(RideStatus.expired), isTrue);
    expect(TripHistoryFilter.completed.matches(RideStatus.cancelled), isFalse);
    expect(TripHistoryRole.rider.column, 'rider_id');
    expect(TripHistoryRole.partner.column, 'partner_id');
  });

  test('a row opens the receipt or the live screen of its own side', () {
    final done = _ride('a', rider: 'me', partner: 'p');
    final live = _ride('b', rider: 'me', partner: 'p', status: 'on_trip');
    expect(tripHistoryRoute(TripHistoryRole.rider, done), '/trips/a');
    expect(tripHistoryRoute(TripHistoryRole.partner, done), '/drive/history/a');
    expect(tripHistoryRoute(TripHistoryRole.rider, live), '/ride/b');
    expect(tripHistoryRoute(TripHistoryRole.partner, live), '/drive/trip/b');
  });

  final rows = [
    _ride('booked1', rider: 'me', partner: 'someone', day: 9),
    _ride('booked2', rider: 'me', status: 'cancelled', day: 8),
    _ride('drove1', rider: 'someone', partner: 'me', day: 7),
    _ride('drove2', rider: 'other', partner: 'me', status: 'expired', day: 6),
  ];

  Future<_Fake> pump(WidgetTester tester, Widget screen, {ThemeData? theme, bool offline = false}) async {
    final fake = _Fake(rows);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripHistoryRepositoryProvider.overrideWithValue(fake),
          if (offline) appOfflineProvider.overrideWith(_Offline.new),
        ],
        child: MaterialApp(theme: theme, home: screen),
      ),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  for (final dark in [false, true]) {
    testWidgets('user side: only the rides booked (${dark ? 'dark' : 'light'})', (tester) async {
      final fake = await pump(tester, const TripsScreen(), theme: dark ? ThemeData.dark() : ThemeData.light());
      expect(fake.reads.single.$1, TripHistoryRole.rider);
      expect(find.byKey(const ValueKey('trip-booked1')), findsOneWidget);
      expect(find.byKey(const ValueKey('trip-booked2')), findsOneWidget);
      expect(find.byKey(const ValueKey('trip-drove1')), findsNothing);
      // Cancelled only.
      await tester.tap(find.byKey(const ValueKey('trip-filter-cancelled')));
      await tester.pumpAndSettle();
      expect(fake.reads.last.$2, TripHistoryFilter.cancelled);
      expect(find.byKey(const ValueKey('trip-booked1')), findsNothing);
      expect(find.byKey(const ValueKey('trip-booked2')), findsOneWidget);
    });

    testWidgets('partner side: only the trips driven (${dark ? 'dark' : 'light'})', (tester) async {
      final fake = await pump(
        tester,
        const PartnerTripHistoryScreen(),
        theme: dark ? ThemeData.dark() : ThemeData.light(),
      );
      expect(fake.reads.single.$1, TripHistoryRole.partner);
      expect(find.byKey(const ValueKey('trip-drove1')), findsOneWidget);
      expect(find.byKey(const ValueKey('trip-drove2')), findsOneWidget);
      expect(find.byKey(const ValueKey('trip-booked1')), findsNothing);
      expect(find.text('Trip history'), findsOneWidget);
    });
  }

  for (final dark in [false, true]) {
    testWidgets('offline, Trips says the list is the saved one (${dark ? 'dark' : 'light'})', (tester) async {
      await pump(tester, const TripsScreen(), theme: dark ? ThemeData.dark() : ThemeData.light(), offline: true);
      expect(find.text(offlineStripText), findsOneWidget);
      expect(find.byKey(const ValueKey('trip-booked1')), findsOneWidget, reason: 'the saved list still shows');
    });
  }

  testWidgets('a cancelled row keeps its date whole at large bold text (iPhone SE @1.3)', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 667);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripHistoryRepositoryProvider.overrideWithValue(_Fake(rows))],
        child: MaterialApp(
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.3), boldText: true),
            child: child!,
          ),
          home: const TripsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final date = tester.renderObject<RenderParagraph>(
      find.descendant(of: find.byKey(const ValueKey('trip-date-booked2')), matching: find.byType(RichText)),
    );
    expect(date.didExceedMaxLines, isFalse, reason: 'the date is not cut');
    expect(find.byKey(const ValueKey('trip-fare-booked2')), findsNothing);
    expect(find.text('Cancelled · Not charged'), findsOneWidget);
    expect(find.byKey(const ValueKey('trip-fare-booked1')), findsOneWidget, reason: 'a billed trip keeps its fare');
  });

  testWidgets('nothing on a side says so', (tester) async {
    final fake = _Fake([_ride('booked1', rider: 'me')]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripHistoryRepositoryProvider.overrideWithValue(fake)],
        child: const MaterialApp(home: PartnerTripHistoryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No trips yet'), findsOneWidget);
    expect(find.text('Trips you drive will show up here.'), findsOneWidget);
  });

  testWidgets('older trips load a page at a time', (tester) async {
    final many = [for (var i = 0; i < tripHistoryPageSize + 5; i++) _ride('r$i', rider: 'me', day: 1)];
    // Newest first, a minute apart.
    for (var i = 0; i < many.length; i++) {
      many[i].raw['created_at'] = DateTime.utc(2026, 10, 10).subtract(Duration(minutes: i)).toIso8601String();
    }
    final fake = _Fake(many);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripHistoryRepositoryProvider.overrideWithValue(fake)],
        child: const MaterialApp(home: TripsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    // The trips, not the filter chips above them.
    final list = find.descendant(of: find.byType(RefreshIndicator), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('trip-history-more')), 400, scrollable: list);
    await tester.tap(find.byKey(const ValueKey('trip-history-more')));
    await tester.pumpAndSettle();
    expect(fake.reads.length, 2);
    expect(fake.reads.last.$3, many[tripHistoryPageSize - 1].createdAt);
    await tester.scrollUntilVisible(find.byKey(ValueKey('trip-r${many.length - 1}')), 400, scrollable: list);
    expect(find.byKey(const ValueKey('trip-history-more')), findsNothing);
  });
}

class _Offline extends AppOffline {
  @override
  bool build() => true;
}
