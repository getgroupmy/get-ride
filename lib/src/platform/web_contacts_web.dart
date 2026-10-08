import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

JSObject get _navigator => web.window.navigator as JSObject;

/// Whether this browser offers the Contact Picker API.
bool webContactsSupported() {
  try {
    return _navigator.has('contacts');
  } catch (_) {
    return false;
  }
}

/// Opens the browser's contact picker for one person's name and numbers;
/// null when they backed out.
Future<({String? name, List<String> numbers})?> pickWebContact() async {
  final contacts = _navigator['contacts'] as JSObject;
  final props = <JSString>['name'.toJS, 'tel'.toJS].toJS;
  final options = JSObject()..['multiple'] = false.toJS;
  final picked = await contacts.callMethod<JSPromise<JSArray<JSObject>>>('select'.toJS, props, options).toDart;
  final list = picked.toDart;
  if (list.isEmpty) return null;
  final c = list.first;
  List<String> strings(String key) {
    final v = c[key];
    if (v == null || v.isUndefinedOrNull) return const [];
    return (v as JSArray<JSString>).toDart.map((s) => s.toDart).toList();
  }

  final names = strings('name');
  return (name: names.isEmpty ? null : names.first, numbers: strings('tel'));
}
