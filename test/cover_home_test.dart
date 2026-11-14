// The iPhone Duo folded-cover home layout (Admin → Display Settings → Duo cover
// home): its config, and the gate that keeps it to the iPhone Duo's cover
// screen only.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/cover_home.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart'
    show defaultDisplaySettings, mergeDisplaySettings;

void main() {
  // The real window metrics the gate is pinned against (as orientation_test.dart
  // uses them): the Duo's folded cover carries a wide horizontal inset no
  // ordinary iPhone has in portrait.
  const duoCover = (w: 466.0, h: 678.0, inset: 84.0); // shortest 466, reserved region
  const iphone = (w: 390.0, h: 844.0, inset: 0.0); // ordinary phone, no side inset
  const tablet = (w: 834.0, h: 1112.0, inset: 0.0);
  const duoInner = (w: 669.0, h: 951.0, inset: 84.0); // unfolded inner: tablet-size

  CoverHomeConfig on() => coverHomeFromSettings(setCoverHomeEnabled(<String, dynamic>{}, true));

  group('config', () {
    test('ships off, with sane defaults', () {
      final c = coverHomeFromSettings(const {});
      expect(c.enabled, isFalse);
      expect(c.stripSide, CoverStripSide.right);
      expect(c.stripWidth, coverStripDefaultWidth);
      expect(c.trimSheet, isTrue);
      expect(c.controlsInStrip, isTrue);
    });

    test('the blob carries a coverHome slot', () {
      expect(defaultDisplaySettings()['coverHome'], isA<Map>());
      expect((defaultDisplaySettings()['coverHome'] as Map)['enabled'], isFalse);
      expect(mergeDisplaySettings(const {})['coverHome'], isA<Map>());
    });

    test('normalize tolerates junk and clamps the width', () {
      final c = coverHomeFromSettings({
        'coverHome': {'enabled': 'yes', 'stripSide': 'nope', 'stripWidth': 9999, 'trimSheet': 'x'}
      });
      expect(c.enabled, isFalse, reason: 'only a real true enables');
      expect(c.stripSide, CoverStripSide.right, reason: 'unknown side falls back');
      expect(c.stripWidth, coverStripMaxWidth, reason: 'clamped');
      expect(c.trimSheet, isTrue, reason: 'default true unless explicitly false');
    });

    test('mutators: enable, side, width (clamped), trim, controls', () {
      var s = <String, dynamic>{};
      s = setCoverHomeEnabled(s, true);
      s = setCoverHomeStripSide(s, CoverStripSide.left);
      s = setCoverHomeStripWidth(s, 5000);
      s = setCoverHomeTrimSheet(s, false);
      s = setCoverHomeControlsInStrip(s, false);
      final c = coverHomeFromSettings(s);
      expect(c.enabled, isTrue);
      expect(c.stripSide, CoverStripSide.left);
      expect(c.stripWidth, coverStripMaxWidth);
      expect(c.trimSheet, isFalse);
      expect(c.controlsInStrip, isFalse);
      // Toggling one setting leaves the rest in place.
      final c2 = coverHomeFromSettings(setCoverHomeStripWidth(s, 60));
      expect(c2.stripWidth, 60);
      expect(c2.stripSide, CoverStripSide.left);
      expect(c2.enabled, isTrue);
    });
  });

  group('the gate: iPhone Duo folded cover only', () {
    bool active(bool ios, bool web, ({double w, double h, double inset}) m, CoverHomeConfig c) =>
        duoCoverHomeActive(ios: ios, web: web, width: m.w, height: m.h, horizontalInset: m.inset, config: c);

    test('on for the iPhone Duo cover when enabled', () {
      expect(active(true, false, duoCover, on()), isTrue);
    });

    test('off until the admin enables it', () {
      expect(active(true, false, duoCover, coverHomeFromSettings(const {})), isFalse);
    });

    test('a non-iOS flip/fold with the same cover metrics is never affected', () {
      expect(active(false, false, duoCover, on()), isFalse, reason: 'Android keeps the current build');
    });

    test('ordinary iPhone, tablet and the unfolded inner display are excluded', () {
      expect(active(true, false, iphone, on()), isFalse);
      expect(active(true, false, tablet, on()), isFalse);
      expect(active(true, false, duoInner, on()), isFalse, reason: 'inner display is tablet-size');
    });

    test('web is excluded', () {
      expect(active(true, true, duoCover, on()), isFalse);
    });
  });
}
