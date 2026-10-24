import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/partner_onboarding.dart';
import 'package:get_ride/src/core/partner_type_rules.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/core/app_display.dart' show AppDisplay;
import 'package:get_ride/src/data/app_display_repository.dart' show appDisplayProvider;
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/partner_onboarding_repository.dart';
import 'package:get_ride/src/data/partner_type_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/data/vehicle_onboarding_repository.dart';
import 'package:get_ride/src/features/partner/partner_onboarding_screen.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/features/partner/vehicle_screens.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _now = DateTime(2026, 10, 19);

const _selangor = ServiceArea(
  countries: ['Malaysia'],
  states: ['Malaysia|Selangor'],
  cities: ['Malaysia|Selangor|Ampang'],
);
const _johor = ServiceArea(countries: ['Malaysia'], states: ['Malaysia|Johor'], cities: ['Malaysia|Johor|Muar']);

/// eHailing: 15 years everywhere, 10 in Selangor; offered in Selangor only.
/// Teksi: a permit in Selangor; street hail in Selangor only.
final _entries = <Map<String, dynamic>>[
  {
    'name': 'eHailing',
    'vehicleRequired': true,
    'rules': {
      'vehicleAge': {
        'required': true,
        'rules': [
          {'maxYears': 15},
          {'country': 'Malaysia', 'state': 'Selangor', 'maxYears': 10},
        ],
      },
      'availability': {
        'all': false,
        'regions': [
          {'country': 'Malaysia', 'state': 'Selangor'},
        ],
      },
    },
  },
  {
    'name': 'Teksi',
    'vehicleRequired': true,
    'rules': {
      'permit': {
        'required': true,
        'all': false,
        'regions': [
          {'country': 'Malaysia', 'state': 'Selangor'},
        ],
      },
      'hail': {
        'allowed': true,
        'all': false,
        'regions': [
          {'country': 'Malaysia', 'state': 'Selangor'},
        ],
      },
    },
  },
  {'name': 'Dealer'},
];

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

