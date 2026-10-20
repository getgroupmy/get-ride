// The ride extras a driver takes (migration 0253): the keys a request
// carries (as the server's ride_extra_keys), the driver filter, the
// switches on "Ride extras I take", the "Passenger added extras" check
// before an offer or Accept, the feed's "not shown" line and the admin's
// read-only list, in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/driver_extras_card.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_assistance.dart';
import 'package:get_ride/src/core/ride_extras.dart';
import 'package:get_ride/src/core/ride_option_settings.dart';
import 'package:get_ride/src/core/ride_pets.dart';
import 'package:get_ride/src/data/app_display_repository.dart' show displaySettingsBlobProvider;
import 'package:get_ride/src/data/driver_extras_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/partner/ride_extras_parts.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// A request with two dogs (M, L), a cat, a child seat, more passengers,
/// luggage help and a guide dog, under the admin's names.
final _request = RideRequest({
  'id': 'r1',
  'rider_id': 'u1',
  'status': 'open',
  'fare': 92,
  'currency': 'MYR',
  'passengers': 5,
  'pets': [
    {'type': 'Dog', 'size': 'M'},
    {'type': 'Cat'},
    {'type': 'Dog', 'size': 'L'},
  ],
  'assistance': {
    'items': [
      {'id': 'luggage', 'name': 'Help with luggage or shopping'},
      {'id': guideDogAssistanceId, 'name': 'Guide or service dog'},
    ],
  },
  'option_names': {'child-seat': 'Child safety seat', 'pet': 'Bringing a pet', 'assistance': 'Assistance required'},
});

/// The driver's row in memory.
class _FakeExtras implements DriverExtrasRepository {
  _FakeExtras([Set<String> off = const {}]) : off = {...off};
  Set<String> off;
  int hidden = 0;

  @override
  Future<Set<String>> mine() async => {...off};

  @override
  Future<Set<String>> of(String driverId) async => {...off};

  @override
  Future<void> setMine(Set<String> next) async => off = {...next};

  @override
  Future<void> turnOff(Iterable<String> keys) async => off = {...off, ...keys};

  @override
  Future<int> hiddenCount(DateTime since) async => hidden;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await _settle(tester);
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
}

