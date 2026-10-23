// The admin Phone card's logic (lib/src/core/phone_details.dart): session
// rows grouped per phone, newest first, push tokens tied to their phone, the
// words the card shows, and the battery and storage the native channel
// answers (lib/src/data/device_details.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/core/app_version.dart';
import 'package:get_ride/src/core/phone_details.dart';
import 'package:get_ride/src/data/device_details.dart';

Map<String, dynamic> _row(
  String at, {
  String? device = 'dev-a',
  String os = 'ios',
  String? model = 'iPhone 15 Pro',
  String? modelId = 'iPhone16,1',
  String? brand = 'Apple',
  String? app = '1.5.2',
  String? build = '412',
  Map<String, dynamic> raw = const {},
  Map<String, dynamic> extra = const {},
}) => {
  'captured_at': at,
  'device_id': device,
  'os_name': os,
  'os_version': os == 'ios' ? 'iOS 18.6' : 'Android 15 (SDK 35)',
  'device_brand': brand,
  'device_model_name': model,
  'device_model_id': modelId,
  'is_physical_device': true,
  'app_version': app,
  'app_build_version': build,
  'raw': raw,
  ...extra,
};

void main() {
  group('grouping', () {
    test('one phone per device id, newest first, whatever order the rows come in', () {
      final phones = phonesFrom([
        _row('2026-10-01T00:00:00Z', device: 'dev-b', os: 'android', model: 'SM-A546E', modelId: 'a54x', brand: 'samsung'),
        _row('2026-10-20T00:00:00Z'),
        _row('2026-08-12T00:00:00Z'),
        _row('2026-06-02T00:00:00Z', device: 'dev-b', os: 'android', model: 'SM-A546E', modelId: 'a54x', brand: 'samsung'),
      ], const []);
      expect(phones.map((p) => p.key), ['dev-a', 'dev-b']);
      expect(phones.first.reports, 2);
      expect(phones.first.reportedAt, DateTime.utc(2026, 10, 20));
      expect(phones.first.firstSeen, DateTime.utc(2026, 8, 12));
      expect(phones.last.modelLine, 'Samsung SM-A546E');
      expect(phones.last.modelCode, 'a54x');
      expect(phones.first.modelLine, 'Apple iPhone 15 Pro');
      expect(phonesFrom([_row('2026-10-20T00:00:00Z', brand: 'Xiaomi', model: 'Xiaomi 14')], const []).single.modelLine,
          'Xiaomi 14', reason: 'the name already says the brand');
    });

    test('no device id: grouped by platform and model', () {
      final phones = phonesFrom([
        _row('2026-10-20T00:00:00Z', device: null),
        _row('2026-10-19T00:00:00Z', device: ''),
        _row('2026-10-18T00:00:00Z', device: null, os: 'android', model: 'Pixel 8'),
      ], const []);
      expect(phones.map((p) => p.key), ['ios|iPhone 15 Pro', 'android|Pixel 8']);
      expect(phones.first.reports, 2);
    });

    test('hardware from the newest row that has it; the app and battery from the newest row only', () {
      final p = phonesFrom([
        _row('2026-10-20T00:00:00Z', model: null, modelId: null, app: '1.5.2', raw: const {}),
        _row('2026-10-19T00:00:00Z', app: '1.5.0', raw: const {'battery_pct': 50, 'screen': '1179x2556', 'pixel_ratio': 3}),
      ], const []).single;
      expect(p.modelName, 'iPhone 15 Pro');
      expect(p.appVersion, '1.5.2');
      expect(p.batteryPct, isNull, reason: "an older report's battery is stale");
      expect(p.screenLabel, '393 × 852 · 3×');
    });

    test('no rows: no phones', () {
      expect(phonesFrom(const [], const [{'platform': 'ios'}]), isEmpty);
    });
  });

  group('push tokens', () {
    test('by device key first, else the newest phone of the platform; VoIP left out', () {
      final phones = phonesFrom([
        _row('2026-10-20T00:00:00Z'),
        _row('2026-10-10T00:00:00Z', device: 'dev-old'),
        _row('2026-10-15T00:00:00Z', device: 'dev-b', os: 'android', raw: const {'push_device_key': 'k-b'}),
      ], [
        {'platform': 'ios_voip', 'location_always': true, 'updated_at': '2026-10-21T00:00:00Z'},
        {'platform': 'ios', 'location_always': true, 'located_at': '2026-10-20T06:00:00Z', 'updated_at': '2026-10-20T00:00:00Z'},
        {'platform': 'android', 'device_key': 'k-b', 'location_always': false, 'updated_at': '2026-09-01T00:00:00Z'},
        {'platform': 'android', 'device_key': 'k-other', 'location_always': true, 'updated_at': '2026-10-21T00:00:00Z'},
      ]);
      expect(phones.map((p) => p.key), ['dev-a', 'dev-b', 'dev-old']);
      expect(phones[0].backgroundTracking, isTrue);
      expect(phones[0].lastSeen, DateTime.utc(2026, 10, 20, 6), reason: 'a background position after the last report');
      expect(phones[0].location, PhoneLocationAccess.always, reason: 'Always on says Always when the row is too old to say');
      expect(phones[1].backgroundTracking, isFalse, reason: 'its own key, not the newer Android token');
      expect(phones[2].backgroundTracking, isNull, reason: 'the only iPhone token went to the newer iPhone');
    });
  });

  group('words', () {
    PhoneDetails phone(Map<String, dynamic> raw, {Map<String, dynamic> extra = const {}}) =>
        phonesFrom([_row('2026-10-20T00:00:00Z', raw: raw, extra: extra)], const []).single;

    test('battery: Low under 20, charging', () {
      expect((phone(const {'battery_pct': 62}).batteryLabel, phone(const {'battery_pct': 62}).batteryLow), ('62%', false));
      final low = phone(const {'battery_pct': 14, 'battery_charging': true});
      expect((low.batteryLabel, low.batteryLow), ('14% · charging', true));
      expect(phone(const {'battery_pct': 20}).batteryLow, isFalse);
      expect(phone(const {'battery_pct': 140}).batteryPct, isNull);
      expect(phone(const {}).batteryLabel, isNull);
    });

    test('storage, screen, language', () {
      final p = phone(const {
        'storage_free_bytes': 38e9,
        'storage_total_bytes': 128e9,
        'screen': '1080x2340',
        'pixel_ratio': 2.625,
        'locale': 'ms-MY',
        'utc_offset_min': 480,
      });
      expect(p.storageLabel, '38 GB free of 128 GB');
      expect(p.screenLabel, '411 × 891 · 2.6×');
      expect(p.languageLabel, 'ms-MY · GMT+8');
      expect(phoneBytesLabel(4200000000), '4.2 GB');
      expect(phoneBytesLabel(4000000000), '4 GB');
      expect(phoneBytesLabel(820000000), '820 MB');
      expect(phoneGmtLabel(330), 'GMT+5:30');
      expect(phoneGmtLabel(-180), 'GMT-3');
      expect(phoneGmtLabel(0), 'GMT');
    });

    test('location and notifications', () {
      expect(phone(const {'perm_location': 'always'}).locationLabel, 'Always');
      final inUse = phone(const {'perm_location': 'while_in_use'});
      expect((inUse.locationLabel, inUse.locationNeedsAlways), ('While using the app', true));
      expect(phone(const {'perm_location': 'denied'}).locationLabel, 'Off');
      final off = phone(const {'perm_location': 'always', 'location_service_on': false});
      expect((off.locationLabel, off.locationNeedsAlways), ('Off (location switched off)', true));
      final unknown = phone(const {});
      expect((unknown.locationLabel, unknown.locationNeedsAlways), ('Not known', false));
      expect(phone(const {'perm_notifications': false}).notifications, isFalse);
      expect(PhoneLocationAccess.ofPermState(PermState.notAsked), PhoneLocationAccess.off);
      expect(PhoneLocationAccess.ofPermState(PermState.limited).value, 'while_in_use');
      expect(phoneNotificationsAllowed(PermState.granted), isTrue);
      expect(phoneNotificationsAllowed(PermState.notAsked), isFalse);
      expect(phoneNotificationsAllowed(PermState.unknown), isNull);
    });

    test('network, operator and IP area', () {
      final p = phone(const {}, extra: {
        'network_type': 'cellular',
        'cellular_generation': '5G',
        'network_operator': 'CelcomDigi',
        'mobile_operator_name': 'Maxis',
        'ip_city': 'Kajang',
        'ip_region': 'Selangor',
        'ip_country': 'MY',
      });
      expect(p.networkLabel, 'Mobile data · 5G');
      expect(p.operatorLabel, 'CelcomDigi (SIM: Maxis)');
      expect(p.networkSummary, 'Mobile data · 5G · CelcomDigi (SIM: Maxis)');
      expect(p.ipAreaLabel, 'Kajang, Selangor, MY');
      final wifi = phone(const {}, extra: {'network_type': 'wifi', 'mobile_operator_name': 'Maxis'});
      expect((wifi.networkLabel, wifi.operatorLabel), ('Wi-Fi', 'Maxis (SIM)'));
    });

    test('the app against the App Version rows', () {
      const rules = [AppVersionRule(platform: 'iOS', latest: '1.5.2')];
      expect(phone(const {}).appLabel, '1.5.2 (412)');
      expect(phone(const {}).appStatus(rules), PhoneAppStatus.latest);
      final old = phonesFrom([_row('2026-10-20T00:00:00Z', app: '1.5.0')], const []).single;
      expect(old.appStatus(rules), PhoneAppStatus.behind);
      expect(old.appStatus(const [AppVersionRule(platform: 'Android', latest: '1.6.0')]), PhoneAppStatus.unknown,
          reason: 'no rule for its platform');
      expect(old.appStatus(const [AppVersionRule(platform: 'All', latest: '1.6.0')]), PhoneAppStatus.behind);
    });

    test('tabs: a second phone of the same model is numbered', () {
      final phones = phonesFrom([
        _row('2026-10-20T00:00:00Z'),
        _row('2026-10-19T00:00:00Z', device: 'dev-2'),
        _row('2026-10-18T00:00:00Z', device: 'dev-3', model: null, modelId: null, os: 'android'),
      ], const []);
      expect(phoneTabLabels(phones), ['iPhone 15 Pro', 'iPhone 15 Pro (2)', 'Android phone']);
      expect(phones.first.summaryLine, 'Apple iPhone 15 Pro · iOS 18.6');
      expect(phones.last.physicalLabel, 'Yes');
    });

    test('raw as a JSON string still reads', () {
      final p = phonesFrom([_row('2026-10-20T00:00:00Z', extra: {'raw': '{"battery_pct": 33}'})], const []).single;
      expect(p.batteryPct, 33);
    });
  });

  test('battery and storage from the network channel', () {
    expect(
      batteryAndStorageExtra(const {'batteryPct': 62, 'batteryCharging': false, 'storageFree': 38000000000, 'storageTotal': 128000000000}),
      {'battery_pct': 62, 'battery_charging': false, 'storage_free_bytes': 38000000000, 'storage_total_bytes': 128000000000},
    );
    expect(batteryAndStorageExtra(const {'batteryPct': -1, 'storageTotal': 0, 'type': 'wifi'}), isEmpty,
        reason: 'iOS answers -1 before monitoring has a reading');
  });
}
