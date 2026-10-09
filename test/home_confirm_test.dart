// The confirm step (a destination chosen) laid out as Expo's ride-confirm:
// addresses over the map, the fare inside the chosen vehicle, and a fixed
// bar with the payment icon and "Find a driver".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/route_estimate.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/ride/auto_accept.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart' show ConfirmSwitch;
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _eco = Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.9300, 101.8300));
const _klcc = Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(2.9400, 101.8400));

class _Rides implements RideRepository {
  _Rides({this.bidding = false});
  final bool bidding;
  Map<Symbol, dynamic>? created;

  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];

  @override
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async => bidding;

  @override
  Future<String?> publicIp() async => null;

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #createRequest) {
      created = i.namedArguments;
      return Future.value(RideRequest({'id': 'r9', 'rider_id': 'me', 'status': 'open', 'fare': 10}));
    }
    return super.noSuchMethod(i);
  }
}

/// The AI estimate, held until [answer] completes.
class _SlowAi implements RouteEstimateRepository {
  final answer = Completer<({RouteEstimate? estimate, bool unavailable})?>();

  @override
  Future<({RouteEstimate? estimate, bool unavailable})?> estimateDetailed(LatLng from, LatLng to) => answer.future;

  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// Lets a sheet or dialog finish opening or closing.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<ProviderContainer> _pump(WidgetTester tester, _Rides rides, {bool book = true, RouteEstimateRepository? ai}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      rideRepositoryProvider.overrideWithValue(rides),
      routeEstimateRepositoryProvider.overrideWithValue(ai ?? _NoAi()),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
      serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
      rideServicesProvider.overrideWith(
        (ref) async => const [
          RideService('Teksi', 'Metered taxi', 1, 4),
          RideService('GET XL', 'Up to 6 seats', 1.5, 6),
        ],
      ),
      recentPlacesProvider.overrideWith((ref) async => const [_eco, _klcc]),
      displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
      appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
      deviceBlockedProvider.overrideWith((ref) async => false),
      profileProvider.overrideWith((ref) async => null),
      fareTariffsProvider.overrideWith((ref) async => const []),
      meterLaunchSessionProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/ride/:id', builder: (_, s) => Text('ride ${s.pathParameters['id']}')),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (!book) return container;
  // Pickup by dragging the map under the pin, destination from the recent
  // list.
  final g = await tester.startGesture(const Offset(200, 150));
  for (var i = 0; i < 5; i++) {
    await g.moveBy(const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await g.up();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  // The sheet starts fully down: drag it up to reach the recent places.
  await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -300));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(find.text('KLCC').first);
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return container;
}

