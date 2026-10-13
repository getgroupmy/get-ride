import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/push_logic.dart';

const _full = FirebaseEnv(
  projectId: 'getride-prod',
  messagingSenderId: '1234567890',
  androidAppId: '1:1234567890:android:abc',
  androidApiKey: 'android-key',
  iosAppId: '1:1234567890:ios:def',
  iosApiKey: 'ios-key',
  iosBundleId: 'com.taxxee.teksi',
);

void main() {
  group('firebaseOptionsFor', () {
    test('Android gets its own app id and key', () {
      final o = firebaseOptionsFor(TargetPlatform.android, _full)!;
      expect(o.appId, '1:1234567890:android:abc');
      expect(o.apiKey, 'android-key');
      expect(o.projectId, 'getride-prod');
      expect(o.messagingSenderId, '1234567890');
    });

    test('iOS gets its own app id, key and bundle id', () {
      final o = firebaseOptionsFor(TargetPlatform.iOS, _full)!;
      expect(o.appId, '1:1234567890:ios:def');
      expect(o.apiKey, 'ios-key');
      expect(o.iosBundleId, 'com.taxxee.teksi');
    });

    test('a build without a Firebase project has no push', () {
      expect(firebaseOptionsFor(TargetPlatform.android, const FirebaseEnv()), isNull);
      expect(firebaseOptionsFor(TargetPlatform.iOS, const FirebaseEnv()), isNull);
    });

    test('a half-configured platform has no push rather than a crash', () {
      const androidOnly = FirebaseEnv(
        projectId: 'p',
        messagingSenderId: 's',
        androidAppId: 'a',
        androidApiKey: 'k',
      );
      expect(firebaseOptionsFor(TargetPlatform.android, androidOnly), isNotNull);
      expect(firebaseOptionsFor(TargetPlatform.iOS, androidOnly), isNull);
      const noSender = FirebaseEnv(projectId: 'p', androidAppId: 'a', androidApiKey: 'k');
      expect(firebaseOptionsFor(TargetPlatform.android, noSender), isNull);
      const blank = FirebaseEnv(projectId: ' ', messagingSenderId: 's', androidAppId: 'a', androidApiKey: 'k');
      expect(firebaseOptionsFor(TargetPlatform.android, blank), isNull);
    });

    test('web and desktop have no push', () {
      expect(firebaseOptionsFor(TargetPlatform.android, _full, isWeb: true), isNull);
      expect(firebaseOptionsFor(TargetPlatform.macOS, _full), isNull);
      expect(firebaseOptionsFor(TargetPlatform.windows, _full), isNull);
      expect(firebaseOptionsFor(TargetPlatform.linux, _full), isNull);
    });
  });

  test('platform names match what the Expo app stores', () {
    expect(pushPlatformName(TargetPlatform.android), 'android');
    expect(pushPlatformName(TargetPlatform.iOS), 'ios');
    expect(pushPlatformName(TargetPlatform.macOS), isNull);
  });

  group('pushRouteFor', () {
    test('ride requests open the partner queue', () {
      expect(pushRouteFor({'type': 'ride_request', 'ride_request_id': 'r1'}), '/drive');
      expect(pushRouteFor({'type': 'ride_request_fare_raised'}), '/drive');
    });

    test('GET.coin transfers open the wallet', () {
      expect(pushRouteFor({'type': 'wallet_transfer_request'}), '/wallet');
      expect(pushRouteFor({'type': 'wallet_transfer_response', 'status': 'accepted'}), '/wallet');
    });

    test('approval decisions open the Drive tab or the vehicle', () {
      expect(pushRouteFor({'type': 'partner_status', 'status': 'approved'}), '/drive');
      expect(pushRouteFor({'type': 'document_status', 'document_id': 'd1'}), '/drive');
      expect(pushRouteFor({'type': 'vehicle_status', 'vehicle_id': 'v 1'}), '/drive/vehicles/v%201');
      expect(pushRouteFor({'type': 'vehicle_status'}), '/drive');
    });

    test('trip safety checks open the passenger trip; lost items the receipt', () {
      expect(pushRouteFor({'type': 'trip_start_check', 'request_id': 'r1'}), '/ride/r1');
      expect(pushRouteFor({'type': 'trip_separation', 'request_id': 'r1'}), '/ride/r1');
      expect(pushRouteFor({'type': 'trip_separation'}), isNull);
      expect(pushRouteFor({'type': 'lost_item', 'item_id': 'i', 'request_id': 'r1'}), '/trips/r1');
    });

    test('anything else just opens the app', () {
      expect(pushRouteFor({'audience': 'all'}), isNull);
      expect(pushRouteFor({}), isNull);
      expect(pushRouteFor({'type': 'something_new'}), isNull);
    });
  });

  test('the device key is a stable hash, never the raw id', () {
    final a = pushDeviceKey('abc');
    expect(a, pushDeviceKey(' abc '));
    expect(a, isNot(pushDeviceKey('abd')));
    expect(a, isNot(contains('abc')));
    expect(a!.length, 64);
    expect(pushDeviceKey(null), isNull);
    expect(pushDeviceKey('  '), isNull);
  });

  test('the mode follows driver and passenger screens; shared screens keep it', () {
    expect(pushModeAt('/drive', null), 'partner');
    expect(pushModeAt('/drive/trip/r1/chat', 'rider'), 'partner');
    expect(pushModeAt('/meter', 'rider'), 'partner');
    expect(pushModeAt('/', 'partner'), 'rider');
    expect(pushModeAt('/ride/r1', 'partner'), 'rider');
    expect(pushModeAt('/trips/r1', 'partner'), 'rider');
    expect(pushModeAt('/wallet', 'partner'), 'partner');
    expect(pushModeAt('/account/settings', 'rider'), 'rider');
    expect(pushModeAt('/wallet', null), isNull);
    expect(pushModeAt('/drivers', 'rider'), 'rider');
  });
}
