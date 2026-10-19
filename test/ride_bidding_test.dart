import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show FlutterMap, MarkerLayer;
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/fare_offer.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/ride/searching_parts.dart';
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';

const _me = '11111111-1111-1111-1111-111111111111';
const _other = '22222222-2222-2222-2222-222222222222';

RideRequest ride({
  String status = 'open',
  double fare = 20,
  double? offered,
  String? partner,
  bool offerMe = true,
  String? partnerName,
}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'status': status,
  'fare': fare,
  'ride_fare': fare,
  'offered_fare': offered,
  'partner_id': partner,
  'partner_name': partnerName,
  'offer_me': offerMe,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
});

class _FakeRides implements RideRepository {
  final rows = StreamController<RideRequest>.broadcast();
  final calls = <String>[];
  RideRequest? acceptResult;

  /// What a direct read of the row answers (the dialog's fallback check).
  RideRequest? row;

  @override
  Stream<RideRequest> watch(String id) => rows.stream;

  @override
  Future<RideRequest?> fetch(String id) async => row;

  @override
  Future<RideRequest?> raiseFare(String id, double fare) async {
    calls.add('raise $fare');
    return ride(fare: fare);
  }

  @override
  Future<RideRequest?> acceptOffer(String id, {required String partnerId, required double amount}) async {
    calls.add('accept $partnerId $amount');
    return acceptResult;
  }

  @override
  Future<void> declineOffer(String id, {required String partnerId}) async => calls.add('decline $partnerId');

  @override
  Future<void> withdrawOffer(String id) async => calls.add('withdraw');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('region bidding', () {
    final klBox = jsonEncode({
      'coords': [
        {'latitude': 3.3, 'longitude': 101.5},
        {'latitude': 3.3, 'longitude': 101.8},
        {'latitude': 3.0, 'longitude': 101.8},
        {'latitude': 3.0, 'longitude': 101.5},
      ],
      'bbox': {'north': 3.3, 'south': 3.0, 'east': 101.8, 'west': 101.5},
    });
    final regions = [
      BiddingRegion.fromValues({'country': 'Malaysia'})!,
      BiddingRegion.fromValues({
        'country': 'Malaysia',
        'state': 'Kuala Lumpur',
        'biddingEnabled': false,
        'boundary': klBox,
      })!,
      BiddingRegion.fromValues({'country': 'Malaysia', 'state': 'Penang', 'biddingEnabled': false})!,
    ];
    const kl = LatLng(3.15, 101.7);
    const penang = LatLng(5.4, 100.3);

    test('a containing boundary decides first', () {
      expect(biddingByBoundary(regions, kl), isFalse);
      expect(biddingEnabledAt(regions, kl), isFalse);
      expect(biddingByBoundary(regions, penang), isNull);
    });

    test('names decide when no boundary does; unknown places stay on', () {
      expect(
        biddingEnabledAt(
          regions,
          penang,
          area: const AreaInfo(country: 'malaysia', state: 'Penang'),
        ),
        isFalse,
      );
      expect(
        biddingEnabledAt(
          regions,
          penang,
          area: const AreaInfo(country: 'Malaysia', state: 'Johor'),
        ),
        isTrue,
      );
      expect(biddingEnabledAt(regions, penang), isTrue);
      expect(biddingEnabledAt(regions, null), isTrue);
      expect(BiddingRegion.fromValues({'state': 'x'}), isNull);
    });
  });

  group('fare limits', () {
    test('raises are capped at 4x the quote', () {
      expect(raisedFare(20, 5, quoted: 20), 25);
      expect(raisedFare(78, 5, quoted: 20), 80);
      expect(raisedFare(80, 1, quoted: 20), 80);
    });

    test('counter-offers sit above the fare and below the cap', () {
      expect(counterOfferPresets(20), [24, 26, 30]);
      expect(counterOfferProblem(20, 20), isNotNull);
      expect(counterOfferProblem(21, 20), isNull);
      expect(counterOfferProblem(81, 20), isNotNull);
    });
  });

