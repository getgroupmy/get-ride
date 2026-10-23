import 'dart:async';
import 'dart:io' show InternetAddressType, NetworkInterface;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/phone_details.dart';
import '../core/session_telemetry.dart';
import 'permission_probe.dart';

/// The phone's network and SIM (`get_ride/network`: MainActivity's
/// NetworkInfoChannel on Android, NetworkInfoPlugin on iOS). Only what the
/// platform gives without a permission: no phone-state access, no ICCID.
const _network = MethodChannel('get_ride/network');

/// Reads [DeviceDetails] for a `user_sessions` row: make and model once, the
/// network, battery, storage, IP and permissions afresh each time. Every
/// part is best-effort and quick; a part that fails or stalls is left out.
/// Nothing asks the user anything: [permissions] is only read.
class DeviceDetailsReader {
  DeviceDetailsReader({DeviceInfoPlugin? info, this._permissions, this._pushKey}) : _info = info ?? DeviceInfoPlugin();

  final DeviceInfoPlugin _info;
  final PermissionProbe? _permissions;

  /// The phone's push device key, which ties its rows to its push token.
  final Future<String?> Function()? _pushKey;
  DeviceDetails? _hardware;

  static const _wait = Duration(seconds: 3);

  Future<DeviceDetails> read() async {
    final permsLater = _guard(_readPermissions());
    final keyLater = _pushKey == null ? Future<String?>.value() : _guard(_pushKey());
    final hardware = _hardware ??= await _guard(_readHardware()) ?? const DeviceDetails();
    final net = await _guard(_readNetwork()) ?? const <String, Object?>{};
    final ip = await _guard(_localIp());
    final perms = await permsLater ?? const <String, Object?>{};
    final pushKey = await keyLater;
    // Android answers the SIM's code whole ("50219"), iOS in two parts.
    final mcc = cleanDeviceText(net['mcc']), mnc = cleanDeviceText(net['mnc']);
    final operatorCode = splitOperatorCode(
      cleanDeviceText(net['simOperator']) ?? (mcc != null && mnc != null ? '$mcc$mnc' : null),
    );
    final networkCode = splitOperatorCode(cleanDeviceText(net['networkOperator']));
    final view = PlatformDispatcher.instance.views.isEmpty ? null : PlatformDispatcher.instance.views.first;
    return DeviceDetails(
      osVersion: hardware.osVersion,
      brand: hardware.brand,
      manufacturer: hardware.manufacturer,
      modelName: hardware.modelName,
      modelId: hardware.modelId,
      isPhysical: hardware.isPhysical,
      networkType: cleanDeviceText(net['type']),
      isConnected: net['connected'] as bool?,
      internetReachable: net['internet'] as bool?,
      networkOperator: cleanDeviceText(net['networkOperatorName']) ?? cleanDeviceText(net['carrierName']),
      mobileOperator: cleanDeviceText(net['simOperatorName']) ?? cleanDeviceText(net['carrierName']),
      mobileCountryCode: operatorCode?.$1 ?? networkCode?.$1,
      mobileNetworkCode: operatorCode?.$2 ?? networkCode?.$2,
      cellularGeneration: cellularGenerationOf(net['radio'] as String?),
      localIp: ip,
      extra: {
        ...hardware.extra,
        for (final k in const ['simCountry', 'networkCountry', 'simState', 'simSlots', 'metered', 'vpn', 'radio'])
          if (net[k] != null) 'net_$k': net[k],
        ...batteryAndStorageExtra(net),
        ...perms,
        PhoneExtra.pushKey: ?pushKey,
        'locale': PlatformDispatcher.instance.locale.toLanguageTag(),
        'timezone': DateTime.now().timeZoneName,
        'utc_offset_min': DateTime.now().timeZoneOffset.inMinutes,
        if (view != null) ...{
          'screen': '${view.physicalSize.width.round()}x${view.physicalSize.height.round()}',
          'pixel_ratio': view.devicePixelRatio,
        },
      },
    );
  }

