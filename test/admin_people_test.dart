import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/admin/screens/people/people_module.dart';

({String id, Map<String, dynamic> values}) entry(String id, Map<String, dynamic> v) => (id: id, values: v);

void main() {
  group('users', () {
    test('profile_status mapping matches Expo upsertUser', () {
      expect(profileStatusFor('approved'), 'Approved');
      expect(profileStatusFor('unapproved'), 'Un-Approved');
      expect(profileStatusFor('unapproved-docs'), 'Un-Approved');
      expect(profileStatusFor('blocked'), 'Blocked');
      expect(profileStatusFor('rejected'), 'Rejected');
      expect(profileStatusFor('deleted'), 'Deleted');
    });

    test('validation requires name and phone', () {
      expect(validateUserForm(name: ' ', phone: '1'), isNotNull);
      expect(validateUserForm(name: 'A', phone: ''), isNotNull);
      expect(validateUserForm(name: 'A', phone: '1'), isNull);
    });

    test('patch trims, blanks to null, empty email becomes "-"', () {
      final p = userProfilePatch(
        name: ' Jane ',
        phone: ' +601 ',
        email: '',
        ic: '',
        address: ' KL ',
        nationality: '',
        birthDate: '',
        referralCode: '',
        gender: 'female',
        profileImage: '',
        idImage: 'https://x/id.png',
        status: 'blocked',
        documentsOk: true,
      );
      expect(p['name'], 'Jane');
      expect(p['phone'], '+601');
      expect(p['email'], '-');
      expect(p['ic'], isNull);
      expect(p['address'], 'KL');
      expect(p['profile_image'], isNull);
      expect(p['id_image'], 'https://x/id.png');
      expect(p['status'], 'blocked');
      expect(p['profile_status'], 'Blocked');
      expect(p['documents_ok'], true);
      expect(p.containsKey('display_id'), isFalse);
    });

    test('deleted never reaches the user_status column', () {
      final p = userProfilePatch(
          name: 'a', phone: '1', email: 'e', ic: '', address: '', nationality: '', birthDate: '', referralCode: '',
          gender: null, profileImage: null, idImage: null, status: 'deleted', documentsOk: false);
      expect(p['status'], 'unapproved');
      expect(p['profile_status'], 'Deleted');
    });

    test('editable status reads profile_status first', () {
      expect(editableUserStatus({'profile_status': 'Approved', 'status': 'unapproved'}), 'approved');
      expect(editableUserStatus({'profile_status': 'Un-Approved', 'status': 'unapproved-docs'}), 'unapproved-docs');
      expect(editableUserStatus({'status': 'blocked'}), 'blocked');
      expect(editableUserStatus({}), 'unapproved');
    });

    test('ISO date validation', () {
      expect(isValidIsoDate('2024-02-29'), isTrue);
      expect(isValidIsoDate('2023-02-29'), isFalse);
      expect(isValidIsoDate('29/02/2024'), isFalse);
    });

    test('storage paths follow Expo edit-profile', () {
      final d = DateTime(2025, 3, 7);
      expect(idImagePath(country: 'Malaysia', phone: '+60 12-345', idNumber: '990101-14', ext: 'jpg', now: d),
          'Malaysia/+60_12-345_990101-14_07032025.jpg');
      expect(avatarPath(country: '', phone: '+6012', name: 'Jane Doe', ext: 'png', now: d), 'Unknown/+6012_jane_doe_07032025.png');
      expect(avatarPath(country: 'MY', phone: '1', name: ' ', ext: 'png', now: d), 'MY/1_user_07032025.png');
      expect(
        avatarPath(country: 'MY', phone: '1', name: 'Jo', ext: 'png', owner: 'u-1', now: d),
        'u-1/MY_1_jo_07032025.png',
      );
      expect(
        idImagePath(country: '', phone: '1', idNumber: '9', ext: 'jpg', owner: 'u-1', now: d),
        'u-1/Unknown_1_9_07032025.jpg',
      );
      expect(docFilePath('p1', 'd1', 'front', 'jpg', ms: 5), 'p1/d1/front-5.jpg');
      expect(vehiclePhotoPath('v1', 'left', 'png', ms: 9), 'v1/photos/left-9.png');
    });

    test('extension and content type guesses', () {
      expect(guessExt('a.JPEG'), 'jpg');
      expect(guessExt('a.heic'), 'png');
      expect(guessExt('x.pdf?token=1'), 'pdf');
      expect(contentTypeFor('jpg'), 'image/jpeg');
      expect(contentTypeFor('png'), 'image/png');
    });
  });

  group('ID documents', () {
    final now = DateTime(2025, 6, 1);
    test('display status: expiry wins, then verdict, else pending', () {
      expect(idDisplayStatus({'id_verified': 'Verified', 'id_expiry_date': '2025-01-01'}, now: now), 'Expired');
      expect(idDisplayStatus({'id_verified': 'Expired'}, now: now), 'Expired');
      expect(idDisplayStatus({'id_verified': 'Verified', 'id_expiry_date': '2026-01-01'}, now: now), 'Verified');
      expect(idDisplayStatus({'id_verified': 'Failed'}, now: now), 'Failed');
      expect(idDisplayStatus({'id_verified': null}, now: now), 'Pending');
    });

    test('counts', () {
      final c = idStatusCounts([
        {'id_verified': 'Verified'},
        {'id_verified': null},
        {'id_verified': null},
      ], now: now);
      expect(c, {'Verified': 1, 'Failed': 0, 'Pending': 2, 'Expired': 0});
    });

    test('rejection needs a note', () {
      expect(validateIdDecision('Failed', ' '), isNotNull);
      expect(validateIdDecision('Failed', 'blurry'), isNull);
      expect(validateIdDecision('Verified', ''), isNull);
    });

    test('pdf detection ignores query strings', () {
      expect(isPdfUri('https://x/a.PDF?x=1'), isTrue);
      expect(isPdfUri('https://x/a.png'), isFalse);
      expect(isPdfUri(null), isFalse);
    });

    test('profile edit patch nulls blanks', () {
      final p = idProfilePatch(
          name: '', phone: '1', email: ' ', ic: 'X', nationality: '', documentsOk: true, idExpiry: '2030-01-01');
      expect(p, {
        'name': null,
        'phone': '1',
        'email': null,
        'ic': 'X',
        'nationality': null,
        'documents_ok': true,
        'id_expiry_date': '2030-01-01',
      });
    });
  });

  group('service area', () {
    const area = ServiceArea(
      countries: ['Malaysia', 'Singapore'],
      states: ['Malaysia|Selangor', 'Singapore|Central'],
      cities: ['Malaysia|Selangor|Semenyih', 'Singapore|Central|Orchard'],
    );

    test('removing a country prunes its states and cities', () {
      final a = area.toggleCountry('Singapore');
      expect(a.countries, ['Malaysia']);
      expect(a.states, ['Malaysia|Selangor']);
      expect(a.cities, ['Malaysia|Selangor|Semenyih']);
    });

    test('removing a state prunes its cities', () {
      final a = area.toggleState('Malaysia|Selangor');
      expect(a.states, ['Singapore|Central']);
      expect(a.cities, ['Singapore|Central|Orchard']);
      expect(a.toggleState('Malaysia|Selangor').states, contains('Malaysia|Selangor'));
    });

    test('complete needs all three levels', () {
      expect(area.complete, isTrue);
      expect(const ServiceArea(countries: ['MY'], states: ['MY|S']).complete, isFalse);
    });

    test('state keys split on "|" with a fallback country', () {
      expect(splitStateKey('Malaysia|Selangor'), (country: 'Malaysia', state: 'Selangor'));
      expect(splitStateKey('Selangor', fallbackCountry: 'Malaysia'), (country: 'Malaysia', state: 'Selangor'));
      expect(area.statePairs().first, (country: 'Malaysia', state: 'Selangor'));
    });

    test('row round trip', () {
      final row = area.toRow();
      expect(ServiceArea.fromRow(row).cities, area.cities);
      expect(ServiceArea.fromRow(null).isEmpty, isTrue);
    });

    test('geo options merge tables with values in use', () {
      final g = GeoOptions.build(
        countryRows: [
          {'name': 'Japan'}
        ],
        stateRows: [
          {'country': 'Malaysia', 'name': 'Johor'}
        ],
        cityRows: const [],
        inUse: [area],
      );
      expect(g.countries, ['Japan', 'Malaysia', 'Singapore']);
      expect(g.statesFor(const ServiceArea(countries: ['Malaysia'])), ['Malaysia|Johor', 'Malaysia|Selangor']);
      expect(g.citiesFor(const ServiceArea(states: ['Malaysia|Selangor'])), ['Malaysia|Selangor|Semenyih']);
      final more = g.including(const ServiceArea(countries: ['Thailand']));
      expect(more.countries, contains('Thailand'));
      expect(more.states, g.states);
    });
  });

  group('partners', () {
    final types = <Map<String, dynamic>>[
      {'name': 'Teksi', 'enabled': true, 'vehicleRequired': true, 'docTypes': '["dt-partner"]'},
      {'name': 'Delivery', 'enabled': true, 'isDefault': true},
      {'name': 'Hidden', 'enabled': false},
      {'name': 'Fleet'},
    ];

    test('options: enabled only, defaults first then by name', () {
      expect(partnerTypeOptions(types), ['Delivery', 'Fleet', 'Teksi']);
    });

    test('vehicle requirement and doc types follow the selected types', () {
      expect(partnerTypesRequireVehicle(types, ['teksi']), isTrue);
      expect(partnerTypesRequireVehicle(types, ['Delivery']), isFalse);
      expect(partnerTypeDocTypeIds(types, ['Teksi', 'Delivery']), ['dt-partner']);
      expect(partnerTypeDocTypeIds(types, ['Delivery']), isNull);
      expect(partnerTypeDocTypeIds(types, const []), isNull);
    });

    test('list parsing accepts arrays and JSON strings', () {
      expect(parseStringList(['a', 1]), ['a', '1']);
      expect(parseStringList('["x","y"]'), ['x', 'y']);
      expect(parseStringList('nope'), isEmpty);
      expect(parseStringList(null), isEmpty);
    });

    test('form validation order mirrors Expo', () {
      const area = ServiceArea(countries: ['MY'], states: ['MY|S'], cities: ['MY|S|C']);
      expect(validatePartnerForm(hasUser: false, area: area, partnerTypes: ['a'], vehicleRequired: false, hasVehicle: false),
          contains('select a user'));
      expect(
          validatePartnerForm(
              hasUser: true, area: const ServiceArea(), partnerTypes: ['a'], vehicleRequired: false, hasVehicle: false),
          contains('country, state and city'));
      expect(validatePartnerForm(hasUser: true, area: area, partnerTypes: const [], vehicleRequired: false, hasVehicle: false),
          contains('partner type'));
      expect(validatePartnerForm(hasUser: true, area: area, partnerTypes: ['a'], vehicleRequired: true, hasVehicle: false),
          contains('requires a vehicle'));
      expect(validatePartnerForm(hasUser: true, area: area, partnerTypes: ['a'], vehicleRequired: true, hasVehicle: true),
          isNull);
    });

    test('partner_types is written verbatim and partner_type joined', () {
      expect(partnerTypeColumns(['Delivery', 'eHailing', 'Teksi']),
          {'partner_type': 'Delivery,eHailing,Teksi', 'partner_types': ['Delivery', 'eHailing', 'Teksi']});
      expect(partnerTypeColumns(const [])['partner_type'], isNull);
    });

    test('vehicle columns', () {
      expect(partnerVehicleColumns({'make': 'Perodua', 'model': 'Bezza', 'plate': 'WPK1', 'vehicle_type': 'Sedan'}), {
        'vehicle': 'Perodua Bezza',
        'plate': 'WPK1',
        'vehicle_type': 'Sedan',
        'make': 'Perodua',
        'model': 'Bezza',
      });
      expect(partnerVehicleColumns(null), {'vehicle': '', 'plate': '', 'vehicle_type': null, 'make': null, 'model': null});
    });

    test('new partner row: no auth_user_id, defaults like Expo addPartner', () {
      final row = newPartnerRow(
        id: 'uuid',
        displayId: 'PR-000001',
        user: {'name': 'Ali', 'phone': '+601', 'email': '-', 'ic': ''},
        vehicle: null,
        partnerTypes: ['Teksi'],
        area: const ServiceArea(countries: ['MY']),
        autoApprove: true,
        joinedAt: 't',
      );
      expect(row.containsKey('auth_user_id'), isFalse);
      expect(row['display_id'], 'PR-000001');
      expect(row['email'], isNull);
      expect(row['ic'], isNull);
      expect(row['status'], 'approved');
      expect(row['permit'], 'none');
      expect(row['documents_ok'], false);
      expect(row['rating'], 0);
      expect(row['partner_types'], ['Teksi']);
      expect(row['service_countries'], ['MY']);
    });

    test('display ids use the last six digits of the epoch millis', () {
      expect(newDisplayId('PR', ms: 1712345678901), 'PR-678901');
      expect(newDisplayId('VH', ms: 1000000000123), 'VH-000123');
    });

    test('eligible users exclude existing partner phones', () {
      final users = [
        {'phone': '+601 '},
        {'phone': '+602'},
      ];
      expect(eligiblePartnerUsers(users, [
        {'phone': '+601'}
      ]), [
        {'phone': '+602'}
      ]);
    });

    test('vehicle search and plate match', () {
      final vs = [
        {'plate': 'WPK 1234', 'make': 'Perodua', 'model': 'Bezza', 'owner_name': 'Ahmad'},
        {'plate': 'ABC 1', 'make': 'Proton', 'model': 'Saga', 'owner_name': 'Siti'},
      ];
      expect(searchVehicles(vs, 'saga').single['plate'], 'ABC 1');
      expect(searchVehicles(vs, '').length, 2);
      expect(vehicleForPlate(vs, ' wpk 1234 ')?['make'], 'Perodua');
      expect(vehicleForPlate(vs, ''), isNull);
    });
  });

  group('vehicles', () {
    test('new vehicle status follows Expo add', () {
      expect(newVehicleStatus(autoApprove: true, documentsOk: false, permit: 'none'), 'approved');
      expect(newVehicleStatus(autoApprove: false, documentsOk: false, permit: 'verified'), 'unapproved-docs');
      expect(newVehicleStatus(autoApprove: false, documentsOk: true, permit: 'pending'), 'permit-pending');
      expect(newVehicleStatus(autoApprove: false, documentsOk: true, permit: 'non-verified'), 'permit-non-verified');
      expect(newVehicleStatus(autoApprove: false, documentsOk: true, permit: 'verified'), 'permit-verified');
      expect(newVehicleStatus(autoApprove: false, documentsOk: true, permit: 'none'), 'unapproved');
    });

    test('validation', () {
      expect(validateVehicleForm(plate: '', make: 'a', model: 'b', ownerName: 'o', ownerPhone: 'p'), contains('plate'));
      expect(validateVehicleForm(plate: 'x', make: null, model: 'b', ownerName: 'o', ownerPhone: 'p'), contains('vehicle'));
      expect(validateVehicleForm(plate: 'x', make: 'a', model: 'b', ownerName: '', ownerPhone: 'p'), contains('owner'));
      expect(validateVehicleForm(plate: 'x', make: 'a', model: 'b', ownerName: 'o', ownerPhone: 'p'), isNull);
    });

    test('columns upper-case the plate and null blanks', () {
      final c = vehicleColumns(
        plate: ' wpk 1 ',
        make: 'Perodua',
        model: 'Bezza',
        vehicleType: '',
        year: '',
        color: 'White',
        ownerName: ' Ali ',
        ownerPhone: '1',
        partnerDisplayId: '',
        ownerPartnerUuid: null,
        status: 'approved',
        permit: 'none',
        documentsOk: true,
        area: const ServiceArea(),
      );
      expect(c['plate'], 'WPK 1');
      expect(c['vehicle_type'], isNull);
      expect(c['year'], isNull);
      expect(c['color'], 'White');
      expect(c['owner_name'], 'Ali');
      expect(c['owner_partner_display_id'], isNull);
      expect(c['service_cities'], isEmpty);
    });

    test('owner suggestions', () {
      final ps = [
        {'name': 'Ahmad', 'phone': '1', 'display_id': 'PR-1'},
        {'name': 'Siti', 'phone': '2', 'display_id': 'PR-2'},
      ];
      expect(partnerSuggestions(ps, ''), isEmpty);
      expect(partnerSuggestions(ps, 'pr-2').single['name'], 'Siti');
    });

    test('vehicle label', () {
      expect(formatVehicleLabel(make: 'Perodua', model: 'Bezza', yearFrom: '2020', yearTo: ''), 'Perodua Bezza (2020 ~)');
      expect(formatVehicleLabel(make: 'A', model: 'B', yearFrom: '2020', yearTo: '2022'), 'A B (2020 - 2022)');
      expect(formatVehicleLabel(make: 'A', model: 'B', yearFrom: '', yearTo: '2022'), 'A B (~ 2022)');
      expect(formatVehicleLabel(make: 'A', model: 'B'), 'A B');
    });

    test('documents approval check before approving', () {
      final now = DateTime(2025, 1, 1);
      expect(vehicleDocsCheck(const []).blockMessage('WPK 1'), contains('no vehicle documents'));
      final rows = [
        {'status': 'Approved'},
        {'status': 'Pending Review'},
        {'status': 'Approved', 'expiry_date': '2024-01-01'},
        {'status': 'Rejected', 'expiry_date': '2024-01-01'},
      ];
      final c = vehicleDocsCheck(rows, now: now);
      expect((c.approved, c.pending, c.expired, c.rejected, c.total), (1, 1, 1, 1, 4));
      expect(c.ok, isFalse);
      expect(c.blockMessage('X'), contains('1/4 vehicle documents are approved (1 pending, 1 rejected, 1 expired)'));
      expect(vehicleDocsCheck([{'status': 'Approved'}]).blockMessage('X'), isNull);
    });
  });

  group('required documents', () {
    final entries = [
      entry('global', {'name': 'Driving License', 'regionsGlobal': true, 'regionsGlobalCompulsory': true, 'docTypes': '["dt-p"]'}),
      entry('optional', {'name': 'PSV', 'regionsGlobal': true, 'required': false, 'docTypes': '["dt-p"]'}),
      entry('vehicle', {'name': 'Insurance', 'regionsGlobal': true, 'docTypes': '["dt-v"]'}),
      entry('inactive', {'name': 'Old', 'active': false}),
      entry('regional', {
        'name': 'KL Permit',
        'regionsGlobal': false,
        'docTypes': '["dt-p"]',
        'regions': '[{"type":"state","country":"Malaysia","state":"Selangor","compulsory":true},'
            '{"type":"country","country":"Singapore","compulsory":false}]',
      }),
      entry('teksi', {'name': 'Driver Permit', 'regionsGlobal': true, 'partnerTypes': '["Teksi"]', 'docTypes': '["dt-x"]'}),
    ];

    test('doc-type filter, compulsory first then by name', () {
      final docs = resolveRequiredDocs(entries, docTypeIds: ['dt-p'], countries: ['Malaysia'], states: [
        (country: 'Malaysia', state: 'Selangor'),
      ]);
      expect(docs.map((d) => d.id), ['teksi', 'global', 'regional', 'optional']);
      expect(docs.firstWhere((d) => d.id == 'regional').labels, ['Selangor, Malaysia']);
      expect(docs.firstWhere((d) => d.id == 'regional').scope, 'state');
    });

    test('regional docs need a matching region once a context exists', () {
      final docs = resolveRequiredDocs(entries, countries: ['Japan']);
      expect(docs.any((d) => d.id == 'regional'), isFalse);
      final sg = resolveRequiredDocs(entries, countries: ['Singapore']).firstWhere((d) => d.id == 'regional');
      expect(sg.compulsory, isFalse);
      expect(sg.scope, 'country');
    });

    test('no context previews every regional doc', () {
      final r = resolveRequiredDocs(entries).firstWhere((d) => d.id == 'regional');
      expect(r.scope, 'mixed');
      expect(r.compulsory, isTrue);
      expect(r.labels, ['Selangor, Malaysia', 'Singapore']);
    });

    test('partner-type tagged docs filter by name when names are given', () {
      expect(resolveRequiredDocs(entries, partnerTypeNames: ['delivery']).any((d) => d.id == 'teksi'), isFalse);
      expect(resolveRequiredDocs(entries, partnerTypeNames: ['teksi']).any((d) => d.id == 'teksi'), isTrue);
      expect(resolveRequiredDocs(entries, partnerTypeNames: ['__ALL__']).any((d) => d.id == 'teksi'), isTrue);
    });

    test('inactive docs are skipped and __ALL__ disables the type filter', () {
      final all = resolveRequiredDocs(entries, docTypeIds: ['__ALL__']);
      expect(all.any((d) => d.id == 'inactive'), isFalse);
      expect(all.any((d) => d.id == 'vehicle'), isTrue);
    });

    test('doc types by name', () {
      expect(
          docTypeIdsNamed([
            entry('a', {'name': 'Vehicle'}),
            entry('b', {'name': 'Admin-Vehicle'}),
          ], 'vehicle'),
          ['a']);
    });

    test('flags parse from values', () {
      final f = DocFlags.fromValues({'requireFrontBack': true, 'requireExpiryDate': 'true', 'isPwd': 0});
      expect(f.requireFrontBack, isTrue);
      expect(f.requireExpiryDate, isTrue);
      expect(f.isPwd, isFalse);
    });

    test('a rejected document carries the reviewer note', () {
      expect(docRejectionNote({'status': 'Rejected', 'reviewer_notes': ' Blurry photo '}), 'Rejected: Blurry photo');
      expect(docRejectionNote({'status': 'Rejected', 'reviewer_notes': '  '}), isNull);
      expect(docRejectionNote({'status': 'Rejected'}), isNull);
      expect(docRejectionNote({'status': 'Approved', 'reviewer_notes': 'Fine'}), isNull);
      expect(docRejectionNote({'status': 'Pending Review', 'reviewer_notes': 'Old note'}), isNull);
    });

    test('display status and upload progress', () {
      final now = DateTime(2025, 1, 1);
      expect(docDisplayStatus({'status': 'Approved', 'expiry_date': '2024-12-31'}, now: now), 'Expired');
      expect(docDisplayStatus({'status': 'Rejected', 'expiry_date': '2024-12-31'}, now: now), 'Rejected');
      final docs = resolveRequiredDocs(entries, docTypeIds: ['dt-p']);
      final uploads = latestUploadByDoc([
        {'doc_id': 'global', 'status': 'Pending Review'},
        {'doc_id': 'global', 'status': 'Rejected'},
        {'doc_id': 'teksi', 'status': 'Rejected'},
      ]);
      expect(uploads['global']!['status'], 'Pending Review');
      final p = uploadProgress(docs, uploads);
      expect(p.uploaded, 1);
      expect(p.compulsoryLeft, 2);
    });

    test('upload validation and payload', () {
      const f = DocFlags(requireFrontBack: true, requireDocumentNumber: true, requireExpiryDate: true);
      String? v({bool back = true, String no = 'X1', String exp = '2030-01-01'}) => validateDocUpload(f,
          hasFront: true, hasBack: back, frontIsPdf: false, documentNumber: no, startDate: '', expiryDate: exp,
          insuranceProviderId: null);
      expect(v(back: false), contains('back'));
      expect(v(no: ''), contains('document number'));
      expect(v(exp: '2030-13-01'), contains('expiry'));
      expect(v(), isNull);
      final p = providerDocPayload(
        partnerId: 'p',
        authUserId: null,
        docId: 'd',
        docName: 'Licence',
        flags: f,
        documentNumber: ' X1 ',
        insuranceProviderId: 'ins',
        insuranceProviderName: 'Ins',
        isPwd: true,
        startDate: '2020-01-01',
        expiryDate: '2030-01-01',
        fileUrl: 'u1',
        fileUrlBack: 'u2',
        uploadedAt: 't',
      );
      expect(p['status'], 'Pending Review');
      expect(p['document_number'], 'X1');
      expect(p['insurance_provider_id'], isNull);
      expect(p['is_pwd'], false);
      expect(p['start_date'], isNull);
      expect(p['expiry_date'], '2030-01-01');
      expect(p['file_url_back'], 'u2');
      expect(p['reviewer_notes'], isNull);
    });
  });

  group('module', () {
    test('every route is under /admin/m/ and entries use section People', () {
      expect(peopleEntries, isNotEmpty);
      for (final e in peopleEntries) {
        expect(e.section, 'People');
        expect(e.path, startsWith('/admin/m/'));
        expect(e.pages.single, startsWith('admin-'));
      }
      expect(peopleEntries.where((e) => !e.listed).map((e) => e.pages.single),
          containsAll(['admin-user-edit', 'admin-partner-edit', 'admin-vehicle-edit']));
      expect(peopleEntries.where((e) => e.listed).map((e) => e.pages.single),
          containsAll(['admin-partner-add', 'admin-vehicle-add', 'admin-documents-users']));
      expect(peopleRoutes.length, peopleEntries.length);
    });
  });
}
