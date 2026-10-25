/// Document reading, part 2: what is printed on each kind of document a
/// partner or vehicle uploads, so every field is read, and what each is
/// checked against. A Required Document is "read as" one kind (Admin ›
/// Required Documents), guessed from its name until the admin picks one.
///
/// The fields go to the AI check as its permit fields (at most 20, by their
/// printed labels, English and Malay), and come back in
/// `ai_verification.extracted.permitFields`. Fields printed but not kept
/// (religion, bank transactions, medical findings) are never asked for.
/// Pure: see test/doc_kinds_test.dart.
library;

import 'document_text.dart' show namesMatch, plateKey, sameIdNumber;

/// What a field is compared with.
enum DocCheck {
  none,

  /// The partner's name (BIN/BINTI/BT read as the same).
  name,

  /// The partner's IC or passport number.
  ic,

  /// The vehicle's plate.
  plate,

  /// The vehicle's chassis (VIN) number.
  chassis,

  /// The vehicle's engine number.
  engine,

  /// The vehicle's make and model.
  makeModel,

  /// The vehicle's year of manufacture.
  year,

  /// The vehicle owner on file (grant owner, else the partner).
  owner,

  /// A date that must not have passed; a warning 30 days before.
  validUntil,

  /// A date within the last 12 months (Puspakom inspections).
  withinYear,

  /// A year of manufacture at most 15 years ago (APAD's e-hailing limit).
  vehicleAge,

  /// Must read as [DocField.expect].
  expected,
}

class DocField {
  const DocField(this.key, this.label, {this.local = '', this.date = false, this.check = DocCheck.none, this.expect});
  final String key;
  final String label;

  /// The label as printed in Malay, when it differs.
  final String local;
  final bool date;
  final DocCheck check;

  /// For [DocCheck.expected]: what a good value reads like.
  final RegExp? expect;
}

class DocKind {
  const DocKind(this.id, this.name, this.fields, {this.notKept = const []});
  final String id;
  final String name;
  final List<DocField> fields;

  /// Printed on it, never read or kept.
  final List<String> notKept;
}

/// The most fields one kind asks the AI for (doc_ai.ts MAX_PERMIT_FIELDS).
const maxDocKindFields = 20;

final _citizen = RegExp(r'WARGANEGARA|CITIZEN|MALAYSIA', caseSensitive: false);
final _competent = RegExp(r'\bCDL\b|COMPETENT|KOMPETEN', caseSensitive: false);
final _psvE = RegExp(r'PSV.{0,6}\(?E\)?|E-?HAILING', caseSensitive: false);
final _eHailing = RegExp(r'E-?HAILING|PRIVATE HIRE|KENDERAAN SEWA', caseSensitive: false);
final _pass = RegExp(r'LULUS|PASS', caseSensitive: false);
final _existing = RegExp(r'EXISTING|WUJUD|ACTIVE|AKTIF|BERDAFTAR', caseSensitive: false);
final _present = RegExp(r'YES|YA|PRESENT|TRUE|SIGNED|ADA', caseSensitive: false);