class _NoTrip implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('rules (pure)', () {
    test('defaults keep today\'s behaviour', () {
      final e = EffectiveTypeRules.of('eHailing', [
        {'name': 'eHailing', 'vehicleRequired': true},
      ]);
      expect(e.ageRequired, isFalse);
      expect(e.permitRequired, isFalse);
      expect(e.hailOn, isFalse, reason: 'street hail stays TEKSI\'s');
      expect(e.availableIn(_johor), isTrue);
      expect(EffectiveTypeRules.of('Teksi', const []).hailOn, isTrue);
      expect(EffectiveTypeRules.of('Teksi', const []).vehicleRequired, isTrue);
      expect(EffectiveTypeRules.of('Unknown', const []).availableIn(_selangor), isTrue);
      expect(vehicleAgeProblem(types: ['eHailing'], year: '1990', area: _selangor, entries: const [], now: _now), isNull);
    });

    test('the narrowest age rule wins, and the reason names it', () {
      final e = EffectiveTypeRules.of('eHailing', _entries);
      expect(e.vehicleAgeProblem('2014', _selangor, now: _now),
          'Vehicles for eHailing in Selangor must be at most 10 years old (this one is 12).');
      expect(e.vehicleAgeProblem('2014', _johor, now: _now), isNull, reason: '15 years outside Selangor');
      expect(e.vehicleAgeProblem('2010', _johor, now: _now),
          'Vehicles for eHailing must be at most 15 years old (this one is 16).');
      expect(e.vehicleAgeProblem('', _selangor, now: _now), contains("Enter the vehicle's year"));
      expect(e.vehicleAgeProblem('', _selangor, now: _now, strict: false), isNull);
    });

    test('a vehicle fit for one of the partner\'s types is accepted', () {
      expect(vehicleAgeProblem(types: ['eHailing', 'Teksi'], year: '2014', area: _selangor, entries: _entries, now: _now),
          isNull);
      expect(vehicleAgeProblem(types: ['eHailing', 'Dealer'], year: '2014', area: _selangor, entries: _entries, now: _now),
          contains('at most 10 years old'));
    });

    test('a type without "Vehicle required" ignores the vehicle rules', () {
      final entries = [
        {..._entries.first, 'vehicleRequired': false},
      ];
      expect(EffectiveTypeRules.of('eHailing', entries).ageRequired, isFalse);
      expect(EffectiveTypeRules.of('eHailing', entries).availableIn(_johor), isFalse,
          reason: 'availability applies to every type');
    });

    test('availability filters the types offered in a service area', () {
      expect(partnerTypesAvailableIn(['Teksi', 'eHailing', 'Dealer'], _entries, _johor), ['Teksi', 'Dealer']);
      expect(partnerTypesAvailableIn(['Teksi', 'eHailing', 'Dealer'], _entries, _selangor), ['Teksi', 'eHailing', 'Dealer']);
    });

    test('street hail where allowed, and not refused where the place is unknown', () {
      final t = EffectiveTypeRules.of('Teksi', _entries);
      expect(t.hailAt((country: 'Malaysia', state: 'Selangor', city: 'Ampang', suburb: '')), isTrue);
      expect(t.hailAt((country: 'Malaysia', state: 'Johor', city: '', suburb: '')), isFalse);
      expect(t.hailAt(unknownPlace), isTrue);
    });

    test('a permit required in the service area makes the permit document compulsory', () {
      final docs = [
        (id: 'lic', values: <String, dynamic>{'name': 'Driving licence'}),
        (
          id: 'permit',
          values: <String, dynamic>{
            'name': 'Driver Permit',
            'isTaxiPermit': true,
            'required': false,
            'regionsGlobalCompulsory': false,
          },
        ),
      ];
      final inSelangor = requiredDocsFor(
        requiredDocuments: docs,
        partnerTypeValues: _entries,
        partnerTypes: ['Teksi'],
        area: _selangor,
      );
      final permit = inSelangor.firstWhere((d) => d.id == 'permit');
      expect(permit.compulsory, isTrue);
      expect(permit.labels, contains('Required for Teksi in Selangor'));
      final inJohor = requiredDocsFor(
        requiredDocuments: docs,
        partnerTypeValues: _entries,
        partnerTypes: ['Teksi'],
        area: _johor,
      );
      expect(inJohor.firstWhere((d) => d.id == 'permit').compulsory, isFalse, reason: 'its own rule: optional');
    });

    test('service area places: cities, then states and countries with nothing below them', () {
      expect(areaPlaces(const ServiceArea()), [unknownPlace]);
      expect(
        areaPlaces(const ServiceArea(
          countries: ['Malaysia', 'Singapore'],
          states: ['Malaysia|Selangor', 'Malaysia|Johor'],
          cities: ['Malaysia|Selangor|Ampang'],
        )),
        [
          (country: 'Malaysia', state: 'Selangor', city: 'Ampang', suburb: ''),
          (country: 'Malaysia', state: 'Johor', city: '', suburb: ''),
          (country: 'Singapore', state: '', city: '', suburb: ''),
        ],
      );
    });

    test('validation: 1 to 50 years; "required" needs a rule or a region', () {
      const ok = PartnerTypeRules();
      expect(ok.problem(vehicleRequired: true), isNull);
      expect(const PartnerTypeRules(ageRequired: true).problem(vehicleRequired: true), contains('Add at least one'));
      expect(const PartnerTypeRules(ageRequired: true).problem(vehicleRequired: false), isNull);
      for (final y in [0, 51]) {
        expect(PartnerTypeRules(ageRequired: true, ageRules: [AgeRule(maxYears: y)]).problem(vehicleRequired: true),
            'A vehicle age limit is 1 to 50 years.');
      }
      expect(
        const PartnerTypeRules(ageRequired: true, ageRules: [AgeRule(maxYears: 5), AgeRule(maxYears: 7)])
            .problem(vehicleRequired: true),
        contains('Two vehicle age rules are for All regions'),
      );
      expect(const PartnerTypeRules(permitRequired: true, permitRegions: RegionList(all: false))
          .problem(vehicleRequired: true), contains('permit'));
      expect(const PartnerTypeRules(hailAllowed: true, hailRegions: RegionList(all: false))
          .problem(vehicleRequired: true), contains('street hail'));
      expect(const PartnerTypeRules(availability: RegionList(all: false)).problem(vehicleRequired: false),
          contains('offered'));
    });

    test('rules survive a round trip, and string-stored lists are read', () {
      final r = PartnerTypeRules.fromValues(_entries.first);
      final back = PartnerTypeRules.fromValues({'rules': r.toJson()});
      expect(back.toJson(), r.toJson());
      final fromString = PartnerTypeRules.fromValues({
        'rules': '{"availability":{"all":false,"regions":"[{\\"country\\":\\"Malaysia\\"}]"}}',
      });
      expect(fromString.availability.regions.single.country, 'Malaysia');
    });

    test('the server\'s verdict is read; unreadable is no verdict', () {
      final c = PartnerTypeCheck.fromJson({'ok': false, 'reason': 'eHailing is not offered in Johor.', 'hail': false});
      expect(c.ok, isFalse);
      expect(c.reason, 'eHailing is not offered in Johor.');
      expect(c.hailBlocked, isTrue);
      expect(PartnerTypeCheck.fromJson(null).ok, isTrue);
      expect(PartnerTypeCheck.fromJson({'ok': true, 'hail': null}).hailBlocked, isFalse);
    });

    test('a vehicle refused for its age says why when it is taken', () {
      final e = PostgrestException(
        message: 'vehicle_too_old',
        hint: 'Vehicles for eHailing in Selangor must be at most 10 years old (this one is 12).',
      );
      expect(claimVehicleErrorMessage(e), 'Vehicles for eHailing in Selangor must be at most 10 years old (this one is 12).');
    });
  });

  for (final b in Brightness.values) {
    group('driver (${b.name})', () {
      testWidgets('an old vehicle is refused at the year step, with the reason', (tester) async {
        final repo = _Vehicles();
        await _pumpVehicle(tester, repo, b);
        expect(find.text('Year and colour'), findsOneWidget);
        await tester.enterText(find.widgetWithText(TextField, 'Year'), '${DateTime.now().year - 12}');
        await tester.enterText(find.widgetWithText(TextField, 'Colour'), 'White');
        await tester.tap(find.text('Save and continue'));
        for (var i = 0; i < 4; i++) {
          await tester.pump();
        }
        expect(find.text('Vehicles for eHailing in Selangor must be at most 10 years old (this one is 12).'), findsOneWidget);
        expect(repo.patches, isEmpty);

        await tester.enterText(find.widgetWithText(TextField, 'Year'), '${DateTime.now().year - 3}');
        await tester.tap(find.text('Save and continue'));
        for (var i = 0; i < 4; i++) {
          await tester.pump();
        }
        expect(repo.patches.single, {'year': '${DateTime.now().year - 3}', 'color': 'White'});
      });

      testWidgets('a type not offered in the service area is not offered at sign-up', (tester) async {
        await _pumpOnboarding(tester, b);
        expect(find.text('What kind of partner are you?'), findsOneWidget);
        expect(find.widgetWithText(FilterChip, 'Teksi'), findsOneWidget);
        expect(find.widgetWithText(FilterChip, 'eHailing'), findsNothing);
      });

      testWidgets('street hail (the Meter) is hidden where it is not allowed', (tester) async {
        await _pumpDrive(tester, b, check: const PartnerTypeCheck(hail: false));
        expect(find.byTooltip('Meter Digital'), findsNothing);
        expect(find.byTooltip('Driver permit'), findsOneWidget);
      });

      testWidgets('street hail (the Meter) shows where it is allowed', (tester) async {
        await _pumpDrive(tester, b, check: const PartnerTypeCheck(hail: true));
        expect(find.byTooltip('Meter Digital'), findsOneWidget);
      });

      testWidgets('going online where the type is not offered is refused, with the reason', (tester) async {
        await _pumpDrive(
          tester,
          b,
          types: ['eHailing'],
          check: const PartnerTypeCheck(ok: false, reason: 'eHailing is not offered in Muar.'),
        );
        await tester.tap(find.text('You are offline'));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.byKey(const ValueKey('type-rules-blocked')), findsOneWidget);
        expect(find.text('eHailing is not offered in Muar.'), findsOneWidget);
        await tester.tap(find.text('OK'));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('You are offline'), findsOneWidget);
      });
    });
  }
}

