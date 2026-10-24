// Partner registration (0288): the text read off a document's photo — on the
// phone by its text recognizer, else by the id-read function — turned into
// the fields a driver checks: a MyKad, MyPR or passport, an SSM company
// document, a Kad Pemandu (taxi driver card) and a Malaysian vehicle grant
// (geran) or VOC. Each reader takes whatever came back, in any order and
// with OCR's slips, and leaves a field null when it can't find it: the
// driver types it in. Pure, so it is tested on synthetic text only.
library;

// ---- Shared ---------------------------------------------------------------------------------------

List<String> _lines(String text) => [
      for (final l in text.split(RegExp(r'[\r\n]+'))) l.replaceAll(RegExp(r'\s+'), ' ').trim(),
    ].where((l) => l.isNotEmpty).toList();

String? _nz(String? s) {
  final t = s?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t == null || t.isEmpty ? null : t;
}

/// Letters and digits only, upper case: how two ID, permit or registration
/// numbers are compared (900101-14-5678 = 900101145678).
String idKey(String? s) => (s ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Whether two numbers are the same once punctuation and case are dropped;
/// false when either is blank.
bool sameIdNumber(String? a, String? b) {
  final x = idKey(a), y = idKey(b);
  return x.isNotEmpty && x == y;
}

/// A plate as compared: upper case, no spaces (WXY 1234 = wxy1234).
String plateKey(String? s) => (s ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Words that join a Malaysian name and may be written or left out:
/// AINA BINTI RAHMAN = AINA BT RAHMAN = AINA RAHMAN.
const _nameJoins = {'BIN', 'BINTI', 'BTE', 'BT', 'B', 'AL', 'AP', 'A', 'L', 'P', 'S', 'D', 'O', 'SO', 'DO'};

/// Company words written several ways: SDN. BHD. = SDN BHD = SENDIRIAN BERHAD.
const _companyWords = {'SDN', 'BHD', 'SENDIRIAN', 'BERHAD', 'PLT', 'ENTERPRISE', 'ENT', 'TRADING', 'CO', 'COMPANY'};

Set<String> _tokens(String? s, Set<String> drop) => {
      for (final w in (s ?? '').toUpperCase().replaceAll(RegExp(r"[^A-Z0-9 ]"), ' ').split(' '))
        if (w.isNotEmpty && !drop.contains(w)) w,
    };

/// Whether two names are the same person's: the same words once the joining
/// words (BIN, BINTI, A/L ...) and punctuation are dropped, in any order.
/// False when either is blank.
bool namesMatch(String? a, String? b) {
  final x = _tokens(a, _nameJoins), y = _tokens(b, _nameJoins);
  return x.isNotEmpty && x.length == y.length && x.containsAll(y);
}

/// Whether two company names are the same company (SDN. BHD. and the like
/// written any way). False when either is blank.
bool companyNamesMatch(String? a, String? b) {
  final x = _tokens(a, _companyWords), y = _tokens(b, _companyWords);
  return x.isNotEmpty && x.length == y.length && x.containsAll(y);
}

const _months = {
  'JAN': 1, 'JANUARY': 1, 'JANUARI': 1, 'FEB': 2, 'FEBRUARY': 2, 'FEBRUARI': 2, 'MAR': 3, 'MARCH': 3, 'MAC': 3,
  'APR': 4, 'APRIL': 4, 'MAY': 5, 'MEI': 5, 'JUN': 6, 'JUNE': 6, 'JUL': 7, 'JULY': 7, 'JULAI': 7, 'AUG': 8,
  'AUGUST': 8, 'OGOS': 8, 'OGO': 8, 'SEP': 9, 'SEPT': 9, 'SEPTEMBER': 9, 'OCT': 10, 'OCTOBER': 10, 'OKT': 10,
  'OKTOBER': 10, 'NOV': 11, 'NOVEMBER': 11, 'DEC': 12, 'DECEMBER': 12, 'DIS': 12, 'DISEMBER': 12,
};

DateTime? _date(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1 || d > 31 || y < 1900 || y > 2200) return null;
  final out = DateTime(y, m, d);
  return out.month == m ? out : null;
}

final _numericDate = RegExp(r'\b(\d{1,2})\s*[/.-]\s*(\d{1,2})\s*[/.-]\s*(\d{4})\b');
final _isoDate = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b');
final _wordDate = RegExp(r'\b(\d{1,2})[\s-]+([A-Za-z]{3,9})[\s-,]+(\d{4})\b');

/// Every date in [s], in order: 12/04/2019, 12-04-2019, 2019-04-12,
/// 12 APRIL 2019, 12 Apr 2019 (day first, as Malaysian documents write it).
List<DateTime> datesIn(String s) {
  final found = <(int, DateTime)>[];
  for (final m in _isoDate.allMatches(s)) {
    final d = _date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    if (d != null) found.add((m.start, d));
  }
  for (final m in _numericDate.allMatches(s)) {
    final d = _date(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!));
    if (d != null) found.add((m.start, d));
  }
  for (final m in _wordDate.allMatches(s)) {
    final month = _months[m[2]!.toUpperCase()];
    if (month == null) continue;
    final d = _date(int.parse(m[3]!), month, int.parse(m[1]!));
    if (d != null) found.add((m.start, d));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final f in found) f.$2];
}

