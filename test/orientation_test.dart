import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/orientation.dart';

void main() {
  test('the app default is portrait only — the meter is the sole landscape exception', () {
    expect(appDefaultOrientations, const [DeviceOrientation.portraitUp]);
    expect(appDefaultOrientations, isNot(contains(DeviceOrientation.landscapeLeft)));
    expect(appDefaultOrientations, isNot(contains(DeviceOrientation.landscapeRight)));
  });
}
