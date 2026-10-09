/// The countries the phone screen offers, with their dial codes and flags
/// (Expo `phone-auth.tsx` `COUNTRIES`, plus Brunei).
library;

class DialCountry {
  const DialCountry(this.name, this.code, this.dialCode, this.flag);
  final String name;
  final String code;
  final String dialCode;
  final String flag;
}

const dialCountries = [
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
