// Partner registration (0288), screen by screen at phone width, in light and
// dark: profile photo, service area (from the current location), Partner
// Service type (cards and the citizens-only notice), National ID (type,
// confirm, photos, the eligibility modal), Check your details (read from the
// ID, the number compared), Your company, Driver permit, Register vehicle
// (grant, age per service, permits, owner, photos), Service documents and
// Pending admin approval. All text read off "documents" here is made up.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/partner_onboarding.dart';
import 'package:get_ride/src/core/vehicle_onboarding.dart' show vehicleServiceMissing;
import 'package:get_ride/src/data/app_display_repository.dart' show appDisplayProvider;
import 'package:get_ride/src/data/document_text_reader.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/partner_onboarding_repository.dart';
import 'package:get_ride/src/data/vehicle_onboarding_repository.dart';
import 'package:get_ride/src/features/partner/driver_permit_screen.dart' show permitDocumentsRoute;
import 'package:get_ride/src/features/partner/partner_onboarding_screen.dart';
import 'package:get_ride/src/features/partner/registration_parts.dart' show registrationLocatorProvider;
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/live_selfie.dart' show LiveSelfie;
import 'package:get_ride/src/widgets/live_selfie_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'partner_registration_fixture.dart';

// No token refresh: its timer would outlive the first test.
final _db = SupabaseClient(
  'http://localhost',
  'anon',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

final _now = DateTime(2026, 10, 24);

/// Serves a fixed onboarding state and records the writes.
class _FakeOnboarding extends PartnerOnboardingRepository {
  _FakeOnboarding(this.state, {this.hasApplication = true}) : super(_db);
  OnboardingState state;
  final bool hasApplication;
  final patches = <Map<String, dynamic>>[];
  final profilePatches = <Map<String, dynamic>>[];
  final mayStarts = <bool>[];
  final uploads = <String>[];

  @override
  Future<OnboardingState> load({bool mayStart = true}) async {
    mayStarts.add(mayStart);
    if (!hasApplication && !mayStart) throw const PartnerRegistrationPaused();
    return state;
  }

  /// The server refuses a change of types (0299, an approved partner).
  bool lockTypes = false;

  @override
  Future<Map<String, dynamic>> patchPartner(OnboardingState s, Map<String, dynamic> patch) async {
    if (lockTypes && patch.containsKey('partner_types')) {
      throw const PostgrestException(message: 'PARTNER_TYPES_LOCKED', code: '42501', hint: 'Server words');
    }
    patches.add(patch);
    final next = {...s.partner, ...patch};
    state = state.copyWith(partner: next);
    return next;
  }

  @override
  Future<Map<String, dynamic>> patchProfile(Map<String, dynamic> patch) async {
    profilePatches.add(patch);
    final next = {...?state.profile, ...patch};
    state = state.copyWith(profile: next);
    return next;
  }

  @override
  Future<String> uploadAvatar(OnboardingState s, Uint8List bytes, String fileName) async {
    uploads.add('avatar:$fileName');
    return 'https://x/storage/v1/object/public/avatars/u1/$fileName';
  }

  @override
  Future<String> uploadIdSide(Uint8List bytes, String fileName, String side) async {
    uploads.add('id:$side');
    return 'https://x/storage/v1/object/public/ID_Image/u1/id_$side.jpg';
  }

  @override
  Future<String> uploadPartnerFile(String partnerId, String folder, String side, Uint8List bytes, String fileName) async {
    uploads.add('$folder:$side');
    return 'https://x/storage/v1/object/public/provider-documents/$partnerId/$folder/$side.jpg';
  }
}

class _FakeVehicles extends VehicleOnboardingRepository {
  _FakeVehicles() : super(_db);
  Map<String, dynamic>? v;
  final statuses = <Map<String, dynamic>>[];
  final updates = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> startWithPlate(String plate, Map<String, dynamic> partner) async =>
      v ??= {'id': 'v1', 'plate': plate, 'status': 'unapproved', 'documents_ok': false};

  @override
  Future<Map<String, dynamic>> update(String id, Map<String, dynamic> patch) async {
    updates.add(patch);
    return v = {...?v, 'id': id, ...patch};
  }

  @override
  Future<Map<String, dynamic>?> vehicle(String id) async => v;

  @override
  Future<List<Map<String, dynamic>>> serviceStatuses(String vehicleId) async => statuses;

  @override
  Future<void> saveServiceStatuses(String vehicleId, List<Map<String, dynamic>> rows) async {
    statuses
      ..clear()
      ..addAll(rows);
  }

  @override
  Future<String> uploadPhoto(String vehicleId, String slot, Uint8List bytes, String fileName) async =>
      'https://x/storage/v1/object/public/vehicle-documents/$vehicleId/photos/$slot.jpg';

  @override
  Future<String> uploadFile(String vehicleId, String folder, String side, Uint8List bytes, String fileName) async =>
      'https://x/storage/v1/object/public/vehicle-documents/$vehicleId/$folder/$side.jpg';
}

class _FakePeople extends PeopleRepository {
  _FakePeople({this.uploads = const [], this.noTypes = false, this.services = const []}) : super(_db);
  final List<Map<String, dynamic>> uploads;

  /// Admin → Vehicle Services, as (id, values).
  final List<({String id, Map<String, dynamic> values})> services;

  @override
  Future<List<({String id, Map<String, dynamic> values})>> vehicleServices() async => services;

  /// No Partner Service type at all: nothing is offered anywhere.
  final bool noTypes;

  @override
  Future<GeoOptions> geoOptions({Iterable<ServiceArea> inUse = const []}) async => const GeoOptions(
        countries: ['Malaysia'],
        states: ['Malaysia|Selangor'],
        cities: ['Malaysia|Selangor|Ampang'],
      );

  @override
  Future<List<({String id, Map<String, dynamic> values})>> partnerTypes() async => [
        if (!noTypes)
          for (final (i, e) in regEntries.indexed) (id: 't$i', values: e),
      ];

  @override
  Future<List<({String id, Map<String, dynamic> values})>> requiredDocuments() async => [
        (id: 'licence', values: <String, dynamic>{'name': 'Driving licence'}),
        (id: 'permit', values: <String, dynamic>{'name': 'Taxi permit', 'partnerTypes': ['Teksi'], 'isTaxiPermit': true}),
        (id: 'puspakom', values: <String, dynamic>{'name': 'Puspakom inspection', 'docTypes': ['type-vehicle']}),
      ];

  @override
  Future<List<({String id, Map<String, dynamic> values})>> documentTypes() async => [
        (id: 'type-vehicle', values: <String, dynamic>{'name': 'Vehicle'}),
      ];

  @override
  Future<List<Map<String, dynamic>>> providerDocuments(String partnerId) async => uploads;

  @override
  Future<List<Map<String, dynamic>>> vehicleDocuments(String vehicleId) async => uploads;

  @override
  Future<List<Map<String, dynamic>>> makeModels() async => [
        {'make': 'Perodua', 'model': 'Bezza', 'service_id': 'ride', 'vehicle_type': 'Sedan'},
      ];
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

const _photo = {'avatar_url': 'https://example.com/a.png', 'selfie_liveness': 'passed'};
const _area = {
  'service_countries': ['Malaysia'],
  'service_states': ['Malaysia|Selangor'],
  'service_cities': ['Malaysia|Selangor|Ampang'],
};
const _id = {
  'name': 'Aina',
  'id_type': 'mykad',
  'id_number_typed': '900101-14-5678',
  'ic': '900101-14-5678',
  'id_image': 'https://x/storage/v1/object/public/ID_Image/u1/id_front.jpg',
  'id_image_back': 'https://x/storage/v1/object/public/ID_Image/u1/id_back.jpg',
};
const _detailsDone = {
  ..._id,
  'id_name': 'AINA BINTI RAHMAN',
  'birth_date': '1990-01-01',
  'address': 'NO 12 JALAN SS2/24, 47300 PETALING JAYA',
  'nationality': 'Malaysian',
};

const _myKadText = 'KAD PENGENALAN\nMALAYSIA\n900101-14-5678\nAINA BINTI RAHMAN\nNO 12 JALAN SS2/24\n47300 PETALING JAYA\n'
    'SELANGOR\nWARGANEGARA';
const _companyText = 'COMPANY PROFILE\nCompany Name : CAHAYA TEKSI SDN. BHD.\nRegistration No. : 201901012345 (1321234-K)\n'
    'Date of Incorporation : 12/04/2019\nRegistered Address : LOT 5, JALAN KENARI 3,\n47100 PUCHONG, SELANGOR\n'
    'DIRECTORS\nAINA BINTI RAHMAN 900101-14-5678\nMOHD FAIZ BIN ISA';
const _permitText = 'AGENSI PENGANGKUTAN AWAM DARAT\nKAD PEMANDU TEKSI\nNo. Kad : KP/B/2024/0000001\n'
    'Nama : AINA BINTI RAHMAN\nNo. K/P : 900101-14-5678\nSah Dari : 02/05/2026 Hingga : 01/05/2027\n'
    'Nama Pengusaha : CAHAYA TEKSI SDN. BHD.\nNo. Lesen Pengusaha : LPKP/TKS/B/000001\n'
    'No. Pendaftaran Kenderaan : HWA 8812\nPEMANDU KEDUA';
const _grantText = 'SIJIL PEMILIKAN KENDERAAN\nNo. Pendaftaran : WXY 1234\nNama Pemunya Berdaftar : AINA BINTI RAHMAN\n'
    'No. Pengenalan : 900101-14-5678\nBuatan/Nama Model : PERODUA BEZZA 1.3 AV\nKeupayaan Enjin : 1329\n'
    'No. Enjin : 1NR-F000001\nNo. Casis : PM2B000000000001\nWarna : SILVER\nTahun Dibuat : 2009\n'
    'Tarikh Pendaftaran : 15/03/2009';

class _Harness {
  _Harness(this.repo, this.vehicles, this.texts);
  final _FakeOnboarding repo;
  final _FakeVehicles vehicles;
  final Map<String, String?> texts;
  int gates = 0;
}

Future<_Harness> _pump(
  WidgetTester tester,
  OnboardingState state, {
  _FakePeople? people,
  PartnerOnboardingScreen? screen,
  Brightness brightness = Brightness.light,
  AppDisplay display = const AppDisplay(),
  bool hasApplication = true,
  Map<String, String?> texts = const {},
  ({String? country, String? state, String? city})? here,
  _FakeVehicles? vehicles,
}) async {
  // A phone: 390 x 844.
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = _Harness(_FakeOnboarding(state, hasApplication: hasApplication), vehicles ?? _FakeVehicles(), {...texts});
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      partnerOnboardingRepositoryProvider.overrideWithValue(h.repo),
      vehicleOnboardingRepositoryProvider.overrideWithValue(h.vehicles),
      peopleRepositoryProvider.overrideWithValue(people ?? _FakePeople()),
      partnerProvider.overrideWith((_) async => null),
      appDisplayProvider.overrideWith((_) async => display),
      liveTablesProvider.overrideWith(_QuietLive.new),
      documentTextReaderProvider.overrideWithValue((bytes, {fileUrl}) async {
        for (final e in h.texts.entries) {
          if ((fileUrl ?? '').contains(e.key)) return e.value;
        }
        return null;
      }),
      liveSelfieGateProvider.overrideWithValue((_) async {
        h.gates++;
        return true;
      }),
      docPhotoPickerProvider.overrideWithValue((_) async => (bytes: Uint8List(4), name: 'doc.jpg')),
      registrationLocatorProvider.overrideWithValue(() async => here),
    ],
    child: MaterialApp(
      theme: appTheme(brightness),
      home: screen ??
          PartnerOnboardingScreen(
            onPhone: true,
            now: _now,
            pickPhoto: (_) async => (bytes: Uint8List(4), name: 'id.jpg', ext: 'jpg', contentType: 'image/jpeg'),
          ),
    ),
  ));
  await _settle(tester);
  return h;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester);
}

