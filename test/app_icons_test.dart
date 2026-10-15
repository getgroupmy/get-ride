// The home-screen icons: the schedule, the passenger's choice, the admin's
// fixed icon, and every icon packaged for iOS, Android and the Settings page.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_icons.dart';

void main() {
  DateTime d(int y, int m, int day) => DateTime(y, m, day, 10);

  group('windows', () {
    test('annual, over the year end', () {
      const w = IconWindow(icon: 'new_year', kind: IconWindowKind.annual, start: '12-27', end: '01-02');
      expect(w.covers(d(2026, 12, 27)), isTrue);
      expect(w.covers(d(2027, 1, 2)), isTrue);
      expect(w.covers(d(2027, 1, 3)), isFalse);
      expect(w.covers(d(2026, 12, 26)), isFalse);
    });

    test('monthly, over the month end (payday)', () {
      const w = IconWindow(icon: 'payday', kind: IconWindowKind.monthly, start: '25', end: '1');
      expect(w.covers(d(2026, 10, 25)), isTrue);
      expect(w.covers(d(2026, 10, 31)), isTrue);
      expect(w.covers(d(2026, 11, 1)), isTrue);
      expect(w.covers(d(2026, 11, 2)), isFalse);
      expect(w.covers(d(2026, 11, 24)), isFalse);
    });

    test('dated, only that year', () {
      const w = IconWindow(icon: 'deepavali', kind: IconWindowKind.dated, start: '2026-11-02', end: '2026-11-09');
      expect(w.covers(d(2026, 11, 8)), isTrue);
      expect(w.covers(d(2027, 11, 8)), isFalse);
    });

    test('bad bounds are dropped when read', () {
      expect(IconWindow.fromJson({'icon': 'payday', 'kind': 'monthly', 'start': '40', 'end': '1'}), isNull);
      expect(IconWindow.fromJson({'icon': 'nope', 'kind': 'annual', 'start': '01-01', 'end': '01-02'}), isNull);
      expect(IconWindow.fromJson({'icon': 'payday', 'kind': 'weekly', 'start': '1', 'end': '2'}), isNull);
      expect(IconWindow.fromJson({'icon': 'christmas', 'kind': 'annual', 'start': '13-01', 'end': '12-26'}), isNull);
    });
  });

  group('which icon', () {
    const config = AppIconConfig.standard;

    test('the standard schedule', () {
      expect(scheduledAppIcon(config, d(2026, 10, 15)), standardAppIcon);
      expect(scheduledAppIcon(config, d(2026, 10, 10)), 'sale_10_10');
      expect(scheduledAppIcon(config, d(2026, 10, 26)), 'payday');
      expect(scheduledAppIcon(config, d(2026, 11, 8)), 'deepavali');
      expect(scheduledAppIcon(config, d(2026, 11, 11)), 'sale_11_11');
      expect(scheduledAppIcon(config, d(2026, 12, 25)), 'christmas', reason: 'Christmas is above payday');
      expect(scheduledAppIcon(config, d(2026, 12, 31)), 'new_year');
      expect(scheduledAppIcon(config, d(2027, 2, 6)), 'chinese_new_year');
      expect(scheduledAppIcon(config, d(2027, 3, 1)), 'ramadan');
      expect(scheduledAppIcon(config, d(2027, 3, 10)), 'hari_raya');
      expect(scheduledAppIcon(config, d(2027, 8, 31)), 'merdeka');
      expect(scheduledAppIcon(config, d(2027, 9, 9)), 'sale_9_9', reason: '9.9 is above Mid-Autumn');
      expect(scheduledAppIcon(config, d(2027, 9, 14)), 'merdeka');
    });

    test('Gawai & Kaamatan only in Sarawak and Sabah', () {
      expect(scheduledAppIcon(config, d(2027, 6, 2)), standardAppIcon);
      expect(scheduledAppIcon(config, d(2027, 6, 1)), 'payday', reason: 'elsewhere, the next window down');
      expect(scheduledAppIcon(config, d(2027, 6, 1), regions: {'Malaysia', 'sarawak'}), 'harvest');
      expect(scheduledAppIcon(config, d(2027, 6, 2), regions: {'Sabah'}), 'harvest');
      expect(scheduledAppIcon(config, d(2027, 6, 2), regions: {'Selangor'}), standardAppIcon);
    });

    test('a switched-off window is skipped (monsoon, until an admin turns it on)', () {
      expect(scheduledAppIcon(config, d(2027, 1, 10)), standardAppIcon);
      final on = config.copyWith(
        schedule: [for (final w in config.schedule) w.icon == 'monsoon' ? w.copyWith(enabled: true) : w],
      );
      expect(scheduledAppIcon(on, d(2027, 1, 10)), 'monsoon');
    });

    test("the passenger's own choice, when the admin allows it", () {
      expect(chosenAppIcon(config, d(2026, 11, 8), userChoice: 'g_dot'), 'g_dot');
      expect(chosenAppIcon(config, d(2026, 11, 8)), 'deepavali');
      final locked = config.copyWith(allowUserChoice: false);
      expect(chosenAppIcon(locked, d(2026, 11, 8), userChoice: 'g_dot'), 'deepavali');
      expect(chosenAppIcon(config, d(2026, 11, 8), userChoice: 'gone'), 'deepavali');
    });

    test("the admin's fixed icon when not automatic", () {
      final fixed = config.copyWith(automatic: false, fixedIcon: 'get_dot');
      expect(chosenAppIcon(fixed, d(2026, 11, 8)), 'get_dot');
      expect(chosenAppIcon(fixed, d(2026, 11, 8), userChoice: 'christmas'), 'christmas');
    });
  });

  test('settings survive saving and reading back', () {
    final c = AppIconConfig.standard.copyWith(
      automatic: false,
      fixedIcon: 'g_dot',
      allowUserChoice: false,
      schedule: const [
        IconWindow(icon: 'harvest', kind: IconWindowKind.annual, start: '05-25', end: '06-02', regions: ['Sabah']),
        IconWindow(icon: 'payday', kind: IconWindowKind.monthly, start: '25', end: '1', enabled: false),
      ],
    );
    final back = AppIconConfig.fromJson(c.toJson());
    expect(back.toJson(), c.toJson());
    expect(AppIconConfig.fromJson(null).schedule, defaultIconSchedule);
    expect(AppIconConfig.fromJson({'fixed_icon': 'nope'}).fixedIcon, standardAppIcon);
  });

  test('every window of the standard schedule is valid', () {
    for (final w in defaultIconSchedule) {
      expect(IconWindow.fromJson(w.toJson())?.toJson(), w.toJson(), reason: w.describe);
    }
  });

  group('every icon is packaged', () {
    final alternates = appIcons.where((i) => i.id != standardAppIcon);

    test('Settings previews, light and dark', () {
      for (final i in appIcons) {
        expect(File(i.preview(dark: false)).existsSync(), isTrue, reason: i.id);
        expect(File(i.preview(dark: true)).existsSync(), isTrue, reason: i.id);
      }
    });

    test('iOS: an icon set each, light, dark and tinted, listed as alternate icons', () {
      final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      final names = RegExp(r'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "([^"]*)";').allMatches(project).toList();
      expect(names, hasLength(3), reason: 'Debug, Release and Profile');
      for (final m in names) {
        expect(m.group(1)!.split(' ').toSet(), {for (final i in alternates) 'AppIcon-${i.id}'});
      }
      for (final i in alternates) {
        final dir = 'ios/Runner/Assets.xcassets/AppIcon-${i.id}.appiconset';
        final contents = File('$dir/Contents.json').readAsStringSync();
        expect(contents, contains('"dark"'), reason: i.id);
        expect(contents, contains('"tinted"'), reason: i.id);
        for (final f in ['Icon-1024.png', 'Icon-Dark-1024.png', 'Icon-Tinted-1024.png']) {
          expect(File('$dir/$f').existsSync(), isTrue, reason: '${i.id} $f');
        }
      }
    });

    test('Android: an alias each, the standard one enabled, artwork for light and dark', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final aliases = RegExp(r'<activity-alias\s+android:name="\.AppIcon_(\w+)"[^>]*?android:enabled="(\w+)"')
          .allMatches(manifest)
          .map((m) => (m.group(1)!, m.group(2)!))
          .toList();
      expect({for (final a in aliases) a.$1}, {for (final i in appIcons) i.id});
      expect(
        [
          for (final a in aliases)
            if (a.$2 == 'true') a.$1,
        ],
        [standardAppIcon],
      );
      const res = 'android/app/src/main/res';
      for (final i in alternates) {
        expect(File('$res/mipmap-anydpi-v26/ic_alt_${i.id}.xml').existsSync(), isTrue, reason: i.id);
        expect(File('$res/drawable-nodpi/ic_alt_${i.id}.webp').existsSync(), isTrue, reason: i.id);
        expect(File('$res/drawable-night-nodpi/ic_alt_${i.id}.webp').existsSync(), isTrue, reason: i.id);
        expect(File('$res/mipmap-xxxhdpi/ic_alt_${i.id}.png').existsSync(), isTrue, reason: i.id);
      }
      // MainActivity's own launcher entry is taken out in every build type.
      for (final type in ['debug', 'profile', 'release']) {
        final overlay = File('android/app/src/$type/AndroidManifest.xml').readAsStringSync();
        expect(overlay, contains('<intent-filter tools:node="remove">'), reason: type);
      }
    });
  });
}