/// One labelled value in [lines]: the text after the first label [labels]
/// matches ("Nama : AINA" or "Nama" then "AINA" on the next line), up to the
/// next label of [others] on the same line.
String? _labelled(List<String> lines, RegExp labels, {RegExp? stopAt}) {
  for (var i = 0; i < lines.length; i++) {
    final m = labels.firstMatch(lines[i]);
    if (m == null) continue;
    var rest = lines[i].substring(m.end).replaceFirst(RegExp(r'^\s*[:.;\-=]*\s*'), '');
    if (stopAt != null) {
      final s = stopAt.firstMatch(rest);
      if (s != null) rest = rest.substring(0, s.start);
    }
    rest = rest.trim();
    if (rest.isNotEmpty) return rest;
    if (i + 1 < lines.length && !(stopAt?.hasMatch(lines[i + 1]) ?? false)) return lines[i + 1];
  }
  return null;
}

RegExp _re(String pattern) => RegExp(pattern, caseSensitive: false);

/// A Malaysian plate: 1–3 letters, 1–4 digits, up to 2 letters after
/// (WXY 1234, HWA 8812, B 1234 X, PUTRAJAYA 123 is not read).
final _plate = RegExp(r'\b([A-Z]{1,3})\s?(\d{1,4})\s?([A-Z]{0,2})\b');

String? _plateIn(String s) {
  final m = _plate.firstMatch(s.toUpperCase());
  if (m == null) return null;
  return [m[1], m[2], if ((m[3] ?? '').isNotEmpty) m[3]].join(' ');
}

// ---- National ID ----------------------------------------------------------------------------------

/// The ID a driver registers with.
enum IdDocType {
  mykad('mykad', 'MyKad', 'Malaysian citizens.'),
  mypr('mypr', 'MyPR', 'Permanent residents (red card).'),
  passport('passport', 'Passport', 'Everyone else.');

  const IdDocType(this.key, this.label, this.hint);

  /// The value kept in `profiles.id_type`.
  final String key;
  final String label;
  final String hint;

  static IdDocType? parse(Object? v) => values.where((t) => t.key == '$v').firstOrNull;

  /// The two photos asked for.
  (String, String) get photoSides =>
      this == passport ? ('Photo page', 'Visa / work pass') : ('Front', 'Back');
}

/// What was read off an ID: nulls for what wasn't found.
class IdRead {
  const IdRead({this.number, this.name, this.dateOfBirth, this.address, this.nationality, this.expiry});
  final String? number;
  final String? name;
  final DateTime? dateOfBirth;
  final String? address;
  final String? nationality;
  final DateTime? expiry;

  bool get isEmpty =>
      number == null && name == null && dateOfBirth == null && address == null && nationality == null;
}

final _icNumber = RegExp(r'\b(\d{6})\s*-?\s*(\d{2})\s*-?\s*(\d{4})\b');

/// The date of birth a MyKad (or MyPR) number starts with (YYMMDD): this
/// century while that is not in the future at [now], else the last one.
DateTime? dobFromMyKad(String? ic, {DateTime? now}) {
  final k = idKey(ic);
  if (!RegExp(r'^\d{12}$').hasMatch(k)) return null;
  final yy = int.parse(k.substring(0, 2)), mm = int.parse(k.substring(2, 4)), dd = int.parse(k.substring(4, 6));
  final n = now ?? DateTime.now();
  final y = 2000 + yy > n.year ? 1900 + yy : 2000 + yy;
  return _date(y, mm, dd);
}

/// Whether [dob] is the date a MyKad number [ic] starts with (YYMMDD).
bool myKadDobMatches(String? ic, DateTime? dob) {
  final k = idKey(ic);
  if (dob == null || k.length < 6) return false;
  String two(int n) => n.toString().padLeft(2, '0');
  return k.substring(0, 6) == '${two(dob.year % 100)}${two(dob.month)}${two(dob.day)}';
}

/// "900101145678" or "900101-14-5678" as printed: 900101-14-5678.
String formatMyKad(String s) {
  final k = idKey(s);
  return RegExp(r'^\d{12}$').hasMatch(k) ? '${k.substring(0, 6)}-${k.substring(6, 8)}-${k.substring(8)}' : s.trim();
}