final docKinds = <DocKind>[
  DocKind('mykad', 'MyKad / MyPR / MyKAS', [
    const DocField('cardType', 'Card type', local: 'MyKad / MyPR / MyKAS'),
    const DocField('icNumber', 'IC number', local: 'No. Kad Pengenalan', check: DocCheck.ic),
    const DocField('fullName', 'Full name', local: 'Nama', check: DocCheck.name),
    const DocField('address', 'Address', local: 'Alamat'),
    const DocField('postcodeTownState', 'Postcode, town and state', local: 'Poskod, bandar, negeri'),
    DocField('citizenship', 'Citizenship', local: 'Warganegara', check: DocCheck.expected, expect: _citizen),
    const DocField('gender', 'Gender', local: 'Lelaki / Perempuan'),
    const DocField('expiry', 'Card expiry (MyKAS only)', local: 'Tarikh luput', date: true, check: DocCheck.validUntil),
    const DocField('cardSerial', 'Card serial number (back)', local: 'No. siri kad'),
  ], notKept: const ['Religion']),
  DocKind('passport', 'Passport', [
    const DocField('passportNumber', 'Passport number', local: 'No. Pasport', check: DocCheck.ic),
    const DocField('fullName', 'Surname and given names', local: 'Nama', check: DocCheck.name),
    const DocField('nationality', 'Nationality', local: 'Warganegara'),
    const DocField('dateOfBirth', 'Date of birth', local: 'Tarikh lahir', date: true),
    const DocField('sex', 'Sex', local: 'Jantina'),
    const DocField('expiry', 'Date of expiry', local: 'Tarikh tamat', date: true, check: DocCheck.validUntil),
    const DocField('issued', 'Date of issue', local: 'Tarikh dikeluarkan', date: true),
    const DocField('placeOfBirth', 'Place of birth', local: 'Tempat lahir'),
    const DocField('authority', 'Issuing authority', local: 'Pihak berkuasa'),
    const DocField('personalNumber', 'Personal number (IC on Malaysian passports)', local: 'No. Pengenalan', check: DocCheck.ic),
    const DocField('mrz', 'Machine-readable lines (MRZ), as printed'),
  ]),
  DocKind('licence', 'Driving licence (incl. PSV)', [
    const DocField('fullName', 'Name', local: 'Nama', check: DocCheck.name),
    const DocField('idNumber', 'ID number', local: 'No. Pengenalan', check: DocCheck.ic),
    DocField('licenceType', 'Licence type (CDL, PDL, LDL, GDL)', local: 'Jenis lesen', check: DocCheck.expected, expect: _competent),
    const DocField('classes', 'Licence classes', local: 'Kelas'),
    const DocField('validFrom', 'Class valid from', local: 'Tempoh sah dari', date: true),
    const DocField('validTo', 'Class valid until', local: 'Tempoh sah hingga', date: true, check: DocCheck.validUntil),
    DocField('psvClass', 'PSV class', local: 'Kelas PSV', check: DocCheck.expected, expect: _psvE),
    const DocField('psvValidTo', 'PSV valid until', local: 'PSV sah hingga', date: true, check: DocCheck.validUntil),
    const DocField('address', 'Address', local: 'Alamat'),
    const DocField('nationality', 'Nationality', local: 'Warganegara'),
    const DocField('serialNumber', 'Licence serial number', local: 'No. siri lesen'),
    const DocField('hasQr', 'QR code present (yes/no)'),
  ]),
  DocKind('evp', 'E-hailing vehicle permit (EVP)', [
    const DocField('permitNumber', 'Permit number', local: 'No. Permit'),
    const DocField('plate', 'Vehicle plate', local: 'No. Pendaftaran Kenderaan', check: DocCheck.plate),
    const DocField('holderName', 'Holder name', local: 'Nama pemegang', check: DocCheck.owner),
    const DocField('holderId', 'Holder ID number', local: 'No. Pengenalan pemegang'),
    const DocField('operator', 'E-hailing operator', local: 'Pengendali e-hailing'),
    const DocField('validFrom', 'Valid from', local: 'Sah dari', date: true),
    const DocField('validTo', 'Valid until', local: 'Sah hingga', date: true, check: DocCheck.validUntil),
    const DocField('makeModel', 'Make and model', local: 'Buatan / model', check: DocCheck.makeModel),
    const DocField('authority', 'Issuing authority (APAD, Sabah, Sarawak)', local: 'Pihak berkuasa'),
    const DocField('hasQr', 'QR code present (yes/no)'),
  ]),
  DocKind('cover', 'Insurance cover note / policy', [
    const DocField('insurer', 'Insurer', local: 'Penanggung insurans'),
    const DocField('coverNoteNumber', 'Cover note number', local: 'No. nota perlindungan'),
    const DocField('policyNumber', 'Policy number', local: 'No. polisi'),
    const DocField('insuredName', 'Insured name', local: 'Nama diinsuranskan', check: DocCheck.owner),
    const DocField('insuredId', 'Insured IC or company number', local: 'No. KP / syarikat'),
    const DocField('plate', 'Vehicle plate', local: 'No. pendaftaran', check: DocCheck.plate),
    const DocField('makeModel', 'Make and model', local: 'Buatan / model', check: DocCheck.makeModel),
    const DocField('year', 'Year of manufacture', local: 'Tahun dibuat', check: DocCheck.year),
    const DocField('chassis', 'Chassis number', local: 'No. casis', check: DocCheck.chassis),
    const DocField('engine', 'Engine number', local: 'No. enjin', check: DocCheck.engine),
    const DocField('engineCcSeats', 'Engine cc and seats', local: 'Sukatan isi padu / tempat duduk'),
    const DocField('coverType', 'Type of cover (Comprehensive, Third party fire & theft, Third party)', local: 'Jenis perlindungan'),
    const DocField('periodFrom', 'Period of insurance from', local: 'Tempoh insurans dari', date: true),
    const DocField('periodTo', 'Period of insurance to', local: 'Tempoh insurans hingga', date: true, check: DocCheck.validUntil),
    DocField('eHailing', 'E-hailing cover (endorsement or e-hailing policy, annual or per-day)',
        local: 'Endorsmen e-hailing', check: DocCheck.expected, expect: _eHailing),
    const DocField('authorisedDrivers', 'Authorised drivers (names, or "all drivers")', local: 'Pemandu dibenarkan'),
    const DocField('sumInsured', 'Sum insured (RM)', local: 'Jumlah diinsuranskan'),
    const DocField('ncd', 'NCD (%)', local: 'Diskaun tanpa tuntutan'),
    const DocField('excess', 'Excess (RM)', local: 'Lebihan'),
    const DocField('financier', 'Hire purchase / financier', local: 'Sewa beli'),
  ]),
  DocKind('grant', 'Vehicle grant (VOC / e-VOC)', [
    const DocField('plate', 'Plate', local: 'No. pendaftaran', check: DocCheck.plate),
    const DocField('ownerName', 'Owner name', local: 'Nama tuan punya berdaftar', check: DocCheck.owner),
    const DocField('ownerId', 'Owner IC or company number', local: 'No. KP / syarikat'),
    const DocField('ownerAddress', 'Owner address', local: 'Alamat'),
    const DocField('makeModel', 'Make and model', local: 'Buatan / nama model', check: DocCheck.makeModel),
    const DocField('bodyType', 'Body type', local: 'Jenis badan'),
    const DocField('colour', 'Colour', local: 'Warna'),
    const DocField('fuel', 'Fuel', local: 'Bahan bakar'),
    const DocField('engine', 'Engine number', local: 'No. enjin', check: DocCheck.engine),
    const DocField('chassis', 'Chassis number', local: 'No. casis', check: DocCheck.chassis),
    const DocField('engineCc', 'Engine cc', local: 'Sukatan isi padu'),
    const DocField('year', 'Year of manufacture', local: 'Tahun dibuat', check: DocCheck.vehicleAge),
    const DocField('registered', 'Registration date', local: 'Tarikh pendaftaran', date: true),
    const DocField('classOfUse', 'Class of use', local: 'Kelas kegunaan'),
    const DocField('seats', 'Seating capacity', local: 'Bilangan tempat duduk'),
    const DocField('ownershipClaim', 'Ownership claim (financier)', local: 'Tuntutan hak milik'),
    const DocField('origin', 'Origin', local: 'Asal (tempatan / import)'),
    const DocField('serial', 'Grant serial number', local: 'No. siri'),
  ]),
  DocKind('roadtax', 'Road tax (e-LKM)', [
    const DocField('plate', 'Plate', local: 'No. pendaftaran', check: DocCheck.plate),
    const DocField('validFrom', 'Valid from', local: 'Sah dari', date: true),
    const DocField('validTo', 'Valid until', local: 'Tamat tempoh', date: true, check: DocCheck.validUntil),
    const DocField('serial', 'LKM serial number', local: 'No. siri LKM'),
    const DocField('classOfUse', 'Class of use', local: 'Kelas kegunaan'),
    const DocField('engineCc', 'Engine cc', local: 'Sukatan isi padu'),
    const DocField('fee', 'Fee (RM)', local: 'Bayaran'),
    const DocField('owner', 'Owner', local: 'Tuan punya', check: DocCheck.owner),
  ]),
  DocKind('puspakom', 'Puspakom inspection', [
    const DocField('reportNumber', 'Report or certificate number', local: 'No. laporan / sijil'),
    DocField('inspectionType', 'Inspection type', local: 'Jenis pemeriksaan', check: DocCheck.expected, expect: _eHailing),
    DocField('result', 'Result', local: 'Keputusan', check: DocCheck.expected, expect: _pass),
    const DocField('inspected', 'Inspection date', local: 'Tarikh pemeriksaan', date: true, check: DocCheck.withinYear),
    const DocField('validTo', 'Valid until / next inspection', local: 'Sah hingga', date: true, check: DocCheck.validUntil),
    const DocField('centre', 'Centre', local: 'Pusat'),
    const DocField('plate', 'Plate', local: 'No. pendaftaran', check: DocCheck.plate),
    const DocField('chassis', 'Chassis number', local: 'No. casis', check: DocCheck.chassis),
    const DocField('engine', 'Engine number', local: 'No. enjin', check: DocCheck.engine),
    const DocField('odometer', 'Odometer (km)', local: 'Bacaan odometer'),
  ]),
  DocKind('authorisation', 'Owner authorisation letter', [
    const DocField('ownerName', 'Owner name', local: 'Nama pemilik', check: DocCheck.owner),
    const DocField('ownerId', 'Owner IC', local: 'No. KP pemilik'),
    const DocField('driverName', 'Driver name', local: 'Nama pemandu', check: DocCheck.name),
    const DocField('driverId', 'Driver IC', local: 'No. KP pemandu', check: DocCheck.ic),
    const DocField('plate', 'Vehicle plate', local: 'No. pendaftaran', check: DocCheck.plate),
    DocField('purpose', 'Purpose', local: 'Tujuan', check: DocCheck.expected, expect: _eHailing),
    const DocField('date', 'Date', local: 'Tarikh', date: true),
    DocField('signed', 'Owner signature present (yes/no)', local: 'Tandatangan', check: DocCheck.expected, expect: _present),
  ]),
  DocKind('taxi', 'Taxi driver card (Kad Pemandu)', [
    const DocField('cardNumber', 'Card number', local: 'No. kad'),
    const DocField('fullName', 'Name', local: 'Nama', check: DocCheck.name),
    const DocField('idNumber', 'ID number', local: 'No. Pengenalan', check: DocCheck.ic),
    const DocField('validFrom', 'Valid from', local: 'Sah dari', date: true),
    const DocField('validTo', 'Valid until', local: 'Sah hingga', date: true, check: DocCheck.validUntil),
    const DocField('serviceType', 'Service type', local: 'Jenis perkhidmatan'),
    const DocField('operator', 'Operator and licence', local: 'Pengendali'),
    const DocField('plate', 'Plate', local: 'No. pendaftaran', check: DocCheck.plate),
    const DocField('issuer', 'Issuer', local: 'Dikeluarkan oleh'),
  ]),
  DocKind('ssm', 'Company registration (SSM)', [
    const DocField('companyName', 'Company name', local: 'Nama syarikat'),
    const DocField('regNumber', 'Registration number', local: 'No. pendaftaran'),
    const DocField('type', 'Type (Sdn Bhd, Enterprise, PLT)', local: 'Jenis'),
    const DocField('registered', 'Registration date', local: 'Tarikh pendaftaran', date: true),
    const DocField('address', 'Business address', local: 'Alamat perniagaan'),
    DocField('status', 'Status', local: 'Status', check: DocCheck.expected, expect: _existing),
    const DocField('directors', 'Directors or owners', local: 'Pengarah / pemilik'),
    const DocField('expiry', 'Expiry (sole proprietor, partnership)', local: 'Tarikh luput', date: true, check: DocCheck.validUntil),
  ]),
  DocKind('bank', 'Bank account proof', [
    const DocField('bank', 'Bank', local: 'Bank'),
    const DocField('holder', 'Account holder', local: 'Nama pemegang akaun', check: DocCheck.name),
    const DocField('accountNumber', 'Account number', local: 'No. akaun'),
    const DocField('statementDate', 'Statement date', local: 'Tarikh penyata', date: true),
  ], notKept: const ['Transactions and balance']),
  DocKind('certificate', 'Certificate (PSV course, medical, good conduct)', [
    const DocField('title', 'Certificate title', local: 'Tajuk sijil'),
    const DocField('holderName', 'Holder name', local: 'Nama', check: DocCheck.name),
    const DocField('holderId', 'Holder ID number', local: 'No. Pengenalan', check: DocCheck.ic),
    const DocField('issuer', 'Issuer', local: 'Dikeluarkan oleh'),
    const DocField('number', 'Certificate number', local: 'No. sijil'),
    const DocField('issued', 'Issue date', local: 'Tarikh dikeluarkan', date: true),
    const DocField('expiry', 'Expiry date', local: 'Tarikh luput', date: true, check: DocCheck.validUntil),
    DocField('fitness', 'Fit / not fit (medical only)', local: 'Layak / tidak layak'),
  ], notKept: const ['Medical findings']),
];

