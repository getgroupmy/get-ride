// Partner registration (0288): reading IDs, company documents, driver
// permits and vehicle grants. Every sample here is made up: no real person,
// company, permit or vehicle.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/document_text.dart';

final _now = DateTime(2026, 10, 24);

void main() {
  group('MyKad / MyPR', () {
    const front = '''
KAD PENGENALAN
MALAYSIA
IDENTITY CARD
MyKad
900101-14-5678
AINA BINTI RAHMAN
NO 12 JALAN SS2/24
47300 PETALING JAYA
SELANGOR
WARGANEGARA
ISLAM
PEREMPUAN
''';

    test('number, name, address, date of birth and nationality', () {
      final r = readIdText(front, IdDocType.mykad, now: _now);
      expect(r.number, '900101-14-5678');
      expect(r.name, 'AINA BINTI RAHMAN');
      expect(r.address, 'NO 12 JALAN SS2/24, 47300 PETALING JAYA, SELANGOR');
      expect(r.dateOfBirth, DateTime(1990, 1, 1));
      expect(r.nationality, 'Malaysian');
    });

    test('a long name wrapping onto a second line', () {
      const t = '''
020315 10 1234
NUR ALYA SOFEA BINTI
ABDULLAH
LOT 5 KAMPUNG BARU
43000 KAJANG
SELANGOR
WARGANEGARA
''';
      final r = readIdText(t, IdDocType.mykad, now: _now);
      expect(r.number, '020315-10-1234');
      expect(r.name, 'NUR ALYA SOFEA BINTI ABDULLAH');
      expect(r.dateOfBirth, DateTime(2002, 3, 15));
      expect(r.address, 'LOT 5 KAMPUNG BARU, 43000 KAJANG, SELANGOR');
    });

    test('a MyPR reads as a permanent resident', () {
      const t = 'MyPR\nPEMASTAUTIN TETAP\n850312-10-5021\nTAN WEI MING\nNO 3 JALAN BUNGA\n50000 KUALA LUMPUR\nPEMASTAUTIN TETAP';
      final r = readIdText(t, IdDocType.mypr, now: _now);
      expect(r.number, '850312-10-5021');
      expect(r.name, 'TAN WEI MING');
      expect(r.nationality, 'Permanent resident');
      expect(idShowsNonCitizen(IdDocType.mypr, r.nationality), isTrue);
    });

    test('unreadable text gives an empty read', () {
      expect(readIdText('blurred\n###', IdDocType.mykad).isEmpty, isTrue);
    });

    test('the date of birth must match the first six digits', () {
      expect(myKadDobMatches('900101-14-5678', DateTime(1990, 1, 1)), isTrue);
      expect(myKadDobMatches('900101-14-5678', DateTime(1990, 1, 2)), isFalse);
      expect(myKadDobMatches('900101-14-5678', null), isFalse);
      expect(dobFromMyKad('250101-14-1111', now: _now), DateTime(2025, 1, 1));
      expect(dobFromMyKad('300101-14-1111', now: _now), DateTime(1930, 1, 1));
      expect(dobFromMyKad('901301-14-1111'), isNull, reason: 'no 13th month');
    });

    test('numbers compare without punctuation', () {
      expect(sameIdNumber('900101-14-5678', '900101145678'), isTrue);
      expect(sameIdNumber('900101-14-5678', '900101-14-5679'), isFalse);
      expect(sameIdNumber('', ''), isFalse);
      expect(formatMyKad('900101145678'), '900101-14-5678');
    });
  });

  group('passport machine lines', () {
    // A made-up specimen, laid out as ICAO 9303.
    const page = '''
REPUBLIK INDONESIA
PASPOR
P<IDNSANTOSO<<BUDI<HARTONO<<<<<<<<<<<<<<<<<<
C4821937<2IDN8503125M3001019<<<<<<<<<<<<<<04
''';

    test('number, nationality, name, date of birth, expiry', () {
      final m = readPassportMrz(page, now: _now)!;
      expect(m.read.number, 'C4821937');
      expect(m.read.nationality, 'Indonesian');
      expect(m.read.name, 'BUDI HARTONO SANTOSO');
      expect(m.read.dateOfBirth, DateTime(1985, 3, 12));
      expect(m.read.expiry, DateTime(2030, 1, 1));
      expect(m.numberChecked, isTrue);
      expect(readIdText(page, IdDocType.passport, now: _now).number, 'C4821937');
      expect(idShowsNonCitizen(IdDocType.passport, 'Indonesian'), isTrue);
      expect(idShowsNonCitizen(IdDocType.passport, 'Malaysian'), isFalse);
    });

    test('a misread number fails its check digit', () {
      final m = readPassportMrz(page.replaceFirst('C4821937<2', 'C4821987<2'), now: _now)!;
      expect(m.numberChecked, isFalse);
    });

    test('a passport photo with no machine lines reads empty', () {
      expect(readIdText('PASSPORT\nSURNAME SANTOSO', IdDocType.passport).isEmpty, isTrue);
    });
  });

  group('names', () {
    test('joining words and order do not matter', () {
      expect(namesMatch('AINA BINTI RAHMAN', 'Aina Rahman'), isTrue);
      expect(namesMatch('AINA BT. RAHMAN', 'AINA BINTI RAHMAN'), isTrue);
      expect(namesMatch('KUMAR A/L SAMY', 'KUMAR SAMY'), isTrue);
      expect(namesMatch('AINA RAHMAN', 'AINA ROSLAN'), isFalse);
      expect(namesMatch('', 'X'), isFalse);
      expect(companyNamesMatch('CAHAYA TEKSI SDN. BHD.', 'Cahaya Teksi Sdn Bhd'), isTrue);
      expect(companyNamesMatch('CAHAYA TEKSI SDN. BHD.', 'BINTANG TEKSI SDN BHD'), isFalse);
    });
  });

  group('SSM company document', () {
    const profile = '''
SURUHANJAYA SYARIKAT MALAYSIA
COMPANIES COMMISSION OF MALAYSIA
COMPANY PROFILE
Company Name : CAHAYA TEKSI SDN. BHD.
Registration No. : 201901012345 (1321234-K)
Date of Incorporation : 12/04/2019
Company Type : PRIVATE LIMITED
Registered Address : LOT 5, JALAN KENARI 3,
47100 PUCHONG, SELANGOR
DIRECTORS / OFFICERS
1. AINA BINTI RAHMAN 900101-14-5678
2. MOHD FAIZ BIN ISA 880505-10-1111
SHAREHOLDERS
''';

    test('name, number, type, date, address and directors', () {
      final r = readCompanyText(profile);
      expect(r.name, 'CAHAYA TEKSI SDN. BHD.');
      expect(r.regNo, '201901012345 (1321234-K)');
      expect(r.type, 'Sdn. Bhd.');
      expect(r.regDate, DateTime(2019, 4, 12));
      expect(r.address, 'LOT 5, JALAN KENARI 3, 47100 PUCHONG, SELANGOR');
      expect(r.directors.map((d) => d.name), ['AINA BINTI RAHMAN', 'MOHD FAIZ BIN ISA']);
      expect(r.directors.first.id, '900101-14-5678');
      expect(driverIsDirector(r.directors, name: 'Aina Rahman', idNumber: '900101145678'), isTrue);
      expect(driverIsDirector(r.directors, name: 'Someone Else', idNumber: '010101-01-0101'), isFalse);
    });

    test('a business registration in Malay', () {
      const t = '''
PERAKUAN PENDAFTARAN PERNIAGAAN
Nama Perniagaan : RAHMAN JAYA ENTERPRISE
No. Pendaftaran : 202003123456 (003123456-X)
Tarikh Pendaftaran : 3 MAC 2020
Alamat Perniagaan : NO 8 JALAN MAWAR
43000 KAJANG SELANGOR
PEMILIK
AINA BINTI RAHMAN
''';
      final r = readCompanyText(t);
      expect(r.name, 'RAHMAN JAYA ENTERPRISE');
      expect(r.regNo, '202003123456 (003123456-X)');
      expect(r.type, 'Enterprise');
      expect(r.regDate, DateTime(2020, 3, 3));
      expect(r.address, 'NO 8 JALAN MAWAR, 43000 KAJANG SELANGOR');
      expect(r.directors.single.name, 'AINA BINTI RAHMAN');
    });

    test('nothing readable', () {
      expect(readCompanyText('').isEmpty, isTrue);
    });
  });

  group('Kad Pemandu', () {
    const card = '''
AGENSI PENGANGKUTAN AWAM DARAT
KAD PEMANDU TEKSI
No. Kad : KP/B/2024/0128843
Nama : AINA BINTI RAHMAN
No. K/P : 900101-14-5678
Sah Dari : 02/05/2026 Hingga : 01/05/2027
Jenis Perkhidmatan : TEKSI
Nama Pengusaha : CAHAYA TEKSI SDN. BHD.
No. Lesen Pengusaha : LPKP/TKS/B/012345
No. Pendaftaran Kenderaan : HWA 8812
PEMANDU KEDUA
Dicetak dari iSPKP
''';

    test('every field', () {
      final r = readDriverPermitText(card);
      expect(r.cardNo, 'KP/B/2024/0128843');
      expect(r.name, 'AINA BINTI RAHMAN');
      expect(r.idNumber, '900101-14-5678');
      expect(r.validFrom, DateTime(2026, 5, 2));
      expect(r.validUntil, DateTime(2027, 5, 1));
      expect(r.serviceType, 'TEKSI');
      expect(r.issuer, 'APAD (via iSPKP)');
      expect(r.operatorName, 'CAHAYA TEKSI SDN. BHD.');
      expect(r.operatorLicence, 'LPKP/TKS/B/012345');
      expect(r.plate, 'HWA 8812');
      expect(r.position, 2);
      expect(driverPositionLabel(2), '2nd driver');
      expect(driverPositionLabel(11), '11th driver');
    });

    test('English labels and a 3rd driver', () {
      const t = 'DRIVER CARD\nCard No: KP/W/2025/0000001\nName: TAN WEI MING\nValid until: 30 Jun 2027\n'
          'Vehicle No: WXY 1234\n3RD DRIVER';
      final r = readDriverPermitText(t);
      expect(r.cardNo, 'KP/W/2025/0000001');
      expect(r.name, 'TAN WEI MING');
      expect(r.validUntil, DateTime(2027, 6, 30));
      expect(r.plate, 'WXY 1234');
      expect(r.position, 3);
    });

    test('nothing readable', () {
      expect(readDriverPermitText('???').isEmpty, isTrue);
    });
  });

  group('vehicle grant / VOC', () {
    const grant = '''
JABATAN PENGANGKUTAN JALAN MALAYSIA
SIJIL PEMILIKAN KENDERAAN
No. Pendaftaran : WXY 1234
Nama Pemunya Berdaftar : AINA BINTI RAHMAN
No. Pengenalan : 900101-14-5678
Buatan/Nama Model : PERODUA BEZZA 1.3 AV
Keupayaan Enjin : 1329
Bahan Bakar : PETROL
No. Enjin : 1NR-F123456
No. Casis : PM2B200S00412345
Warna : SILVER
Tahun Dibuat : 2021
Tarikh Pendaftaran : 15/03/2021
''';

    test('every field', () {
      final r = readVehicleGrantText(grant);
      expect(r.plate, 'WXY 1234');
      expect(r.ownerName, 'AINA BINTI RAHMAN');
      expect(r.ownerId, '900101-14-5678');
      expect(r.make, 'PERODUA');
      expect(r.model, 'BEZZA 1.3 AV');
      expect(r.engineCc, 1329);
      expect(r.engineNo, '1NR-F123456');
      expect(r.chassisNo, 'PM2B200S00412345');
      expect(r.colour, 'SILVER');
      expect(r.year, 2021);
      expect(r.registrationDate, DateTime(2021, 3, 15));
    });

    test('English VOC with separate make and model', () {
      const t = 'VEHICLE OWNERSHIP CERTIFICATE\nRegistration No: HWA 8812\nRegistered Owner: CAHAYA TEKSI SDN. BHD.\n'
          'Make: PROTON\nModel: PERSONA 1.6\nEngine Capacity: 1597 cc\nColour: WHITE\nYear of Manufacture: 2009\n'
          'Registration Date: 2009-08-01';
      final r = readVehicleGrantText(t);
      expect(r.plate, 'HWA 8812');
      expect(r.ownerName, 'CAHAYA TEKSI SDN. BHD.');
      expect(r.make, 'PROTON');
      expect(r.model, 'PERSONA 1.6');
      expect(r.engineCc, 1597);
      expect(r.colour, 'WHITE');
      expect(r.year, 2009);
      expect(r.registrationDate, DateTime(2009, 8, 1));
      expect(plateKey('hwa 8812'), plateKey(r.plate));
    });

    test('nothing readable', () {
      expect(readVehicleGrantText('').isEmpty, isTrue);
    });
  });
}