const _notNameWords = {
  'KAD', 'PENGENALAN', 'MALAYSIA', 'MYKAD', 'MYPR', 'IDENTITY', 'CARD', 'WARGANEGARA', 'LELAKI', 'PEREMPUAN',
  'ISLAM', 'PASPORT', 'PASSPORT', 'JALAN', 'JLN', 'TAMAN', 'LORONG', 'KAMPUNG', 'KG', 'NO', 'KUALA', 'LUMPUR',
  'SELANGOR', 'JOHOR', 'PULAU', 'PINANG', 'PERAK', 'KEDAH', 'KELANTAN', 'TERENGGANU', 'PAHANG', 'MELAKA',
  'SABAH', 'SARAWAK', 'NEGERI', 'SEMBILAN', 'PERLIS', 'LABUAN', 'PUTRAJAYA', 'BANDAR', 'MYS', 'TYPE', 'JENIS',
  'PEMASTAUTIN', 'TETAP', 'PERMANENT', 'RESIDENT', 'BUKAN', 'LOT', 'BLOK', 'PERSIARAN', 'LEBUH', 'SEKSYEN',
};

final _nameLine = RegExp(r"^[A-Z][A-Z '@./-]+$");

bool _looksLikeName(String l) =>
    _nameLine.hasMatch(l) && !l.split(' ').any((w) => _notNameWords.contains(w.replaceAll(RegExp(r'[^A-Z]'), '')));

bool _endsCard(String l) => RegExp(
      r'\b(WARGANEGARA|PEMASTAUTIN|ISLAM|LELAKI|PEREMPUAN|KRISTIAN|BUDDHA|HINDU|BUKAN|PERMANENT RESIDENT)\b',
    ).hasMatch(l.toUpperCase());

/// A MyKad's or MyPR's front: the number (YYMMDD-PB-###G), the name under it
/// (two lines when it wraps), the address under that (to the line with the
/// postcode), the date of birth from the number, and the citizenship word.
IdRead readMyKadText(String text, {IdDocType type = IdDocType.mykad, DateTime? now}) {
  final lines = _lines(text.toUpperCase());
  String? number;
  var at = -1;
  for (var i = 0; i < lines.length && number == null; i++) {
    final m = _icNumber.firstMatch(lines[i]);
    if (m != null) {
      number = '${m[1]}-${m[2]}-${m[3]}';
      at = i;
    }
  }
  String? name;
  var i = at + 1;
  for (; i < lines.length && name == null; i++) {
    if (_looksLikeName(lines[i]) && lines[i].split(' ').length >= 2) {
      name = lines[i];
      // A long name wraps: the next line joins it when it is letters only
      // and the line before ended on a joining word, or it is one word.
      if (i + 1 < lines.length &&
          _looksLikeName(lines[i + 1]) &&
          !_endsCard(lines[i + 1]) &&
          (_nameJoins.contains(name.split(' ').last) || !lines[i + 1].contains(' '))) {
        name = '$name ${lines[i + 1]}';
        i++;
      }
    }
  }
  final address = <String>[];
  if (name != null) {
    for (; i < lines.length; i++) {
      final l = lines[i];
      if (_endsCard(l)) break;
      address.add(l);
      if (address.length >= 5) break;
    }
  }
  String? nationality;
  final all = lines.join(' ');
  if (RegExp(r'\bBUKAN WARGANEGARA\b').hasMatch(all)) {
    nationality = 'Non-citizen';
  } else if (RegExp(r'\b(PEMASTAUTIN TETAP|PERMANENT RESIDENT|MYPR)\b').hasMatch(all) || type == IdDocType.mypr) {
    nationality = 'Permanent resident';
  } else if (RegExp(r'\bWARGANEGARA\b').hasMatch(all) || (type == IdDocType.mykad && number != null)) {
    nationality = 'Malaysian';
  }
  return IdRead(
    number: number,
    name: name,
    dateOfBirth: dobFromMyKad(number, now: now),
    address: address.isEmpty ? null : address.join(', '),
    nationality: nationality,
  );
}

/// Nationalities by ICAO code, for the passports drivers most often hold;
/// any other code is shown as it is.
const passportNationalities = {
  'MYS': 'Malaysian', 'IDN': 'Indonesian', 'BGD': 'Bangladeshi', 'IND': 'Indian', 'PAK': 'Pakistani',
  'NPL': 'Nepali', 'MMR': 'Myanmar', 'PHL': 'Filipino', 'THA': 'Thai', 'VNM': 'Vietnamese', 'CHN': 'Chinese',
  'SGP': 'Singaporean', 'LKA': 'Sri Lankan', 'KHM': 'Cambodian', 'BRN': 'Bruneian', 'GBR': 'British',
  'USA': 'American', 'AUS': 'Australian', 'JPN': 'Japanese', 'KOR': 'Korean', 'NGA': 'Nigerian',
  'YEM': 'Yemeni', 'EGY': 'Egyptian',
};

