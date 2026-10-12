// My Ride on the driver's side (migration 0160): the code screen (QR, Change
// code, hide / unhide the riders who added them) and the request list
// (starred requests pinned with a gold star, "for you first", the pickup
// radius, and a request first seen in an UPDATE popping up as new).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/my_ride.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/my_ride_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/my_ride_badges.dart';
import 'package:get_ride/src/features/partner/my_ride_code_screen.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:qr_flutter/qr_flutter.dart';

class _FakeMyRide implements MyRideRepository {
  _FakeMyRide({List<FavouriteRider>? riders}) : riders = riders ?? [];

  String? code = 'ABCD2345';
  List<FavouriteRider> riders;
  final hides = <(String, bool)>[];
  var rotations = 0;

  @override
  Future<String?> myCode() async => code;

  @override
  Future<String?> rotateCode() async {
    rotations++;
    return code = 'WXYZ6789';
  }

  @override
  Future<List<FavouriteRider>?> favouriteRiders() async => riders;

  @override
  Future<Set<String>> favouriteRiderIds() async => {
    for (final r in riders)
      if (!r.hidden) r.riderId,
  };

  @override
  Future<bool?> hideRider(String riderId, {required bool hidden}) async {
    hides.add((riderId, hidden));
    riders = [
      for (final r in riders)
        r.riderId == riderId
            ? FavouriteRider(
                riderId: r.riderId,
                name: r.name,
                addedAt: r.addedAt,
                hidden: hidden,
                ridesTogether: r.ridesTogether,
              )
            : r,
    ];
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  Future<void> markViewed(String id) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _me = LatLng(3.1500, 101.7100);

RideRequest _req(String id, {double lat = 3.1600, String rider = 'rider-x', Map<String, dynamic> extra = const {}}) =>
    RideRequest({
      'id': id,
      'status': 'open',
      'service': 'Teksi',
      'rider_id': rider,
      'fare': 12,
      'ride_fare': 12,
      'currency': 'MYR',
      'distance_km': 5,
      'passengers': 1,
      'payment_mode': 'Cash',
      'rider_name': 'Siti',
      'pickup_name': 'Pickup $id',
      'drop_name': 'KL Sentral',
      'pickup_lat': lat,
      'pickup_lng': 101.7100,
      ...extra,
    });

void main() {
  group('code screen', () {
    Future<_FakeMyRide> pump(
      WidgetTester tester, {
      _FakeMyRide? repo,
      bool dark = false,
      Size size = const Size(360, 1400),
    }) async {
      final fake = repo ?? _FakeMyRide();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [myRideRepositoryProvider.overrideWithValue(fake), currentUserIdProvider.overrideWithValue('me')],
          child: MaterialApp(
            theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
            home: const MyRideCodeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('shows the QR of the code on white, the readable code and the explainer', (tester) async {
      await pump(tester);
      final qr = tester.widget<QrImageView>(find.byKey(const ValueKey('my-ride-qr')));
      expect(qr.backgroundColor, Colors.white);
      expect(find.text('ABCD 2345'), findsOneWidget);
      expect(find.text(myRideCodeExplainer), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-copy')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Change code asks first, explaining riders keep their link', (tester) async {
      final repo = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('my-ride-rotate')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('my-ride-rotate-confirm')), findsOneWidget);
      expect(find.textContaining('already added you keep you'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.rotations, 0);

      await tester.tap(find.byKey(const ValueKey('my-ride-rotate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-ride-rotate-ok')));
      await tester.pumpAndSettle();
      expect(repo.rotations, 1);
      expect(find.text('WXYZ 6789'), findsOneWidget);
    });

    testWidgets('hiding a rider asks first; unhiding does not', (tester) async {
      final repo = await pump(
        tester,
        repo: _FakeMyRide(
          riders: [FavouriteRider(riderId: 'r1', name: 'Aminah A.', addedAt: DateTime(2026, 10, 3), ridesTogether: 4)],
        ),
      );
      expect(find.text('Aminah A.'), findsOneWidget);
      expect(find.text('Added 3 Oct 2026 · 4 rides together'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('my-ride-hide-r1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('my-ride-hide-confirm')), findsOneWidget);
      expect(find.textContaining("won't be sent to you first and won't be starred"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-ride-hide-ok')));
      await tester.pumpAndSettle();
      expect(repo.hides, [('r1', true)]);
      expect(tester.widget<Switch>(find.byKey(const ValueKey('my-ride-hide-r1'))).value, isTrue);
      expect(find.textContaining('Hidden ·'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('my-ride-hide-r1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('my-ride-hide-confirm')), findsNothing);
      expect(repo.hides, [('r1', true), ('r1', false)]);
      expect(tester.widget<Switch>(find.byKey(const ValueKey('my-ride-hide-r1'))).value, isFalse);
    });

    testWidgets('no riders yet', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('my-ride-no-riders')), findsOneWidget);
    });

    testWidgets('without My Ride on the database: "not available yet"', (tester) async {
      await pump(tester, repo: _FakeMyRide()..code = null);
      expect(find.byKey(const ValueKey('my-ride-unavailable')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-qr')), findsNothing);
    });

    for (final (name, size) in [('phone', const Size(360, 1400)), ('desktop', const Size(1280, 900))]) {
      testWidgets('dark mode on a $name: the QR stays white and nothing overflows', (tester) async {
        await pump(
          tester,
          dark: true,
          size: size,
          repo: _FakeMyRide(
            riders: [
              FavouriteRider(
                riderId: 'r1',
                name: 'A rather long masked rider name that goes on B.',
                addedAt: DateTime(2026, 1, 30),
                ridesTogether: 128,
                hidden: true,
              ),
            ],
          ),
        );
        expect(tester.widget<QrImageView>(find.byKey(const ValueKey('my-ride-qr'))).backgroundColor, Colors.white);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('request list', () {
    late StreamController<List<RideRequest>> open;
    late DateTime now;

    setUp(() {
      open = StreamController<List<RideRequest>>.broadcast();
      now = DateTime.utc(2026, 10, 12, 9);
    });
    tearDown(() => open.close());

    Future<void> pump(
      WidgetTester tester, {
      Set<String> favourites = const {},
      bool dark = false,
      List<RideRequest> waiting = const [],
      LatLng? position = _me,
      Size size = const Size(1280, 2400),
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => open.stream),
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => [
                (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
              ],
            ),
            partnerDocCheckProvider.overrideWithValue((_, {required teksi}) async => const []),
            requestAlertClockProvider.overrideWithValue(() => now),
            currentUserIdProvider.overrideWithValue('me'),
            favouriteRiderIdsProvider.overrideWith((ref) async => favourites),
            serviceDispatchConfigsProvider.overrideWith((ref) async => const {}),
            driverPositionProvider.overrideWithValue(() async => position),
            driverPositionStreamProvider.overrideWithValue(() => const Stream<LatLng>.empty()),
          ],
          child: MaterialApp.router(
            theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (waiting.isNotEmpty) {
        // Already waiting when the driver goes online: in the list, no pop-up.
        open.add(waiting);
        await tester.pump();
      }
      await tester.tap(find.text('You are offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    double top(WidgetTester tester, String id) => tester.getTopLeft(find.byKey(ValueKey('queue-$id'))).dy;

    testWidgets('a starred request is pinned on top with a gold star', (tester) async {
      await pump(
        tester,
        favourites: {'rider-fav'},
        waiting: [
          _req('near'),
          _req('nearer', lat: 3.1510),
          _req('fav', lat: 3.1900, rider: 'rider-fav'),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
      expect(top(tester, 'fav'), lessThan(top(tester, 'nearer')));
      expect(top(tester, 'nearer'), lessThan(top(tester, 'near')));
      expect(find.byKey(const ValueKey('my-ride-star-fav')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-star-near')), findsNothing);
      final star = tester.widget<Icon>(
        find.descendant(of: find.byKey(const ValueKey('my-ride-star-fav')), matching: find.byType(Icon)),
      );
      expect(star.icon, Icons.star);
      expect(star.color, myRideStarColor(Brightness.light));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a request offered to me first: "for you first" with the seconds left', (tester) async {
      final targeted = _req(
        'mine',
        extra: {
          'target_driver_ids': ['me'],
          'targeted_until': now.add(const Duration(seconds: 42)).toIso8601String(),
        },
      );
      await pump(tester, waiting: [_req('other', lat: 3.1505), targeted]);
      await tester.pumpAndSettle();
      expect(top(tester, 'mine'), lessThan(top(tester, 'other')));
      expect(find.byKey(const ValueKey('my-ride-star-mine')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-for-you-mine')), findsOneWidget);
      expect(find.text('Your regular rider · for you first'), findsOneWidget);
      expect(find.text('42 s'), findsOneWidget);
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('40 s'), findsOneWidget);
      // The window over: the star stays (offered to me), the label goes.
      now = now.add(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('my-ride-for-you-mine')), findsNothing);
      expect(find.byKey(const ValueKey('my-ride-star-mine')), findsOneWidget);
    });

    testWidgets('requests beyond the service radius are left out, starred ones never', (tester) async {
      await pump(
        tester,
        favourites: {'rider-fav'},
        waiting: [
          _req('near'),
          _req('far', lat: 3.6000),
          _req('far-fav', lat: 3.6000, rider: 'rider-fav'),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('queue-near')), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-far')), findsNothing);
      expect(find.byKey(const ValueKey('queue-far-fav')), findsOneWidget);
    });

    testWidgets('with no position every request shows', (tester) async {
      await pump(tester, position: null, waiting: [_req('near'), _req('far', lat: 3.6000)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('queue-near')), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-far')), findsOneWidget);
    });

    testWidgets('a row first seen in an UPDATE (a window opening) pops up as new', (tester) async {
      await pump(tester, waiting: [_req('a')]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
      // Invisible to this driver until its favourites window ended; the
      // refetch the UPDATE triggers now has it.
      open.add([
        _req('a'),
        _req(
          'b',
          extra: {
            'target_driver_ids': ['someone-else'],
            'targeted_until': now.subtract(const Duration(seconds: 1)).toIso8601String(),
            'fallback_pushed_at': now.toIso8601String(),
          },
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('alert-overlay-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-for-you-b')), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('a starred request popping up carries its star; dark mode', (tester) async {
      await pump(tester, favourites: {'rider-fav'}, dark: true);
      open.add([_req('plain', lat: 3.1505), _req('fav', rider: 'rider-fav')]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The starred one is spotlighted first.
      expect(find.byKey(const ValueKey('alert-overlay-fav')), findsOneWidget);
      final star = tester.widget<Icon>(
        find.descendant(
          of: find.descendant(
            of: find.byKey(const ValueKey('request-alert')),
            matching: find.byKey(const ValueKey('my-ride-star-fav')),
          ),
          matching: find.byType(Icon),
        ),
      );
      expect(star.color, myRideStarColor(Brightness.dark));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });

    for (final dark in [false, true]) {
      testWidgets('on a 360 px phone the request sheet shows the star and "for you first" (dark: $dark)', (
        tester,
      ) async {
        await pump(tester, dark: dark, size: const Size(360, 800));
        open.add([
          _req(
            'mine',
            extra: {
              'target_driver_ids': ['me'],
              'targeted_until': now.add(const Duration(seconds: 30)).toIso8601String(),
            },
          ),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final sheet = find.byKey(const ValueKey('request-alert'));
        expect(sheet, findsOneWidget);
        expect(find.descendant(of: sheet, matching: find.byKey(const ValueKey('my-ride-star-mine'))), findsOneWidget);
        expect(find.descendant(of: sheet, matching: find.text('Your regular rider · for you first')), findsOneWidget);
        expect(find.descendant(of: sheet, matching: find.text('30 s')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