void main() {
  group('pure', () {
    test("a request's extras: each pet type with its count and sizes, each kind of help, a seat, more passengers", () {
      final x = _request.extras;
      expect([for (final e in x) e.key],
          ['child-seat', 'more-passengers', 'pet:dog', 'pet:cat', 'assist:luggage'],
          reason: 'never the guide dog; the keys the server keeps');
      expect([for (final e in x) e.line], [
        'Child safety seat',
        'More than 4 passengers',
        'Bringing a pet: Dog ×2 (M, L)',
        'Bringing a pet: Cat ×1',
        'Assistance required: Help with luggage or shopping',
      ]);
      expect([for (final e in x) e.label].skip(2), ['Dog', 'Cat', 'Help with luggage or shopping']);
      expect(RideRequest({'id': 'r2', 'passengers': 1}).extras, isEmpty);
    });

    test('the driver filter: a request with an extra turned off is not taken', () {
      final x = _request.extras;
      expect(driverTakes(const {}, x), isTrue, reason: 'everything on by default');
      expect(driverTakes({'pet:rabbit'}, x), isTrue);
      expect(driverTakes({'pet:dog'}, x), isFalse);
      expect(driverTakes({'assist:luggage'}, x), isFalse);
      expect(driverTakes({'more-passengers'}, x), isFalse);
      expect(driverTakes({'assist:$guideDogAssistanceId'}, x), isTrue, reason: 'the guide dog is never an extra');
      expect(RideExtraKey.pet(' Guinea Pig '), 'pet:guinea pig');
    });

    test('the switches follow the admin: names, order, pet types and help offered; never the guide dog', () {
      final config = RideOptionsConfig.fromSettings({
        RideOptionsConfig.key: {
          'order': ['pet', 'assistance', 'child-seat', 'more-passengers'],
          'hidden': ['more-passengers'],
          'labels': {'pet': 'Bringing a pet'},
        },
      });
      final groups = rideExtraGroups(config, const PetConfig(types: ['Dog', 'Iguana']), const AssistanceCatalogue());
      expect([for (final g in groups) g.option], [RideOptionKind.pet, RideOptionKind.assistance, RideOptionKind.childSeat]);
      expect(groups.first.title, 'Bringing a pet');
      expect([for (final i in groups.first.items) i.key], ['pet:dog', 'pet:iguana']);
      expect(groups[1].items.any((i) => i.key == 'assist:$guideDogAssistanceId'), isFalse);
      expect(groups[1].items.length, defaultAssistanceItems.length - 1);
      expect(hiddenExtrasText(0), isNull);
      expect(hiddenExtrasText(1), '1 request not shown: it includes an extra you turned off.');
      expect(hiddenExtrasText(3), '3 requests not shown: they include an extra you turned off.');
      expect(
        describeExtrasOff({'pet:dog', 'child-seat', 'pet:gone'}, config, const PetConfig(types: ['Dog']),
            const AssistanceCatalogue()),
        ['Child safety seat', 'Bringing a pet: Dog', 'pet:gone'],
      );
    });
  });

  for (final b in Brightness.values) {
    final mode = b == Brightness.dark ? ' (dark)' : '';

    group('Driver$mode', () {
      Future<void> host(WidgetTester tester, Widget child, {_FakeExtras? extras}) async {
        tester.view.physicalSize = const Size(420, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(
          retry: (_, _) => null,
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            driverExtrasRepositoryProvider.overrideWithValue(extras ?? _FakeExtras()),
            displaySettingsBlobProvider.overrideWith((ref) async => {
              ...const PetConfig(types: ['Dog', 'Cat']).toSettings(),
            }),
          ],
          child: MaterialApp(theme: appTheme(b), home: Scaffold(body: child)),
        ));
        await _settle(tester);
      }

      Future<void> unmount(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 1));
      }

      testWidgets('Passenger added extras: the extras as booked, Cancel keeps the ticks', (tester) async {
        RideExtrasAnswer? answer;
        await host(
          tester,
          Builder(
            builder: (context) => Column(children: [
              TextButton(
                key: const ValueKey('offer'),
                onPressed: () async => answer = await askRideExtras(context, _request, accepting: false),
                child: const Text('Offer'),
              ),
              TextButton(
                key: const ValueKey('accept'),
                onPressed: () async => answer = await askRideExtras(context, _request, accepting: true),
                child: const Text('Accept'),
              ),
              TextButton(
                key: const ValueKey('plain'),
                onPressed: () async =>
                    answer = await askRideExtras(context, RideRequest({'id': 'x', 'passengers': 1}), accepting: true),
                child: const Text('Plain'),
              ),
            ]),
          ),
        );
        // An offer: "Offer fare"; each extra, and a box to stop showing it.
        await _tapKey(tester, 'offer');
        expect(find.text('Passenger added extras'), findsOneWidget);
        expect(find.text('Bringing a pet: Dog ×2 (M, L)'), findsOneWidget);
        expect(find.text('Assistance required: Help with luggage or shopping'), findsOneWidget);
        expect(find.textContaining('Guide'), findsNothing);
        expect(find.text('Offer fare'), findsOneWidget);
        expect(find.text('Stop showing Dog rides'), findsOneWidget);
        await _tapKey(tester, 'ride-extras-stop-pet:dog');
        await _tapKey(tester, 'ride-extras-cancel');
        expect(answer!.go, isFalse);
        expect(answer!.stop, {'pet:dog'}, reason: 'the tick is kept on Cancel');

        // Accept: "Accept"; nothing ticked, on.
        await _tapKey(tester, 'accept');
        expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
        await _tapKey(tester, 'ride-extras-stop-assist:luggage');
        await _tapKey(tester, 'ride-extras-go');
        expect(answer!.go, isTrue);
        expect(answer!.stop, {'assist:luggage'});

        // A tap outside is Cancel, with the ticks.
        await _tapKey(tester, 'offer');
        await _tapKey(tester, 'ride-extras-stop-more-passengers');
        await tester.tapAt(const Offset(5, 5));
        await _settle(tester);
        expect(find.byKey(const ValueKey('ride-extras-dialog')), findsNothing);
        expect(answer!.go, isFalse);
        expect(answer!.stop, {'more-passengers'});

        // No extras: no popup.
        await _tapKey(tester, 'plain');
        expect(find.byKey(const ValueKey('ride-extras-dialog')), findsNothing);
        expect(answer, isNull);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });

      testWidgets('Ride extras I take: all on, turned off one by one, saved', (tester) async {
        final extras = _FakeExtras({'pet:cat'});
        await host(tester, const RideExtrasScreen(), extras: extras);
        Switch sw(String key) =>
            tester.widget<Switch>(find.descendant(of: find.byKey(ValueKey('ride-extra-$key')), matching: find.byType(Switch)));
        expect(sw('pet:dog').value, isTrue);
        expect(sw('pet:cat').value, isFalse);
        expect(find.byKey(const ValueKey('ride-extra-assist:$guideDogAssistanceId')), findsNothing);
        await tester.ensureVisible(find.byKey(const ValueKey('ride-extra-pet:dog')));
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('ride-extra-pet:dog')), matching: find.byType(Switch)));
        await _settle(tester);
        expect(extras.off, {'pet:cat', 'pet:dog'});
        await tester.ensureVisible(find.byKey(const ValueKey('ride-extra-pet:cat')));
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('ride-extra-pet:cat')), matching: find.byType(Switch)));
        await _settle(tester);
        expect(extras.off, {'pet:dog'});
        expect(sw('pet:cat').value, isTrue);
        // A child seat alone: "I take these".
        expect(find.descendant(of: find.byKey(const ValueKey('ride-extra-child-seat')), matching: find.text('I take these')),
            findsOneWidget);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });

      testWidgets("the feed's line, and the admin's read-only list", (tester) async {
        final extras = _FakeExtras({'pet:dog', 'child-seat'})..hidden = 1;
        await host(
          tester,
          const Column(children: [HiddenExtrasLine(feed: 'r1'), DriverExtrasOffCard(driverId: 'd1')]),
          extras: extras,
        );
        expect(find.text('1 request not shown: it includes an extra you turned off.'), findsOneWidget);
        expect(find.text('Child safety seat'), findsOneWidget);
        expect(find.text('Pet with me: Dog'), findsOneWidget);
        expect(find.byType(Switch), findsNothing, reason: 'read only');
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });

      testWidgets('nothing turned off: no line, and "None"', (tester) async {
        await host(tester, const Column(children: [HiddenExtrasLine(), DriverExtrasOffCard(driverId: 'd1')]));
        expect(find.byKey(const ValueKey('hidden-extras-line')), findsNothing);
        expect(find.byKey(const ValueKey('driver-extras-off-none')), findsOneWidget);
        await unmount(tester);
      });
    });
  }
}
