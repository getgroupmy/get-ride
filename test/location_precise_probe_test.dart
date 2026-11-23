// Precise or approximate: what the phone is asked, and how its answer is read
// (data/permission_probe.dart). The phone is stood in for at its two channels:
// the location plugin's, and the app's own (MainActivity.kt).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/permission_ask.dart';
import 'package:get_ride/src/data/permission_probe.dart';

const _geolocator = MethodChannel('flutter.baseflow.com/geolocator');
const _geolocatorAndroid = MethodChannel('flutter.baseflow.com/geolocator_android');

/// What the location plugin answers "which accuracy is allowed?" with.
const _reduced = 0, _precise = 1, _unknown = 2;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// The phone: the accuracy it allows (null: location is not allowed at all,
  /// and the plugin says so), what its own question does when it is asked,
  /// and how long that takes.
  late Object? accuracy;
  late Future<void> Function() onAsked;
  late List<String> asked;

  late PermissionProbe probe;
  late ProviderContainer container;

  setUp(() {
    accuracy = _reduced;
    asked = [];
    onAsked = () async {};
    Future<Object?> plugin(MethodCall call) async {
      if (call.method != 'getLocationAccuracy') return null;
      if (accuracy == null) throw PlatformException(code: 'PERMISSION_DENIED', message: 'not allowed');
      return accuracy;
    }

    messenger.setMockMethodCallHandler(_geolocator, plugin);
    messenger.setMockMethodCallHandler(_geolocatorAndroid, plugin);
    messenger.setMockMethodCallHandler(permissionsChannel, (call) async {
      asked.add(call.method);
      if (call.method == 'requestPreciseLocation') {
        await onAsked();
        return accuracy == _precise;
      }
      return null;
    });
    container = ProviderContainer();
    probe = container.read(permissionProbeProvider);
  });

  tearDown(() {
    container.dispose();
    debugDefaultTargetPlatformOverride = null;
    for (final channel in [_geolocator, _geolocatorAndroid, permissionsChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('${platform.name}: what the phone allows is read as precise, approximate, or not known', () async {
      debugDefaultTargetPlatformOverride = platform;
      accuracy = _precise;
      expect(await probe.locationPrecise(), isTrue);
      accuracy = _reduced;
      expect(await probe.locationPrecise(), isFalse);
      accuracy = _unknown;
      expect(await probe.locationPrecise(), isNull);
      // Location not allowed at all: not this check's to say.
      accuracy = null;
      expect(await probe.locationPrecise(), isNull);
      // A phone whose plugin gives no answer.
      accuracy = 'nonsense';
      expect(await probe.locationPrecise(), isNull);
      expect(asked, isEmpty, reason: 'looking never asks');
    });
  }

  group('asking, on Android', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test("approximate: the phone's own question is asked, on its own; allowed there, it is precise", () async {
      onAsked = () async => accuracy = _precise;
      expect(await probe.askLocationPrecise(), const AskResult(AskAnswer.granted));
      expect(asked, ['requestPreciseLocation']);
      expect(await probe.locationPrecise(), isTrue);
    });

    test('told to keep it approximate, after a moment to read the question: refused, and may be asked again', () async {
      onAsked = () => Future<void>.delayed(askNoDialogUnder + const Duration(milliseconds: 100));
      expect(await probe.askLocationPrecise(), const AskResult(AskAnswer.denied));
      expect(asked, ['requestPreciseLocation']);
    });

    test('answered at once, still approximate: the phone did not ask (refused twice before)', () async {
      expect(await probe.askLocationPrecise(), const AskResult(AskAnswer.blocked, prompted: false));
      expect(asked, ['requestPreciseLocation']);
    });

    test('a build without the native half: as if the phone would not ask', () async {
      messenger.setMockMethodCallHandler(permissionsChannel, null);
      expect(await probe.askLocationPrecise(), const AskResult(AskAnswer.blocked, prompted: false));
    });

    test('precise already: nothing is asked', () async {
      accuracy = _precise;
      expect(await probe.askLocationPrecise(), const AskResult(AskAnswer.granted, prompted: false));
      expect(asked, isEmpty);
    });

    test('a phone that cannot say which it has: nothing is asked', () async {
      accuracy = _unknown;
      expect(await probe.askLocationPrecise(), const AskResult(AskAnswer.unsupported, prompted: false));
      accuracy = null;
      expect(await probe.askLocationPrecise(), const AskResult(AskAnswer.unsupported, prompted: false));
      expect(asked, isEmpty);
    });
  });

  test('asking, on an iPhone: there is no question for it, only its Settings', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await probe.askLocationPrecise(), const AskResult(AskAnswer.blocked, prompted: false));
    expect(asked, isEmpty);
    accuracy = _precise;
    expect(await probe.askLocationPrecise(), const AskResult(AskAnswer.granted, prompted: false));
  });
}
