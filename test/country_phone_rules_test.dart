// Phone numbers and sign-in per country (migration 0292): the server's
// refusals as the phone screen shows them, the country list from the rules,
// and the admin page's helpers.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/country_phone_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/core/dial_countries.dart';
import 'package:get_ride/src/core/phone_rules.dart';

void main() {
  group('refusals', () {
    test('read from the server words, inline or as a popup', () {
      final landline = parsePhoneRuleRefusal(
          'PostgrestException(message: PHONE_NOT_MOBILE: This looks like a landline. Enter a mobile number from Malaysia (starts with 01)., code: P0001)');
      expect(landline?.code, phoneNotMobile);
      expect(landline?.message, 'This looks like a landline. Enter a mobile number from Malaysia (starts with 01).');
      expect(parsePhoneRuleRefusal("AuthException(message: PHONE_BLOCKED: GET.ride isn't available for numbers from Malaysia., statusCode: 403)")?.message,
          "GET.ride isn't available for numbers from Malaysia.");
      expect(landline?.inline, isTrue);
      final blocked = parsePhoneRuleRefusal("PHONE_BLOCKED: GET.ride isn't available for numbers from Malaysia.");
      expect(blocked?.inline, isFalse);
      expect(blocked?.title, 'Not available');
      expect(parsePhoneRuleRefusal('PHONE_LENGTH: Mobile numbers from Malaysia are 9 to 10 digits after +60.')?.inline, isTrue);
      expect(parsePhoneRuleRefusal('PHONE_REGISTRATION_CLOSED: x')?.title, 'New accounts closed');
      expect(parsePhoneRuleRefusal('PHONE_DAILY_LIMIT: Too many sign-ups right now. Please try again later.')?.title,
          'Too many sign-ups right now');
      expect(parsePhoneRuleRefusal('RATE_LIMITED:30'), isNull);
      expect(parsePhoneRuleRefusal(null), isNull);
    });
  });

  group('country list', () {
    tearDown(() => setDialCountries(const []));

    test('every country but the Blocked ones, A to Z, the default first', () {
      final list = dialCountriesFromRules([
        {'iso': 'SG', 'dial_code': '+65', 'access': 'allowed'},
        {'iso': 'MY', 'dial_code': '+60', 'access': 'registration_closed'},
        {'iso': 'NO', 'dial_code': '+47', 'access': 'blocked'},
        {'iso': 'AL', 'dial_code': '+355', 'access': 'allowed'},
        {'iso': 'X', 'dial_code': '+1', 'access': 'allowed'},
      ], {'SG': 'Singapore', 'MY': 'Malaysia', 'AL': 'Albania'}, first: 'MY');
      expect([for (final c in list) c.code], ['MY', 'AL', 'SG']);
      expect(list.first.flag, '🇲🇾');
      expect(list.first.dialCode, '+60');
    });

    test('replaces the built-in list, and empty keeps it', () {
      expect(dialCountries, builtInDialCountries);
      setDialCountries([const DialCountry('Albania', 'AL', '+355', '🇦🇱')]);
      expect(dialCountries.single.code, 'AL');
      setDialCountries(const []);
      expect(dialCountries, builtInDialCountries);
    });

    test('a flag from its code', () {
      expect(flagForIso('my'), '🇲🇾');
      expect(flagForIso('GB'), '🇬🇧');
      expect(flagForIso('M1'), '🌐');
    });
  });

  group('admin page', () {
    test('mobile digits typed with commas or spaces', () {
      expect(parsePrefixes('1, 8 9,90, x, 1'), ['1', '8', '9', '90']);
      expect(parsePrefixes(''), isEmpty);
    });

    test('blocked numbers read as typed', () {
      expect(phoneBlockLabel({'kind': 'prefix', 'value_from': '1150'}, '+60'), 'Starts with +60 1150');
      expect(phoneBlockLabel({'kind': 'range', 'value_from': '123400000', 'value_to': '123499999'}, '+60'),
          '+60 123400000 to +60 123499999');
      expect(phoneBlockLabel({'kind': 'number', 'value_from': '198765432'}, '+60'), '+60 198765432');
    });

    test('access keys match the server', () {
      expect([for (final a in PhoneAccess.values) a.key], ['allowed', 'registration_closed', 'blocked']);
      expect(PhoneAccess.of('blocked'), PhoneAccess.blocked);
      expect(PhoneAccess.of(null), PhoneAccess.allowed);
    });

    test('only a country with an ISO code opens its phone rules', () {
      RegionRow row(Map<String, dynamic> v, [RegionLevel level = RegionLevel.country]) => RegionRow(
            level: level,
            country: 'Malaysia',
            entry: RegionEntry(id: '1', values: {'country': 'Malaysia', ...v}),
          );
      expect(countryIsoOf(row({'isoCode': 'my'})), 'MY');
      expect(countryIsoOf(row({})), isNull);
      expect(countryIsoOf(row({'isoCode': 'MY'}, RegionLevel.state)), isNull);
    });
  });
}
