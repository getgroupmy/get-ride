/// The countries the phone screen offers, with their dial codes and flags:
/// Admin › Country / States / Cities' phone rules (migration 0292) once the
/// app has read them, every country whose numbers aren't Blocked; until then
/// (or offline) the built-in list (Expo `phone-auth.tsx` `COUNTRIES`, plus
/// Brunei).
library;

class DialCountry {
  const DialCountry(this.name, this.code, this.dialCode, this.flag);
  final String name;
  final String code;
  final String dialCode;
  final String flag;
}

const builtInDialCountries = [
  DialCountry('Malaysia', 'MY', '+60', '🇲🇾'),
  DialCountry('United States', 'US', '+1', '🇺🇸'),
  DialCountry('United Kingdom', 'GB', '+44', '🇬🇧'),
  DialCountry('Singapore', 'SG', '+65', '🇸🇬'),
  DialCountry('Indonesia', 'ID', '+62', '🇮🇩'),
  DialCountry('Thailand', 'TH', '+66', '🇹🇭'),
  DialCountry('Philippines', 'PH', '+63', '🇵🇭'),
  DialCountry('Vietnam', 'VN', '+84', '🇻🇳'),
  DialCountry('Brunei', 'BN', '+673', '🇧🇳'),
  DialCountry('Australia', 'AU', '+61', '🇦🇺'),
  DialCountry('India', 'IN', '+91', '🇮🇳'),
  DialCountry('China', 'CN', '+86', '🇨🇳'),
  DialCountry('Japan', 'JP', '+81', '🇯🇵'),
  DialCountry('South Korea', 'KR', '+82', '🇰🇷'),
  DialCountry('Canada', 'CA', '+1', '🇨🇦'),
  DialCountry('Germany', 'DE', '+49', '🇩🇪'),
  DialCountry('France', 'FR', '+33', '🇫🇷'),
  DialCountry('Italy', 'IT', '+39', '🇮🇹'),
  DialCountry('Spain', 'ES', '+34', '🇪🇸'),
  DialCountry('Netherlands', 'NL', '+31', '🇳🇱'),
  DialCountry('Brazil', 'BR', '+55', '🇧🇷'),
  DialCountry('Mexico', 'MX', '+52', '🇲🇽'),
  DialCountry('Argentina', 'AR', '+54', '🇦🇷'),
  DialCountry('South Africa', 'ZA', '+27', '🇿🇦'),
  DialCountry('Egypt', 'EG', '+20', '🇪🇬'),
  DialCountry('Saudi Arabia', 'SA', '+966', '🇸🇦'),
  DialCountry('UAE', 'AE', '+971', '🇦🇪'),
  DialCountry('Turkey', 'TR', '+90', '🇹🇷'),
  DialCountry('Russia', 'RU', '+7', '🇷🇺'),
  DialCountry('Pakistan', 'PK', '+92', '🇵🇰'),
  DialCountry('Bangladesh', 'BD', '+880', '🇧🇩'),
];

List<DialCountry>? _liveDialCountries;

/// The countries offered now: the admin's list when read, else the built-in one.
List<DialCountry> get dialCountries => _liveDialCountries ?? builtInDialCountries;

/// Replaces the list with the admin's ([countries] empty keeps the built-in one).
void setDialCountries(List<DialCountry> countries) =>
    _liveDialCountries = countries.isEmpty ? null : List.unmodifiable(countries);

/// [iso]'s flag emoji ("MY" -> regional indicators M and Y).
String flagForIso(String iso) {
  final code = iso.toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(code)) return '🌐';
  return String.fromCharCodes(code.codeUnits.map((u) => 0x1F1E6 + u - 0x41));
}

/// The phone screen's list from the phone rules ([rules]: `iso`, `dial_code`,
/// `access`) and the countries' names ([names], ISO code to name): Blocked
/// countries left out, A to Z, [first]'s dial code at the top.
List<DialCountry> dialCountriesFromRules(
  Iterable<Map<String, dynamic>> rules,
  Map<String, String> names, {
  String? first,
}) {
  final out = <DialCountry>[];
  for (final r in rules) {
    final iso = '${r['iso'] ?? ''}'.toUpperCase();
    final dial = '${r['dial_code'] ?? ''}';
    if (iso.length != 2 || !dial.startsWith('+') || r['access'] == 'blocked') continue;
    final name = names[iso] ?? _builtInName(iso) ?? iso;
    out.add(DialCountry(name, iso, dial, flagForIso(iso)));
  }
  out.sort((a, b) {
    final fa = a.code == first, fb = b.code == first;
    if (fa != fb) return fa ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

String? _builtInName(String iso) {
  for (final c in builtInDialCountries) {
    if (c.code == iso) return c.name;
  }
  return null;
}

/// The country to start on for [dialCode] (the build's default): the first
/// with that code, else a bare entry so an unlisted default still works.
DialCountry dialCountryFor(String dialCode) {
  for (final c in dialCountries) {
    if (c.dialCode == dialCode) return c;
  }
  return DialCountry(dialCode, '', dialCode, '🌐');
}

/// Countries matching [query] by name, ISO code or dial code.
List<DialCountry> searchDialCountries(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return dialCountries;
  final digits = q.replaceAll(RegExp(r'\D'), '');
  return [
    for (final c in dialCountries)
      if (c.name.toLowerCase().contains(q) ||
          c.code.toLowerCase() == q ||
          (digits.isNotEmpty && c.dialCode.substring(1).startsWith(digits)))
        c,
  ];
}