// ---- Vehicle wizard ------------------------------------------------------------------------

const _partner = {
  'id': 'p1',
  'auth_user_id': 'u1',
  'name': 'Aina',
  'phone': '+60123',
  'ic': '900101-14-5555',
  'partner_types': ['eHailing'],
  'service_countries': ['Malaysia'],
  'service_states': ['Malaysia|Selangor'],
  'service_cities': ['Malaysia|Selangor|Ampang'],
  'documents_ok': true,
};

class _Onboarding extends PartnerOnboardingRepository {
  _Onboarding([this.partner = _partner]) : super(_db);
  final Map<String, dynamic> partner;
  @override
  Future<OnboardingState> load({bool mayStart = true}) async => OnboardingState(profile: const {}, partner: partner);
}

class _Vehicles extends VehicleOnboardingRepository {
  _Vehicles() : super(_db);
  final patches = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>?> vehicle(String id) async =>
      {'id': 'v1', 'plate': 'WXY 1', 'make': 'Proton', 'model': 'Saga', 'status': 'unapproved'};

  @override
  Future<List<Map<String, dynamic>>> myVehicles(String partnerId) async => const [];

  @override
  Future<Map<String, dynamic>> patch(Map<String, dynamic> v, Map<String, dynamic> patch) async {
    patches.add(patch);
    return {...v, ...patch};
  }
}

