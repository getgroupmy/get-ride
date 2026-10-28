import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// The browser can run the check (WebGL is asked for when it loads).
const browserFaceCheckSupported = true;

Future<JSObject>? _module;

/// {state: match | no_match | no_face, score} for the two photos (signed
/// links), or null when the library or a photo couldn't be loaded.
Future<({String state, double? score})?> browserFaceCompare(String selfieUrl, String cardUrl) async {
  try {
    final module = await (_module ??= importModule(_glue().toJS).toDart);
    final compare = module['compare'] as JSFunction;
    final promise = compare.callAsFunction(null, selfieUrl.toJS, cardUrl.toJS) as JSPromise<JSObject>;
    final r = await promise.toDart;
    final state = (r['state'] as JSString?)?.toDart;
    final score = (r['score'] as JSNumber?)?.toDartDouble;
    if (state == null) return null;
    return (state: state, score: score);
  } catch (_) {
    _module = null;
    return null;
  }
}

/// The glue served with the app, beside index.html (its `<base href>`, so a
/// deep admin link like /admin/m/... still finds it).
String _glue() => Uri.parse(web.document.baseURI).resolve('face_check/face_check.js').toString();