/// The ICAO 9303 check digit of [s] (digits, letters, '<').
int mrzCheckDigit(String s) {
  const weights = [7, 3, 1];
  var sum = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final v = c >= 48 && c <= 57 ? c - 48 : (c >= 65 && c <= 90 ? c - 55 : 0);
    sum += v * weights[i % 3];
  }
  return sum % 10;
}

DateTime? _mrzDate(String yymmdd, {required bool future, DateTime? now}) {
  if (!RegExp(r'^\d{6}$').hasMatch(yymmdd)) return null;
  final yy = int.parse(yymmdd.substring(0, 2));
  final n = now ?? DateTime.now();
  // A birth date is in the past; an expiry is at most ten years ahead.
  final y = future ? 2000 + yy : (2000 + yy > n.year ? 1900 + yy : 2000 + yy);
  return _date(y, int.parse(yymmdd.substring(2, 4)), int.parse(yymmdd.substring(4, 6)));
}

/// A passport's photo page: the two machine lines (44 characters each) give
/// the number, nationality, name, date of birth and expiry. Null when there
/// are none. [numberChecked] says whether the number's check digit agreed.
({IdRead read, bool numberChecked})? readPassportMrz(String text, {DateTime? now}) {
  final clean = [
    for (final l in _lines(text)) l.replaceAll(' ', '').toUpperCase(),
  ];
  for (var i = 0; i + 1 < clean.length; i++) {
    final a = clean[i], b = clean[i + 1];
    if (!a.startsWith('P') || a.length < 40 || b.length < 40 || !RegExp(r'^[A-Z0-9<]+$').hasMatch(b)) continue;
    final names = a.substring(5).split('<<');
    final surname = names.first.replaceAll('<', ' ').trim();
    final given = names.length > 1 ? names[1].replaceAll('<', ' ').trim() : '';
    final name = [given, surname].where((s) => s.isNotEmpty).join(' ');
    final rawNumber = b.substring(0, 9);
    final number = rawNumber.replaceAll('<', '');
    final checked = RegExp(r'^\d$').hasMatch(b[9]) && mrzCheckDigit(rawNumber) == int.parse(b[9]);
    final code = b.substring(10, 13).replaceAll('<', '');
    return (
      read: IdRead(
        number: RegExp(r'^[A-Z0-9]{5,9}$').hasMatch(number) ? number : null,
        name: name.isEmpty ? null : name,
        nationality: code.isEmpty ? null : (passportNationalities[code] ?? code),
        dateOfBirth: _mrzDate(b.substring(13, 19), future: false, now: now),
        expiry: _mrzDate(b.substring(21, 27), future: true, now: now),
      ),
      numberChecked: checked,
    );
  }
  return null;
}

/// What an ID photo's text says, for the ID type the driver chose: a
/// passport's machine lines, else the MyKad / MyPR layout (a passport
/// without readable machine lines reads empty).
IdRead readIdText(String text, IdDocType type, {DateTime? now}) {
  final mrz = readPassportMrz(text, now: now);
  if (mrz != null) return mrz.read;
  if (type == IdDocType.passport) return const IdRead();
  return readMyKadText(text, type: type, now: now);
}

/// Whether the ID shows someone who is not a citizen: a MyPR or a passport,
/// or a nationality other than Malaysian.
bool idShowsNonCitizen(IdDocType? type, String? nationality) {
  if (type == IdDocType.mypr || type == IdDocType.passport) {
    final n = (nationality ?? '').trim().toLowerCase();
    return !(type == IdDocType.passport && (n == 'malaysian' || n == 'mys'));
  }
  final n = (nationality ?? '').trim().toLowerCase();
  return n.isNotEmpty && n != 'malaysian' && n != 'warganegara';
}

// ---- SSM: company or business registration --------------------------------------------------------

/// A director, owner or partner named on the company document.
typedef CompanyPerson = ({String name, String? id});

class CompanyRead {
  const CompanyRead({this.name, this.regNo, this.type, this.regDate, this.address, this.directors = const []});
  final String? name;

  /// As printed: 201901012345 (1321234-K).
  final String? regNo;
  final String? type;
  final DateTime? regDate;
  final String? address;
  final List<CompanyPerson> directors;

  bool get isEmpty => name == null && regNo == null && type == null && regDate == null && address == null && directors.isEmpty;
}

final _companyLabel = _re(r'\b(company name|nama syarikat|business name|nama perniagaan|name of company|nama)\b');
final _regNoLabel = _re(r'\b(registration no|registration number|company no|no\.? pendaftaran|no\.? syarikat|reg\.? no)\b\.?');
final _dateLabel = _re(
    r'\b(date of incorporation|tarikh diperbadankan|date of registration|tarikh pendaftaran|incorporation date|registration date|tarikh daftar)\b');
