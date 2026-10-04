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

    test('anything else just opens the app', () {
      expect(pushRouteFor({'audience': 'all'}), isNull);
      expect(pushRouteFor({}), isNull);
      expect(pushRouteFor({'type': 'something_new'}), isNull);
    });
  });
}
