import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/account_app_version.dart';
import 'package:get_ride/src/admin/admin_filters.dart';

void main() {
  final now = DateTime.utc(2026, 10, 14, 12);

  test('the recorded version, platform, build and when', () {
    final u = {
      'app_version': '1.4.6',
      'app_build': '12',
      'app_platform': 'android',
      'app_version_at': '2026-10-14T09:00:00Z',
    };
    expect(accountAppVersion(u, now: now), 'Android 1.4.6 (12) · 3 h ago');
    expect(accountAppVersionShort(u), '1.4.6');
    expect(accountAppVersion({'app_version': '1.4.6', 'app_platform': 'ios'}, now: now), 'iOS 1.4.6');
    expect(accountAppVersion(const {}, now: now), contains('Not recorded'));
    expect(accountAppVersionShort(const {}), isNull);
  });

  test('behind the latest for its platform', () {
    const latest = {'ios': '1.4.6', 'android': '1.4.7'};
    expect(accountAppBehind({'app_version': '1.4.6', 'app_platform': 'android'}, latest), isTrue);
    expect(accountAppBehind({'app_version': '1.4.6', 'app_platform': 'ios'}, latest), isFalse);
    expect(accountAppBehind(const {}, latest), isFalse);
  });

  test('the Users filter for accounts not yet on 1.4.6', () {
    expect(userMatches(const {}, 'old-app'), isTrue);
    expect(userMatches({'app_version': '1.4.6'}, 'old-app'), isFalse);
  });
}
