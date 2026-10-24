import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/core/partner_onboarding.dart';
import 'package:get_ride/src/core/partner_registration.dart';

Map<String, dynamic> _partner({
  String? avatar,
  String? ic,
  String? address,
  List<String> countries = const [],
  List<String> states = const [],
  List<String> cities = const [],
  List<String> types = const [],
  bool docsOk = false,
}) =>
    {
      'avatar_url': avatar,
      'ic': ic,
      'address': address,
      'service_countries': countries,
      'service_states': states,
      'service_cities': cities,
      'partner_types': types,
      'documents_ok': docsOk,
    };

RequiredDoc _doc(String id, {bool compulsory = true}) => RequiredDoc(
      id: id,
      name: id,
      description: '',
      compulsory: compulsory,
      scope: 'global',
      labels: const ['Global'],
      flags: const DocFlags(),
    );

void main() {
  group('firstIncompleteStep (0288 order)', () {
    const id = {
      'id_type': 'mykad',
      'ic': '900101-14-5678',
      'id_image': 'https://x/ID_Image/u/id_front.jpg',
      'id_image_back': 'https://x/ID_Image/u/id_back.jpg',
    };
    final area = _partner(
      avatar: 'a',
      countries: ['Malaysia'],
      states: ['Malaysia|Selangor'],
      cities: ['Malaysia|Selangor|Ampang'],
    );

    test('a brand-new partner starts at the photo', () {
      expect(firstIncompleteStep(null, null), OnboardingStep.avatar);
      expect(firstIncompleteStep({}, _partner()), OnboardingStep.avatar);
      expect(firstIncompleteStep({'avatar_url': '  '}, _partner()), OnboardingStep.avatar, reason: 'blank does not count');
    });

    test('on a phone the photo must have passed the live check', () {
      expect(firstIncompleteStep({'profile_image': 'p.png'}, _partner(), onPhone: true), OnboardingStep.avatar);
      expect(
        firstIncompleteStep({'profile_image': 'p.png'}, {..._partner(), 'selfie_liveness': 'passed'}, onPhone: true),
        OnboardingStep.serviceArea,
      );
      expect(firstIncompleteStep({'profile_image': 'p.png'}, _partner()), OnboardingStep.serviceArea,
          reason: 'elsewhere any photo will do (flagged for the admin)');
    });

    test('service area, then Partner Service type, then the National ID', () {
      final p = _partner(avatar: 'a', countries: ['Malaysia'], states: ['Malaysia|Selangor']);
      expect(firstIncompleteStep(null, p), OnboardingStep.serviceArea, reason: 'a city is needed too');
      expect(firstIncompleteStep(null, area), OnboardingStep.partnerType);
      final typed = {...area, 'partner_types': ['TEKSI']};
      expect(firstIncompleteStep(null, typed), OnboardingStep.id);
      expect(firstIncompleteStep({...id, 'id_image_back': ''}, typed), OnboardingStep.id, reason: 'both photos');
      expect(firstIncompleteStep({...id, 'id_type': 'driving-licence'}, typed), OnboardingStep.id);
      expect(firstIncompleteStep(id, typed), OnboardingStep.details);
    });

    test('the optional steps only when the picks need them, in order', () {
      final typed = {...area, 'partner_types': ['TEKSI'], 'registration_steps': ['details']};
      expect(firstIncompleteStep(id, typed), OnboardingStep.requirements, reason: 'nothing else needed');
      const all = RegistrationNeeds(company: true, driverPermit: true, vehicle: true);
      expect(firstIncompleteStep(id, typed, needs: all), OnboardingStep.company);
      expect(
        firstIncompleteStep(id, {...typed, 'registration_steps': ['details', 'company']}, needs: all),
        OnboardingStep.driverPermit,
      );
      expect(
        firstIncompleteStep(id, {...typed, 'registration_steps': ['details', 'company', 'driver-permit']}, needs: all),
        OnboardingStep.vehicle,
      );
      expect(
        firstIncompleteStep(
          id,
          {...typed, 'registration_steps': ['details', 'company', 'driver-permit', 'vehicle']},
          needs: all,
        ),
        OnboardingStep.vehicleDocs,
      );
      expect(
        firstIncompleteStep(
          id,
          {...typed, 'registration_steps': ['details', 'company', 'driver-permit', 'vehicle', 'vehicle-documents']},
          needs: all,
        ),
        OnboardingStep.requirements,
      );
    });

    test('an application already sent is done, whatever the new steps say', () {
      expect(firstIncompleteStep(null, {..._partner(), 'documents_ok': true}), OnboardingStep.done);
    });

    test('someone part-way through the old order resumes at the first step missing in the new one', () {
      // The old order kept the ID number and address, no ID type or photos.
      final old = {...area, 'partner_types': ['TEKSI'], 'ic': '900101-14-5678', 'address': 'Jalan 1'};
      expect(firstIncompleteStep({'ic': '900101-14-5678', 'address': 'Jalan 1'}, old), OnboardingStep.id);
    });

    test('the steps a partner sees, and the keys stored in onboarding_step', () {
      expect(OnboardingStep.stepsFor(RegistrationNeeds.none).map((s) => s.label), [
        'Profile photo',
        'Service area',
        'Partner Service type',
        'National ID',
        'Check your details',
        'Service documents',
      ]);
      expect(
        OnboardingStep.stepsFor(const RegistrationNeeds(vehicle: true), includePhoto: false).map((s) => s.key),
        ['service-area', 'partner-type', 'id', 'details', 'vehicle', 'vehicle-documents', 'requirements'],
      );
      expect(OnboardingStep.done.label, 'Pending admin approval');
    });

    test('the progress line counts the steps that apply', () {
      expect(onboardingProgress(null, const {}), (step: 1, of: 6, label: 'Profile photo', done: 0.0));
      final p = onboardingProgress(const {'avatar_url': 'a'}, {...area, 'partner_types': ['TEKSI']},
          needs: const RegistrationNeeds(vehicle: true))!;
      expect('Step ${p.step} of ${p.of} · ${p.label}', 'Step 4 of 8 · National ID');
      expect(onboardingProgress(null, {..._partner(), 'documents_ok': true}), isNull);
    });
  });

  test('a stub row is not an active partner until a type is chosen', () {
    expect(isActivePartner(null), isFalse);
    expect(isActivePartner(_partner()), isFalse);
    expect(isActivePartner(_partner(types: ['E-HAILING'])), isTrue);
    expect(isActivePartner(_partner(docsOk: true)), isTrue);
  });

  test('setup is incomplete until a type is chosen and documents are submitted', () {
    expect(partnerSetupIncomplete(_partner()), isTrue);
    expect(partnerSetupIncomplete(_partner(types: ['TEKSI'])), isTrue);
    expect(partnerSetupIncomplete(_partner(types: ['TEKSI'], docsOk: true)), isFalse);
  });

  test('the stub satisfies the self-insert guard and copies the profile', () {
    final row = newPartnerStub(
      id: 'p1',
      displayId: 'PR-123456',
      userId: 'u1',
      profile: {'name': 'Aina', 'phone': '+60123', 'email': '', 'profile_image': 'img.png'},
      joinedAt: '2026-10-04T00:00:00Z',
    );
    expect(row['auth_user_id'], 'u1');
    expect(row['status'], 'unapproved');
    expect(row['permit'], 'none');
    expect(row['rating'], 0);
    expect(row['total_rides'], 0);
    expect(row['documents_ok'], false);
    expect(row['name'], 'Aina');
    expect(row['email'], isNull);
    expect(row['avatar_url'], 'img.png');
    expect(row['partner_types'], isEmpty);
  });

  group('compulsoryDocsComplete', () {
    final now = DateTime.utc(2026, 10, 4);
    final docs = [_doc('licence'), _doc('insurance'), _doc('extra', compulsory: false)];

    test('every compulsory document needs a live upload', () {
      final uploads = {
        'licence': {'status': 'Pending Review'},
        'extra': {'status': 'Approved'},
      };
      expect(compulsoryDocsComplete(docs, uploads, now: now), isFalse);
      expect(
        compulsoryDocsComplete(docs, {...uploads, 'insurance': {'status': 'Approved'}}, now: now),
        isTrue,
      );
    });

    test('rejected or expired uploads do not count', () {
      final base = {'licence': {'status': 'Approved'}};
      expect(compulsoryDocsComplete(docs, {...base, 'insurance': {'status': 'Rejected'}}, now: now), isFalse);
      expect(
        compulsoryDocsComplete(
            docs, {...base, 'insurance': {'status': 'Approved', 'expiry_date': '2026-01-01'}}, now: now),
        isFalse,
      );
    });

    test('nothing compulsory means nothing to wait for', () {
      expect(compulsoryDocsComplete([_doc('x', compulsory: false)], {}, now: now), isTrue);
    });
  });

  test('required documents follow the Partner Service type and service area', () {
    final entries = [
      (id: 'all', values: <String, dynamic>{'name': 'IC copy'}),
      (id: 'teksi', values: <String, dynamic>{'name': 'Taxi permit', 'partnerTypes': ['TEKSI']}),
      (
        id: 'sel',
        values: <String, dynamic>{
          'name': 'Selangor pass',
          'regionsGlobal': false,
          'regions': [
            {'type': 'state', 'country': 'Malaysia', 'state': 'Selangor', 'compulsory': false},
          ],
        }
      ),
    ];
    final area = ServiceArea(countries: ['Malaysia'], states: ['Malaysia|Selangor'], cities: ['Malaysia|Selangor|Ampang']);
    List<String> ids(List<String> types, ServiceArea a) => requiredDocsFor(
          requiredDocuments: entries,
          partnerTypeValues: const [],
          partnerTypes: types,
          area: a,
        ).map((d) => d.id).toList();

    expect(ids(['TEKSI'], area), containsAll(['all', 'teksi', 'sel']));
    expect(ids(['E-HAILING'], area), isNot(contains('teksi')));
    expect(ids(['TEKSI'], const ServiceArea(countries: ['Malaysia'], states: ['Malaysia|Johor'])),
        isNot(contains('sel')));
  });

  test('uploads are filed under the first service country, else nationality', () {
    expect(uploadCountry({'service_countries': ['Malaysia']}, {'nationality': 'Singapore'}), 'Malaysia');
    expect(uploadCountry({'service_countries': []}, {'nationality': 'Singapore'}), 'Singapore');
    expect(uploadCountry(null, null), '');
  });
}
