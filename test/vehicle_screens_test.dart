import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/partner_onboarding_repository.dart';
import 'package:get_ride/src/data/vehicle_onboarding_repository.dart';
import 'package:get_ride/src/features/partner/vehicle_screens.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the first test.
final _db = SupabaseClient(
  'http://localhost',
  'anon',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

const _partner = {
  'id': 'p1',
  'display_id': 'PR-1',
  'auth_user_id': 'u1',
  'name': 'Aina',
  'phone': '+60123',
  'ic': '900101-14-5555',
  'partner_types': ['Teksi'],
  'service_countries': ['Malaysia'],
  'service_states': ['Malaysia|Selangor'],
  'service_cities': ['Malaysia|Selangor|Ampang'],
  'documents_ok': true,
};

class _FakeOnboarding extends PartnerOnboardingRepository {
  _FakeOnboarding() : super(_db);
  @override
  Future<OnboardingState> load() async => const OnboardingState(profile: {}, partner: _partner);
}

class _FakeVehicles extends VehicleOnboardingRepository {
  _FakeVehicles({this.existing, this.taken = false}) : super(_db);
  final Map<String, dynamic>? existing;
  final bool taken;
  final patches = <Map<String, dynamic>>[];
  String? startedWith;

  @override
  Future<Map<String, dynamic>?> vehicle(String id) async => existing;

  @override
  Future<List<Map<String, dynamic>>> myVehicles(String partnerId) async => [?existing];

  @override
  Future<Map<String, dynamic>> startWithPlate(String plate, Map<String, dynamic> partner) async {
    startedWith = plate;
    if (taken) throw VehiclePlateTaken(plate);
    return {'id': 'v1', 'plate': plate, 'status': 'unapproved', 'permit': 'pending'};
  }

  @override
  Future<Map<String, dynamic>> patch(Map<String, dynamic> v, Map<String, dynamic> patch) async {
    patches.add(patch);
    return {...v, ...patch};
  }

  @override
  Future<String> uploadPhoto(String vehicleId, String slot, Uint8List bytes, String fileName) async => 'https://x/$slot';
}

class _FakePeople extends PeopleRepository {
  _FakePeople({this.uploads = const []}) : super(_db);
  final List<Map<String, dynamic>> uploads;

  @override
  Future<List<({String id, Map<String, dynamic> values})>> requiredDocuments() async => [
        (id: 'licence', values: <String, dynamic>{'name': 'Driving License'}),
        (id: 'puspakom', values: <String, dynamic>{'name': 'Puspakom inspection', 'docTypes': ['type-vehicle']}),
      ];

  @override
  Future<List<({String id, Map<String, dynamic> values})>> documentTypes() async => [
        (id: 'type-vehicle', values: <String, dynamic>{'name': 'Vehicle'}),
      ];

  @override
  Future<List<Map<String, dynamic>>> vehicleDocuments(String vehicleId) async => uploads;
}

const _ready = {
  'id': 'v1',
  'plate': 'WXY 1',
  'make': 'Proton',
  'model': 'Saga',
  'year': '2020',
  'color': 'White',
  'image_front': 'https://x/f',
  'image_left': 'https://x/l',
  'image_right': 'https://x/r',
  'image_back': 'https://x/b',
  'owner_name': 'Aina',
  'owner_phone': '+60123',
  'owner_ic': '900101-14-5555',
  'status': 'unapproved',
  'permit': 'pending',
  'documents_ok': false,
};

Future<_FakeVehicles> _pump(
  WidgetTester tester,
  Widget screen, {
  _FakeVehicles? vehicles,
  _FakePeople? people,
  Brightness brightness = Brightness.light,
  GoRouter? router,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = vehicles ?? _FakeVehicles();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      partnerOnboardingRepositoryProvider.overrideWithValue(_FakeOnboarding()),
      vehicleOnboardingRepositoryProvider.overrideWithValue(repo),
      peopleRepositoryProvider.overrideWithValue(people ?? _FakePeople()),
      // No realtime socket in a test.
      liveTablesProvider.overrideWith(_QuietLive.new),
    ],
    child: router == null
        ? MaterialApp(theme: appTheme(brightness), home: screen)
        : MaterialApp.router(theme: appTheme(brightness), routerConfig: router),
  ));
  await tester.pump();
  await tester.pump();
  return repo;
}

