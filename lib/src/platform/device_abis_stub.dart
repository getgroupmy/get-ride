import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Android's `supportedAbis` (`[arm64-v8a, armeabi-v7a, armeabi]` on most
/// phones, `[armeabi-v7a, armeabi]` on a 32-bit-only one). Empty anywhere
/// else, or when the platform doesn't answer. Never throws.
Future<List<String>> readDeviceAbis() async {
  if (defaultTargetPlatform != TargetPlatform.android) return const [];
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    return [for (final a in info.supportedAbis) a.toLowerCase()];
  } catch (_) {
    return const [];
  }
}