void _noOverflow(WidgetTester tester) => expect(tester.takeException(), isNull);

void main() {
  startStepTests();

  for (final b in Brightness.values) {
    testWidgets('driver sign-up closed: a passenger with no application sees it paused (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(profile: const {}, partner: _partner()),
        brightness: b,
        display: const AppDisplay(driverRegistrationEnabled: false),
        hasApplication: false,
      );
      expect(h.repo.mayStarts, [false]);
      expect(find.byKey(const ValueKey('partner-registration-paused')), findsOneWidget);
      expect(find.text(partnerRegistrationPausedTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('onboarding-progress')), findsNothing, reason: 'no wizard');
      _noOverflow(tester);
    });

    testWidgets('a new partner starts at the photo; the live selfie is kept on both rows (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(profile: const {}, partner: _partner()),
        brightness: b,
        screen: PartnerOnboardingScreen(
          onPhone: true,
          takeSelfie: (_) async => LiveSelfie(bytes: Uint8List(4), name: 'me.jpg', liveness: 'passed', detail: 'blink'),
        ),
        here: (country: 'Malaysia', state: 'Selangor', city: 'Ampang'),
      );
      expect(find.text('Step 1 of 6 · Profile photo'), findsOneWidget);
      expect(find.text('Add a profile photo'), findsOneWidget);
      // On the phone the photo counts once the server says it was live.
      h.repo.state = h.repo.state.copyWith(partner: {...h.repo.state.partner, 'selfie_liveness': 'passed'});
      await _tap(tester, find.text('Take a selfie'));
      expect(h.repo.uploads, ['avatar:me.jpg']);
      expect(h.repo.profilePatches.single, {'avatar_url': 'https://x/storage/v1/object/public/avatars/u1/me.jpg'});
      _noOverflow(tester);
    });

    testWidgets('the service area is filled in from the current location (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(profile: const {}, partner: _partner(_photo)),
        brightness: b,
        here: (country: 'Malaysia', state: 'Selangor', city: 'Ampang'),
      );
      expect(find.text('Step 2 of 6 · Service area'), findsOneWidget, reason: 'the photo step done still counts, so the count stays the same');
      expect(find.byKey(const ValueKey('area-from-location')), findsOneWidget);
      expect(find.text('Ampang'), findsOneWidget);
      await _tap(tester, find.text('Continue'));
      expect(h.repo.patches.single['service_cities'], ['Malaysia|Selangor|Ampang']);
      expect(find.text('Choose your Partner Service type'), findsOneWidget);
      _noOverflow(tester);
    });

    testWidgets('no service offered in the area: says so, and Change area goes back (${b.name})', (tester) async {
      await _pump(
        tester,
        OnboardingState(profile: const {}, partner: _partner({
          ..._photo,
          'service_countries': ['Zedland'],
          'service_states': ['Zedland|North'],
          'service_cities': ['Zedland|North|Nowhere'],
        })),
        brightness: b,
        people: _FakePeople(noTypes: true),
      );
      expect(find.byKey(const ValueKey('partner-type-none')), findsOneWidget);
      expect(find.text('No services offered in Nowhere yet'), findsOneWidget);
      expect(find.text('Continue'), findsNothing, reason: 'no Continue that can only refuse');
      await _tap(tester, find.byKey(const ValueKey('partner-type-change-area')));
      expect(find.text('Where will you work?'), findsOneWidget);
      _noOverflow(tester);
    });

    testWidgets('Partner Service type: cards, the citizens-only notice, several picked (${b.name})', (tester) async {
      final h = await _pump(tester, OnboardingState(profile: const {}, partner: _partner({..._photo, ..._area})), brightness: b);
      expect(find.byKey(const ValueKey('citizens-notice')), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'Citizens only in Selangor: (eHailing, Teksi|Teksi, eHailing)\.'), findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('Open to everyone: Delivery', findRichText: true), findsOneWidget);
      expect(find.textContaining('Vehicle up to 15 years old'), findsOneWidget);
      expect(find.textContaining('Needs: Driving licence, Taxi permit, Kad Pemandu (APAD)'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('service-card-Teksi')));
      await _tap(tester, find.byKey(const ValueKey('service-card-Delivery')));
      await _tap(tester, find.text('Continue'));
      expect(h.repo.patches.single, {'partner_type': 'Teksi,Delivery', 'partner_types': ['Teksi', 'Delivery']});
      expect(find.text('Your national ID number'), findsOneWidget);
      // Teksi adds the company, driver permit and vehicle steps.
      expect(find.text('Step 4 of 10 · National ID'), findsOneWidget);
      _noOverflow(tester);
    });

    testWidgets("an approved partner's types are locked: said plainly in a modal (M7, ${b.name})", (tester) async {
      final h = await _pump(tester, OnboardingState(profile: const {}, partner: _partner({..._photo, ..._area})), brightness: b);
      h.repo.lockTypes = true;
      await _tap(tester, find.byKey(const ValueKey('service-card-Delivery')));
      await _tap(tester, find.text('Continue'));
      expect(h.repo.patches, isEmpty);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.textContaining("your Partner Service types can't be changed here"), findsOneWidget);
      expect(find.textContaining('Server words'), findsNothing);
      expect(find.text('Your national ID number'), findsNothing, reason: 'stays on the step');
      _noOverflow(tester);
    });

    testWidgets('National ID: number, "Is this your ID number?", photos, then read (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(profile: const {'name': 'Aina'}, partner: _partner({..._photo, ..._area, 'partner_types': ['Delivery']})),
        brightness: b,
      );
      await tester.enterText(find.byKey(const ValueKey('id-number')), '900101145678');
      await _tap(tester, find.byKey(const ValueKey('id-continue')));
      expect(find.text('Is this your ID number?'), findsOneWidget);
      expect(find.text('900101-14-5678'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('id-confirm-yes')));
      expect(h.repo.profilePatches.last,
          {'id_type': 'mykad', 'id_number_typed': '900101-14-5678', 'ic': '900101-14-5678'});
      expect(find.text('Take photos of your ID'), findsOneWidget);
      final read = tester.widget<FilledButton>(find.descendant(of: find.byKey(const ValueKey('id-read')), matching: find.byType(FilledButton)));
      expect(read.onPressed, isNull, reason: 'both photos first');
      await _tap(tester, find.byKey(const ValueKey('id-front')));
      await _tap(tester, find.byKey(const ValueKey('id-back')));
      expect(h.repo.uploads, ['id:front', 'id:back']);
      expect(h.gates, 2, reason: 'a live selfie before each photo of the ID');
      expect(find.text('Take photos of your ID'), findsOneWidget, reason: 'stays until read');
      await _tap(tester, find.byKey(const ValueKey('id-read')));
      expect(find.text('Check your details'), findsWidgets);
      _noOverflow(tester);
    });

    testWidgets('a passport: the eligibility modal, Continue or Change my services (${b.name})', (tester) async {
      await _pump(
        tester,
        OnboardingState(
          profile: const {'id_type': 'passport', 'ic': 'C4821937', 'id_image': 'f', 'id_image_back': 'b'},
          partner: _partner({..._photo, ..._area, 'partner_types': ['Teksi', 'Delivery']}),
        ),
        brightness: b,
        screen: const PartnerOnboardingScreen(onPhone: true, startAt: OnboardingStep.id),
      );
      await _tap(tester, find.byKey(const ValueKey('onboarding-step-id')));
      await _tap(tester, find.byKey(const ValueKey('id-read')));
      expect(find.byKey(const ValueKey('eligibility-modal')), findsOneWidget);
      expect(find.text('You may not be eligible to join some services'), findsOneWidget);
      expect(find.textContaining('You are registering with a passport.'), findsOneWidget);
      expect(find.textContaining('Teksi. You can carry on', findRichText: true), findsOneWidget);
      expect(find.text('Open to you: Delivery.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('eligibility-change')));
      expect(find.text('Choose your Partner Service type'), findsOneWidget);
      _noOverflow(tester);
    });
  }

  for (final b in Brightness.values) {
    testWidgets('Check your details: read from the MyKad, the number matches, saved (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(profile: _id, partner: _partner({..._photo, ..._area, 'partner_types': ['Delivery']})),
        brightness: b,
        texts: {'id_front': _myKadText},
      );
      expect(find.text('Read from your MyKad. Check each line, then confirm.'), findsOneWidget);
      expect(find.text('Matches'), findsOneWidget);
      expect(find.text('AINA BINTI RAHMAN'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('details-confirm')));
      expect(h.repo.profilePatches.last['id_number_read'], '900101-14-5678');
      expect(h.repo.profilePatches.last['birth_date'], '1990-01-01');
      expect(h.repo.profilePatches.last['id_name'], 'AINA BINTI RAHMAN');
      expect(h.repo.profilePatches.last['address'], 'NO 12 JALAN SS2/24, 47300 PETALING JAYA, SELANGOR');
      expect(h.repo.patches.last['registration_steps'], ['details']);
      expect(find.text('Upload service documents'), findsOneWidget);
      _noOverflow(tester);
    });

    testWidgets('a number that differs: the message, then a modal before keeping it (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(
          profile: {..._id, 'id_number_typed': '900101-14-5679', 'ic': '900101-14-5679'},
          partner: _partner({..._photo, ..._area, 'partner_types': ['Delivery']}),
        ),
        brightness: b,
        texts: {'id_front': _myKadText},
      );
      expect(find.text("The number on your ID doesn't match the one you typed"), findsOneWidget);
      expect(find.byKey(const ValueKey('details-retake')), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('details-confirm')));
      // The date of birth read (1990-01-01) is not the typed number's: no, it
      // is (900101); the mismatch modal comes up.
      expect(find.text('Keep it as typed'), findsOneWidget);
      await _tap(tester, find.text('Go back'));
      expect(h.repo.patches, isEmpty);
      _noOverflow(tester);
    });

    testWidgets('an ID that can\'t be read opens empty for typing (${b.name})', (tester) async {
      await _pump(
        tester,
        OnboardingState(profile: _id, partner: _partner({..._photo, ..._area, 'partner_types': ['Delivery']})),
        brightness: b,
      );
      expect(find.byKey(const ValueKey('details-unread')), findsOneWidget);
      expect(find.text('Not read'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('details-confirm')));
      expect(find.text('Enter your full name as it is on your ID.'), findsOneWidget);
      _noOverflow(tester);
    });

    testWidgets('Your company: read from the SSM document, the driver listed as a director (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(
          profile: _detailsDone,
          partner: _partner({..._photo, ..._area, 'partner_types': ['Teksi'], 'registration_steps': ['details']}),
        ),
        brightness: b,
        texts: {'company/front': _companyText},
      );
      expect(find.text('Your company registration'), findsOneWidget);
      expect(find.textContaining('Teksi needs a registered business'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('company-photo')));
      expect(find.text('Check your company details'), findsOneWidget);
      expect(find.text('CAHAYA TEKSI SDN. BHD.'), findsOneWidget);
      expect(find.text('You are listed as a director.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('company-confirm')));
      final saved = h.repo.patches.last;
      expect(saved['company_reg_no'], '201901012345 (1321234-K)');
      expect(saved['company_reg_date'], '2019-04-12');
      expect(saved['company_driver_is_director'], isTrue);
      expect(saved['company_directors'], [
        {'name': 'AINA BINTI RAHMAN'},
        {'name': 'MOHD FAIZ BIN ISA'},
      ]);
      expect(saved['registration_steps'], ['details', 'company']);
      expect(find.text('Upload your driver permit'), findsOneWidget);
      _noOverflow(tester);
    });

    testWidgets('Driver permit: read from the Kad Pemandu, checks against the ID and company (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(
          profile: _detailsDone,
          partner: _partner({
            ..._photo,
            ..._area,
            'partner_types': ['Teksi'],
            'registration_steps': ['details', 'company'],
            'company_name': 'CAHAYA TEKSI SDN. BHD.',
            'company_reg_no': '201901012345 (1321234-K)',
          }),
        ),
        brightness: b,
        texts: {'driver-permit/front': _permitText},
      );
      expect(find.textContaining('Kad Pemandu issued by APAD'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('permit-front')));
      await _tap(tester, find.byKey(const ValueKey('permit-back')));
      expect(h.gates, 2);
      await _tap(tester, find.byKey(const ValueKey('permit-read')));
      expect(find.text('Check your permit details'), findsOneWidget);
      expect(find.text('Name and ID number match your ID'), findsOneWidget);
      expect(find.text('Operator matches your company (SSM 201901012345)'), findsOneWidget);
      expect(find.textContaining('You are the 2nd driver for HWA 8812'), findsOneWidget);
      expect(find.textContaining('Valid for 6 more months'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('permit-confirm')));
      final saved = h.repo.patches.last;
      expect(saved['driver_permit_card_no'], 'KP/B/2024/0000001');
      expect(saved['driver_permit_valid_until'], '2027-05-01');
      expect(saved['driver_permit_position'], 2);
      expect(saved['driver_permit_plate'], 'HWA 8812');
      expect(saved['driver_permit_flags'], isEmpty);
      expect(find.text('Register your vehicle'), findsOneWidget);
      _noOverflow(tester);
    });
  }

  for (final b in Brightness.values) {
    testWidgets('Register vehicle: grant first, age per service, permits, owner, photos (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(
          profile: _detailsDone,
          partner: _partner({
            ..._photo, ..._area, 'phone': '+60123456789', 'partner_types': ['eHailing', 'Delivery'],
            'registration_steps': ['details'],
          }),
        ),
        brightness: b,
        texts: {'vehicle-grant/front': _grantText},
      );
      expect(find.text('Register your vehicle'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('grant-front')));
      await _tap(tester, find.byKey(const ValueKey('grant-read')));
      expect(find.text('Check your vehicle details'), findsOneWidget);
      expect(find.text('WXY 1234'), findsOneWidget);
      // 2009: 17 years old, over eHailing's 15. Paused, not refused.
      expect(find.text('eHailing: limit 15 years. Not active until you add a newer vehicle.'), findsOneWidget);
      expect(find.textContaining('the paused one turns on when you add a newer vehicle'), findsOneWidget);
      expect(find.textContaining('eHailing: needs EVP (APAD)'), findsOneWidget);
      expect(find.text('Owner matches your ID. Nothing more is needed.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('vehicle-save')));
      expect(h.repo.patches.last, {'registration_vehicle_id': 'v1'});
      final v = h.vehicles.updates.last;
      expect(v['registration_date'], '2009-03-15');
      expect(v['vin'], 'PM2B000000000001');
      expect(v['engine_cc'], 1329);
      expect(v['owner_match'], 'driver');
      // H1: the driver owns it, so their ID and phone are the owner's.
      expect(v['owner_ic'], '900101-14-5678');
      expect(v['owner_phone'], '+60123456789');
      expect(v['service_id'], 'ride', reason: 'from the make and model, as today');
      expect(v['grant_front_url'], contains('vehicle-grant/front'));
      expect(h.vehicles.statuses.single['status'], 'paused_age');
      expect(find.text('Your vehicle'), findsOneWidget);
      for (final slot in ['front', 'left', 'right', 'back']) {
        await _tap(tester, find.byKey(ValueKey('vehicle-photo-$slot')));
      }
      expect(find.byKey(const ValueKey('vehicle-authorisation')), findsNothing, reason: 'the owner is the driver');
      await _tap(tester, find.byKey(const ValueKey('vehicle-continue')));
      expect(h.repo.patches.last['registration_steps'], ['details', 'vehicle']);
      expect(find.text('Upload vehicle documents'), findsOneWidget);
      _noOverflow(tester);
    });

    testWidgets('Register vehicle: the vehicle service, set by the make & model or chosen (${b.name})', (tester) async {
      final h = await _pump(
        tester,
        OnboardingState(
          profile: _detailsDone,
          partner: _partner({
            ..._photo, ..._area, 'phone': '+60123456789', 'partner_types': ['eHailing'],
            'registration_steps': ['details'],
          }),
        ),
        brightness: b,
        texts: {'vehicle-grant/front': _grantText},
        people: _FakePeople(services: [
          (id: 'ride', values: <String, dynamic>{'name': 'Ride'}),
          (id: 'comfort', values: <String, dynamic>{'name': 'Comfort'}),
        ]),
      );
      await _tap(tester, find.byKey(const ValueKey('grant-front')));
      await _tap(tester, find.byKey(const ValueKey('grant-read')));
      // PERODUA BEZZA: GET.ride set Ride for it, so it is filled in.
      expect(find.text('Vehicle service *'), findsOneWidget);
      expect(find.text('Ride · from make & model'), findsOneWidget);
      // Another model the list sets nothing for: the driver must choose.
      await tester.enterText(find.widgetWithText(TextField, 'Model'), 'AXIA');
      await _settle(tester);
      expect(find.text('Ride · from make & model'), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('vehicle-save')));
      await closeNotice(tester);
      expect(find.text(vehicleServiceMissing), findsOneWidget, reason: 'the field says what is missing');
      expect(h.vehicles.updates, isEmpty, reason: 'nothing saved without a service');
      await _tap(tester, find.byKey(const ValueKey('vehicle-service')));
      await _tap(tester, find.text('Comfort').last);
      expect(find.text(vehicleServiceMissing), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('vehicle-save')));
      expect(h.vehicles.updates.last['service_id'], 'comfort');
      expect(h.vehicles.updates.last['model'], 'AXIA');
      _noOverflow(tester);
    });

    testWidgets('a vehicle owned by someone else needs the owner\'s letter (${b.name})', (tester) async {
      final vehicles = _FakeVehicles()
        ..v = {
          'id': 'v1',
          'plate': 'WXY 1234',
          'make': 'PERODUA',
          'model': 'BEZZA',
          'owner_match': 'other',
          'registration_date': '2021-03-15',
          for (final s in ['front', 'left', 'right', 'back']) 'image_$s': 'x',
        };
      await _pump(
        tester,
        OnboardingState(
          profile: _detailsDone,
          partner: _partner({
            ..._photo,
            ..._area,
            'partner_types': ['eHailing'],
            'registration_steps': ['details'],
            'registration_vehicle_id': 'v1',
          }),
        ),
        brightness: b,
        vehicles: vehicles,
      );
      expect(find.text('Authorisation letter from the owner'), findsOneWidget);
      expect(find.text('Rental / hire-purchase agreement'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('vehicle-continue')));
      expect(find.text("Add the owner's authorisation letter."), findsOneWidget, reason: 'a modal says so');
      await _tap(tester, find.byKey(const ValueKey('notice-ok')));
      await _tap(tester, find.byKey(const ValueKey('vehicle-authorisation')));
      expect(vehicles.updates.last.keys, ['authorisation_letter_url']);
      _noOverflow(tester);
    });

    testWidgets('service documents leave out the permit read in its own step; submit sends both (${b.name})', (tester) async {
      final vehicles = _FakeVehicles()..v = {'id': 'v1', 'plate': 'HWA 8812', 'documents_ok': false};
      final h = await _pump(
        tester,
        OnboardingState(
          profile: _detailsDone,
          partner: _partner({
            ..._photo,
            ..._area,
            'partner_types': ['Teksi'],
            'registration_steps': ['details', 'company', 'driver-permit', 'vehicle', 'vehicle-documents'],
            'registration_vehicle_id': 'v1',
          }),
        ),
        brightness: b,
        vehicles: vehicles,
        people: _FakePeople(uploads: [
          {'doc_id': 'licence', 'status': 'Pending Review'},
        ]),
      );
      expect(find.text('Upload service documents'), findsOneWidget);
      expect(find.text('Driving licence'), findsOneWidget);
      expect(find.text('Taxi permit'), findsNothing, reason: 'read in the Driver permit step');
      await _tap(tester, find.text('Submit for review'));
      expect(vehicles.updates.last, {'documents_ok': true, 'onboarding_step': 'done'});
      expect(h.repo.patches.last, {'documents_ok': true});
      expect(find.byKey(const ValueKey('pending-approval')), findsOneWidget);
      expect(find.text('Pending admin approval'), findsOneWidget);
      _noOverflow(tester);
    });

    testWidgets('pending: paused services and vehicle permits waiting (${b.name})', (tester) async {
      final vehicles = _FakeVehicles()
        ..v = {'id': 'v1', 'plate': 'WXY 1234'}
        ..statuses.addAll([
          {'service': 'eHailing', 'status': 'paused_age', 'max_age_years': 15},
          {'service': 'Teksi', 'status': 'waiting_permit', 'permit_name': 'EVP'},
        ]);
      await _pump(
        tester,
        OnboardingState(
          profile: _detailsDone,
          partner: _partner({..._photo, ..._area, 'partner_types': ['eHailing'], 'registration_vehicle_id': 'v1', 'documents_ok': true}),
        ),
        brightness: b,
        vehicles: vehicles,
      );
      expect(find.text('Pending admin approval'), findsOneWidget);
      expect(find.text('eHailing not active'), findsOneWidget);
      expect(find.text('EVP for Teksi'), findsOneWidget);
      expect(find.textContaining('Partner and vehicle are reviewed together.'), findsOneWidget);
      _noOverflow(tester);
    });
  }

  testWidgets('finished steps reopen from the header; later ones are locked labels', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, OnboardingState(profile: const {}, partner: _partner({..._photo, ..._area})));
    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).toList();
    expect(chips.map((c) => (c.label as Text).data), ['Profile photo', 'Service area', 'Partner Service type'],
        reason: 'the photo step, done, is listed too, so the count holds');
    expect(chips.first.avatar, isA<Icon>(), reason: 'a finished step keeps its tick');
    expect(find.text('National ID · next'), findsOneWidget);
    final locked = tester.getSemantics(find.byKey(const ValueKey('onboarding-step-id')));
    expect(locked.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    await _tap(tester, find.widgetWithText(ChoiceChip, 'Service area'));
    expect(find.text('Where will you work?'), findsOneWidget);
    handle.dispose();
  });
}