void main() {
  testWidgets('a new vehicle starts at the plate and normalises it', (tester) async {
    final repo = await _pump(tester, const VehicleOnboardingScreen());
    expect(find.text("What's the plate number?"), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  wxy   1 ');
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump();
    expect(repo.startedWith, 'WXY 1');
    expect(find.text('Make and model'), findsOneWidget);
  });

  testWidgets('a plate on another account explains what to do', (tester) async {
    await _pump(tester, const VehicleOnboardingScreen(), vehicles: _FakeVehicles(taken: true));
    await tester.enterText(find.byType(TextField), 'ABC 9');
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('already registered to another account'), findsOneWidget);
    expect(find.text("What's the plate number?"), findsOneWidget);
  });

  testWidgets('year and colour are both required', (tester) async {
    final repo = await _pump(
      tester,
      const VehicleOnboardingScreen(vehicleId: 'v1'),
      vehicles: _FakeVehicles(existing: const {'id': 'v1', 'plate': 'WXY 1', 'make': 'Proton', 'model': 'Saga'}),
    );
    expect(find.text('Year and colour'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Year'), '2020');
    await tester.tap(find.text('Save and continue'));
    await tester.pump();
    expect(repo.patches, isEmpty);
    await tester.enterText(find.widgetWithText(TextField, 'Colour'), 'White');
    await tester.tap(find.text('Save and continue'));
    await tester.pump();
    await tester.pump();
    expect(repo.patches.single, {'year': '2020', 'color': 'White'});
    expect(find.text('Photos of the vehicle'), findsOneWidget);
  });

  testWidgets('"my own vehicle" fills the owner from the partner', (tester) async {
    final existing = Map<String, dynamic>.from(_ready)
      ..remove('owner_name')
      ..remove('owner_phone')
      ..remove('owner_ic');
    final repo = await _pump(tester, const VehicleOnboardingScreen(vehicleId: 'v1'),
        vehicles: _FakeVehicles(existing: existing));
    expect(find.text('Who owns the vehicle?'), findsOneWidget);
    await tester.tap(find.text("It's my own vehicle"));
    await tester.pump();
    await tester.tap(find.text('Save and continue'));
    await tester.pump();
    await tester.pump();
    expect(repo.patches.single, {'owner_name': 'Aina', 'owner_phone': '+60123', 'owner_ic': '900101-14-5555'});
  });

  testWidgets('only vehicle documents are asked for, and they gate the submit', (tester) async {
    final repo = await _pump(tester, const VehicleOnboardingScreen(vehicleId: 'v1'),
        vehicles: _FakeVehicles(existing: _ready));
    await tester.pump();
    expect(find.text('Vehicle documents'), findsOneWidget);
    expect(find.text('Puspakom inspection'), findsOneWidget);
    expect(find.text('Driving License'), findsNothing);
    await tester.tap(find.text('Upload every compulsory document'));
    await tester.pump();
    expect(repo.patches, isEmpty);
  });

  testWidgets('with the documents in, the vehicle is submitted for review', (tester) async {
    final repo = await _pump(
      tester,
      const VehicleOnboardingScreen(vehicleId: 'v1'),
      vehicles: _FakeVehicles(existing: _ready),
      people: _FakePeople(uploads: [
        {'doc_id': 'puspakom', 'status': 'Pending Review'},
      ]),
    );
    await tester.pump();
    await tester.tap(find.text('Submit for review'));
    await tester.pump();
    await tester.pump();
    expect(repo.patches.single, {'documents_ok': true});
    expect(find.text('Proton Saga · Pending review'), findsOneWidget);
  });

  testWidgets('the vehicle list shows where each vehicle stands', (tester) async {
    await _pump(tester, const VehiclesScreen(),
        vehicles: _FakeVehicles(existing: {..._ready, 'make': null, 'model': null}));
    await tester.pump();
    expect(find.text('WXY 1'), findsOneWidget);
    expect(find.text('Incomplete: Make & model'), findsOneWidget);
    expect(find.text('Add vehicle'), findsOneWidget);
  });

  testWidgets('the year must be four digits in range', (tester) async {
    final repo = await _pump(
      tester,
      const VehicleOnboardingScreen(vehicleId: 'v1'),
      vehicles: _FakeVehicles(existing: const {'id': 'v1', 'plate': 'WXY 1', 'make': 'Proton', 'model': 'Saga'}),
    );
    await tester.enterText(find.widgetWithText(TextField, 'Colour'), 'White');
    await tester.enterText(find.widgetWithText(TextField, 'Year'), '1890');
    await tester.tap(find.text('Save and continue'));
    await tester.pump();
    expect(find.textContaining('Enter the year as 4 digits, from 1950 to'), findsOneWidget);
    expect(repo.patches, isEmpty);
    await tester.enterText(find.widgetWithText(TextField, 'Year'), '202');
    await tester.tap(find.text('Save and continue'));
    await tester.pump();
    expect(repo.patches, isEmpty);
    // A fifth digit is not taken.
    await tester.enterText(find.widgetWithText(TextField, 'Year'), '20201');
    expect(find.widgetWithText(TextField, '2020'), findsOneWidget);
  });

  testWidgets('the owner step needs "Is this your own vehicle?" answered', (tester) async {
    final existing = Map<String, dynamic>.from(_ready)
      ..remove('owner_name')
      ..remove('owner_phone')
      ..remove('owner_ic');
    final repo = await _pump(tester, const VehicleOnboardingScreen(vehicleId: 'v1'),
        vehicles: _FakeVehicles(existing: existing));
    expect(find.text('Is this your own vehicle?'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, "Owner's name"), 'Siti');
    await tester.enterText(find.widgetWithText(TextField, "Owner's phone"), '+60199');
    await tester.enterText(find.widgetWithText(TextField, "Owner's ID number"), '800101-10-1111');
    await tester.tap(find.text('Select an option to continue'));
    await tester.pump();
    expect(find.text('Please tell us whether this is your own vehicle.'), findsOneWidget);
    expect(repo.patches, isEmpty);

    await tester.tap(find.text("It's someone else's"));
    await tester.pump();
    // Choosing clears the fields for the real owner's details.
    await tester.enterText(find.widgetWithText(TextField, "Owner's name"), 'Siti');
    await tester.enterText(find.widgetWithText(TextField, "Owner's phone"), '+60199');
    await tester.enterText(find.widgetWithText(TextField, "Owner's ID number"), '800101-10-1111');
    await tester.tap(find.text('Save and continue'));
    await tester.pump();
    await tester.pump();
    expect(repo.patches.single, {'owner_name': 'Siti', 'owner_phone': '+60199', 'owner_ic': '800101-10-1111'});
  });

  GoRouter router(String vehicleId) => GoRouter(
        initialLocation: '/drive/vehicles',
        routes: [
          GoRoute(path: '/drive', builder: (_, _) => const Scaffold(body: Text('drive tab'))),
          GoRoute(
            path: '/drive/vehicles',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => context.push('/drive/vehicles/$vehicleId'),
                child: const Text('vehicle list'),
              ),
            ),
          ),
          GoRoute(
            path: '/drive/vehicles/:id',
            builder: (_, s) => VehicleOnboardingScreen(vehicleId: s.pathParameters['id']),
          ),
        ],
      );

  testWidgets('Done takes an approved vehicle to the Drive tab', (tester) async {
    await _pump(tester, const SizedBox(),
        router: router('v1'),
        vehicles: _FakeVehicles(existing: {..._ready, 'status': 'approved', 'documents_ok': true}));
    await tester.tap(find.text('vehicle list'));
    await tester.pumpAndSettle();
    expect(find.text('Proton Saga · Approved'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('drive tab'), findsOneWidget);
  });

  testWidgets('Done on a vehicle still in review goes back', (tester) async {
    await _pump(tester, const SizedBox(),
        router: router('v1'), vehicles: _FakeVehicles(existing: {..._ready, 'documents_ok': true}));
    await tester.tap(find.text('vehicle list'));
    await tester.pumpAndSettle();
    expect(find.text('Proton Saga · Pending review'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('vehicle list'), findsOneWidget);
    expect(find.text('drive tab'), findsNothing);
  });

  for (final b in Brightness.values) {
    testWidgets('a rejected vehicle document shows the reason (${b.name})', (tester) async {
      await _pump(
        tester,
        const VehicleOnboardingScreen(vehicleId: 'v1'),
        brightness: b,
        vehicles: _FakeVehicles(existing: {..._ready, 'documents_ok': true}),
        people: _FakePeople(uploads: [
          {'doc_id': 'puspakom', 'status': 'Rejected', 'reviewer_notes': 'Inspection date is cut off'},
        ]),
      );
      await tester.pump();
      final note = find.text('Rejected: Inspection date is cut off');
      expect(note, findsOneWidget);
      expect(tester.widget<Text>(note).style?.color, Theme.of(tester.element(note)).colorScheme.error);
    });
  }
}

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}
