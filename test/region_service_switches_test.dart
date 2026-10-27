import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/admin/screens/geo/regions_screen.dart';
import 'package:get_ride/src/core/region_service_switches.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/core/service_tree.dart';
import 'package:get_ride/src/features/ride/service_not_offered.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// The same made-up catalogue and places as
// supabase/tests/region_service_switches_0302.sql, so the app's resolver
// and the server's answer alike:
//   Car: Ride, Premium (and XL under Premium); Food: Courier.
const _car = 'car', _food = 'food', _ride = 'ride', _premium = 'premium', _xl = 'xl', _courier = 'courier';

final _tree = ServiceTree.build(
  const [
    ServiceEntry(id: _car, name: 'Car', category: masterServiceCategory),
    ServiceEntry(id: _food, name: 'Food', category: masterServiceCategory),
  ],
  const [
    ServiceEntry(id: _ride, name: 'Ride', category: 'vehicle-services', typeNames: ['Car']),
    ServiceEntry(id: _premium, name: 'Premium', category: 'vehicle-services', typeNames: ['Car']),
    ServiceEntry(id: _xl, name: 'XL', category: 'vehicle-services', parentIds: [_premium]),
    ServiceEntry(id: _courier, name: 'Courier', category: 'vehicle-services', typeNames: ['Food']),
  ],
);

bool _isMaster(String id) => id == _car || id == _food;

/// Offered at a place whose regions' values are [values], most specific first.
bool _offered(String id, List<Map<String, dynamic>> values) =>
    serviceOffered(_tree.lineage(id), [for (final v in values) ServiceSwitchLevel.fromValues(v)], isMaster: _isMaster);

// Switchland: Car on in the country, the state inherits, Premium off in the
// city, on again in a suburb.
final _switchland = {
  'serviceSwitches': {_car: 'on'},
  'services': jsonEncode({_car: true}),
};
const _midstate = <String, dynamic>{};
const _offtown = {
  'subServices': {_premium: false},
};
const _backon = {
  'subServices': {_premium: true},
};
// Listland: a list from before switches; a state switching Food off.
final _listland = {
  'services': jsonEncode({_car: true, _food: true}),
};
const _nofood = {
  'serviceSwitches': {_food: 'off'},
};
// Oldland: lists only.
final _oldland = {
  'services': jsonEncode({_car: true, _food: false}),
};
const _oldstate = {'services': '{}'};
final _foodtown = {
  'services': jsonEncode({_food: true}),
};

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Repo extends GeoAdminRepository {
  _Repo(this.entries, {this.check}) : super(_db);
  final List<RegionEntry> entries;
  RegionServiceCheck? check;
  final saved = <Map<String, dynamic>>[];
  final modes = <RegionCheckMode>[];

  @override
  Future<List<RegionEntry>> regions() async => entries;
  @override
  Future<List<ServiceOption>> services() async =>
      const [ServiceOption(id: _car, name: 'Car'), ServiceOption(id: _food, name: 'Food')];
  @override
  Future<ServiceTree> serviceTree() async => _tree;
  @override
  Future<void> saveRegion({String? id, required Map<String, dynamic> values, int position = 0}) async =>
      saved.add(values);
  @override
  Future<RegionServiceCheck> regionServiceCheck() async => check ?? (throw StateError('not there'));
  @override
  Future<void> setRegionServiceCheck(RegionCheckMode mode) async {
    modes.add(mode);
    check = RegionServiceCheck(mode: mode, canEdit: true, day: check!.day, week: check!.week, month: check!.month);
  }
}