void startStepTests() {
  test('"Update documents" opens on the service documents unless an earlier step is still missing', () {
    expect(onboardingStepFromQuery('requirements'), OnboardingStep.requirements);
    expect(onboardingStepFromQuery('nope'), isNull);
    expect(onboardingStepFromQuery(null), isNull);
    expect(onboardingStartStep(OnboardingStep.done, OnboardingStep.requirements), OnboardingStep.requirements);
    expect(onboardingStartStep(OnboardingStep.requirements, OnboardingStep.requirements), OnboardingStep.requirements);
    expect(onboardingStartStep(OnboardingStep.id, OnboardingStep.requirements), OnboardingStep.id,
        reason: 'the steps go in order: the missing ID comes first');
    expect(permitDocumentsRoute, '/drive/onboarding?step=requirements');
  });

  for (final b in Brightness.values) {
    testWidgets('a submitted partner sent for their documents lands on the service documents (${b.name})',
        (tester) async {
      await _pump(
        tester,
        OnboardingState(
          profile: _detailsDone,
          partner: _partner({..._photo, ..._area, 'partner_types': ['Delivery'], 'documents_ok': true}),
        ),
        brightness: b,
        screen: const PartnerOnboardingScreen(onPhone: true, startAt: OnboardingStep.requirements),
      );
      expect(find.text('Upload service documents'), findsOneWidget);
      final docs = tester.widget<ChoiceChip>(find.byKey(const ValueKey('onboarding-step-requirements')));
      expect(docs.selected, isTrue);
      _noOverflow(tester);
    });
  }
}

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}