final _addressLabel = _re(
    r'\b(registered address|alamat berdaftar|business address|alamat perniagaan|principal place of business|alamat tempat perniagaan|address|alamat)\b');
final _typeLabel = _re(r'\b(company type|jenis syarikat|type of company|status|entity type|jenis entiti)\b');
final _peopleHeader = _re(r'\b(directors?|pengarah|owners?|pemilik|partners?|rakan kongsi|officers?|pegawai)\b');
final _anyLabel = _re(
    r'\b(company|business|registration|date|tarikh|address|alamat|type|jenis|status|directors?|pengarah|owners?|pemilik|shareholders?|pemegang|secretary|setiausaha|capital|modal|nature|jenis perniagaan|officers?)\b\s*[:.]?');
final _newRegNo = RegExp(r'\b((?:19|20)\d{2})\s?(\d{2})\s?(\d{6})\b');
final _oldRegNo = RegExp(r'\b(\d{5,9})\s?-\s?([A-Z])\b');
final _postcode = RegExp(r'\b\d{5}\b');

String _companyTypeFrom(String? name, String? entityCode, String all) {
  final n = (name ?? '').toUpperCase();
  if (RegExp(r'\bSDN\.?\s*BHD\b|\bSENDIRIAN BERHAD\b').hasMatch(n)) return 'Sdn. Bhd.';
  if (RegExp(r'\bBHD\b|\bBERHAD\b').hasMatch(n)) return 'Bhd.';
  if (RegExp(r'\bPLT\b').hasMatch(n) || entityCode == '04') return 'PLT';
  if (entityCode == '03' || RegExp(r'\b(ENTERPRISE|TRADING|PERNIAGAAN)\b').hasMatch(n)) return 'Enterprise';
  if (entityCode == '01') return RegExp(r'PRIVATE|SENDIRIAN', caseSensitive: false).hasMatch(all) ? 'Sdn. Bhd.' : 'Bhd.';
  return '';
}

