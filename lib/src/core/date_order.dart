/// The order a date is typed and shown in — day/month/year, month/day/year
/// or year/month/day — from the user's country, and the parsing and checks
/// behind the three date boxes (`widgets/date_boxes.dart`).
///
/// The country is the signed-in user's profile country (`profiles.nationality`,
/// shown as "Country" on the profile), else the phone's locale country, else
/// Malaysia.
library;

import 'dart:ui' show PlatformDispatcher;

import 'dial_countries.dart';

enum DateOrder { dmy, mdy, ymd }

/// The three boxes of a date.
enum DatePart { day, month, year }

const _ymdCountries = {'CN', 'JP', 'KR', 'TW', 'HU', 'LT', 'MN', 'IR'};
const _mdyCountries = {'US', 'PH', 'FM', 'MH', 'PW'};

/// The order dates are written in [countryCode] (ISO 3166 alpha-2, any
/// case): year first in East Asia, Hungary, Lithuania, Mongolia and Iran;
/// month first in the US and the Philippines (and the Pacific states that
/// follow the US); day first everywhere else, Malaysia included.
DateOrder dateOrderFor(String? countryCode) {
  final c = (countryCode ?? '').trim().toUpperCase();
  if (_ymdCountries.contains(c)) return DateOrder.ymd;
  if (_mdyCountries.contains(c)) return DateOrder.mdy;
  return DateOrder.dmy;
}

/// The boxes in the order they are typed.
List<DatePart> datePartsIn(DateOrder order) => switch (order) {
      DateOrder.dmy => const [DatePart.day, DatePart.month, DatePart.year],
      DateOrder.mdy => const [DatePart.month, DatePart.day, DatePart.year],
      DateOrder.ymd => const [DatePart.year, DatePart.month, DatePart.day],
    };

/// "DD", "MM" or "YYYY".
String datePartLabel(DatePart p) => switch (p) {
      DatePart.day => 'DD',
      DatePart.month => 'MM',
      DatePart.year => 'YYYY',
    };

/// "day", "month" or "year": what a screen reader says after the field's name.
String datePartName(DatePart p) => p.name;

/// How many digits a box holds.
int datePartLength(DatePart p) => p == DatePart.year ? 4 : 2;

/// "DD / MM / YYYY", "MM / DD / YYYY" or "YYYY / MM / DD".
String dateOrderLabel(DateOrder order) => datePartsIn(order).map(datePartLabel).join(' / ');

// ---- Which country -----------------------------------------------------

/// Country names and nationalities (as typed on a profile) that are not in
/// [dialCountries], for the countries that do not write the day first, and
/// a few common spellings.
const _extraNames = <String, String>{
  'taiwan': 'TW',
  'hungary': 'HU',
  'lithuania': 'LT',
  'mongolia': 'MN',
  'iran': 'IR',
  'micronesia': 'FM',
  'marshall islands': 'MH',
  'palau': 'PW',
  'united states of america': 'US',
  'usa': 'US',
  'korea': 'KR',
  'republic of korea': 'KR',
  'malaysian': 'MY',
  'american': 'US',
  'filipino': 'PH',
  'japanese': 'JP',
  'chinese': 'CN',
  'korean': 'KR',
  'south korean': 'KR',
  'taiwanese': 'TW',
  'hungarian': 'HU',
  'lithuanian': 'LT',
  'mongolian': 'MN',
  'iranian': 'IR',
  'singaporean': 'SG',
  'indonesian': 'ID',
  'thai': 'TH',
  'british': 'GB',
  'australian': 'AU',
  'indian': 'IN',
};

/// The ISO code for [country]: a two-letter code as is, or a country name
/// or nationality as saved on a profile ("Malaysia", "United States",
/// "Japanese"). Null when blank or unknown.
String? countryCodeFor(String? country) {
  final raw = (country ?? '').trim();
  if (raw.isEmpty) return null;
  if (RegExp(r'^[A-Za-z]{2}$').hasMatch(raw)) return raw.toUpperCase();
  final key = raw.toLowerCase();
  for (final c in dialCountries) {
    if (c.name.toLowerCase() == key && c.code.isNotEmpty) return c.code;
  }
  return _extraNames[key];
}

/// The country whose date order the user gets: the profile's, else the
/// phone's, else Malaysia.
String dateCountryFor({String? profileCountry, String? deviceCountry}) =>
    countryCodeFor(profileCountry) ?? countryCodeFor(deviceCountry) ?? 'MY';

String? _profileCountry;

/// The phone's locale country. Tests pin it (test/flutter_test_config.dart).
String? Function() deviceDateCountry = () => PlatformDispatcher.instance.locale.countryCode;

/// Sets the signed-in user's profile country (name or code); null on sign out.
void setProfileDateCountry(String? country) => _profileCountry = country;

/// The signed-in user's country for dates (see [dateCountryFor]).
String userDateCountry() => dateCountryFor(profileCountry: _profileCountry, deviceCountry: deviceDateCountry());

/// The signed-in user's date order.
DateOrder userDateOrder() => dateOrderFor(userDateCountry());

// ---- Showing a date ----------------------------------------------------

String _two(int n) => n.toString().padLeft(2, '0');

/// [d] as numbers in the user's order: "12/05/2027", "05/12/2027" or
/// "2027/05/12". A dash when there is no date.
String formatDateForUser(DateTime? d, {DateOrder? order}) {
  if (d == null) return '—';
  final o = order ?? userDateOrder();
  return datePartsIn(o).map((p) => switch (p) {
        DatePart.day => _two(d.day),
        DatePart.month => _two(d.month),
        DatePart.year => d.year.toString().padLeft(4, '0'),
      }).join('/');
}