DocKind? docKindById(Object? id) {
  for (final k in docKinds) {
    if (k.id == id) return k;
  }
  return null;
}

final _guesses = <(RegExp, String)>[
  (RegExp(r'cover\s*note|insuran|polisi|policy', caseSensitive: false), 'cover'),
  (RegExp(r'puspakom|inspect|pemeriksaan', caseSensitive: false), 'puspakom'),
  (RegExp(r'\bevp\b|vehicle permit|permit kenderaan|e-?hailing permit', caseSensitive: false), 'evp'),
  (RegExp(r'grant|geran|\bvoc\b|ownership cert|pemilikan', caseSensitive: false), 'grant'),
  (RegExp(r'road\s*tax|\blkm\b|cukai jalan', caseSensitive: false), 'roadtax'),
  (RegExp(r'authori[sz]ation|kebenaran|consent letter', caseSensitive: false), 'authorisation'),
  (RegExp(r'kad pemandu|taxi (driver )?(card|permit)|teksi', caseSensitive: false), 'taxi'),
  (RegExp(r'licen[cs]e|lesen|\bpsv\b|\bgdl\b|\bcdl\b', caseSensitive: false), 'licence'),
  (RegExp(r'passport|pasport', caseSensitive: false), 'passport'),
  (RegExp(r'mykad|mypr|mykas|\bic\b|identity|kad pengenalan|national id', caseSensitive: false), 'mykad'),
  (RegExp(r'\bssm\b|company|syarikat|business reg', caseSensitive: false), 'ssm'),
  (RegExp(r'bank|statement|penyata', caseSensitive: false), 'bank'),
  (RegExp(r'certificate|sijil|course|kursus|medical|perubatan|good conduct', caseSensitive: false), 'certificate'),
];