  group('reading the row', () {
    test('standing offer', () {
      expect(standingOffer(ride(offered: 25, partner: _other))!.amount, 25);
      expect(standingOffer(ride(offered: 25)), isNull);
      expect(standingOffer(ride(status: 'accepted', offered: 25, partner: _other)), isNull);
    });

    test('offer outcomes', () {
      OfferOutcome o(RideRequest r) => offerOutcome(r, me: _me, amount: 25, fareWhenOffered: 20);
      expect(o(ride(offered: 25, partner: _me)), OfferOutcome.pending);
      expect(o(ride(status: 'accepted', fare: 25, partner: _me)), OfferOutcome.won);
      expect(o(ride(status: 'accepted', partner: _other)), OfferOutcome.outbid);
      expect(o(ride(offered: 26, partner: _other)), OfferOutcome.outbid);
      expect(o(ride(fare: 25)), OfferOutcome.raised);
      expect(o(ride()), OfferOutcome.declined);
      expect(o(ride(status: 'cancelled')), OfferOutcome.closed);
    });
  });

  group('rider screen', () {
    Future<_FakeRides> pump(WidgetTester tester, RideRequest first) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rides = _FakeRides();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideStreamProvider.overrideWith((ref, id) => Stream.value(first)),
          ],
          child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
        ),
      );
      await tester.pump();
      await tester.pump();
      // The offer card rises in before it can be answered.
      await tester.pump(const Duration(milliseconds: 500));
      return rides;
    }

    testWidgets('the clock and a moving driver rebuild the countdown and the map, not the sheet', (tester) async {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
          ],
          child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
        ),
      );
      rows.add(ride());
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      var panels = 0, ticks = 0;
      debugOnRebuildDirtyWidget = (e, _) {
        if (e.widget.runtimeType.toString() == '_RidePanel') panels++;
        if (e.widget is SearchHeader) ticks++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      await tester.pump(const Duration(seconds: 3));
      expect(panels, 0);
      expect(ticks, greaterThanOrEqualTo(1), reason: 'the countdown still runs');

      RideRequest moving(double lat) => RideRequest({
        ...ride(status: 'accepted', partner: _other, partnerName: 'Ali').raw,
        'partner_live_lat': lat,
        'partner_live_lng': 101.7,
        'updated_at': '2026-10-18T10:00:${(lat * 1000).round() % 60}Z',
      });
      rows.add(moving(3.10));
      await tester.pump();
      await tester.pump();
      panels = 0;
      rows.add(moving(3.101));
      await tester.pump();
      await tester.pump();
      expect(panels, 0, reason: 'a new position alone leaves the sheet as it is');
      rows.add(RideRequest({...moving(3.101).raw, 'status': 'arrived'}));
      await tester.pump();
      await tester.pump();
      expect(panels, greaterThan(0), reason: 'anything else still reaches it');
      expect(find.text(RideStatus.arrived.label), findsWidgets);
      debugOnRebuildDirtyWidget = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    for (final size in const [Size(390, 844), Size(360, 640)]) {
      for (final bidding in const [true, false]) {
      testWidgets(
          'at rest the raise-fare controls and the drop-off show above the pinned Cancel request '
          '(${size.width.round()}x${size.height.round()}${bidding ? '' : ', fixed fare'})', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final open = RideRequest({
          ...ride(offerMe: bidding).raw,
          'pickup_address': 'Kuala Lumpur City Centre, Kuala Lumpur',
          'drop_address': 'KL Sentral, Brickfields',
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              rideRepositoryProvider.overrideWithValue(_FakeRides()),
              rideStreamProvider.overrideWith((ref, id) => Stream.value(open)),
              riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
            ],
            child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final dropRow = find.descendant(
          of: find.byKey(const ValueKey('search-route')),
          matching: find.textContaining('KL Sentral'),
        );
        final band = find.byKey(const ValueKey('ride-cancel-footer'));
        expect(band, findsOneWidget);
        final handle = find.byKey(const ValueKey('map-sheet-handle'));
        final restsAt = tester.getTopLeft(handle).dy;
        // Offer mode: raising the fare needs no drag either (web tester #115).
        final shown = [
          dropRow,
          if (bidding) find.text('Confirm'),
          if (bidding) find.byKey(const ValueKey('search-auto-accept')),
        ];
        for (final f in shown) {
          expect(f, findsOneWidget);
        }
        if (shown.any((f) => tester.getBottomLeft(f).dy > tester.getTopLeft(band).dy)) {
          // Taller than the screen (the test font is wide): it rests all
          // the way up instead.
          await tester.drag(handle, const Offset(0, -1000));
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(handle).dy, closeTo(restsAt, 0.5), reason: 'hidden only when even the full sheet cannot hold them');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });
      }
    }

    test('a ride is steady while only its live positions move', () {
      final a = ride(status: 'accepted').raw;
      SteadyRide s(Map<String, dynamic> raw) => SteadyRide(AsyncData(RideRequest(raw)));
      expect(s({...a, 'partner_live_lat': 3.1}), s({...a, 'partner_live_lat': 3.2, 'updated_at': 'x'}));
      expect(s({...a, 'user_live_lat': 3.1}), s({...a, 'user_live_lat': 3.2}));
      expect(s(a) == s({...a, 'status': 'arrived'}), isFalse);
      expect(s(a) == SteadyRide(const AsyncLoading()), isFalse);
    });

    testWidgets('accepts a standing offer by partner and amount', (tester) async {
      final rides = await pump(tester, ride(offered: 25, partner: _other, partnerName: 'Ali'));
      expect(find.text('Ali'), findsOneWidget);
      expect(find.text('Your fare'), findsNothing, reason: 'above the fare');
      await tester.tap(find.byKey(const ValueKey('accept-offer')));
      await tester.pump();
      expect(rides.calls, ['accept $_other 25.0']);
      expect(find.text('That offer changed before you accepted it.'), findsOneWidget);
    });

    testWidgets('declines an offer and raises the fare', (tester) async {
      final rides = await pump(tester, ride(offered: 25, partner: _other));
      await tester.tap(find.byKey(const ValueKey('decline-offer')));
      await tester.pump();
      // The keys only move the fare; Confirm sends it.
      FilledButton confirm() => tester.widget(find.byKey(const ValueKey('search-fare-confirm')));
      expect(confirm().onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('search-fare-raise')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('search-fare-raise')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('search-fare-lower')));
      await tester.pump();
      expect(find.text('Confirm RM25.00'), findsOneWidget);
      expect(rides.calls, ['decline $_other']);
      await tester.tap(find.byKey(const ValueKey('search-fare-confirm')));
      await tester.pump();
      expect(rides.calls, ['decline $_other', 'raise 25.0']);
      expect(find.text('You raised the fare'), findsOneWidget);
    });

    testWidgets('on a desktop screen the offer flies in over the map, and out once answered', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
          ],
          child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
        ),
      );
      rows.add(ride(offered: 25, partner: _other, partnerName: 'Ali'));
      await tester.pump();
      await tester.pump();
      final overMap = find.descendant(
        of: find.byType(OfferStack),
        matching: find.byKey(const ValueKey('ride-offer')),
      );
      expect(overMap, findsOneWidget);
      expect(find.byKey(const ValueKey('ride-offer')), findsOneWidget, reason: 'not in the list as well');
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getTopLeft(overMap).dx, greaterThan(420), reason: 'over the map, right of the panel');

      rows.add(ride());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Ali'), findsOneWidget, reason: 'flying out');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Ali'), findsNothing);
    });

    for (final b in Brightness.values) {
      testWidgets('landscape 915x412: the offer cards stand clear of the map buttons; Decline keeps the theme font '
          '(${b.name})', (tester) async {
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final rows = StreamController<RideRequest>();
        addTearDown(rows.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              rideRepositoryProvider.overrideWithValue(_FakeRides()),
              rideStreamProvider.overrideWith((ref, id) => rows.stream),
            ],
            child: MaterialApp(theme: ThemeData(brightness: b), home: const RideTrackingScreen(requestId: 'r1')),
          ),
        );
        rows.add(ride(offered: 25, partner: _other, partnerName: 'Ali'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final card = tester.getRect(find.byKey(const ValueKey('ride-offer')));
        for (final key in const ['map-type', 'map-recenter']) {
          final button = tester.getRect(find.byKey(ValueKey(key)));
          expect(card.overlaps(button), isFalse, reason: 'the offer card covers $key');
          expect(card.right, lessThanOrEqualTo(button.left), reason: 'left of the map buttons');
        }
        final decline = find.byKey(const ValueKey('decline-offer'));
        final label = tester.renderObject<RenderParagraph>(find.descendant(of: decline, matching: find.text('Decline')));
        expect(label.text.style?.fontFamily, Theme.of(tester.element(decline)).textTheme.labelLarge?.fontFamily);
        expect(label.text.style?.fontFamily, isNotNull);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('on a phone the offer floats over the top of the map, not in the sheet', (tester) async {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
          ],
          child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
        ),
      );
      rows.add(ride(offered: 25, partner: _other, partnerName: 'Ali'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final overScreen = find.descendant(
        of: find.byType(ChooseDriverOverlay),
        matching: find.byKey(const ValueKey('ride-offer')),
      );
      expect(overScreen, findsOneWidget);
      expect(find.byKey(const ValueKey('ride-offer')), findsOneWidget, reason: 'not in the sheet as well');
      expect(find.text('Choose a driver'), findsOneWidget);
      expect(tester.getRect(overScreen).top, lessThan(300), reason: 'at the top, under the title');
    });

    for (final dark in [false, true]) {
      testWidgets('412x915 at 1.3x: under "Choose a driver" the sheet header stands down '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final rows = StreamController<RideRequest>();
        addTearDown(rows.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              rideRepositoryProvider.overrideWithValue(_FakeRides()),
              rideStreamProvider.overrideWith((ref, id) => rows.stream),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
                child: child!,
              ),
              home: const RideTrackingScreen(requestId: 'r1'),
            ),
          ),
        );
        bool headerShown() =>
            tester.widget<Visibility>(find.byKey(const ValueKey('search-header-slot'))).visible;
        rows.add(ride());
        await tester.pump();
        await tester.pump();
        expect(headerShown(), isTrue, reason: 'no offers yet: the sheet says what is happening');
        rows.add(ride(offered: 25, partner: _other, partnerName: 'Ali'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(ChooseDriverOverlay), findsOneWidget);
        expect(headerShown(), isFalse);
        // Only the overlay's "All drivers verified" is there to see or hear.
        expect(find.text('All drivers verified').hitTestable(), findsOneWidget);
        final slot = tester.widget<Visibility>(find.byKey(const ValueKey('search-header-slot')));
        expect(slot.maintainSemantics, isFalse, reason: 'nor read out twice');
        expect(tester.takeException(), isNull);
      });
    }

    for (final dark in [false, true]) {
      testWidgets('165: at 360x640 "Choose a driver" covers the whole map, its title on a near-solid band '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final rows = StreamController<RideRequest>();
        addTearDown(rows.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              rideRepositoryProvider.overrideWithValue(_FakeRides()),
              rideStreamProvider.overrideWith((ref, id) => rows.stream),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
              home: const RideTrackingScreen(requestId: 'r1'),
            ),
          ),
        );
        rows.add(ride(offered: 25, partner: _other, partnerName: 'Ali'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final overlay = tester.getRect(find.byType(ChooseDriverOverlay));
        final map = tester.getRect(find.byType(FlutterMap));
        // Over the map from its top edge, side to side; since #434 the dim
        // stops above the sheet's footer instead of covering it.
        expect(overlay.top, lessThanOrEqualTo(map.top + 0.5), reason: 'over the map from its top, markers and all');
        expect(overlay.left, lessThanOrEqualTo(map.left + 0.5));
        expect(overlay.right, greaterThanOrEqualTo(map.right - 0.5));
        // Painted after the map: the overlay is a later child of the same Stack.
        final stack = tester.widget<Stack>(find.ancestor(of: find.byType(ChooseDriverOverlay), matching: find.byType(Stack)).first);
        expect(stack.children.last, isA<Positioned>());
        final header = find.byKey(const ValueKey('choose-driver-header'));
        expect(tester.widget<ColoredBox>(header).color.a, greaterThanOrEqualTo(0.9));
        expect(find.descendant(of: header, matching: find.text('All drivers verified')), findsOneWidget);
        expect(find.descendant(of: header, matching: find.text('Choose a driver')), findsOneWidget);
        // Topmost under "All drivers verified" is the overlay, not a pin.
        final at = tester.getCenter(find.descendant(of: header, matching: find.text('All drivers verified')));
        final hits = tester.hitTestOnBinding(at).path.map((e) => e.target).whereType<RenderBox>();
        final markerLayer = find.byType(MarkerLayer).evaluate().map((e) => e.renderObject).toSet();
        expect(hits.any(markerLayer.contains), isFalse);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('no offer card or raise once accepted', (tester) async {
      await pump(tester, ride(status: 'accepted', partner: _other, partnerName: 'Ali'));
      expect(find.byKey(const ValueKey('ride-offer')), findsNothing);
      expect(find.byKey(const ValueKey('raise-5')), findsNothing);
    });
  });

  group('partner waiting on an offer', () {
    Future<(_FakeRides, Future<RideRequest?>)> pump(WidgetTester tester) async {
      final rides = _FakeRides();
      late Future<RideRequest?> result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => result = showDialog<RideRequest>(
                context: context,
                builder: (_) => OfferPendingDialog(
                  repo: rides,
                  ride: ride(),
                  me: _me,
                  amount: 25,
                  window: const Duration(seconds: 3),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      return (rides, result);
    }

    testWidgets('a win closes with the ride', (tester) async {
      final (rides, result) = await pump(tester);
      rides.rows.add(ride(offered: 25, partner: _me));
      await tester.pump();
      expect(find.text('Offer sent'), findsOneWidget);
      rides.rows.add(ride(status: 'accepted', fare: 25, partner: _me));
      await tester.pumpAndSettle();
      expect((await result)!.status, RideStatus.accepted);
    });

    testWidgets('a win reaches the driver even when realtime never delivers it', (tester) async {
      final (rides, result) = await pump(tester);
      rides.row = ride(offered: 25, partner: _me);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Offer sent'), findsOneWidget, reason: 'still waiting');
      // The rider accepted; no realtime update comes, but the next read sees it.
      rides.row = ride(status: 'accepted', fare: 25, partner: _me);
      await tester.pump(offerAnswerPoll);
      await tester.pumpAndSettle();
      expect((await result)!.status, RideStatus.accepted);
    });

    testWidgets('a raise and a timeout are explained; a timeout withdraws', (tester) async {
      var (rides, _) = await pump(tester);
      rides.rows.add(ride(fare: 30));
      await tester.pump();
      expect(find.textContaining('raised the fare to RM30.00'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      (rides, _) = await pump(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining('did not answer in time'), findsOneWidget);
      expect(rides.calls, ['withdraw']);
    });

    testWidgets('a closed offer closes itself after 3 seconds, counting down', (tester) async {
      final (rides, _) = await pump(tester);
      rides.rows.add(ride());
      await tester.pump();
      expect(find.text('The rider declined your offer.'), findsOneWidget);
      expect(find.text('Closing in 3s'), findsOneWidget);
      final full = tester.widget<LinearProgressIndicator>(find.byKey(const ValueKey('offer-closed-timer'))).value!;
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('Closing in 2s'), findsOneWidget);
      expect(
        tester.widget<LinearProgressIndicator>(find.byKey(const ValueKey('offer-closed-timer'))).value,
        lessThan(full),
        reason: 'the bar drains',
      );
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pumpAndSettle();
      expect(find.text('The rider declined your offer.'), findsNothing, reason: 'closed by itself');
    });
  });
}
