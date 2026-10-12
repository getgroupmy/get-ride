// A request that is both My Ride and GET.now: the rider is one of the
// driver's regulars and booked them by scanning their GET.now code. The
// server targets a direct booking at its driver for ten minutes, so on the
// row it looks like a favourites window too; the driver must read it as a
// direct booking, pinned above every starred request, and never see a
// ten-minute "for you first" countdown.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/my_ride.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/partner/direct_booking_badge.dart';
import 'package:get_ride/src/features/partner/my_ride_badges.dart';

final _now = DateTime.utc(2026, 10, 12, 13);

RideRequest _req(String id, {String? rider, List<String>? targets, Duration? window, String? direct}) => RideRequest({
  'id': id,
  'rider_id': ?rider,
  'target_driver_ids': ?targets,
  if (window != null) 'targeted_until': _now.add(window).toIso8601String(),
  'direct_driver_id': ?direct,
});

/// The driver list's order, as partner_screen.dart composes it.
List<String> _order(List<RideRequest> list, String me, Set<String> regulars) => [
  for (final r in pinDirectFirst(pinStarredFirst(list, (r) => r.starredFor(me, regulars)), me)) r.id,
];

void main() {
  const me = 'driver-me';
  const regulars = {'rider-regular'};

  // Booked directly by a regular rider: targeted at me with the server's
  // ten-minute hold, as 0161's insert trigger stores it.
  final both = _req('both', rider: 'rider-regular', targets: [me], window: const Duration(minutes: 10), direct: me);
  // Booked directly by someone who has never ridden with me.
  final directOnly = _req('direct', rider: 'rider-new', targets: [me], window: const Duration(minutes: 10), direct: me);
  // My Ride: offered to me first for another 42 s.
  final starred = _req('starred', rider: 'rider-x', targets: [me, 'driver-2'], window: const Duration(seconds: 42));
  final plain = _req('plain', rider: 'rider-y');

  group('a request that is both My Ride and GET.now', () {
    test('is a direct booking and still a regular rider', () {
      expect(both.isDirectBooking, isTrue);
      expect(bookedMeDirectly(both, me), isTrue);
      expect(both.starredFor(me, regulars), isTrue);
    });

    test('the direct hold alone does not star a stranger', () {
      expect(directOnly.starredFor(me, regulars), isFalse);
      expect(starred.starredFor(me, regulars), isTrue);
    });

    test('direct bookings sort above starred requests, whatever the input order', () {
      expect(_order([plain, starred, directOnly, both], me, regulars), ['both', 'direct', 'starred', 'plain']);
      expect(_order([both, plain, directOnly, starred], me, regulars), ['both', 'direct', 'starred', 'plain']);
    });

    test('another driver sees neither mark nor pin', () {
      expect(bookedMeDirectly(both, 'driver-2'), isFalse);
      expect(both.starredFor('driver-2', const {}), isFalse);
      expect(_order([plain, both], 'driver-2', const {}), ['plain', 'both']);
    });
  });

  group('labels', () {
    Future<void> pump(WidgetTester tester, RideRequest r) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MyRideForYouLabel(request: r, me: me, clock: () => _now),
              DirectBookingLabel(request: r, me: me),
            ],
          ),
        ),
      ),
    );

    testWidgets('a direct booking from a regular reads "Booked you directly" only, with no countdown', (tester) async {
      await pump(tester, both);
      expect(find.byKey(const ValueKey('direct-booking-both')), findsOneWidget);
      expect(find.text('Booked you directly'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-for-you-both')), findsNothing);
      expect(find.byKey(const ValueKey('my-ride-window-both')), findsNothing);
      expect(find.textContaining('for you first'), findsNothing);
    });

    testWidgets('a My Ride request still reads "for you first" with its seconds', (tester) async {
      await pump(tester, starred);
      expect(find.byKey(const ValueKey('my-ride-for-you-starred')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-window-starred')), findsOneWidget);
      expect(find.byKey(const ValueKey('direct-booking-starred')), findsNothing);
    });
  });
}