/// The kind a Required Document is read as: the admin's `readAs`, else a
/// guess from its name; null when neither says.
DocKind? docKindFor(Map<String, dynamic> values) {
  final set = docKindById(values['readAs']);
  if (set != null) return set;
  if (values['readAs'] == 'none') return null;
  return guessDocKind('${values['name'] ?? ''}');
}

DocKind? guessDocKind(String name) {
  for (final (re, id) in _guesses) {
    if (re.hasMatch(name)) return docKindById(id);
  }
  return null;
}

/// The kind's fields as the AI check asks for them (`permitFields`), after
/// any [first] (a permit type's own), at most [maxDocKindFields].
List<({String key, String label, String labelLocal, bool isDate})> docKindAsk(
  DocKind kind, {
  List<({String key, String label, String labelLocal, bool isDate})> first = const [],
}) {
  final seen = {for (final f in first) f.key};
  return [
    ...first,
    for (final f in kind.fields)
      if (seen.add(f.key)) (key: f.key, label: f.label, labelLocal: f.local, isDate: f.date),
  ].take(maxDocKindFields).toList();
}

// ---- Checking what was read -----------------------------------------------------------------

/// What GET.ride has on file to compare with.
class DocOnFile {
  const DocOnFile({
    this.name,
    this.ic,
    this.plate,
    this.chassis,
    this.engine,
    this.make,
    this.model,
    this.year,
    this.ownerName,
  });

