import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/data/partner_onboarding_repository.dart';
import 'package:get_ride/src/features/partner/partner_onboarding_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the first test.
final _db = SupabaseClient(
  'http://localhost',
  'anon',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

/// Serves a fixed onboarding state and records the partner patches.
class _FakeOnboarding extends PartnerOnboardingRepository {
  _FakeOnboarding(this.state) : super(_db);
  OnboardingState state;
  final patches = <Map<String, dynamic>>[];

  @override
  Future<OnboardingState> load() async => state;

  @override
  Future<Map<String, dynamic>> patchPartner(OnboardingState s, Map<String, dynamic> patch) async {
    patches.add(patch);
    return {...s.partner, ...patch};
  }

  @override
  Future<Map<String, dynamic>> patchProfile(Map<String, dynamic> patch) async => {...?state.profile, ...patch};
}

class _FakePeople extends PeopleRepository {
  _FakePeople({this.uploads = const []}) : super(_db);
  final List<Map<String, dynamic>> uploads;

  @override
  Future<GeoOptions> geoOptions({Iterable<ServiceArea> inUse = const []}) async => const GeoOptions(
        countries: ['Malaysia'],
        states: ['Malaysia|Selangor'],
        cities: ['Malaysia|Selangor|Ampang'],
      );

  @override
  Future<List<({String id, Map<String, dynamic> values})>> partnerTypes() async => [
        (id: 't1', values: <String, dynamic>{'name': 'TEKSI'}),
        (id: 't2', values: <String, dynamic>{'name': 'E-HAILING'}),
      ];

  @override
  Future<List<({String id, Map<String, dynamic> values})>> requiredDocuments() async => [
        (id: 'licence', values: <String, dynamic>{'name': 'Driving licence'}),
        (id: 'permit', values: <String, dynamic>{'name': 'Taxi permit', 'partnerTypes': ['TEKSI']}),
      ];

  @override
  Future<List<Map<String, dynamic>>> providerDocuments(String partnerId) async => uploads;
}

Map<String, dynamic> _partner([Map<String, dynamic> extra = const {}]) => {
      'id': 'p1',
      'auth_user_id': 'u1',
      'status': 'unapproved',
      'partner_types': <String>[],
      'service_countries': <String>[],
      'service_states': <String>[],
      'service_cities': <String>[],
      'documents_ok': false,
      ...extra,
    };

const _filledIn = {
  'avatar_url': 'https://example.com/a.png',
  'ic': '900101-14-5555',
  'address': 'Jalan 1, Ampang',
  'service_countries': ['Malaysia'],
  'service_states': ['Malaysia|Selangor'],
  'service_cities': ['Malaysia|Selangor|Ampang'],
  'partner_types': ['TEKSI'],
};

Future<_FakeOnboarding> _pump(WidgetTester tester, OnboardingState state, {_FakePeople? people}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = _FakeOnboarding(state);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      partnerOnboardingRepositoryProvider.overrideWithValue(repo),
      peopleRepositoryProvider.overrideWithValue(people ?? _FakePeople()),
      partnerProvider.overrideWith((_) async => null),
    ],
    child: const MaterialApp(home: PartnerOnboardingScreen()),
  ));
  await tester.pump();
  await tester.pump();
  return repo;
}

void main() {
  testWidgets('a new partner starts at the profile photo', (tester) async {
    await _pump(tester, OnboardingState(profile: const {}, partner: _partner()));
    expect(find.text('Step 1 of 6'), findsOneWidget);
    expect(find.text('Add a profile photo'), findsOneWidget);
    expect(find.text('Choose photo'), findsOneWidget);
  });

  testWidgets('the ID number is required, then saved to both rows', (tester) async {
    final repo = await _pump(
      tester,
      OnboardingState(profile: const {'profile_image': 'x.png'}, partner: _partner()),
    );
    expect(find.text('Your ID'), findsOneWidget);
    await tester.tap(find.text('Save and continue'));
    await tester.pump();
    expect(find.text('Please enter your ID number.'), findsOneWidget);
    expect(repo.patches, isEmpty);

    await tester.enterText(find.byType(TextField), '900101-14-5555');
    await tester.tap(find.text('Save and continue'));
    await tester.pump();
    await tester.pump();
    expect(repo.patches.single, {'ic': '900101-14-5555'});
    expect(find.text('Your address'), findsOneWidget);
  });

  testWidgets('partner types come from settings and are saved with partner_type', (tester) async {
    final repo = await _pump(
      tester,
      OnboardingState(
        profile: const {},
        partner: _partner({..._filledIn, 'partner_types': <String>[]}),
      ),
    );
    expect(find.text('What kind of partner are you?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'TEKSI'));
    await tester.pump();
    await tester.tap(find.text('Save and continue'));
    await tester.pump();
    await tester.pump();
    expect(repo.patches.single, {'partner_type': 'TEKSI', 'partner_types': ['TEKSI']});
    expect(find.text('Upload your documents'), findsOneWidget);
  });

  testWidgets('documents follow the partner type and gate the submit', (tester) async {
    final repo = await _pump(tester, OnboardingState(profile: const {}, partner: _partner(_filledIn)));
    await tester.pump();
    expect(find.text('Driving licence'), findsOneWidget);
    expect(find.text('Taxi permit'), findsOneWidget);
    expect(find.text('Upload every compulsory document'), findsOneWidget);
    await tester.tap(find.text('Upload every compulsory document'));
    await tester.pump();
    expect(repo.patches, isEmpty);
  });

  testWidgets('with every compulsory document uploaded the application is submitted', (tester) async {
    final repo = await _pump(
      tester,
      OnboardingState(profile: const {}, partner: _partner(_filledIn)),
      people: _FakePeople(uploads: [
        {'doc_id': 'licence', 'status': 'Pending Review'},
        {'doc_id': 'permit', 'status': 'Approved'},
      ]),
    );
    await tester.pump();
    expect(find.text('Submit for review'), findsOneWidget);
    await tester.tap(find.text('Submit for review'));
    await tester.pump();
    await tester.pump();
    expect(repo.patches.single, {'documents_ok': true});
    expect(find.text('Application submitted'), findsOneWidget);
    expect(find.text('All steps complete'), findsOneWidget);
  });
}
