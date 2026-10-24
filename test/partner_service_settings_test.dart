import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/screens/catalogue/catalogue_logic.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart' show ServiceArea;
import 'package:get_ride/src/core/partner_type_rules.dart';

const _selangor = ServiceArea(
  countries: ['Malaysia'],
  states: ['Malaysia|Selangor'],
  cities: ['Malaysia|Selangor|Ampang'],
);
const _johor = ServiceArea(countries: ['Malaysia'], states: ['Malaysia|Johor']);
const _singapore = ServiceArea(countries: ['Singapore']);

/// Example settings only (no real permit holder): eHailing is citizens-only
/// in Malaysia, needs a vehicle permit there (also for a taxi) and is 15
/// years (10 in Selangor); Teksi needs a business in Malaysia and Kad
/// Pemandu, is 20 years and covers eHailing; Motor has no permit; Dealer
/// needs no vehicle.
final _entries = <Map<String, dynamic>>[
  {
    'name': 'eHailing',
    'vehicleRequired': true,
    'rules': {
      'vehicleAge': {
        'required': true,
        'rules': [
          {'country': 'Malaysia', 'maxYears': 15},
          {'country': 'Malaysia', 'state': 'Selangor', 'maxYears': 10},
        ],
      },
    },
    'citizensOnly': {
      'required': true,
      'all': false,
      'regions': [
        {'country': 'Malaysia'},
      ],
    },
    'vehiclePermit': {
      'required': true,
      'rules': [
        {'country': 'Malaysia', 'name': 'EVP', 'issuer': 'APAD', 'permitType': 'evp'},
      ],
    },
    'vehiclePermitAlsoFor': ['TEKSI'],
  },
  {
    'name': 'Teksi',
    'vehicleRequired': true,
    'rules': {
      'vehicleAge': {
        'required': true,
        'rules': [
          {'country': 'Malaysia', 'maxYears': 20},
        ],
      },
    },
    'citizensOnly': {
      'required': true,
      'all': false,
      'regions': [
        {'country': 'Malaysia', 'state': 'Selangor'},
      ],
    },
    'businessRegistration': {
      'required': true,
      'all': false,
      'regions': [
        {'country': 'Malaysia'},
      ],
    },
    'driverPermit': {
      'required': true,
      'rules': [
        {'country': 'Malaysia', 'name': 'Kad Pemandu', 'issuer': 'APAD', 'permitType': 'kad-pemandu'},
      ],
    },
    'ageLimitCovers': [
      {
        'country': 'Malaysia',
        'types': ['eHailing'],
      },
    ],
  },
  {
    'name': 'Motor',
    'vehicleRequired': true,
    'rules': {
      'vehicleAge': {
        'required': true,
        'rules': [
          {'maxYears': 8},
        ],
      },
    },
    'ageLimitCovers': [
      {
        'types': ['eHailing'],
      },
    ],
  },
  {
    'name': 'Limo',
    'vehicleRequired': true,
    'driverPermit': {
      'required': true,
      'rules': [
        {'country': 'Malaysia', 'name': 'Kad Pemandu', 'issuer': 'APAD', 'permitType': 'kad-pemandu'},
        {'country': 'Singapore', 'name': 'Vocational licence', 'issuer': 'LTA'},
      ],
    },
  },
  {
    'name': 'Dealer',
    'vehicleRequired': false,
    'businessRegistration': {'required': true, 'all': true, 'regions': <Object>[]},
    // A vehicle permit on a type that needs no vehicle is ignored.
    'vehiclePermit': {
      'required': true,
      'rules': [
        {'name': 'X'},
      ],
    },
  },
];