/// An SSM certificate or company profile (Form 9, Section 17, e-Info) or a
/// business registration: the company name, registration number (the 12
/// digit one and the old one beside it), type, date, address and the
/// directors or owners listed under their heading (with their ID numbers
/// when printed beside them).
CompanyRead readCompanyText(String text) {
  final lines = _lines(text);
  final upper = [for (final l in lines) l.toUpperCase()];
  var name = _nz(_labelled(upper, _companyLabel, stopAt: _regNoLabel));
  if (name != null && !RegExp(r'[A-Z]').hasMatch(name)) name = null;
  name ??= upper.where((l) => RegExp(r'\b(SDN\.? ?BHD\.?|BERHAD|PLT|ENTERPRISE)\b').hasMatch(l) && !l.contains(':')).firstOrNull;
  final all = upper.join('\n');
  final n = _newRegNo.firstMatch(all);
  final o = _oldRegNo.firstMatch(all);
  String? regNo;
  if (n != null) {
    regNo = '${n[1]}${n[2]}${n[3]}${o == null ? '' : ' (${o[1]}-${o[2]})'}';
  } else if (o != null) {
    regNo = '${o[1]}-${o[2]}';
  }
  final dateText = _labelled(upper, _dateLabel);
  final regDate = dateText == null ? null : datesIn(dateText).firstOrNull;
  // The address: the labelled line and those after it, to the postcode.
  String? address;
  for (var i = 0; i < upper.length && address == null; i++) {
    final m = _addressLabel.firstMatch(upper[i]);
    if (m == null) continue;
    final parts = <String>[];
    final first = upper[i].substring(m.end).replaceFirst(RegExp(r'^\s*[:.]*\s*'), '').trim();
    if (first.isNotEmpty) parts.add(first);
    for (var j = i + 1; j < upper.length && parts.length < 5; j++) {
      if (parts.any(_postcode.hasMatch) && !RegExp(r'^[A-Z ]+$').hasMatch(upper[j])) break;
      if (_anyLabel.hasMatch(upper[j]) && upper[j].contains(':')) break;
      if (_peopleHeader.hasMatch(upper[j])) break;
      parts.add(upper[j]);
      if (_postcode.hasMatch(upper[j]) && j + 1 < upper.length && !RegExp(r'^[A-Z ]+$').hasMatch(upper[j + 1])) break;
      if (parts.any(_postcode.hasMatch) && RegExp(r'^[A-Z ]+$').hasMatch(upper[j])) break;
    }
    if (parts.isNotEmpty) address = parts.join(', ').replaceAll(RegExp(r',\s*,'), ',');
  }
  var type = _nz(_labelled(upper, _typeLabel));
  final derived = _companyTypeFrom(name, n?[2], all);
  if (type == null || derived.isNotEmpty) type = derived.isEmpty ? type : derived;
  // Directors / owners: names after their heading, to the next heading.
  final people = <CompanyPerson>[];
  for (var i = 0; i < upper.length; i++) {
    if (!_peopleHeader.hasMatch(upper[i]) || upper[i].contains(':') && upper[i].split(':').last.trim().isNotEmpty) {
      continue;
    }
    for (var j = i + 1; j < upper.length && people.length < 30; j++) {
      final l = upper[j];
      if (_anyLabel.hasMatch(l) && !_peopleHeader.hasMatch(l)) break;
      final ic = _icNumber.firstMatch(l);
      final namePart = l
          .replaceAll(_icNumber, '')
          .replaceAll(RegExp(r'^\s*\d+[.)]\s*'), '')
          .replaceAll(RegExp(r'[,;]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (_nameLine.hasMatch(namePart) && namePart.split(' ').length >= 2 && !_peopleHeader.hasMatch(namePart)) {
        people.add((name: namePart, id: ic == null ? null : '${ic[1]}-${ic[2]}-${ic[3]}'));
      } else if (ic != null && people.isNotEmpty && people.last.id == null) {
        people[people.length - 1] = (name: people.last.name, id: '${ic[1]}-${ic[2]}-${ic[3]}');
      }
    }
    break;
  }
  return CompanyRead(
    name: _nz(name),
    regNo: regNo,
    type: _nz(type),
    regDate: regDate,
    address: _nz(address),
    directors: people,
  );
}

/// Whether the driver ([name], [idNumber]) is among [directors]: by ID
/// number when one is printed, else by name.
bool driverIsDirector(List<CompanyPerson> directors, {String? name, String? idNumber}) => directors.any(
      (d) => (d.id != null && sameIdNumber(d.id, idNumber)) || (d.id == null || idNumber == null) && namesMatch(d.name, name),
    );

// ---- Kad Pemandu (APAD driver card) ----------------------------------------------------------------

class DriverPermitRead {
  const DriverPermitRead({
    this.cardNo,
    this.validFrom,
    this.validUntil,
    this.serviceType,
    this.issuer,
    this.name,
    this.idNumber,
    this.operatorName,
    this.operatorLicence,
    this.plate,
    this.position,
  });
  final String? cardNo;
  final DateTime? validFrom, validUntil;
  final String? serviceType, issuer, name, idNumber, operatorName, operatorLicence, plate;

  /// The driver's place for the vehicle: 1 for its 1st driver, 2 the 2nd ...
  final int? position;

  bool get isEmpty => cardNo == null && name == null && idNumber == null && validUntil == null && plate == null;
}

/// "1st driver", "2nd driver", "3rd driver", "4th driver".
String driverPositionLabel(int n) {
  final suffix = n % 100 >= 11 && n % 100 <= 13
      ? 'th'
      : switch (n % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$n$suffix driver';
}

final _permitCardLabel = _re(r'\b(no\.? kad|card no|card number|no\.? kad pemandu|nombor kad|permit no)\b\.?');
final _permitNameLabel = _re(r'\b(nama pemandu|nama|name)\b');
final _permitIcLabel = _re(r'\b(no\.? k/?p|no\.? kad pengenalan|mykad|ic no|no\.? ic|nric)\b\.?');
final _permitFromLabel = _re(r'\b(sah dari|sah mulai|tarikh mula|tarikh dikeluarkan|valid from|issued on|tarikh keluar)\b');
final _permitUntilLabel = _re(r'\b(hingga|sehingga|sah sehingga|tamat|tarikh tamat|valid until|valid to|expiry|expires)\b');
final _permitServiceLabel = _re(r'\b(jenis perkhidmatan|perkhidmatan|service type|jenis kenderaan awam|kategori)\b');
final _permitOperatorLabel = _re(r'\b(nama pengusaha|pengusaha|syarikat|operator|company)\b');
final _permitLicenceLabel = _re(
    r'\b(no\.? lesen(?: pengusaha)?|no\.? permit(?: pengusaha)?|lesen/permit pengusaha|operator licen[cs]e|licen[cs]e no|no\.? lesen/permit(?: pengusaha)?)\b\.?');
final _permitPlateLabel = _re(
    r'\b(no\.? pendaftaran kenderaan|no\.? kenderaan|no\.? pendaftaran|vehicle registration(?: no| number)?|vehicle no|plate)\b\.?');
final _permitIssuerLabel = _re(r'\b(dikeluarkan oleh|issued by|pengeluar)\b');
final _anyPermitLabel = _re(
    r'\b(no\.? kad|card no|nama|name|no\.? k/?p|sah|hingga|tamat|valid|jenis|perkhidmatan|service|pengusaha|syarikat|operator|lesen|licen[cs]e|pendaftaran|kenderaan|vehicle|dikeluarkan|issued|pemandu)\b');

const _positionWords = {
  'PERTAMA': 1, 'KEDUA': 2, 'KETIGA': 3, 'KEEMPAT': 4, 'KELIMA': 5,
  '1ST': 1, '2ND': 2, '3RD': 3, '4TH': 4, '5TH': 5, 'FIRST': 1, 'SECOND': 2, 'THIRD': 3,
};

/// A Kad Pemandu (taxi or e-hailing driver card from APAD, or its iSPKP
/// printout): card number, validity, service type, issuer, driver's name and
/// MyKad number, operator and its licence, the vehicle's plate and the
/// driver's place for it (1st, 2nd, 3rd driver).
DriverPermitRead readDriverPermitText(String text) {
  final lines = _lines(text);
  final upper = [for (final l in lines) l.toUpperCase()];
  final all = upper.join('\n');
  String? v(RegExp label) => _nz(_labelled(upper, label, stopAt: _anyPermitLabel));

  var cardNo = v(_permitCardLabel);
  cardNo ??= RegExp(r'\b(KP/[A-Z0-9/]+)\b').firstMatch(all)?[1];
  if (cardNo != null) cardNo = cardNo.split(' ').first;

  var name = v(_permitNameLabel);
  if (name != null && !_nameLine.hasMatch(name)) name = null;
  final icText = v(_permitIcLabel);
  final icMatch = _icNumber.firstMatch(icText ?? '') ?? _icNumber.firstMatch(all);
  final idNumber = icMatch == null ? null : '${icMatch[1]}-${icMatch[2]}-${icMatch[3]}';

  // Valid from / until: their labels, else the two dates on one line.
  DateTime? from, until;
  for (final l in upper) {
    final ds = datesIn(l);
    if (ds.isEmpty) continue;
    final f = _permitFromLabel.firstMatch(l), u = _permitUntilLabel.firstMatch(l);
    if (f != null && u != null && ds.length >= 2) {
      from ??= ds[0];
      until ??= ds[1];
    } else if (u != null) {
      until ??= datesIn(l.substring(u.start)).firstOrNull ?? ds.last;
    } else if (f != null) {
      from ??= ds.first;
    } else if (ds.length >= 2) {
      from ??= ds[0];
      until ??= ds[1];
    }
  }
  if (from != null && until != null && until.isBefore(from)) (from, until) = (until, from);

  var service = v(_permitServiceLabel);
  if (service == null) {
    if (RegExp(r'\bTEKSI\b|\bTAXI\b').hasMatch(all)) {
      service = 'Teksi';
    } else if (RegExp(r'\bE-?HAILING\b|\bEHAILING\b').hasMatch(all)) {
      service = 'eHailing';
    }
  }
  var issuer = v(_permitIssuerLabel);
  if (RegExp(r'\bAPAD\b|AGENSI PENGANGKUTAN AWAM DARAT').hasMatch(all)) {
    issuer ??= RegExp(r'\bISPKP\b').hasMatch(all) ? 'APAD (via iSPKP)' : 'APAD';
  }
  final operator = v(_permitOperatorLabel);
  var licence = v(_permitLicenceLabel);
  licence ??= RegExp(r'\b(LPKP/[A-Z0-9/]+)\b').firstMatch(all)?[1];
  if (licence != null) licence = licence.split(' ').first;
  final plateText = v(_permitPlateLabel);
  final plate = plateText == null ? null : _plateIn(plateText);

  int? position;
  final p = RegExp(r'\bPEMANDU\s+(PERTAMA|KEDUA|KETIGA|KEEMPAT|KELIMA)\b|\b(1ST|2ND|3RD|4TH|5TH|FIRST|SECOND|THIRD)\s+DRIVER\b|\bPEMANDU\s+(\d)\b|\bDRIVER\s+(\d)\b')
      .firstMatch(all);
  if (p != null) {
    final word = p[1] ?? p[2];
    position = word != null ? _positionWords[word] : int.tryParse(p[3] ?? p[4] ?? '');
  }
  return DriverPermitRead(
    cardNo: _nz(cardNo),
    validFrom: from,
    validUntil: until,
    serviceType: service,
    issuer: issuer,
    name: name,
    idNumber: idNumber,
    operatorName: operator,
    operatorLicence: _nz(licence),
    plate: plate,
    position: position,
  );
}

// ---- Vehicle grant (geran) / VOC -----------------------------------------------------------------

class VehicleGrantRead {
  const VehicleGrantRead({
    this.plate,
    this.make,
    this.model,
    this.year,
    this.colour,
    this.engineNo,
    this.chassisNo,
    this.registrationDate,
    this.engineCc,
    this.ownerName,
    this.ownerId,
  });
  final String? plate, make, model, colour, engineNo, chassisNo, ownerName, ownerId;
  final int? year, engineCc;
  final DateTime? registrationDate;

  bool get isEmpty => plate == null && make == null && chassisNo == null && registrationDate == null;
}

final _grantPlateLabel = _re(r'\b(no\.? pendaftaran(?! kenderaan baru)|registration no|registration number|no\.? daftar|vehicle no)\b\.?');
final _grantOwnerLabel = _re(r'\b(nama pemunya(?: berdaftar)?|pemunya berdaftar|registered owner|owner(?:.s)? name|nama pemilik|pemilik)\b');
final _grantOwnerIdLabel = _re(r'\b(no\.? pengenalan|no\.? k/?p|no\.? syarikat|id no|identification no|owner id)\b\.?');
final _grantMakeModelLabel = _re(r'\b(buatan\s*/\s*nama model|buatan/model|make\s*/\s*model)\b');
final _grantMakeLabel = _re(r'\b(buatan|make|jenama)\b');
final _grantModelLabel = _re(r'\b(nama model|model)\b');
final _grantCcLabel = _re(r'\b(keupayaan enjin|kapasiti enjin|engine capacity|isipadu|cc)\b');
final _grantEngineLabel = _re(r'\b(no\.? enjin|engine no|engine number|nombor enjin)\b\.?');
final _grantChassisLabel = _re(r'\b(no\.? casis|chassis no|chassis number|no\.? chasis|vin)\b\.?');
final _grantColourLabel = _re(r'\b(warna|colou?r)\b');
final _grantYearLabel = _re(r'\b(tahun dibuat|tahun buatan|year of manufacture|year made|tahun)\b');
final _grantRegDateLabel = _re(r'\b(tarikh pendaftaran|registration date|date of registration|tarikh daftar)\b');
final _anyGrantLabel = _re(
    r'\b(no\.? pendaftaran|registration|nama|pemunya|owner|pengenalan|buatan|make|model|keupayaan|kapasiti|engine|enjin|casis|chassis|warna|colou?r|tahun|year|tarikh|date|bahan bakar|fuel|kelas|class|status|jenis badan|body)\b');

/// A vehicle ownership certificate (JPJ grant, VOC, MyJPJ e-VOC): plate,
/// make and model, year made, colour, engine and chassis numbers,
/// registration date, engine capacity and the registered owner.
VehicleGrantRead readVehicleGrantText(String text) {
  final upper = [for (final l in _lines(text)) l.toUpperCase()];
  final all = upper.join('\n');
  String? v(RegExp label) => _nz(_labelled(upper, label, stopAt: _anyGrantLabel));

  final plateText = v(_grantPlateLabel);
  final plate = plateText == null ? null : _plateIn(plateText);
  String? make, model;
  final mm = v(_grantMakeModelLabel);
  if (mm != null) {
    final parts = mm.replaceAll('/', ' ').replaceAll(RegExp(r'\s+'), ' ').trim().split(' ');
    make = parts.first;
    model = parts.length > 1 ? parts.skip(1).join(' ') : null;
  } else {
    make = v(_grantMakeLabel);
    model = v(_grantModelLabel);
  }
  final ccText = v(_grantCcLabel) ?? RegExp(r'\b(\d{3,5})\s?CC\b').firstMatch(all)?[1];
  final cc = ccText == null ? null : int.tryParse(RegExp(r'\d{2,5}').firstMatch(ccText)?[0] ?? '');
  final engine = v(_grantEngineLabel)?.split(' ').first;
  final chassis = v(_grantChassisLabel)?.split(' ').first;
  final colour = v(_grantColourLabel);
  final yearText = v(_grantYearLabel);
  final year = int.tryParse(RegExp(r'\b(19|20)\d{2}\b').firstMatch(yearText ?? '')?[0] ?? '');
  final regText = v(_grantRegDateLabel);
  final reg = regText == null ? null : datesIn(regText).firstOrNull;
  var owner = v(_grantOwnerLabel);
  if (owner != null && !RegExp(r'[A-Z]').hasMatch(owner)) owner = null;
  final ownerIdText = v(_grantOwnerIdLabel);
  String? ownerId;
  if (ownerIdText != null) {
    final ic = _icNumber.firstMatch(ownerIdText);
    ownerId = ic != null ? '${ic[1]}-${ic[2]}-${ic[3]}' : ownerIdText.split(' ').first;
  }
  return VehicleGrantRead(
    plate: plate,
    make: _nz(make),
    model: _nz(model),
    year: year,
    colour: _nz(colour),
    engineNo: _nz(engine),
    chassisNo: _nz(chassis),
    registrationDate: reg,
    engineCc: cc,
    ownerName: _nz(owner),
    ownerId: _nz(ownerId),
  );
}
