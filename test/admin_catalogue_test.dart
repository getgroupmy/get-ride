import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/screens/catalogue/catalogue_logic.dart';

SettingEntry e(String id, Map<String, dynamic> v) => SettingEntry(id: id, values: v);

VehicleMakeModel vmm(String id, String vt, String et, String mk, String model, {String from = '', String to = ''}) =>
    VehicleMakeModel(id: id, vehicleType: vt, energyType: et, make: mk, model: model, yearFrom: from, yearTo: to);

void main() {
  group('shared helpers', () {
    test('jsBool follows JS truthiness', () {
      expect(jsBool(null, true), isTrue);
      expect(jsBool(false, true), isFalse);
      expect(jsBool(''), isFalse);
      expect(jsBool('x'), isTrue);
      expect(jsBool(0), isFalse);
    });

    test('sortByPriority puts missing priorities last', () {
      final sorted = sortByPriority([
        e('a', {'displayPriority': 3}),
        e('b', {}),
        e('c', {'displayPriority': '1'}),
      ]);
      expect(sorted.map((x) => x.id), ['c', 'a', 'b']);
    });

    test('sortByPriority ties by name for partner types', () {
      final sorted = sortByPriority([
        e('a', {'displayPriority': 1, 'name': 'Zed'}),
        e('b', {'displayPriority': 1, 'name': 'Alpha'}),
      ], byName: true);
      expect(sorted.map((x) => x.id), ['b', 'a']);
    });

    test('reorderPriorities renumbers only changed rows', () {
      final sorted = [
        e('a', {'displayPriority': 1}),
        e('b', {'displayPriority': 2}),
        e('c', {'displayPriority': 3}),
      ];
      expect(reorderPriorities(sorted, 2, -1), {'c': 2, 'b': 3});
      expect(reorderPriorities(sorted, 0, -1), isEmpty);
      // Unnumbered rows get numbered.
      expect(reorderPriorities([e('x', {}), e('y', {})], 0, 1), {'y': 1, 'x': 2});
    });

    test('toggleWithAll', () {
      expect(toggleWithAll([], allToken), [allToken]);
      expect(toggleWithAll([allToken], allToken), isEmpty);
      expect(toggleWithAll([allToken], 'a'), ['a']);
      expect(toggleWithAll(['a', 'b'], 'a'), ['b']);
    });

    test('entryMatches searches every value', () {
      expect(
        entryMatches(
          e('1', {
            'name': 'Car',
            'serviceTypes': ['Bike'],
          }),
          'bik',
        ),
        isTrue,
      );
      expect(entryMatches(e('1', {'name': 'Car'}), 'van'), isFalse);
    });
  });

  group('service settings', () {
    test('requires a name', () {
      final r = buildServiceValues(
        name: ' ',
        description: '',
        iconUri: '',
        priorityText: '',
        active: true,
        entryCount: 0,
      );
      expect(r.error, 'Please fill in Service Name.');
    });

    test('defaults priority and keeps isDefault on edit', () {
      final r = buildServiceValues(
        name: ' Car ',
        description: ' d ',
        iconUri: 'data:x',
        priorityText: 'abc',
        active: false,
        entryCount: 5,
        editing: {'isDefault': true},
      );
      expect(r.values, {
        'name': 'Car',
        'description': 'd',
        'iconUri': 'data:x',
        'displayPriority': 6,
        'active': false,
        'isDefault': true,
      });
      final add = buildServiceValues(
        name: 'X',
        description: '',
        iconUri: '',
        priorityText: '2.5',
        active: true,
        entryCount: 0,
      );
      expect(add.values['displayPriority'], 2.5);
      expect(add.values['isDefault'], isFalse);
    });
  });

  group('vehicle services', () {
    test('required number fields are validated', () {
      final r = buildVehicleServiceValues(
        text: {'name': 'Ride'},
        numbers: {'costPerKm': '1'},
        serviceTypes: const [],
        fuel: const [],
        status: true,
      );
      expect(r.error, 'Please fill in Cost Per Min.');
    });

    test('numbers default to 0 and lists are arrays', () {
      final r = buildVehicleServiceValues(
        text: {'name': 'Ride', 'mapIconColor': '#EF4444'},
        numbers: {'costPerKm': '1.5', 'costPerMin': '0.2', 'minFareAmount': '5', 'maxPax': 'x'},
        serviceTypes: const ['Car'],
        fuel: const ['Petrol'],
        status: false,
      );
      expect(r.error, isNull);
      expect(r.values['costPerKm'], 1.5);
      expect(r.values['maxPax'], 0);
      expect(r.values['maxVehicleAge'], 0);
      expect(r.values['serviceTypes'], ['Car']);
      expect(r.values['fuelTypes'], ['Petrol']);
      expect(r.values['status'], isFalse);
      expect(r.values['mapIconColor'], '#EF4444');
      expect(r.values.keys, containsAll(vehicleServiceNumberFields.map((f) => f.key)));
    });

    test('service type options come from service settings by priority', () {
      expect(
        serviceTypeOptions([
          e('a', {'name': 'Bike', 'displayPriority': 2}),
          e('b', {'name': 'Car', 'displayPriority': 1}),
          e('c', {'name': ' '}),
        ]),
        ['Car', 'Bike'],
      );
    });

    test('meta line', () {
      expect(vehicleServiceMeta({'costPerKm': 1, 'minFareAmount': 5}), 'Km 1 • Min Fare 5');
    });
  });

  group('partner type', () {
    const json =
        '[{"id":"S-1","name":"A","enabled":true,"children":[{"id":"S-2","name":"A1","children":[]}]},'
        '{"name":""},{"id":"S-3","name":"B","enabled":false}]';

    test('parses and sanitises the sub-service tree', () {
      final t = parseSubServiceTree(json);
      expect(t.map((n) => n.name), ['A', 'B']);
      expect(t[0].children.single.enabled, isTrue);
      expect(t[1].enabled, isFalse);
      expect(countSubServices(t), 3);
      expect(parseSubServiceTree('not json'), isEmpty);
      expect(parseSubServiceTree(null), isEmpty);
    });

    test('round-trips through JSON with Expo keys', () {
      final t = parseSubServiceTree(json);
      final again = jsonDecode(encodeSubServiceTree(t)) as List;
      expect((again.first as Map).keys, ['id', 'name', 'enabled', 'children']);
    });

    test('tree mutations by path', () {
      var t = parseSubServiceTree(json);
      t = addSubService(t, [0, 0], 'A1a', id: 'S-9');
      expect(t[0].children[0].children.single.name, 'A1a');
      expect(canAddSubServiceChild([0, 0, 0]), isFalse);
      expect(addSubService(t, [0, 0, 0], 'too deep'), same(t));
      t = renameSubService(t, [1], 'Bee');
      expect(t[1].name, 'Bee');
      t = toggleSubService(t, [0, 0]);
      expect(t[0].children[0].enabled, isFalse);
      t = removeSubService(t, [0]);
      expect(t.map((n) => n.name), ['Bee']);
      t = addSubService(t, const [], '  ');
      expect(t, hasLength(1));
    });

    test('search covers sub-services', () {
      final x = e('1', {'name': 'Teksi', 'subServicesJson': json});
      expect(partnerTypeMatches(x, 'a1'), isTrue);
      expect(partnerTypeMatches(x, 'zzz'), isFalse);
    });

    test('values: duplicate check, JSON strings, priority', () {
      final all = [
        e('1', {'name': 'Teksi', 'displayPriority': 4, 'isDefault': true}),
        e('2', {'name': 'Dealer'}),
      ];
      final dup = buildPartnerTypeValues(
        entries: all,
        name: 'teksi',
        shortInfo: '',
        iconUrl: '',
        enabled: true,
        subServicesEnabled: false,
        vehicleRequired: false,
        tree: const [],
        docTypes: const [],
      );
      expect(dup.error, 'A partner type with this name already exists.');
      final edit = buildPartnerTypeValues(
        entries: all,
        editing: all[0],
        name: 'Teksi',
        shortInfo: ' hi ',
        iconUrl: '',
        enabled: false,
        subServicesEnabled: true,
        vehicleRequired: true,
        tree: const [SubService(id: 'S-1', name: 'x')],
        docTypes: const [allToken],
      );
      expect(edit.values['isDefault'], isTrue);
      expect(edit.values['displayPriority'], 4);
      expect(edit.values['shortInfo'], 'hi');
      expect(edit.values['docTypes'], '["__ALL__"]');
      expect(edit.values['subServicesJson'], isA<String>());
      final add = buildPartnerTypeValues(
        entries: all,
        name: 'Fleet',
        shortInfo: '',
        iconUrl: '',
        enabled: true,
        subServicesEnabled: false,
        vehicleRequired: false,
        tree: const [],
        docTypes: const [],
      );
      expect(add.values['displayPriority'], 3);
      expect(add.values['isDefault'], isFalse);
    });

    test('partner doc types parse strictly', () {
      expect(parsePartnerDocTypes('["a",1,"b"]'), ['a', 'b']);
      expect(parsePartnerDocTypes('x'), isEmpty);
    });

    test('icon upload path and types', () {
      expect(
        partnerTypeIconPath('png', now: DateTime.fromMillisecondsSinceEpoch(42), rand: 'abc123'),
        'icon-42-abc123.png',
      );
      expect(iconExt('A.JPEG'), 'jpg');
      expect(iconExt('a.heic'), 'png');
      expect(imageContentType('a.webp'), 'image/webp');
      expect(toDataUrl([1, 2, 3], 'x.png'), 'data:image/png;base64,AQID');
    });
  });

  group('document type', () {
    test('defaults plan adds missing and removes legacy defaults only', () {
      final plan = documentTypeDefaultsPlan([
        e('1', {'name': 'Partner', 'isDefault': true}),
        e('2', {'name': 'Teksi', 'isDefault': true}),
        e('3', {'name': 'Custom'}),
        e('4', {'name': 'user'}),
      ]);
      expect(plan.removeIds, ['2']);
      expect(plan.add.map((v) => v['name']), ['Vehicle', 'Admin-Partner', 'Admin-User', 'Admin-Vehicle']);
      expect(plan.add.first['isDefault'], isTrue);
    });

    test('sort defaults first, then by name', () {
      final s = sortDocumentTypes([
        e('1', {'name': 'B'}),
        e('2', {'name': 'Z', 'isDefault': true}),
        e('3', {'name': 'A'}),
      ]);
      expect(s.map((x) => x.id), ['2', '3', '1']);
    });

    test('values and duplicate check', () {
      final all = [
        e('1', {'name': 'User', 'isDefault': true}),
      ];
      expect(buildDocumentTypeValues(entries: all, name: 'user', description: '', enabled: true).error, isNotNull);
      final r = buildDocumentTypeValues(
        entries: all,
        editing: all[0],
        name: 'User',
        description: ' x ',
        enabled: false,
      );
      expect(r.values, {'name': 'User', 'description': 'x', 'isDefault': true, 'enabled': false});
    });

    test('enabled document types sorted by name', () {
      final l = enabledDocumentTypes([
        e('1', {'name': 'B'}),
        e('2', {'name': 'A', 'enabled': false}),
        e('3', {'name': 'A'}),
      ]);
      expect(l.map((x) => x.id), ['3', '1']);
    });
  });

  group('required documents', () {
    test('loose list parsing', () {
      expect(parseLooseList(['a', 1]), ['a', '1']);
      expect(parseLooseList('["x"]'), ['x']);
      expect(parseLooseList('a, b'), ['a', 'b']);
      expect(parseLooseList(null), isEmpty);
    });

    test('regions parse from JSON string', () {
      final r = parseRegions(
        jsonEncode([
          {'type': 'country', 'country': 'Malaysia', 'state': '', 'compulsory': false},
          {'type': 'state', 'country': 'Malaysia', 'state': 'Selangor'},
          {'type': 'state', 'country': 'Malaysia', 'state': ''},
          {'country': ''},
        ]),
      );
      expect(r.map((x) => x.key), ['country:Malaysia', 'state:Malaysia|Selangor']);
      expect(r[0].compulsory, isFalse);
      expect(r[1].compulsory, isTrue);
      expect(r[1].label, 'Selangor, Malaysia');
    });

    test('region summary', () {
      expect(regionSummary({}), 'Global');
      expect(regionSummary({'regionsGlobal': true, 'regions': '[{"country":"MY"}]'}), 'Global');
      expect(regionSummary({'regionsGlobal': false, 'regions': '[{"country":"MY"}]'}), '1 region');
      expect(regionSummary({'regionsGlobal': false, 'regions': '[]'}), 'Global');
    });

    test('form from legacy values infers global and compulsory', () {
      final f = RequiredDocForm.fromValues({'name': 'Driving License', 'required': false});
      expect(f.regionsGlobal, isTrue);
      expect(f.regionsGlobalCompulsory, isFalse);
      expect(f.active, isTrue);
      final g = RequiredDocForm.fromValues({'regions': '[{"type":"country","country":"MY"}]'});
      expect(g.regionsGlobal, isFalse);
    });

    test('region toggling and compulsory cycling', () {
      final f = RequiredDocForm();
      const r = RegionSelection(type: 'country', country: 'MY', compulsory: false);
      f.toggleRegion(r);
      expect(f.regions.single.compulsory, isTrue);
      f.cycleRegionCompulsory('country:MY');
      expect(f.regions.single.compulsory, isFalse);
      f.toggleRegion(r);
      expect(f.regions, isEmpty);
    });

    test('values: validation and Expo shape', () {
      final all = [
        e('1', {'name': 'PSV', 'legacyKey': 1}),
      ];
      final noRegion = RequiredDocForm(name: 'X', regionsGlobal: false);
      expect(
        buildRequiredDocValues(entries: all, form: noRegion).error,
        'Select at least one country/state or enable Global.',
      );
      expect(
        buildRequiredDocValues(
          entries: all,
          form: RequiredDocForm(name: 'psv'),
        ).error,
        isNotNull,
      );

      final f = RequiredDocForm.fromValues(all[0].values)
        ..docTypes = [allToken]
        ..regionsGlobal = false
        ..regions = [const RegionSelection(type: 'state', country: 'MY', state: 'Sel')]
        ..isTaxiPermit = true;
      f.options['requireExpiryDate'] = true;
      final r = buildRequiredDocValues(entries: all, editing: all[0], form: f);
      expect(r.error, isNull);
      expect(r.values['legacyKey'], 1);
      expect(r.values['docTypes'], '["__ALL__"]');
      expect(r.values['partnerTypes'], '[]');
      expect(jsonDecode(r.values['regions'] as String), [
        {'type': 'state', 'country': 'MY', 'state': 'Sel', 'compulsory': true},
      ]);
      expect(r.values['requireExpiryDate'], isTrue);
      expect(r.values['requireStartDate'], isFalse);
      expect(r.values['isTaxiPermit'], isTrue);
    });

    test('partner type names and doc type labels', () {
      expect(
        enabledPartnerTypeNames([
          e('1', {'name': 'Teksi'}),
          e('2', {'name': 'Dealer', 'enabled': false}),
          e('3', {'name': 'Fleet', 'active': true}),
        ]),
        ['Fleet', 'Teksi'],
      );
      final types = [
        e('t1', {'name': 'Partner'}),
      ];
      expect(docTypeLabels(['t1', 'zz'], types), ['Partner', 'Unknown']);
      expect(docTypeLabels([allToken, 't1'], types), ['All']);
    });
  });

  group('vehicle make & model', () {
    final all = [
      vmm('1', 'Car', 'Petrol', 'Proton', 'Wira', from: '1993', to: '2009'),
      vmm('2', 'Car', 'Petrol', 'Proton', 'Saga', from: '2016', to: '~'),
      vmm('3', 'Car', 'EV', 'BYD', 'Atto 3'),
      vmm('4', 'Bike', 'Petrol', '', ''), // placeholder category row
    ];

    test('row mapping matches Expo upsert', () {
      final r = VehicleMakeModel.fromRow({
        'id': 'x',
        'vehicle_type': ' Car ',
        'energy_type': 'EV',
        'make': 'BYD',
        'model': 'Seal',
        'year_from': null,
        'year_to': '~',
        'icon_uri': null,
        'status': null,
        'is_default': true,
        'position': 2,
      });
      expect(r.vehicleType, 'Car');
      expect(r.status, isTrue);
      expect(r.toRow(), {
        'id': 'x',
        'vehicle_type': 'Car',
        'energy_type': 'EV',
        'make': 'BYD',
        'model': 'Seal',
        'year_from': '',
        'year_to': '~',
        'icon_uri': '',
        'status': true,
        'is_default': true,
        'position': 2,
      });
    });

    test('formatYearRange', () {
      expect(formatYearRange('', ''), '');
      expect(formatYearRange('1993', ''), '(1993 ~)');
      expect(formatYearRange('', '2009'), '(~ 2009)');
      expect(formatYearRange('1993', '2009'), '(1993 - 2009)');
      expect(formatYearRange('2016', '~'), '(2016 - ~)');
    });

    test('path levels', () {
      const p = VmmPath(vehicleType: 'Car', energyType: 'Petrol', make: 'Proton');
      expect(p.level, 3);
      expect(p.parent.level, 2);
      expect(const VmmPath().child('Car').vehicleType, 'Car');
      expect(p.renamed(2, 'Proton', 'Perodua').make, 'Perodua');
    });

    test('categories with model counts and deep search', () {
      final root = vmmCategories(all, const VmmPath());
      expect(root, [(name: 'Bike', count: 0), (name: 'Car', count: 3)]);
      expect(vmmCategories(all, const VmmPath(), query: 'wira').map((c) => c.name), ['Car']);
      final energies = vmmCategories(all, const VmmPath(vehicleType: 'Car'));
      expect(energies.map((c) => c.name), ['EV', 'Petrol']);
      // Below level 0 the vehicle-type name itself does not match.
      expect(vmmCategories(all, const VmmPath(vehicleType: 'Car'), query: 'car'), isEmpty);
    });

    test('models and global search', () {
      const path = VmmPath(vehicleType: 'Car', energyType: 'Petrol', make: 'Proton');
      expect(vmmModels(all, path).map((m) => m.model), ['Saga', 'Wira']);
      expect(vmmModels(all, path, query: '1993').map((m) => m.model), ['Wira']);
      expect(vmmGlobalSearch(all, const VmmPath(), 'byd').map((m) => m.id), ['3']);
      expect(vmmGlobalSearch(all, const VmmPath(vehicleType: 'Bike'), 'a'), isEmpty);
    });

    test('category validation', () {
      expect(vmmCategoryError(all, level: 0, name: 'car', parents: const VmmPath()), contains('already exists'));
      expect(
        vmmCategoryError(all, level: 1, name: 'Diesel', parents: const VmmPath()),
        'Please select or enter a Vehicle Type.',
      );
      expect(
        vmmCategoryError(
          all,
          level: 1,
          name: 'Diesel',
          parents: const VmmPath(vehicleType: 'Car'),
        ),
        isNull,
      );
      expect(
        vmmCategoryError(
          all,
          level: 2,
          name: 'Proton',
          parents: const VmmPath(vehicleType: 'Car', energyType: 'Petrol'),
        ),
        isNotNull,
      );
      expect(vmmCategoryError(all, level: 0, name: 'Car', parents: const VmmPath(), renameFrom: 'Car'), isNull);
      expect(
        vmmCategoryError(all, level: 0, name: 'Bike', parents: const VmmPath(), renameFrom: 'Car'),
        '"Bike" already exists at this level.',
      );
    });

    test('rename/delete targets and placeholders', () {
      expect(vmmCategoryRows(all, const VmmPath(vehicleType: 'Car'), 1, 'Petrol').map((r) => r.id), ['1', '2']);
      final ph = vmmCategoryPlaceholder(2, 'Perodua', const VmmPath(vehicleType: 'Car', energyType: 'Petrol'), 'id');
      expect([ph['vehicle_type'], ph['energy_type'], ph['make'], ph['model']], ['Car', 'Petrol', 'Perodua', '']);
      expect(vmmCategoryPlaceholder(0, 'Van', const VmmPath(), 'id')['energy_type'], '');
    });

    test('suggestions', () {
      expect(vmmCategorySuggestions(all, 0, const VmmPath(), 'c'), ['Car']);
      expect(vmmCategorySuggestions(all, 2, const VmmPath(vehicleType: 'Car', energyType: 'EV'), ''), ['BYD']);
      expect(vmmCategorySuggestions(all, 1, const VmmPath(), ''), isEmpty);
    });

    test('model row validation, ongoing and duplicates', () {
      final f = ModelForm(
        vehicleType: 'Car',
        energyType: 'Petrol',
        make: 'Proton',
        model: 'saga',
        yearFrom: '2016',
        ongoing: true,
      );
      expect(buildModelRow(all, f, newId: 'n').error, contains('already exists'));
      f.yearFrom = '2020';
      final r = buildModelRow(all, f, newId: 'n');
      expect(r.row!['id'], 'n');
      expect(r.row!['year_to'], '~');
      expect(r.row!['model'], 'saga');
      expect(buildModelRow(all, ModelForm(vehicleType: 'Car'), newId: 'n').error, 'Please fill in Energy Type.');
      // Editing a row does not collide with itself.
      final edit = ModelForm.fromRecord(all[1]);
      expect(edit.ongoing, isTrue);
      expect(edit.yearTo, '');
      expect(buildModelRow(all, edit, editing: all[1], newId: 'n').row!['id'], '2');
    });
  });

  group('assign service', () {
    test('pages and capabilities match the Expo store', () {
      expect(mappingPages, hasLength(16));
      for (final p in mappingPages) {
        for (final c in p.capabilities) {
          expect(capabilityLabels.containsKey(c), isTrue, reason: c);
        }
      }
      expect(filterMappingPages('teksi').map((p) => p.id), ['partner-teksi']);
      expect(filterMappingPages('/ride-').length, 3);
    });

    test('legacy page ids migrate', () {
      final m = migrateLegacyPageIds({
        'driver-teksi': {
          'maps': {'providerId': 'google', 'serviceId': 'maps'},
        },
        'driver-ehailing': {
          'maps': {'providerId': 'a', 'serviceId': 'b'},
        },
        'partner-ehailing': {
          'maps': {'providerId': 'c', 'serviceId': 'd'},
        },
      });
      expect(m.changed, isTrue);
      expect(m.next.keys.toSet(), {'partner-teksi', 'partner-ehailing'});
      expect(m.next['partner-ehailing']!['maps']!['providerId'], 'c');
      expect(migrateLegacyPageIds({}).changed, isFalse);
    });

    test('set/clear assignment and totals', () {
      var map = parseAssignments('{"search":{"places":{"providerId":"google","serviceId":"places"}}}');
      expect(assignmentTotals(map).assigned, 1);
      map = setAssignment(map, 'search', 'geocoding', (providerId: 'osm', serviceId: 'nominatim'));
      expect(map['search']!.keys, containsAll(['places', 'geocoding']));
      map = setAssignment(map, 'search', 'places', null);
      expect(map['search']!.keys, ['geocoding']);
      final t = assignmentTotals(map);
      expect(t.total, mappingPages.fold<int>(0, (n, p) => n + p.capabilities.length));
      expect(parseAssignments('garbage'), isEmpty);
      expect(parseDocumentSources('{"driver-permit":"abc"}'), {'driver-permit': 'abc'});
    });

    test('providers are merged with defaults and never keep key values', () {
      final list = providersFromStored([
        {
          'id': 'google',
          'name': 'Google Maps',
          'category': 'Mapping',
          'services': [
            {
              'id': 'maps',
              'name': 'Maps',
              'keys': [
                {'id': 'k', 'label': 'main', 'value': 'SECRET'},
              ],
            },
          ],
        },
        {'id': 'custom', 'name': 'Mine', 'services': []},
      ]);
      expect(list.first.id, 'google');
      expect(list.first.name, 'Google Maps');
      expect(list.first.services.first.keyCount, 1);
      // Missing default services were merged in.
      expect(list.first.services.map((s) => s.id), contains('roads'));
      expect(list.last.id, 'custom');
      expect(list.map((p) => p.id), contains('ip_geolocation'));
      expect(providersFromStored(null).first.services.every((s) => s.keyCount == 0), isTrue);
    });
  });
}
