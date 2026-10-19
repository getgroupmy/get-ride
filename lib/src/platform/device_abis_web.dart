import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../core/app_builds.dart' show deviceAbisFromUserAgent;

/// What the browser says of the phone: `navigator.userAgentData`'s bitness
/// and architecture where it gives them (Chromium), else the user agent's
/// processor, if it still names one. Empty when it can't be told, which
/// means 64-bit. Never throws, and never waits long.
Future<List<String>> readDeviceAbis() async {
  var ua = '';
  String? bitness;
  String? architecture;
  try {
    ua = web.window.navigator.userAgent;
    final data = (web.window.navigator as JSObject).getProperty<JSAny?>('userAgentData'.toJS);
    if (data != null && data.isA<JSObject>()) {
      final hints = <JSString>['bitness'.toJS, 'architecture'.toJS].toJS;
      final values = await (data as JSObject)
          .callMethod<JSPromise<JSObject>>('getHighEntropyValues'.toJS, hints)
          .toDart
          .timeout(const Duration(seconds: 2));
      String? read(String key) {
        final v = values.getProperty<JSAny?>(key.toJS);
        return v != null && v.isA<JSString>() ? (v as JSString).toDart : null;
      }

      bitness = read('bitness');
      architecture = read('architecture');
    }
  } catch (_) {}
  try {
    return deviceAbisFromUserAgent(ua, bitness: bitness, architecture: architecture);
  } catch (_) {
    return const [];
  }
}
