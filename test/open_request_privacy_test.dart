// Open-request privacy (migration 0195): a driver deciding on an open
// request sees the rider's first name and an icon for a ride booked for
// someone else, never who it is for.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/providers.dart';

class _Rides implements RideRepository {
  @override
  Future<RequestViewers> viewers(String requestId) async => RequestViewers.none;

  @override
  Future<void> markViewed(String requestId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _open(Map<String, dynamic> extra) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'status': 'open',
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'created_at': DateTime.now().toUtc().toIso8601String(),
  ...extra,
});

void main() {
  test('booked for someone else is told by the flag alone once the details are aside', () {
    expect(_open({'booked_for_other': true}).isForOthers, isTrue);
    expect(_open({'booked_for_phone': '+60123456789'}).isForOthers, isTrue);
    expect(_open(const {}).isForOthers, isFalse);
  });

  test('drivers see a first name', () {
    expect(_open({'rider_name': '  Siti Aminah binti Ali '}).firstNameForDrivers, 'Siti');
    expect(_open(const {}).firstNameForDrivers, 'Passenger');
  });

  for (final dark in [false, true]) {
    testWidgets('the request sheet shows the first name and an icon, not the passenger${dark ? ' (dark)' : ''}', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [rideRepositoryProvider.overrideWithValue(_Rides())],
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: Scaffold(
              body: RideRequestSheet(
                // A database before 0195 still sends the names: never shown.
                request: _open({
                  'rider_name': 'Siti Aminah',
                  'booked_for_name': 'Mum',
                  'booked_for_phone': '+60130000195',
                }),
                shown: Duration.zero,
                now: DateTime.now(),
                onAccept: () async {},
                onSkip: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Siti'), findsOneWidget);
      expect(find.text('Mum'), findsNothing);
      expect(find.textContaining('Booked by'), findsNothing);
      expect(find.byKey(const ValueKey('request-for-others')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
