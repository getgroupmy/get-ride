import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/screens/meterapp/app_updates_logic.dart';
import 'package:get_ride/src/config.dart';
import 'package:get_ride/src/core/app_version.dart';

SettingEntry _row(String id, Map<String, dynamic> values) => SettingEntry(id: id, values: values);

void main() {
  test('the compiled-in version is the one in pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    final version = line.substring('version:'.length).trim().split('+').first;
    expect(AppConfig.appVersion, version, reason: 'bump AppConfig.appVersion with pubspec');
  });

  group('rows', () {
    final rows = [
      _row('a', {'platform': 'iOS', 'version': '1.4.6', 'minVersion': '1.4.5', 'forceUpdate': false}),
      _row('b', {'platform': 'Android', 'version': '1.4.6', 'forceUpdate': 'true', 'storeUrl': 'market://x'}),
    ];

    test('each platform finds its own row', () {
      expect(appUpdateRowFor(rows, 'ios')?.id, 'a');
      expect(appUpdateRowFor(rows, 'android')?.id, 'b');
      expect(appUpdateRowFor([rows.first], 'android'), isNull);
    });

    test('Force update is on when either platform forces it', () {
      expect(forceUpdateOn(rows), isTrue);
      expect(forceUpdateOn([rows.first]), isFalse);
      expect(forceUpdateOn(const []), isFalse);
    });

    test('saving keeps the store link and platform name', () {
      final v = appUpdateValues(rows[1].values, platform: 'android', latest: ' 1.4.7 ', min: '', force: false);
      expect(v, {
        'platform': 'Android',
        'version': '1.4.7',
        'minVersion': '',
        'forceUpdate': false,
        'storeUrl': 'market://x',
      });
      final fresh = appUpdateValues(null, platform: 'ios', latest: '1.4.7', min: '1.4.5', force: true);
      expect(fresh['platform'], 'iOS');
      expect(fresh['forceUpdate'], isTrue);
      // What the apps' gate makes of it: forced, so below the latest is required.
      final rule = AppVersionRule.fromValues(fresh)!;
      expect(resolveUpdate([rule], platform: 'ios', current: '1.4.6').kind, UpdateKind.required);
      expect(resolveUpdate([rule], platform: 'ios', current: '1.4.7').kind, UpdateKind.none);
    });
  });

  test('versions are checked before saving', () {
    expect(appUpdateProblem('1.4.6', ''), isNull);
    expect(appUpdateProblem('1.4.6', '1.4.5'), isNull);
    expect(appUpdateProblem('', ''), contains('latest'));
    expect(appUpdateProblem('latest', ''), contains('numbers'));
    expect(appUpdateProblem('1.4.6', 'x'), contains('minimum'));
    expect(appUpdateProblem('1.4.5', '1.4.6'), contains("can't be newer"));
  });

  test('installed versions: per platform, newest first, older than latest flagged', () {
    final counts = installedVersionCounts(
      [
        {'app_platform': 'android', 'app_version': '1.4.5'},
        {'app_platform': 'ios', 'app_version': '1.4.6'},
        {'app_platform': 'android', 'app_version': '1.4.6'},
        {'app_platform': 'android', 'app_version': '1.4.5'},
        {'app_platform': 'ios', 'app_version': null},
      ],
      {'ios': '1.4.6', 'android': '1.4.6'},
    );
    expect(counts.map((c) => '${c.platform} ${c.version} ${c.accounts} ${c.behind}'), [
      'ios 1.4.6 1 false',
      'android 1.4.6 1 false',
      'android 1.4.5 2 true',
    ]);
  });
}
