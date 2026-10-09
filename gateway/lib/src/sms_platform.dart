// The phone's side of the gateway: sending and receiving SMS, listing SIMs,
// and the foreground service that keeps the gateway running with the screen
// off. Implemented in Kotlin (android/app/src/main/kotlin/.../MainActivity.kt);
// an interface so the engine can be tested without a phone.
import 'dart:async';

import 'package:flutter/services.dart';

import 'core.dart';

abstract class SmsPlatform {
  /// Sends [body] to [to] from the SIM [subscriptionId] (the default SIM when
  /// null) and completes once the radio has reported every part.
  Future<SmsSendResult> send(String to, String body, {int? subscriptionId});

  /// SMS as they arrive, while the app is running.
  Stream<IncomingSms> get incoming;

  /// SMS received but not yet acknowledged, including any that arrived while
  /// the app was closed.
  Future<List<IncomingSms>> pending();

  /// Drops SMS the server now has from the phone's queue.
  Future<void> acknowledge(List<String> ids);

  Future<List<SimCard>> sims();

  /// Starts (or updates the text of) the ongoing "Gateway online" notification
  /// that keeps the app running in the background.
  Future<void> startService(String text);

  Future<void> stopService();

  /// Whether Android may pause the app to save battery, which would stop the
  /// gateway while the screen is off.
  Future<bool> batteryOptimized();

  /// Asks Android to let the gateway run unrestricted.
  Future<void> requestBatteryExemption();
}

class MethodChannelSmsPlatform implements SmsPlatform {
  static const _methods = MethodChannel('getride.gateway/sms');
  static const _events = EventChannel('getride.gateway/sms_in');

  @override
  Future<SmsSendResult> send(String to, String body, {int? subscriptionId}) async {
    try {
      final r = await _methods.invokeMapMethod<String, Object?>('send', {
        'to': to,
        'body': body,
        'subscriptionId': subscriptionId,
      });
      if (r?['ok'] == true) return const SmsSendResult.sent();
      return SmsSendResult.failed('${r?['error'] ?? 'The phone did not send it.'}');
    } on PlatformException catch (e) {
      return SmsSendResult.failed(e.message ?? e.code);
    }
  }

  @override
  Stream<IncomingSms> get incoming => _events
      .receiveBroadcastStream()
      .map((e) {
        return e is Map ? IncomingSms.fromMap(e) : null;
      })
      .where((e) => e != null)
      .cast<IncomingSms>();

  @override
  Future<List<IncomingSms>> pending() async {
    final list = await _methods.invokeListMethod<Object?>('pending') ?? const [];
    return [
      for (final m in list)
        if (m is Map) ?IncomingSms.fromMap(m),
    ];
  }

  @override
  Future<void> acknowledge(List<String> ids) => _methods.invokeMethod('acknowledge', {'ids': ids});

  @override
  Future<List<SimCard>> sims() async {
    try {
      final list = await _methods.invokeListMethod<Object?>('sims') ?? const [];
      return [
        for (final m in list)
          if (m is Map) ?SimCard.fromMap(m),
      ];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<void> startService(String text) => _methods.invokeMethod('startService', {'text': text});

  @override
  Future<void> stopService() => _methods.invokeMethod('stopService');

  @override
  Future<bool> batteryOptimized() async => await _methods.invokeMethod<bool>('batteryOptimized') ?? false;

  @override
  Future<void> requestBatteryExemption() => _methods.invokeMethod('requestBatteryExemption');
}
