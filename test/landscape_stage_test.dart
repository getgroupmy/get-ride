import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/landscape_stage.dart';

void main() {
  test('a landscape viewport is passed through untouched', () {
    const insets = EdgeInsets.fromLTRB(47, 0, 47, 21);
    final s = resolveLandscapeStage(const Size(844, 390), insets);
    expect(s.quarterTurns, 0);
    expect(s.size, const Size(844, 390));
    expect(s.padding, insets);
  });

  test('a portrait viewport is turned, and its insets roll round with it', () {
    // A portrait iPhone: notch on top, home indicator at the bottom.
    final s = resolveLandscapeStage(const Size(390, 844), const EdgeInsets.fromLTRB(0, 47, 0, 34));
    expect(s.quarterTurns, 1);
    expect(s.size, const Size(844, 390), reason: "the glass's long edge is the console's width");
    // Turned clockwise, the content's left meets the glass's top (the notch)
    // and its right meets the bottom (the home indicator).
    expect(s.padding, const EdgeInsets.fromLTRB(47, 0, 34, 0));
  });

  test('a square viewport counts as landscape', () {
    expect(resolveLandscapeStage(const Size(500, 500), EdgeInsets.zero).quarterTurns, 0);
  });

  test('the console layout keeps its width and follows the shape within limits', () {
    expect(meterConsoleLayout(const Size(1640, 720)), const Size(820, 360));
    expect(meterConsoleLayout(const Size(1000, 600)), const Size(820, 492));
    expect(meterConsoleLayout(const Size(2000, 400)), const Size(820, 360), reason: 'never shorter than the keys need');
    expect(meterConsoleLayout(const Size(800, 800)), const Size(820, 600), reason: 'never taller than it can fill');
    expect(meterConsoleLayout(Size.zero), const Size(820, 360));
  });
}
