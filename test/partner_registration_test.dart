// Partner registration (0288): which steps apply, the citizens-only notice,
// the details checks, the owner check, the driver permit checks, and each
// vehicle service's status (age limit, vehicle permit). Synthetic data only.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/catalogue/catalogue_logic.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/core/document_text.dart';
import 'package:get_ride/src/core/partner_registration.dart';

import 'partner_registration_fixture.dart';

final _now = DateTime(2026, 10, 24);

void main() {
  test('which optional steps the picks need', () {
    expect(RegistrationNeeds.of(['Delivery'], regEntries, regSelangor), RegistrationNeeds.none);
    expect(RegistrationNeeds.of(['eHailing'], regEntries, regSelangor), const RegistrationNeeds(vehicle: true));
    expect(
      RegistrationNeeds.of(['Teksi', 'Delivery'], regEntries, regSelangor),
      const RegistrationNeeds(company: true, driverPermit: true, vehicle: true),
    );
    expect(
      RegistrationNeeds.of(['Teksi'], regEntries, const ServiceArea(countries: ['Singapore'])),
      const RegistrationNeeds(vehicle: true),
      reason: 'the business and permit rules are for Malaysia',
    );
    expect(vehicleServicesOf(['Delivery', 'Teksi', 'eHailing'], regEntries), ['Teksi', 'eHailing']);
    expect(withRegistrationStep({'registration_steps': ['details']}, 'company'), {
      'registration_steps': ['details', 'company'],
    });
    expect(withRegistrationStep({'registration_steps': ['details']}, 'details')['registration_steps'], ['details']);
  });

  test('the service area from where the phone is', () {
    const geo = GeoOptions(
      countries: ['Malaysia', 'Singapore'],
      states: ['Malaysia|Selangor', 'Malaysia|Kuala Lumpur'],
      cities: ['Malaysia|Selangor|Petaling Jaya', 'Malaysia|Kuala Lumpur|Kuala Lumpur'],
    );
    final pj = areaFromPlace(country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya', options: geo)!;
    expect(pj.cities, ['Malaysia|Selangor|Petaling Jaya']);
    final kl = areaFromPlace(country: 'Malaysia', state: 'Wilayah Persekutuan Kuala Lumpur', city: 'Kuala Lumpur', options: geo)!;
    expect(kl.states, ['Malaysia|Kuala Lumpur']);
    expect(areaFromPlace(country: 'Malaysia', state: 'Johor', city: 'Muar', options: geo)!.countries, ['Malaysia']);
    expect(areaFromPlace(country: 'Thailand', options: geo), isNull);
  });

  test('a card says the age limit and the documents', () {
    expect(
      serviceCardText(type: 'eHailing', entries: regEntries, area: regSelangor, documents: ['Driving License']),
      'Vehicle up to 15 years old · Needs: Driving License',
    );
    expect(
      serviceCardText(
        type: 'Teksi',
        entries: regEntries,
        area: regSelangor,
        documents: const [],
        driverPermit: 'Kad Pemandu (APAD)',
      ),
      'Vehicle up to 20 years old · Needs: Kad Pemandu (APAD)',
    );
    expect(serviceCardText(type: 'Delivery', entries: regEntries, area: regSelangor, documents: const []),
        'No service documents set up yet');
  });

  test('the eligibility notice: who is asked and what it lists', () {
    const offered = ['Delivery', 'eHailing', 'Teksi'];
    expect(
      eligibilityNotice(idType: IdDocType.mykad, offered: offered, picked: const ['Teksi'], entries: regEntries, area: regSelangor),
      isNull,
      reason: 'a citizen',
    );
    final n = eligibilityNotice(
      idType: IdDocType.passport,
      nationality: 'Indonesian',
      offered: offered,
      picked: const ['Teksi', 'Delivery'],
      entries: regEntries,
      area: regSelangor,
    )!;
    expect(n.citizensOnly, ['eHailing', 'Teksi']);
    expect(n.picked, ['Teksi']);
    expect(n.open, ['Delivery']);
    expect(eligibilityLead(IdDocType.mypr), 'You are registering as a permanent resident.');
    expect(
      eligibilityNotice(idType: IdDocType.mypr, offered: const ['Delivery'], picked: const [], entries: regEntries, area: regSelangor),
      isNull,
      reason: 'nothing citizens-only there',
    );
  });

  test('details: everything filled in, and a MyKad date of birth from its number', () {
    String? p({String number = '900101-14-5678', String name = 'AINA BINTI RAHMAN', DateTime? dob, String address = 'X'}) =>
        detailsProblem(idType: IdDocType.mykad, number: number, name: name, dateOfBirth: dob, address: address);
    expect(p(dob: DateTime(1990, 1, 1)), isNull);
    expect(p(dob: DateTime(1990, 1, 2)), contains('first six digits'));
    expect(p(), 'Enter your date of birth.');
    expect(p(name: ' ', dob: DateTime(1990, 1, 1)), contains('full name'));
    expect(
      detailsProblem(idType: IdDocType.passport, number: 'C4821937', name: 'B', dateOfBirth: DateTime(1985), address: 'Y'),
      isNull,
      reason: 'a passport number holds no date',
    );
  });

  test('the owner on the grant: the driver, their company, or someone else', () {
    OwnerMatch m(String owner, {String? id}) => ownerMatchFor(
          owner: owner,
          ownerId: id,
          driverName: 'AINA BINTI RAHMAN',
          driverId: '900101-14-5678',
          companyName: 'CAHAYA TEKSI SDN. BHD.',
          companyRegNo: '201901012345 (1321234-K)',
        );
    expect(m('AINA RAHMAN'), OwnerMatch.driver);
    expect(m('SOMEONE', id: '900101145678'), OwnerMatch.driver);
    expect(m('Cahaya Teksi Sdn Bhd'), OwnerMatch.company);
    expect(m('X', id: '201901012345'), OwnerMatch.company);
    expect(m('BINTANG TEKSI SDN. BHD.'), OwnerMatch.other);
  });

  group('driver permit checks', () {
    final good = DriverPermitRead(
      cardNo: 'KP/B/2024/0000001',
      validUntil: DateTime(2027, 5, 1),
      name: 'AINA BINTI RAHMAN',
      idNumber: '900101-14-5678',
      operatorName: 'CAHAYA TEKSI SDN BHD',
      plate: 'HWA 8812',
      position: 2,
    );
    List<PermitCheck> run(DriverPermitRead p, {String? plate}) => driverPermitChecks(
          p: p,
          idName: 'Aina Rahman',
          idNumber: '900101145678',
          companyName: 'CAHAYA TEKSI SDN. BHD.',
          companyRegNo: '201901012345 (1321234-K)',
          vehiclePlate: plate,
          now: _now,
        );

    test('all pass', () {
      final c = run(good);
      expect(c.every((x) => x.ok), isTrue);
      expect(c.map((x) => x.text), [
        'Name and ID number match your ID',
        'Operator matches your company (SSM 201901012345)',
        'Plate HWA 8812 is checked against the vehicle you register next',
        'You are the 2nd driver for HWA 8812. The taxi is shared, not handed over.',
        'Valid for 6 more months. We remind you 30 days before it ends.',
      ]);
      expect(permitFlags(c), isEmpty);
    });

    test('a different person, operator or plate is flagged, not blocked', () {
      final c = run(
        DriverPermitRead(
          cardNo: 'x',
          validUntil: DateTime(2027),
          name: 'TAN WEI MING',
          idNumber: '900101-14-5678',
          operatorName: 'BINTANG',
          plate: 'WXY 1',
        ),
        plate: 'HWA 8812',
      );
      expect(permitFlags(c), ['name_id', 'operator', 'plate']);
      expect(c.any((x) => x.blocking && !x.ok), isFalse);
    });

    test('an expired permit is blocked; one ending soon is a reminder', () {
      final expired = run(DriverPermitRead(cardNo: 'x', validUntil: DateTime(2026, 10, 1), name: 'Aina Rahman', idNumber: '900101145678'));
      expect(expired.where((x) => x.blocking && !x.ok).single.key, 'expiry');
      final soon = run(DriverPermitRead(cardNo: 'x', validUntil: DateTime(2026, 11, 3), name: 'Aina Rahman', idNumber: '900101145678'));
      expect(soon.last.text, startsWith('Valid for 10 more days'));
      expect(soon.last.ok, isTrue);
      final none = run(const DriverPermitRead(cardNo: 'x'));
      expect(none.last.blocking, isTrue);
    });
  });

  group('each vehicle service on a vehicle', () {
    test('within the limits: eHailing waits for its vehicle permit, Teksi is active', () {
      final st = vehicleServiceStatuses(
        services: ['eHailing'],
        entries: regEntries,
        area: regSelangor,
        registered: DateTime(2021, 3, 15),
        now: _now,
      );
      expect(st.single.state, VehicleServiceState.waitingPermit);
      expect(st.single.permit!.name, 'EVP');
      expect(vehicleAgeLine(st.single), 'eHailing: limit 15 years. Active until 03/2037.');
      expect(vehiclePermitLine(st.single), startsWith('eHailing: needs EVP (APAD). GET.ride applies and uploads it'));
      expect(st.single.toRow('v1'), {
        'vehicle_id': 'v1',
        'service': 'eHailing',
        'status': 'waiting_permit',
        'max_age_years': 15,
        'limit_type': 'eHailing',
        'permit_name': 'EVP',
        'permit_type': 'evp',
      });
    });

    test('too old: only that service is paused, never a refusal', () {
      final st = vehicleServiceStatuses(
        services: ['eHailing', 'Teksi'],
        entries: regEntries,
        area: regSelangor,
        registered: DateTime(2009, 3, 15),
        now: _now,
      );
      // A registered taxi's 20 years cover eHailing: 17 years old is fine.
      expect(st.map((s) => s.state), [VehicleServiceState.waitingPermit, VehicleServiceState.active]);
      expect(st.first.coveredBy, 'Teksi');
      expect(vehicleAgeLine(st.first), contains('registered for Teksi, so its limit of 20 years applies'));
      final car = vehicleServiceStatuses(
        services: ['eHailing'],
        entries: regEntries,
        area: regSelangor,
        registered: DateTime(2009, 3, 15),
        now: _now,
      );
      expect(car.single.state, VehicleServiceState.pausedAge);
      expect(vehicleAgeLine(car.single), 'eHailing: limit 15 years. Not active until you add a newer vehicle.');
    });

    test('a year before the limit, a reminder', () {
      final st = vehicleServiceStatuses(
        services: ['Teksi'],
        entries: regEntries,
        area: regSelangor,
        registered: DateTime(2006, 6, 1),
        now: _now,
      );
      expect(st.single.state, VehicleServiceState.active);
      expect(st.single.remindSoon, isTrue);
    });
  });

  test('the service documents leave out what the driver permit step read', () {
    const permit = RequiredDoc(
      id: 'kp',
      name: 'Driver Permit',
      description: '',
      compulsory: true,
      scope: 'global',
      labels: [],
      flags: DocFlags(isTaxiPermit: true),
    );
    const licence = RequiredDoc(
      id: 'dl',
      name: 'Driving License',
      description: '',
      compulsory: true,
      scope: 'global',
      labels: [],
      flags: DocFlags(),
    );
    expect(serviceDocsAfterPermitStep([permit, licence], permitStep: true).map((d) => d.id), ['dl']);
    expect(serviceDocsAfterPermitStep([permit, licence], permitStep: false).map((d) => d.id), ['kp', 'dl']);
  });

  test('a document carries the person\'s photo by the admin\'s switch, else by its name', () {
    expect(requiredDocHasPhoto(const {'name': 'Driving License'}), isTrue);
    expect(requiredDocHasPhoto(const {'name': 'PSV licence'}), isTrue);
    expect(requiredDocHasPhoto(const {'name': 'Vehicle Insurance'}), isFalse);
    expect(requiredDocHasPhoto(const {'name': 'Inspection', 'isTaxiPermit': true}), isTrue);
    expect(requiredDocHasPhoto(const {'name': 'Driving License', 'hasPhoto': false}), isFalse);
    expect(requiredDocHasPhoto(const {'name': 'Insurance', 'hasPhoto': true}), isTrue);
  });

  test('Required Documents: "Has the person\'s photo" defaults by name and is saved', () {
    final licence = RequiredDocForm(name: 'Driving License');
    expect(licence.effectiveHasPhoto, isTrue);
    expect(buildRequiredDocValues(entries: const [], form: licence).values['hasPhoto'], isTrue);
    final insurance = RequiredDocForm(name: 'Vehicle Insurance');
    expect(buildRequiredDocValues(entries: const [], form: insurance).values['hasPhoto'], isFalse);
    expect(RequiredDocForm.fromValues(const {'name': 'Driving License', 'hasPhoto': false}).effectiveHasPhoto, isFalse);
    insurance.hasPhoto = true;
    expect(buildRequiredDocValues(entries: const [], form: insurance).values['hasPhoto'], isTrue);
  });

  test('the grant\'s make and model find the catalogue row', () {
    final rows = [
      {'make': 'Perodua', 'model': 'Bezza', 'service_id': 'ride'},
      {'make': 'PERODUA', 'model': 'Bezza 1.3', 'service_id': 'comfort'},
      {'make': 'Proton', 'model': 'Persona', 'service_id': 'taxi'},
    ];
    expect(matchMakeModel(rows, 'PERODUA', 'BEZZA 1.3 AV')?['service_id'], 'comfort');
    expect(matchMakeModel(rows, 'PERODUA', 'BEZZA')?['service_id'], 'ride');
    expect(matchMakeModel(rows, 'PROTON', 'SAGA'), isNull);
  });

  test('why an application needs a closer look, in words', () {
    expect(closerLookReasonText('face_low'), 'Low face match between the selfie and a document photo');
    expect(closerLookReasonText('selfie_not_live'), 'Selfie taken without the live check');
  });
}
