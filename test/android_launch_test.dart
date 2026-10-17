import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android: one copy of the app, so a call never opens a second one', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final main = RegExp(r'<activity\s+android:name="\.MainActivity"[^>]*>').firstMatch(manifest)!.group(0)!;
    expect(main, contains('android:launchMode="singleTask"'));
  });
}