  final String? name;
  final String? ic;
  final String? plate;
  final String? chassis;
  final String? engine;
  final String? make;
  final String? model;
  final String? year;

  /// The vehicle's registered owner (grant owner), when known.
  final String? ownerName;

  String? get makeModel => [make, model].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ').trim().nullIfEmpty;
}

extension on String {
  String? get nullIfEmpty => trim().isEmpty ? null : this;
}

enum FieldVerdict { match, check, mismatch, none }

class DocFieldRow {
  const DocFieldRow(this.field, this.read, this.onFile, this.verdict, [this.note]);
  final DocField field;
  final String? read;
  final String? onFile;
  final FieldVerdict verdict;
  final String? note;
}

String _norm(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

DateTime? _readDate(String? s) {
  if (s == null) return null;
  final iso = DateTime.tryParse(s.trim());
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final m = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$').firstMatch(s.trim());
  if (m == null) return null;
  return DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!));
}

/// Every field of [kind] with what was [read] (the AI's permitFields), what is
/// on file, and whether they agree. [today] for the date checks.
List<DocFieldRow> checkDocFields(DocKind kind, Map<String, dynamic> read, DocOnFile onFile, {required DateTime today}) {
  final day = DateTime(today.year, today.month, today.day);
  return [
    for (final f in kind.fields)
      () {
        final v = '${read[f.key] ?? ''}'.trim();
        final value = v.isEmpty || v.toLowerCase() == 'null' ? null : v;
        DocFieldRow row(String? file, bool? ok, [String? note, bool warn = false]) => DocFieldRow(
              f,
              value,
              file,
              value == null || ok == null
                  ? FieldVerdict.none
                  : warn
                      ? FieldVerdict.check
                      : ok
                          ? FieldVerdict.match
                          : FieldVerdict.mismatch,
              note,
            );
        switch (f.check) {
          case DocCheck.none:
            return row(null, null);
          case DocCheck.name:
            return row(onFile.name, onFile.name == null ? null : namesMatch(value, onFile.name));
          case DocCheck.ic:
            return row(onFile.ic, onFile.ic == null ? null : sameIdNumber(value, onFile.ic));
          case DocCheck.plate:
            return row(onFile.plate, onFile.plate == null ? null : plateKey(value) == plateKey(onFile.plate));
          case DocCheck.chassis:
            return row(onFile.chassis, onFile.chassis == null ? null : _norm(value ?? '') == _norm(onFile.chassis!));
          case DocCheck.engine:
            return row(onFile.engine, onFile.engine == null ? null : _norm(value ?? '') == _norm(onFile.engine!));
          case DocCheck.makeModel:
            final mm = onFile.makeModel;
            if (mm == null || value == null) return row(mm, null);
            final want = _norm(onFile.model ?? mm);
            return row(mm, want.isNotEmpty && _norm(value).contains(want));
          case DocCheck.year:
            return row(onFile.year, onFile.year == null ? null : _norm(value ?? '') == _norm(onFile.year!));
          case DocCheck.owner:
            final owner = onFile.ownerName ?? onFile.name;
            if (owner == null || value == null) return row(owner, null);
            final ok = namesMatch(value, owner);
            return row(owner, ok, ok ? null : "Not the person on file: an owner authorisation letter is needed.", !ok);
          case DocCheck.validUntil:
            final d = _readDate(value);
            if (d == null) return row(null, null);
            if (d.isBefore(day)) return row(null, false, 'Expired.');
            final left = d.difference(day).inDays;
            return left <= 30 ? row(null, true, 'Ends in $left days.', true) : row(null, true);
          case DocCheck.withinYear:
            final d = _readDate(value);
            if (d == null) return row(null, null);
            return row(null, !d.isBefore(DateTime(day.year - 1, day.month, day.day)) && !d.isAfter(day),
                'Must be within the last 12 months.');
          case DocCheck.vehicleAge:
            final y = int.tryParse(RegExp(r'\d{4}').firstMatch(value ?? '')?.group(0) ?? '');
            final file = onFile.year;
            if (y == null) return row(file, null);
            final sameYear = file == null || _norm(file) == '$y';
            final young = day.year - y <= 15;
            return row(file, sameYear && young,
                !young ? 'Over 15 years old: past the e-hailing limit.' : (sameYear ? null : 'Not the year on file.'));
          case DocCheck.expected:
            return row(null, value == null ? null : f.expect!.hasMatch(value), null);
        }
      }(),
  ];
}

/// "18 fields read: 12 match, 1 to check."
String docFieldsSummary(List<DocFieldRow> rows) {
  final read = rows.where((r) => r.read != null).length;
  int n(FieldVerdict v) => rows.where((r) => r.verdict == v).length;
  final parts = [
    if (n(FieldVerdict.match) > 0) '${n(FieldVerdict.match)} match',
    if (n(FieldVerdict.check) > 0) '${n(FieldVerdict.check)} to check',
    if (n(FieldVerdict.mismatch) > 0) '${n(FieldVerdict.mismatch)} wrong',
  ];
  return '$read of ${rows.length} fields read${parts.isEmpty ? '' : ': ${parts.join(', ')}'}.';
}