/// A stored date (`2027-05-12`, or a timestamp starting with one) in the
/// user's order. Anything else is shown as it is; blank is a dash.
String formatStoredDateForUser(Object? stored, {DateOrder? order}) {
  final s = '${stored ?? ''}'.trim();
  if (s.isEmpty || s == 'null') return '—';
  final d = parseIsoDate(s);
  return d == null ? s : formatDateForUser(d, order: order);
}

const _monthsShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthsLong = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// A day with its weekday and month name, in the user's order: "Fri 16 Oct"
/// where the day comes first, "Fri Oct 16" where the month does.
String formatWeekdayDayMonthForUser(DateTime d, {DateOrder? order}) {
  final o = order ?? userDateOrder();
  final w = _weekdays[d.weekday - 1], m = _monthsShort[d.month - 1];
  return o == DateOrder.dmy ? '$w ${d.day} $m' : '$w $m ${d.day}';
}

// ---- Reading a date ----------------------------------------------------

/// The date at the start of [s] when it is `yyyy-mm-dd` (a timestamp's
/// time is ignored), and a real date. Null otherwise.
DateTime? parseIsoDate(String? s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch((s ?? '').trim());
  if (m == null) return null;
  return realDate(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// `yyyy-mm-dd`, as dates are stored.
String isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

/// The date for [year]-[month]-[day] when it exists (no 31 February).
DateTime? realDate(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1) return null;
  if (day > daysInMonth(year, month)) return null;
  return DateTime(year, month, day);
}

int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// The three numbers in [text], a pasted or typed whole date, as box texts:
/// `2027-05-12` (year first, always), `12/05/2027` or `12.05.2027` (in
/// [order]), or eight digits in a row (in [order]). Null when it is not a
/// whole date. The numbers are not checked; [checkDateBoxes] does that.
Map<DatePart, String>? splitDateText(String text, DateOrder order) {
  final t = text.trim();
  final iso = RegExp(r'^(\d{4})[-/. ](\d{1,2})[-/. ](\d{1,2})(?:[T ].*)?$').firstMatch(t);
  if (iso != null) {
    return {DatePart.year: iso[1]!, DatePart.month: _pad(iso[2]!), DatePart.day: _pad(iso[3]!)};
  }
  final parts = datePartsIn(order == DateOrder.ymd ? DateOrder.dmy : order);
  final three = RegExp(r'^(\d{1,2})\s*[-/. ]\s*(\d{1,2})\s*[-/. ]\s*(\d{4})$').firstMatch(t);
  if (three != null) {
    return {parts[0]: _pad(three[1]!), parts[1]: _pad(three[2]!), DatePart.year: three[3]!};
  }
  if (RegExp(r'^\d{8}$').hasMatch(t)) {
    final out = <DatePart, String>{};
    var i = 0;
    for (final p in datePartsIn(order)) {
      final n = datePartLength(p);
      out[p] = t.substring(i, i + n);
      i += n;
    }
    return out;
  }
  return null;
}

String _pad(String s) => s.length == 1 ? '0$s' : s;

/// What the three boxes hold: the date, or why it is not one.
typedef DateBoxesCheck = ({DateTime? date, String? error});

/// Checks the three boxes. Blank is fine unless [required]; otherwise each
/// box must be filled, the month 01–12, the day one the month has, and the
/// date within [firstDate]..[lastDate] (days, inclusive). [beforeFirst] and
/// [afterLast] replace the messages for a date outside them.
DateBoxesCheck checkDateBoxes({
  required String day,
  required String month,
  required String year,
  DateTime? firstDate,
  DateTime? lastDate,
  bool required = false,
  String? beforeFirst,
  String? afterLast,
  DateOrder? order,
  DateTime? now,
}) {
  final d = day.trim(), m = month.trim(), y = year.trim();
  if (d.isEmpty && m.isEmpty && y.isEmpty) return (date: null, error: required ? 'Enter the date' : null);
  final missing = [if (d.isEmpty) 'day', if (m.isEmpty) 'month', if (y.isEmpty) 'year'];
  if (missing.isNotEmpty) {
    final list = missing.length == 1
        ? missing.single
        : '${missing.sublist(0, missing.length - 1).join(', ')} and ${missing.last}';
    return (date: null, error: 'Enter the $list');
  }
  final di = int.tryParse(d), mi = int.tryParse(m), yi = int.tryParse(y);
  if (yi == null || y.length != 4) return (date: null, error: 'Enter the year as 4 digits, e.g. 2027');
  if (mi == null || mi < 1 || mi > 12) return (date: null, error: 'The month must be 01 to 12');
  if (di == null || di < 1 || di > 31) return (date: null, error: 'The day must be 01 to 31');
  final date = realDate(yi, mi, di);
  if (date == null) {
    final leap = mi == 2 && di == 29 ? ' ($yi is not a leap year)' : '';
    return (date: null, error: '$di ${_monthsLong[mi - 1]} $yi is not a real date$leap');
  }
  DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
  final today = dayOf(now ?? DateTime.now());
  if (firstDate != null && date.isBefore(dayOf(firstDate))) {
    final f = dayOf(firstDate);
    return (
      date: null,
      error: beforeFirst ??
          (f == today ? "The date can't be in the past" : "The date can't be before ${formatDateForUser(f, order: order)}"),
    );
  }
  if (lastDate != null && date.isAfter(dayOf(lastDate))) {
    final l = dayOf(lastDate);
    return (
      date: null,
      error: afterLast ??
          (l == today ? "The date can't be in the future" : "The date can't be after ${formatDateForUser(l, order: order)}"),
    );
  }
  return (date: date, error: null);
}
