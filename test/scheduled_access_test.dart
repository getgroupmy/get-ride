// Where scheduled rides are found: Scheduled Request in both side menus
// (only while scheduled rides are on, in its place in a menu the admin has
// already arranged), the Scheduled tab on Trips, the driver's card on
// Drive, and where a reminder opens.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/core/side_menu.dart';
import 'package:get_ride/src/core/trip_history.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/scheduled_ride_repository.dart';
import 'package:get_ride/src/data/trip_history_repository.dart';
import 'package:get_ride/src/features/partner/partner_menu.dart' show partnerMenuRowShows;
import 'package:get_ride/src/features/partner/scheduled_jobs_screen.dart' show PartnerUpcomingBookingCard;
import 'package:get_ride/src/features/profile/account_screen.dart' show riderMenuRowShows;
import 'package:get_ride/src/features/ride/trips_screen.dart';

class _NoTrips implements TripHistoryRepository {
  @override
  Future<List<RideRequest>> page(
    TripHistoryRole role, {
    TripHistoryFilter filter = TripHistoryFilter.all,
    DateTime? before,
    int limit = tripHistoryPageSize,
  }) async => const [];
}

const _on = ScheduledRidesConfig(enabled: true);

void main() {
  group('side menus', () {
    test('Scheduled Request follows Request history and Trip history', () {
      final user = [for (final e in resolveSideMenu(const {}, 'user')) e.id];
      expect(user.indexOf(scheduledRidesMenuItemId), user.indexOf('request-history') + 1);
      final partner = [for (final e in resolveSideMenu(const {}, 'partner')) e.id];
      expect(partner.indexOf(scheduledRidesMenuItemId), partner.indexOf('trip-history') + 1);
      expect(
        resolveSideMenu(const {}, 'user').firstWhere((e) => e.id == scheduledRidesMenuItemId).label,
        'Scheduled Request',
      );
    });

    test('a menu the admin arranged before gets it in its place, not under Logout', () {
      final saved = [
        for (final (id, _) in defaultUserMenuItems.reversed)
          if (id != scheduledRidesMenuItemId) id,
      ];
      final ids = [
        for (final e in resolveSideMenu({
          'userMenu': {'order': saved},
        }, 'user'))
          e.id,
      ];
      // Wherever the admin put Request history, the new item follows it.
      expect(ids.indexOf(scheduledRidesMenuItemId), ids.indexOf('request-history') + 1);
      expect(ids.first, 'logout', reason: "the admin's order is kept");
    });

    test('shown only while scheduled rides are on', () {
      expect(riderMenuRowShows(scheduledRidesMenuItemId), isFalse);
      expect(riderMenuRowShows(scheduledRidesMenuItemId, scheduledRides: true), isTrue);
      expect(riderMenuRowShows('wallet'), isTrue);
      expect(partnerMenuRowShows(scheduledRidesMenuItemId, obdLinked: false, hasMyRideCode: false), isFalse);
      expect(
        partnerMenuRowShows(scheduledRidesMenuItemId, obdLinked: false, hasMyRideCode: false, scheduledRides: true),
        isTrue,
      );
    });
  });

  test('a reminder opens the bookings on the side it was sent to', () {
    expect(pushRouteFor({'type': 'scheduled_reminder', 'scheduled_ride_id': 's1'}), '/trips/scheduled');
    expect(pushRouteFor({'type': 'scheduled_reminder', 'role': 'partner'}), '/drive/scheduled');
  });

  group('Trips', () {
    Future<void> pump(WidgetTester tester, ScheduledRidesConfig config, {ThemeData? theme}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tripHistoryRepositoryProvider.overrideWithValue(_NoTrips()),
            scheduledRidesConfigProvider.overrideWith((_) async => config),
            myScheduledRidesProvider.overrideWith((_) async => const <ScheduledRide>[]),
          ],
          child: MaterialApp(theme: theme, home: const TripsScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final dark in [false, true]) {
      testWidgets('a Scheduled tab with the bookings (${dark ? 'dark' : 'light'})', (tester) async {
        await pump(tester, _on, theme: dark ? ThemeData.dark() : ThemeData.light());
        await tester.tap(find.byKey(const ValueKey('trips-tab-scheduled')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('scheduled-empty')), findsOneWidget);
      });
    }

    testWidgets('no tab while scheduled rides are off', (tester) async {
      await pump(tester, ScheduledRidesConfig.off);
      expect(find.byKey(const ValueKey('trips-tab-scheduled')), findsNothing);
    });
  });

  group("the driver's card on Drive", () {
    ScheduledRide booking(String id, int hours, {ScheduledStatus status = ScheduledStatus.assigned}) => ScheduledRide(
      id: id,
      pickupAt: DateTime(2026, 10, 16, 8 + hours, 30),
      status: status,
      pickupAddress: 'Pickup $id',
    );

    Future<void> pump(WidgetTester tester, List<ScheduledRide> taken, {ThemeData? theme}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            scheduledRidesConfigProvider.overrideWith((_) async => _on),
            acceptedScheduledRidesProvider.overrideWith((_) async => taken),
          ],
          child: MaterialApp(
            theme: theme,
            home: const Scaffold(body: PartnerUpcomingBookingCard()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final dark in [false, true]) {
      testWidgets('the next one taken, and how many more (${dark ? 'dark' : 'light'})', (tester) async {
        await pump(tester, [
          booking('r0', 0, status: ScheduledStatus.released), // already sent: on the job list, not here
          booking('a1', 1),
          booking('a2', 3),
        ], theme: dark ? ThemeData.dark() : ThemeData.light());
        expect(find.text('Scheduled ride · Fri 16 Oct, 9:30 AM · +1 more'), findsOneWidget);
        expect(find.text('Pickup a1'), findsOneWidget);
      });
    }

    testWidgets('a long pickup address does not hide how many more', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final long = ScheduledRide(
        id: 'a1',
        pickupAt: DateTime(2026, 10, 16, 9, 30),
        status: ScheduledStatus.assigned,
        pickupAddress: 'Mid Valley Megamall, Lingkaran Syed Putra, Mid Valley City, 59200 Kuala Lumpur',
      );
      await pump(tester, [long, booking('a2', 3), booking('a3', 5)]);
      expect(find.text('Scheduled ride · Fri 16 Oct, 9:30 AM · +2 more'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no count with a single booking', (tester) async {
      await pump(tester, [booking('a1', 1)]);
      expect(find.text('Scheduled ride · Fri 16 Oct, 9:30 AM'), findsOneWidget);
    });

    testWidgets('nothing when none is taken', (tester) async {
      await pump(tester, const []);
      expect(find.byKey(const ValueKey('partner-upcoming-booking')), findsNothing);
    });
  });
}