void main() {
  group('PartnerServiceSettings', () {
    test('missing keys are off', () {
      final s = PartnerServiceSettings.fromValues(const {'name': 'Dealer'});
      expect(s.citizensOnly.required, isFalse);
      expect(s.businessRegistration.required, isFalse);
      expect(s.driverPermit.required, isFalse);
      expect(s.vehiclePermit.required, isFalse);
      expect(s.vehiclePermitAlsoFor, isEmpty);
      expect(s.ageLimitCovers, isEmpty);
    });

    test('round-trips through values, also from JSON strings', () {
      final s = PartnerServiceSettings.fromValues(_entries[1]);
      final back = PartnerServiceSettings.fromValues(s.toValues());
      expect(back.toValues(), s.toValues());
      expect(back.driverPermit.rules.single.label, 'Kad Pemandu (APAD)');
      expect(back.ageLimitCovers.single.types, ['eHailing']);
      final fromStrings = PartnerServiceSettings.fromValues({
        'citizensOnly': '{"required": true, "all": true}',
        'vehiclePermitAlsoFor': '["Teksi", "teksi", ""]',
      });
      expect(fromStrings.citizensOnly.required, isTrue);
      expect(fromStrings.vehiclePermitAlsoFor, ['Teksi'], reason: 'deduplicated by name key, blanks dropped');
    });

    test('problems', () {
      String? p(PartnerServiceSettings s, {bool vehicle = true, bool age = true}) =>
          s.problem(vehicleRequired: vehicle, ageRequired: age);
      const none = PartnerServiceSettings();
      expect(p(none), isNull);
      expect(
        p(none.copyWith(citizensOnly: const RegionRequirement(required: true, where: RegionList(all: false)))),
        contains('only citizens'),
      );
      expect(
        p(none.copyWith(businessRegistration: const RegionRequirement(required: true, where: RegionList(all: false)))),
        contains('registered business'),
      );
      expect(p(none.copyWith(driverPermit: const PermitRequirement(required: true))), contains('driver permit'));
      expect(
        p(none.copyWith(driverPermit: const PermitRequirement(required: true, rules: [PermitRule()]))),
        'Name the driver permit for All regions.',
      );
      expect(
        p(none.copyWith(
          driverPermit: const PermitRequirement(required: true, rules: [PermitRule(name: 'A'), PermitRule(name: 'B')]),
        )),
        contains('Two driver permit rules'),
      );
      const badVehicle = PartnerServiceSettings(vehiclePermit: PermitRequirement(required: true));
      expect(p(badVehicle), contains('vehicle permit'));
      expect(p(badVehicle, vehicle: false), isNull, reason: 'hidden without a vehicle');
      const badCover = PartnerServiceSettings(ageLimitCovers: [AgeCoverRule()]);
      expect(p(badCover), contains('age limit covers'));
      expect(p(badCover, age: false), isNull, reason: 'hidden without the age limit');
    });

    test('buildPartnerTypeValues writes them once edited, else keeps what was stored', () {
      final editing = SettingEntry(id: 'teksi', values: {..._entries[1], 'enabled': true});
      ValuesResult build(PartnerServiceSettings? s) => buildPartnerTypeValues(
            entries: [editing],
            editing: editing,
            name: 'Teksi',
            shortInfo: '',
            iconUrl: '',
            enabled: true,
            subServicesEnabled: false,
            vehicleRequired: true,
            tree: const [],
            docTypes: const [],
            settings: s,
          );
      final kept = build(null).values;
      for (final k in ['citizensOnly', 'businessRegistration', 'driverPermit', 'ageLimitCovers']) {
        expect(kept[k], _entries[1][k], reason: k);
      }
      expect(kept.containsKey('vehiclePermit'), isFalse);
      final edited = build(const PartnerServiceSettings(vehiclePermitAlsoFor: ['eHailing'])).values;
      expect(edited['vehiclePermitAlsoFor'], ['eHailing']);
      expect((edited['citizensOnly'] as Map)['required'], isFalse);
      final refused = build(const PartnerServiceSettings(vehiclePermit: PermitRequirement(required: true)));
      expect(refused.error, contains('vehicle permit'));
    });
  });

  group('citizens only and business registration', () {
    const all = ['eHailing', 'Teksi', 'Motor', 'Dealer'];

    test('citizensOnlyTypes: by country and by state', () {
      expect(citizensOnlyTypes(all, _entries, _selangor), ['eHailing', 'Teksi']);
      expect(citizensOnlyTypes(all, _entries, _johor), ['eHailing']);
      expect(citizensOnlyTypes(all, _entries, _singapore), isEmpty);
      expect(openToEveryoneTypes(all, _entries, _selangor), ['Motor', 'Dealer']);
      expect(openToEveryoneTypes(['ehailing', 'motor'], _entries, _johor), ['Motor'],
          reason: 'names compare as the apps do, and come back as the entries spell them');
    });

    test('an area spanning a citizens-only state counts', () {
      const both = ServiceArea(
        countries: ['Malaysia'],
        states: ['Malaysia|Selangor', 'Malaysia|Johor'],
        cities: ['Malaysia|Selangor|Ampang'],
      );
      expect(citizensOnlyTypes(['Teksi'], _entries, both), ['Teksi']);
    });

    test('needsBusinessRegistration', () {
      expect(needsBusinessRegistration(['eHailing'], _entries, _selangor), isFalse);
      expect(needsBusinessRegistration(['eHailing', 'Teksi'], _entries, _selangor), isTrue);
      expect(needsBusinessRegistration(['Teksi'], _entries, _singapore), isFalse);
      expect(needsBusinessRegistration(['Dealer'], _entries, _singapore), isTrue, reason: 'All regions');
      expect(businessRegistrationTypes(['Teksi', 'Dealer', 'Motor'], _entries, _johor), ['Teksi', 'Dealer']);
      expect(needsBusinessRegistration(['Unknown'], _entries, _selangor), isFalse);
    });
  });

  group('permits', () {
    test('driverPermitFor: name, issuer and region; one per permit', () {
      final kp = driverPermitFor(['eHailing', 'Teksi', 'Limo'], _entries, _selangor);
      expect(kp, hasLength(1), reason: 'Teksi and Limo share Kad Pemandu');
      expect(kp.single, (type: 'Teksi', name: 'Kad Pemandu', issuer: 'APAD', permitType: 'kad-pemandu', region: 'Malaysia'));
      final sg = driverPermitFor(['Teksi', 'Limo'], _entries, _singapore);
      expect(sg.single.name, 'Vocational licence');
      expect(sg.single.permitType, '');
      expect(driverPermitFor(['eHailing'], _entries, _selangor), isEmpty);
    });

    test('vehiclePermitFor: the service, the types it also covers, an unregistered vehicle', () {
      final evp = vehiclePermitFor('eHailing', ['eHailing'], _entries, _selangor);
      expect(evp?.name, 'EVP');
      expect(evp?.issuer, 'APAD');
      expect(evp?.permitType, 'evp');
      expect(vehiclePermitFor('eHailing', ['Teksi'], _entries, _selangor)?.name, 'EVP',
          reason: 'a taxi doing eHailing needs it too');
      expect(vehiclePermitFor('eHailing', ['Motor'], _entries, _selangor), isNull, reason: 'a motorbike does not');
      expect(vehiclePermitFor('eHailing', const [], _entries, _selangor)?.name, 'EVP', reason: 'not registered yet');
      expect(vehiclePermitFor('eHailing', ['eHailing'], _entries, _singapore), isNull, reason: 'Malaysia only');
      expect(vehiclePermitFor('Teksi', ['Teksi'], _entries, _selangor), isNull);
      expect(vehiclePermitFor('Dealer', const [], _entries, _selangor), isNull, reason: 'no vehicle service');
    });

    test('the narrowest permit rule wins', () {
      const r = PermitRequirement(required: true, rules: [
        PermitRule(scope: RegionScope(country: 'Malaysia'), name: 'Country'),
        PermitRule(scope: RegionScope(country: 'Malaysia', state: 'Selangor'), name: 'State'),
      ]);
      expect(r.ruleAt((country: 'Malaysia', state: 'Selangor', city: '', suburb: ''))?.name, 'State');
      expect(r.ruleAt((country: 'Malaysia', state: 'Johor', city: '', suburb: ''))?.name, 'Country');
      expect(r.copyWith(required: false).ruleAt((country: 'Malaysia', state: '', city: '', suburb: '')), isNull);
    });
  });

  group('effectiveMaxVehicleAge', () {
    test("the service's own limit, narrowest rule", () {
      expect(effectiveMaxVehicleAge('eHailing', ['eHailing'], _entries, _selangor),
          (maxYears: 10, type: 'eHailing', region: 'Selangor'));
      expect(effectiveMaxVehicleAge('eHailing', ['eHailing'], _entries, _johor),
          (maxYears: 15, type: 'eHailing', region: 'Malaysia'));
      expect(effectiveMaxVehicleAge('eHailing', ['eHailing'], _entries, _singapore), isNull);
    });

    test("a registered taxi's limit replaces eHailing's where Teksi covers it", () {
      expect(effectiveMaxVehicleAge('eHailing', ['Teksi'], _entries, _johor),
          (maxYears: 20, type: 'Teksi', region: 'Malaysia'));
      expect(effectiveMaxVehicleAge('eHailing', ['Teksi', 'eHailing'], _entries, _selangor)?.maxYears, 20);
      expect(effectiveMaxVehicleAge('Teksi', ['Teksi'], _entries, _johor)?.maxYears, 20);
    });

    test('the cover replaces, even when lower; several covers take the largest', () {
      expect(effectiveMaxVehicleAge('eHailing', ['Motor'], _entries, _johor),
          (maxYears: 8, type: 'Motor', region: ''));
      expect(effectiveMaxVehicleAge('eHailing', ['Motor', 'Teksi'], _entries, _johor)?.maxYears, 20);
    });

    test('no limit for the service means none, covered or not', () {
      expect(effectiveMaxVehicleAge('Limo', ['Teksi'], _entries, _johor), isNull);
      expect(effectiveMaxVehicleAge('', ['Teksi'], _entries, _johor), isNull);
    });

    test('over an area, the lowest place wins', () {
      const both = ServiceArea(
        countries: ['Malaysia'],
        states: ['Malaysia|Selangor', 'Malaysia|Johor'],
        cities: ['Malaysia|Selangor|Ampang'],
      );
      expect(effectiveMaxVehicleAge('eHailing', ['eHailing'], _entries, both)?.maxYears, 10);
    });

    test('vehicle age from the registration date', () {
      final reg = DateTime(2010, 11, 1);
      expect(vehicleAgeYears(reg, now: DateTime(2026, 10, 31)), 15);
      expect(vehicleAgeYears(reg, now: DateTime(2026, 11, 1)), 16);
      expect(vehicleAgeYears(DateTime(2030), now: DateTime(2026)), 0);
      const limit = (maxYears: 15, type: 'eHailing', region: '');
      expect(overVehicleAgeLimit(reg, limit, now: DateTime(2026, 10, 31)), isFalse);
      expect(overVehicleAgeLimit(reg, limit, now: DateTime(2026, 11, 1)), isTrue);
    });
  });
}