class _People extends PeopleRepository {
  _People() : super(_db);

  @override
  Future<GeoOptions> geoOptions({Iterable<ServiceArea> inUse = const []}) async => const GeoOptions(
        countries: ['Malaysia'],
        states: ['Malaysia|Johor'],
        cities: ['Malaysia|Johor|Muar'],
      );

  @override
  Future<List<({String id, Map<String, dynamic> values})>> partnerTypes() async => [
        for (final (i, e) in _entries.indexed) (id: 't$i', values: e),
      ];

  @override
  Future<List<({String id, Map<String, dynamic> values})>> requiredDocuments() async => const [];

  @override
  Future<List<({String id, Map<String, dynamic> values})>> documentTypes() async => const [];

  @override
  Future<List<Map<String, dynamic>>> providerDocuments(String partnerId) async => const [];

  @override
  Future<List<Map<String, dynamic>>> vehicleDocuments(String vehicleId) async => const [];
}

Future<void> _pumpVehicle(WidgetTester tester, _Vehicles repo, Brightness b) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      partnerOnboardingRepositoryProvider.overrideWithValue(_Onboarding()),
      vehicleOnboardingRepositoryProvider.overrideWithValue(repo),
      peopleRepositoryProvider.overrideWithValue(_People()),
      liveTablesProvider.overrideWith(_QuietLive.new),
    ],
    child: MaterialApp(theme: appTheme(b), home: const VehicleOnboardingScreen(vehicleId: 'v1')),
  ));
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpOnboarding(WidgetTester tester, Brightness b) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final partner = {
    ..._partner,
    'status': 'unapproved',
    'avatar_url': 'https://example.com/a.png',
    'address': 'Jalan 1, Muar',
    'service_states': ['Malaysia|Johor'],
    'service_cities': ['Malaysia|Johor|Muar'],
    'partner_types': <String>[],
    'documents_ok': false,
  };
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      partnerOnboardingRepositoryProvider.overrideWithValue(_Onboarding(partner)),
      peopleRepositoryProvider.overrideWithValue(_People()),
      partnerProvider.overrideWith((_) async => null),
      appDisplayProvider.overrideWith((_) async => const AppDisplay()),
      liveTablesProvider.overrideWith(_QuietLive.new),
    ],
    child: MaterialApp(theme: appTheme(b), home: const PartnerOnboardingScreen()),
  ));
  await tester.pump();
  await tester.pump();
}

// ---- Drive screen -----------------------------------------------------------------------------

Future<void> _pumpDrive(
  WidgetTester tester,
  Brightness b, {
  required PartnerTypeCheck check,
  List<String> types = const ['Teksi'],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(700, 1400);
  addTearDown(tester.view.reset);
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        partnerProvider.overrideWith(
          (ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali', 'partner_types': types}),
        ),
        rideRepositoryProvider.overrideWithValue(_NoTrip()),
        openRequestsProvider.overrideWith((ref) => const Stream<List<RideRequest>>.empty()),
        assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
        partnerTypeEntriesProvider.overrideWith(
          (ref) async => [
            (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
            (id: 't', values: <String, dynamic>{'name': 'Teksi', 'vehicleRequired': false}),
          ],
        ),
        partnerDocCheckProvider.overrideWithValue((partner, {required teksi}) async => const []),
        partnerTypeCheckerProvider.overrideWithValue(({lat, lng, required teksi}) async => check),
        liveTablesProvider.overrideWith(_QuietLive.new),
      ],
      child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}