void main() {
  testWidgets('"Calculating fare" covers the confirm step until the AI estimate is in', (tester) async {
    final ai = _SlowAi();
    await _pump(tester, _Rides(), ai: ai);
    expect(find.byKey(const ValueKey('calculating-fare')), findsOneWidget);
    expect(find.text('Calculating fare'), findsOneWidget);
    ai.answer.complete((estimate: null, unavailable: false));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('calculating-fare')), findsNothing);
    expect(find.byKey(const ValueKey('traffic-unavailable')), findsNothing);
  });

  testWidgets('an AI fare service that is on but gives nothing warns about traffic', (tester) async {
    final ai = _SlowAi();
    await _pump(tester, _Rides(), ai: ai);
    ai.answer.complete((estimate: null, unavailable: true));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(trafficUnavailableTitle), findsOneWidget);
    await tester.tap(find.text('OK'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(trafficUnavailableTitle), findsNothing);
  });

  testWidgets('the main screen opens with its sheet fully down', (tester) async {
    await _pump(tester, _Rides(), book: false);
    final top = tester.getTopLeft(find.byKey(const ValueKey('map-sheet-handle'))).dy;
    expect(top, greaterThan(860 * (1 - 0.22) - 24), reason: 'at its lowest (22%), not half way up');
  });

  testWidgets('the confirm step is laid out as Expo ride-confirm', (tester) async {
    await _pump(tester, _Rides());

    expect(find.byKey(const ValueKey('confirm-address-card')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('confirm-address-card')), matching: find.text('Pinned location')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('confirm-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-recenter')), findsNothing, reason: "Expo's confirm has no recenter");
    expect(find.byKey(const ValueKey('map-dot-pickup')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-dot-drop')), findsOneWidget);
    expect(find.byKey(const ValueKey('promo-banner')), findsOneWidget);
    // The fare sits inside the chosen card; without bidding, no −/+.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('service-Teksi')),
        matching: find.byKey(const ValueKey('confirm-fare')),
      ),
      findsOneWidget,
    );
    expect(find.text('Recommended fare'), findsOneWidget);
    expect(find.byKey(const ValueKey('fare-raise')), findsNothing);
    expect(find.text('Fare does not include state entry tax, tolls, or parking fees'), findsOneWidget);
    // Above the pinned bar, faded out until the sheet is all the way up
    // (Expo shows it only expanded), and out again when it comes down.
    double shown() =>
        tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('map-sheet-above-footer'))).opacity;
    expect(shown(), 0);
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('confirm-disclaimer'))).dy,
      lessThan(tester.getTopLeft(find.text('Find a driver')).dy),
    );
    await tester.drag(find.text('Recommended fare'), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(shown(), 1);
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(shown(), 0);
    expect(find.text('Find a driver'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-payment')), findsOneWidget);
    expect(find.textContaining('Auto-accept offer of'), findsOneWidget);

    // Choosing another vehicle moves the fare into its card (the sheet
    // raised to reach it above the footer).
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('service-GET XL')));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('service-GET XL')),
        matching: find.byKey(const ValueKey('confirm-fare')),
      ),
      findsOneWidget,
    );

    // Back leaves the confirm step for the home map.
    await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-back')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('confirm-address-card')), findsNothing);
    expect(find.text('Find a driver'), findsNothing);
  });

  testWidgets('the entrance, the payment and auto-accept go with the booking', (tester) async {
    final rides = _Rides();
    final container = await _pump(tester, rides);

    await tester.tap(find.byKey(const ValueKey('confirm-entrance')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('entrance-key-1')));
    await tester.tap(find.byKey(const ValueKey('entrance-key-2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('entrance-done')));
    await _settle(tester);
    expect(find.text('Entrance 12'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-payment')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('payment-Get Pay')));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('auto-accept')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('book')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(rides.created, isNotNull);
    expect(rides.created![#note], 'Entrance 12');
    expect(rides.created![#paymentMode], 'Get Pay');
    expect(container.read(autoAcceptProvider)['r9'], rides.created![#fare]);
    expect(find.text('ride r9'), findsOneWidget);
  });

  testWidgets('the options button beside Find a driver opens Options; they go with the booking', (tester) async {
    final rides = _Rides();
    await _pump(tester, rides);
    Badge badge() => tester.widget<Badge>(
      find.descendant(of: find.byKey(const ValueKey('confirm-options')), matching: find.byType(Badge)),
    );
    expect(badge().isLabelVisible, isFalse);
    expect(find.text('Note to driver (optional)'), findsNothing, reason: 'the note is Options → Comments');
    expect(
      tester.getCenter(find.byKey(const ValueKey('confirm-options'))).dx,
      greaterThan(tester.getCenter(find.byKey(const ValueKey('book'))).dx),
      reason: 'right of Find a driver',
    );

    await tester.tap(find.byKey(const ValueKey('confirm-options')));
    await _settle(tester);
    expect(find.text('Options'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('option-child-seat')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('option-pet')));
    await tester.pump();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('option-pet'))).value, isTrue);
    // Comments: ← goes back to Options without saving; Save keeps it.
    await tester.tap(find.byKey(const ValueKey('option-comments')));
    await _settle(tester);
    expect(find.text('What your driver should know?'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('option-comments-field')), 'Not this');
    await tester.tap(find.byKey(const ValueKey('option-comments-back')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('option-comments-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('ride-options')), findsOneWidget);
    expect(find.text('Not this'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('option-comments')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('option-comments-field')), 'Blue gate');
    await tester.tap(find.byKey(const ValueKey('option-comments-done')));
    await _settle(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('option-comments')), matching: find.text('Blue gate')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ride-options-close')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ride-options')), findsNothing);
    expect(badge().isLabelVisible, isTrue, reason: 'an option is on');

    // ✕ on Comments closes Options too.
    await tester.tap(find.byKey(const ValueKey('confirm-options')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('option-comments')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('option-comments-x')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('option-comments-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('ride-options')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('book')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(rides.created![#note], 'Child safety seat · Pet with me · Blue gate');
    expect(rides.created![#passengers], 1);
  });

  testWidgets('booking for someone else is a toggle under GET.coin; the modal fills it in', (tester) async {
    final rides = _Rides();
    await _pump(tester, rides);
    final toggle = find.byKey(const ValueKey('who-riding'));
    expect(find.text('Someone else'), findsNothing, reason: 'no Me / Someone else buttons any more');
    // In the pinned footer, below the auto-accept row's top and above Find a driver.
    expect(find.descendant(of: find.byKey(const ValueKey('confirm-footer')), matching: toggle), findsOneWidget);
    expect(tester.getTopLeft(toggle).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('book'))).dy));
    expect(tester.widget<ConfirmSwitch>(toggle).value, isFalse);

    // Closed without Done the first time: back off.
    await tester.tap(toggle);
    await _settle(tester);
    expect(find.byKey(const ValueKey('book-for-sheet')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('book-for-done'))).onPressed, isNull);
    await tester.tapAt(const Offset(200, 20));
    await _settle(tester);
    expect(find.byKey(const ValueKey('book-for-sheet')), findsNothing);
    expect(tester.widget<ConfirmSwitch>(toggle).value, isFalse);
    expect(find.byKey(const ValueKey('book-for-edit')), findsNothing);
    expect(find.text('Find a driver'), findsOneWidget);

    // Filled in and Done: on, and the row shows who, with a pen.
    await tester.tap(toggle);
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('book-for-name')), 'Aminah');
    await tester.enterText(find.byKey(const ValueKey('book-for-phone')), '+60 12-345 6789');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('book-for-done')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('book-for-sheet')), findsNothing);
    expect(tester.widget<ConfirmSwitch>(toggle).value, isTrue);
    expect(tester.widget<Text>(find.byKey(const ValueKey('book-for-who'))).data, 'Aminah · +60123456789');
    expect(find.text('Find a driver for Aminah'), findsOneWidget);

    // The pen reopens it filled in; closing it keeps them.
    await tester.tap(find.byKey(const ValueKey('book-for-edit')));
    await _settle(tester);
    expect(find.widgetWithText(TextField, 'Aminah'), findsOneWidget);
    await tester.tapAt(const Offset(200, 20));
    await _settle(tester);
    expect(find.text('Find a driver for Aminah'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('book')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(rides.created![#bookedFor], (name: 'Aminah', phone: '+60123456789'));
  });

  testWidgets('switching it off books for the rider again', (tester) async {
    final rides = _Rides();
    await _pump(tester, rides);
    final toggle = find.byKey(const ValueKey('who-riding'));
    await tester.tap(toggle);
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('book-for-name')), 'Aminah');
    await tester.enterText(find.byKey(const ValueKey('book-for-phone')), '+60 12-345 6789');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('book-for-done')));
    await _settle(tester);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<ConfirmSwitch>(toggle).value, isFalse);
    expect(find.text('Find a driver'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(rides.created![#bookedFor], isNull);
  });

  testWidgets('where bidding is on the chosen card has the round −/+ and a pencil', (tester) async {
    await _pump(tester, _Rides(bidding: true));
    expect(find.byKey(const ValueKey('fare-raise')), findsOneWidget);
    expect(find.byKey(const ValueKey('fare-edit')), findsOneWidget);
    final before = tester.widget<Text>(find.byKey(const ValueKey('confirm-fare'))).data;
    await tester.tap(find.byKey(const ValueKey('fare-raise')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('confirm-fare'))).data, isNot(before));
    expect(find.textContaining('Recommended fare: '), findsOneWidget);
  });

  testWidgets('the pencil opens Offer your fare; a typed fare and the payment come back to the sheet', (tester) async {
    await _pump(tester, _Rides(bidding: true));
    await tester.tap(find.byKey(const ValueKey('fare-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offer-fare-screen')), findsOneWidget);
    expect(find.text('You can change the recommended fare'), findsOneWidget);
    final recommended = tester.widget<Text>(find.byKey(const ValueKey('offer-fare-note'))).data!;
    expect(recommended, startsWith('Recommended fare: '));

    // A fare far below the range is named, and Find a driver waits for a good one.
    await tester.enterText(find.byKey(const ValueKey('offer-fare-field')), '1');
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('offer-fare-note'))).data, startsWith('Minimum fare is'));
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('offer-fare-find'))).onPressed, isNull);

    final field = tester.widget<TextField>(find.byKey(const ValueKey('offer-fare-field')));
    final typed = (double.parse(recommended.replaceAll(RegExp(r'[^0-9.]'), '')) + 2).round();
    await tester.enterText(find.byKey(const ValueKey('offer-fare-field')), '$typed');
    await tester.pump();
    expect(field.controller!.text, '$typed');
    await tester.tap(find.byKey(const ValueKey('offer-fare-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offer-fare-screen')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('confirm-fare'))).data, contains('$typed'));
  });
}
