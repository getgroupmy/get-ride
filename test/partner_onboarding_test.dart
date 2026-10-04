import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/core/partner_onboarding.dart';

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
  group('firstIncompleteStep', () {
    test('a brand-new partner starts at the photo', () {
      expect(firstIncompleteStep(null, null), OnboardingStep.avatar);
      expect(firstIncompleteStep({}, _partner()), OnboardingStep.avatar);
    });

    test('photo, ID and address may already be on the profile', () {
      final profile = {'profile_image': 'p.png', 'ic': '900101-14-5555', 'address': 'Jalan 1'};
      expect(firstIncompleteStep(profile, _partner()), OnboardingStep.serviceArea);
    });

    test('blank values do not count', () {
      expect(firstIncompleteStep({'avatar_url': '  '}, _partner(ic: 'x')), OnboardingStep.avatar);
      expect(firstIncompleteStep(null, _partner(avatar: 'a', ic: ' ')), OnboardingStep.id);
    });

    test('the service area needs a country, a state and a city', () {
      final p = _partner(avatar: 'a', ic: 'i', address: 'ad', countries: ['Malaysia'], states: ['Malaysia|Selangor']);
      expect(firstIncompleteStep(null, p), OnboardingStep.serviceArea);
    });

    test('then partner type, documents, done', () {
      final area = _partner(
        avatar: 'a',
        ic: 'i',
        address: 'ad',
        countries: ['Malaysia'],
        states: ['Malaysia|Selangor'],
        cities: ['Malaysia|Selangor|Ampang'],
      );
      expect(firstIncompleteStep(null, area), OnboardingStep.partnerType);
      expect(firstIncompleteStep(null, {...area, 'partner_types': ['TEKSI']}), OnboardingStep.requirements);
      expect(firstIncompleteStep(null, {...area, 'partner_types': ['TEKSI'], 'documents_ok': true}),
          OnboardingStep.done);
    });

    test('step keys match what the Expo app stores in onboarding_step', () {
      expect(OnboardingStep.wizard.map((s) => s.key),
          ['avatar', 'id', 'address', 'service-area', 'partner-type', 'requirements']);
      expect(OnboardingStep.done.key, 'done');
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

  test('required documents follow the partner type and service area', () {
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