  static Future<T?> _guard<T>(Future<T> f) async {
    try {
      return await f.timeout(_wait);
    } catch (e) {
      debugPrint('[session] device detail unavailable: $e');
      return null;
    }
  }

  Future<DeviceDetails> _readHardware() async {
    if (kIsWeb) {
      final w = await _info.webBrowserInfo;
      return DeviceDetails(
        brand: w.vendor,
        modelName: w.browserName.name,
        modelId: w.platform,
        extra: {'user_agent': w.userAgent},
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final a = await _info.androidInfo;
        return DeviceDetails(
          osVersion: 'Android ${a.version.release} (SDK ${a.version.sdkInt})',
          brand: a.brand,
          manufacturer: a.manufacturer,
          modelName: a.model,
          modelId: a.device,
          isPhysical: a.isPhysicalDevice,
          extra: {'android_product': a.product, 'security_patch': a.version.securityPatch, 'android_board': a.board},
        );
      case TargetPlatform.iOS:
        final i = await _info.iosInfo;
        return DeviceDetails(
          osVersion: '${i.systemName} ${i.systemVersion}',
          brand: 'Apple',
          manufacturer: 'Apple',
          modelName: i.modelName,
          modelId: i.utsname.machine,
          isPhysical: i.isPhysicalDevice,
        );
      case TargetPlatform.macOS:
        final m = await _info.macOsInfo;
        return DeviceDetails(
          osVersion: 'macOS ${m.osRelease}',
          brand: 'Apple',
          manufacturer: 'Apple',
          modelName: m.modelName,
          modelId: m.model,
          isPhysical: true,
        );
      case TargetPlatform.windows:
        final w = await _info.windowsInfo;
        return DeviceDetails(osVersion: '${w.productName} ${w.displayVersion}', modelName: w.computerName, isPhysical: true);
      default:
        return const DeviceDetails();
    }
  }

  /// Where location and notifications stand, read without asking.
  Future<Map<String, Object?>> _readPermissions() async {
    final p = _permissions;
    if (p == null) return const {};
    final (on, location) = await p.location();
    final notifications = phoneNotificationsAllowed(await p.notifications());
    return {
      PhoneExtra.location: PhoneLocationAccess.ofPermState(location).value,
      PhoneExtra.locationServiceOn: on,
      PhoneExtra.notifications: ?notifications,
    };
  }

  Future<Map<String, Object?>> _readNetwork() async {
    if (kIsWeb || (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS)) {
      return const {};
    }
    final m = await _network.invokeMapMethod<String, Object?>('info');
    return m ?? const {};
  }

  /// The phone's own address on its network (Wi-Fi first), not the public
  /// one `ip-lookup` gives.
  Future<String?> _localIp() async {
    if (kIsWeb) return null;
    final all = await NetworkInterface.list(type: InternetAddressType.IPv4);
    if (all.isEmpty) return null;
    final wifi = all.where((n) => n.name.startsWith('wlan') || n.name.startsWith('en'));
    final pick = (wifi.isNotEmpty ? wifi : all).expand((n) => n.addresses).where((a) => !a.isLoopback);
    return pick.isEmpty ? null : pick.first.address;
  }
}

/// The battery and storage the `get_ride/network` channel answers with the
/// network, under the keys the admin Phone card reads ([PhoneExtra]); an
/// out-of-range or missing value is left out. Pure.
Map<String, Object?> batteryAndStorageExtra(Map<String, Object?> net) {
  final pct = net['batteryPct'], charging = net['batteryCharging'];
  final free = net['storageFree'], total = net['storageTotal'];
  return {
    if (pct is num && pct >= 0 && pct <= 100) PhoneExtra.batteryPct: pct.round(),
    if (charging is bool) PhoneExtra.batteryCharging: charging,
    if (free is num && free >= 0) PhoneExtra.storageFree: free.toInt(),
    if (total is num && total > 0) PhoneExtra.storageTotal: total.toInt(),
  };
}
