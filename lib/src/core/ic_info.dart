/// Derive the date of birth and gender encoded in a Malaysian NRIC (MyKad).
///
/// A MyKad number is `YYMMDD-PB-###G` (12 digits): the first six are the birth
/// date, and the final digit's parity is the gender (odd = male, even =
/// female). Nothing else — a passport, a malformed or non-12-digit number —
/// yields nulls, so the ID sheet shows "—" rather than a guess.
library;

class IcInfo {
  const IcInfo({this.dob, this.gender});

  /// The date of birth, or null when it can't be read.
  final DateTime? dob;

  /// 'Male' / 'Female', or null when it can't be read.
  final String? gender;

  bool get isEmpty => dob == null && gender == null;
}

/// Parse [ic] as a MyKad number. [now] bounds the century choice (a two-digit
/// year that would land in the future is read as 19xx); it defaults to today.
IcInfo malaysianIcInfo(String? ic, {DateTime? now}) {
  final digits = (ic ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length != 12) return const IcInfo();

  final yy = int.parse(digits.substring(0, 2));
  final mm = int.parse(digits.substring(2, 4));
  final dd = int.parse(digits.substring(4, 6));
  if (mm < 1 || mm > 12 || dd < 1 || dd > 31) return const IcInfo();

  final today = now ?? DateTime.now();
  var year = 2000 + yy;
  if (DateTime(year, mm, dd).isAfter(today)) year = 1900 + yy;
  final dob = DateTime(year, mm, dd);
  // Reject a rolled-over date (e.g. day 31 of a 30-day month → next month).
  if (dob.month != mm || dob.day != dd) return IcInfo(gender: _gender(digits));

  return IcInfo(dob: dob, gender: _gender(digits));
}

String _gender(String digits) =>
    int.parse(digits.substring(11)).isOdd ? 'Male' : 'Female';