void main() {
  group('the resolver (as service_offered_at, 0302)', () {
    test('country on, state inherit, city off; a suburb turns it on again', () {
      expect(_offered(_premium, [_midstate, _switchland]), isTrue, reason: 'Car on in the country, the state inherits');
      expect(_offered(_premium, [_offtown, _midstate, _switchland]), isFalse, reason: 'Premium off in the city');
      expect(_offered(_xl, [_offtown, _midstate, _switchland]), isFalse, reason: 'XL is under Premium');
      expect(_offered(_ride, [_offtown, _midstate, _switchland]), isTrue);
      expect(_offered(_xl, [_backon, _offtown, _midstate, _switchland]), isTrue, reason: 'Premium on again in the suburb');
      expect(_offered(_courier, [_switchland]), isTrue, reason: 'Food set nowhere: On (the country default)');
    });

    test('an explicit Off beats the list above it', () {
      expect(_offered(_courier, [_listland]), isTrue);
      expect(_offered(_courier, [_nofood, _listland]), isFalse);
      expect(_offered(_ride, [_nofood, _listland]), isTrue, reason: 'Car left to the country\'s list');
    });

    test('a list from before switches offers only those', () {
      expect(_offered(_ride, [_oldstate, _oldland]), isTrue, reason: 'the state\'s empty list follows the country');
      expect(_offered(_courier, [_oldland]), isFalse);
      expect(_offered(_courier, [_foodtown, _oldstate, _oldland]), isTrue, reason: 'the city\'s own list wins');
      expect(_offered(_ride, [_foodtown, _oldstate, _oldland]), isFalse);
    });

    test('nothing set, or no regions: On', () {
      expect(_offered(_premium, [<String, dynamic>{}]), isTrue);
      expect(_offered(_premium, const []), isTrue);
    });

    test('one region at a time, as region_service_resolve', () {
      ServiceSwitchLevel l(Map<String, dynamic> v) => ServiceSwitchLevel.fromValues(v);
      expect(
        resolveServiceSwitch('x', [l({'subServices': {'x': false}}), l({'subServices': {'x': true}})], master: false).on,
        isFalse,
      );
      final up = resolveServiceSwitch('m', [l({}), l({'serviceSwitches': {'m': 'off'}})], master: true);
      expect([up.on, up.level], [false, 1]);
      expect(
        resolveServiceSwitch('o', [l({'services': '{"m":true}', 'serviceSwitches': {'n': 'on'}})], master: true).on,
        isTrue,
        reason: 'a region with switches: its list is for older apps only',
      );
      expect(resolveServiceSwitch('m', [l({'services': '{"m":true}'})], master: false).on, isTrue,
          reason: 'a list says nothing about sub-services');
      expect(resolveServiceSwitch('m', [l({'serviceSwitches': 'not json'})], master: true).on, isTrue);
      final none = resolveServiceSwitch('m', const [], master: true);
      expect([none.on, none.level], [true, null]);
    });

    test('the rider app reads the switches from a region row, as the server does', () {
      final regions = [
        BiddingRegion.fromValues({'country': 'Switchland', ..._switchland})!,
        BiddingRegion.fromValues({'country': 'Switchland', 'state': 'Midstate', 'city': 'Offtown', ..._offtown})!,
        BiddingRegion.fromValues({'country': 'Switchland', 'state': 'Midstate', 'city': 'Offtown', 'suburb': 'X', 'serviceSwitches': '{"food":"off"}'})!,
      ];
      final ctx = RegionRuleContext([regions[2], regions[1], regions[0]]);
      final now = DateTime.utc(2026, 10, 27, 3);
      expect(ctx.available(types: {_car}, vehicleType: _premium, lineage: _tree.lineage(_premium), nowUtc: now), isFalse);
      expect(ctx.available(types: {_car}, vehicleType: _ride, lineage: _tree.lineage(_ride), nowUtc: now), isTrue);
      expect(ctx.available(types: {_food}, vehicleType: _courier, lineage: _tree.lineage(_courier), nowUtc: now), isFalse,
          reason: 'Food off in the suburb (stored as a JSON string)');
      expect(ctx.available(types: {_food}, masterIds: {_car, _food}, nowUtc: now), isFalse, reason: 'the Food box');
    });
  });

  group('saving', () {
    test('older apps get the list of what is on here; a region from before turns into switches', () {
      final f = RegionForm.fromEntry(RegionEntry(id: 'x', values: {
        'country': 'Oldland',
        'services': jsonEncode({_car: true}),
      }));
      expect(f.switchLevel().legacyList, isTrue);
      f.setMasterSwitch(_food, ServiceSwitch.inherit, [_car, _food]);
      expect(f.serviceSwitches, {_car: true}, reason: 'Car on as listed; Food, set to Inherit, inherits');
      f.settleServicesForOlderApps([_car, _food], const []);
      final v = f.toValues();
      expect(v['serviceSwitches'], {_car: 'on'});
      expect(jsonDecode(v['services'] as String), {_car: true, _food: true}, reason: 'Food inherits On here now');

      final state = RegionForm(country: 'Switchland', state: 'Midstate');
      state.setMasterSwitch(_food, ServiceSwitch.off, [_car, _food]);
      state.settleServicesForOlderApps([_car, _food], [ServiceSwitchLevel.fromValues(_switchland, name: 'Switchland')]);
      expect(jsonDecode(state.toValues()['services'] as String), {_car: true},
          reason: 'not "Food only": older apps read a non-empty list as all that is offered');
      state.setMasterSwitch(_food, ServiceSwitch.inherit, [_car, _food]);
      state.settleServicesForOlderApps([_car, _food], const []);
      expect([state.toValues()['services'], state.toValues()['serviceSwitches']], ['{}', <String, String>{}],
          reason: 'all Inherit: follows its parent, in old apps too');
    });

    test('where each service\'s answer comes from', () {
      final above = [
        const ServiceSwitchLevel(name: 'Selangor', switches: {_car: false}),
        const ServiceSwitchLevel(name: 'Malaysia'),
      ];
      final here = const ServiceSwitchLevel(switches: {_food: true});
      final levels = [here, ...above];
      expect(serviceSwitchSource(resolveServiceSwitch(_car, levels, master: true), above), 'Off (from Selangor)');
      expect(serviceSwitchSource(resolveServiceSwitch(_food, levels, master: true), above), 'On (set here)');
      expect(serviceSwitchSource(resolveServiceSwitch('bike', levels, master: true), above), 'On (default)');
      final entries = [
        RegionEntry(id: 'c', values: {'country': 'Malaysia', 'state': '', 'city': '', 'suburb': '', 'serviceSwitches': {_car: 'off'}}),
        RegionEntry(id: 's', values: {'country': 'Malaysia', 'state': 'Selangor', 'city': '', 'suburb': ''}),
      ];
      final got = regionLevelsAbove(entries, RegionLevel.city, country: 'Malaysia', state: 'Selangor', city: 'Kajang');
      expect([for (final l in got) l.name], ['Selangor', 'Malaysia']);
      expect(got.last.switches, {_car: false});
    });
  });

  test('the server\'s refusal reads as its modal', () {
    const e = 'PostgrestException(message: SERVICE_NOT_OFFERED_HERE, code: 22023, details: Bad Request, '
        "hint: Premium isn't offered for pickups in Kajang. Choose another service for this trip.)";
    final r = serviceNotOfferedOf(e)!;
    expect(r.title, "Premium isn't offered here");
    expect(r.message, "Premium isn't offered for pickups in Kajang. Choose another service for this trip.");
    expect(serviceNotOfferedOf('PostgrestException(message: SERVICE_NOT_OFFERED_HERE, hint: null)', service: 'Comfort')!.title,
        "Comfort isn't offered here");
    expect(serviceNotOfferedOf('PostgrestException(message: RIDE_OPTION_NOT_OFFERED)'), isNull);
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    final theme = ThemeData(brightness: dark ? Brightness.dark : Brightness.light);

    Future<_Repo> pump(WidgetTester tester, {RegionServiceCheck? check, bool edit = true}) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _Repo([
        RegionEntry(id: 'c1', values: {
          'country': 'Switchland', 'state': '', 'city': '', 'suburb': '', ..._switchland,
        }),
        RegionEntry(id: 's1', values: {'country': 'Switchland', 'state': 'Midstate', 'city': '', 'suburb': '',
          'subServices': {_premium: false}}),
      ], check: check);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            adminAccessProvider.overrideWith(
                (_) async => AdminAccess([AdminGrant(page: edit ? '*' : regionsPage, edit: edit)])),
            geoAdminRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(theme: theme, home: const AdminRegionsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('Inherit / On / Off for each service, with what holds and where from ($mode)', (tester) async {
      final repo = await pump(tester);
      await tester.tap(find.text('Switchland'));
      await tester.pumpAndSettle();
      // The Edit button spins while its sheet is open: no settling.
      Future<void> settle() async {
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
      }

      await tester.tap(find.byTooltip('Edit').first);
      await settle();

      String status(String id) => tester.widget<Text>(find.byKey(ValueKey('region-switch-status-$id'))).data!;
      expect(status(_car), 'On (from Switchland)');
      expect(status(_food), 'On (default)');
      expect(status(_premium), 'Off (set here)');
      expect(status(_xl), 'Off (under Premium, which is off)');
      for (final s in ServiceSwitch.values) {
        expect(find.descendant(of: find.byKey(const ValueKey('region-switch-$_car')), matching: find.text(s.label)),
            findsOneWidget);
      }

      Future<void> pick(String id, String label) async {
        final f = find.descendant(of: find.byKey(ValueKey('region-switch-$id')), matching: find.text(label));
        await tester.ensureVisible(f);
        await tester.tap(f);
        await settle();
      }

      await pick(_food, 'Off');
      expect(status(_food), 'Off (set here)');
      expect(status(_courier), 'Off (under Food, which is off)');
      await pick(_premium, 'Inherit');
      expect(status(_premium), 'On (default)');
      await tester.ensureVisible(find.text('Update'));
      await tester.tap(find.text('Update'));
      await settle();
      final v = repo.saved.single;
      expect(v['serviceSwitches'], {_food: 'off'});
      expect(v['subServices'], <String, bool>{});
      expect(jsonDecode(v['services'] as String), {_car: true}, reason: 'for older apps: what is on here');
      await _drain(tester);
    });

    testWidgets('the Service check: three choices, what each does, counts and the latest ($mode)', (tester) async {
      final repo = await pump(tester, check: RegionServiceCheck(
        canEdit: true,
        day: 1,
        week: 3,
        month: 9,
        recent: [
          RegionCheckRow(at: DateTime.utc(2026, 10, 27, 2), service: 'Premium', place: 'Offtown, Midstate, Switchland'),
        ],
      ));
      expect(find.byKey(const ValueKey('region-service-check')), findsOneWidget);
      expect(find.textContaining('Record only: a booking'), findsOneWidget);
      expect(find.text('Recorded: 1 in 24 hours · 3 in 7 days · 9 in 30 days'), findsOneWidget);
      await tester.tap(find.text('Latest recorded (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Premium'), findsOneWidget);
      expect(find.textContaining('Offtown, Midstate, Switchland'), findsOneWidget);

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('region-service-check-mode')), matching: find.text('Refuse')));
      await tester.pumpAndSettle();
      expect(repo.modes, [RegionCheckMode.refuse]);
      expect(find.textContaining("Refusals aren't listed"), findsOneWidget);
      await tester.tap(find.text('OK').last);
      await tester.pumpAndSettle();
      await _drain(tester);
    });

    testWidgets('without EDIT on Regions the check is shown, not changed ($mode)', (tester) async {
      final repo = await pump(tester, edit: false, check: const RegionServiceCheck(mode: RegionCheckMode.off));
      expect(find.textContaining("Off: the server doesn't check"), findsOneWidget);
      expect(find.text('Only an admin who can edit Regions can change it.'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('region-service-check-mode')), matching: find.text('Refuse')));
      await tester.pumpAndSettle();
      expect(repo.modes, isEmpty);
      await _drain(tester);
    });

    testWidgets('the rider is told the service isn\'t offered here, with an OK ($mode)', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold();
        }),
      ));
      expect(showServiceNotOffered(ctx, StateError('network'), service: 'Premium'), isFalse);
      expect(
        showServiceNotOffered(
          ctx,
          const PostgrestException(
            message: 'SERVICE_NOT_OFFERED_HERE',
            code: '22023',
            hint: "Premium isn't offered for pickups in Kajang. Choose another service for this trip.",
          ),
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('service-not-offered')), findsOneWidget);
      expect(find.text("Premium isn't offered here"), findsOneWidget);
      expect(find.text("Premium isn't offered for pickups in Kajang. Choose another service for this trip."), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('service-not-offered')), findsNothing);
    });
  }
}

/// Lets the success note and any realtime retry run out.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}
