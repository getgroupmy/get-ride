/// The iPhone Duo's folded-cover home layout (Admin → Display Settings → Duo
/// cover home). A separate, admin-configurable layout the app uses ONLY on an
/// iPhone Duo folded onto its cover screen — never on an ordinary phone, a
/// tablet, the Duo's unfolded inner display, the web, or a non-iOS flip/fold
/// (those keep the current build's behaviour). Off by default: until an admin
/// turns it on, the cover shows the normal home.
///
/// This slice is the pure config + the gate only; the admin editor and the
/// home-screen render come in later slices. Tested in test/cover_home_test.dart.
library;

import 'launch_destination.dart' show isFoldedCoverSize;

/// The blob key the config lives under.
const coverHomeKey = 'coverHome';

/// The reserved strip's width, in logical points — clamped to this range so a
/// value can never swallow the whole screen or shrink to nothing.
const coverStripMinWidth = 48.0;
const coverStripMaxWidth = 120.0;
const coverStripDefaultWidth = 74.0;

/// Which side of the cover screen the reserved region (camera / sensors) sits
/// on, and so which side the sheet is trimmed on and the map controls move to.
enum CoverStripSide { left, right }

CoverStripSide _sideOf(Object? v) => '${v ?? ''}' == 'left' ? CoverStripSide.left : CoverStripSide.right;

/// The floating buttons on the cover home that the admin can reposition, each
/// independently: the top-left menu, and the bottom-right map-control stack
/// (overlays, map type, recenter). Each carries its own [CoverButtonOffset].
enum CoverButton { menu, overlays, mapType, recenter }

/// A single button's nudge off its default spot, in logical points: [dx] to the
/// right, [dy] down (so negatives move it left / up). Clamped to
/// [coverButtonOffsetLimit].
typedef CoverButtonOffset = ({double dx, double dy});

/// How far one up/down/left/right tap moves a button, and the furthest a button
/// may be nudged from its default on each axis.
const coverButtonNudgeStep = 8.0;
const coverButtonOffsetLimit = 400.0;

String _buttonKey(CoverButton b) => switch (b) {
      CoverButton.menu => 'menu',
      CoverButton.overlays => 'overlays',
      CoverButton.mapType => 'mapType',
      CoverButton.recenter => 'recenter',
    };

double _clampOffset(Object? v) {
  final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
  return (n ?? 0).clamp(-coverButtonOffsetLimit, coverButtonOffsetLimit).toDouble();
}

Map<CoverButton, CoverButtonOffset> _offsetsOf(Object? raw) {
  final m = raw is Map ? raw : const <dynamic, dynamic>{};
  return <CoverButton, CoverButtonOffset>{
    for (final b in CoverButton.values)
      b: () {
        final cell = m[_buttonKey(b)];
        final cm = cell is Map ? cell : const <dynamic, dynamic>{};
        return (dx: _clampOffset(cm['dx']), dy: _clampOffset(cm['dy']));
      }(),
  };
}

Map<String, dynamic> _offsetsToMap(Map<CoverButton, CoverButtonOffset> o) => <String, dynamic>{
      for (final b in CoverButton.values)
        _buttonKey(b): <String, dynamic>{'dx': (o[b] ?? (dx: 0.0, dy: 0.0)).dx, 'dy': (o[b] ?? (dx: 0.0, dy: 0.0)).dy},
    };

double _clampWidth(Object? v) {
  final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
  return (n ?? coverStripDefaultWidth).clamp(coverStripMinWidth, coverStripMaxWidth).toDouble();
}

/// The cover-home layout as the admin set it. Pure data.
class CoverHomeConfig {
  const CoverHomeConfig({
    required this.enabled,
    required this.stripSide,
    required this.stripWidth,
    required this.trimSheet,
    required this.controlsInStrip,
    required this.offsets,
  });

  /// The master switch: the cover layout is used only when this is on.
  final bool enabled;

  /// Where the reserved strip sits.
  final CoverStripSide stripSide;

  /// The strip's width in logical points.
  final double stripWidth;

  /// Whether the booking sheet stops before the strip (so the map shows there)
  /// rather than running full width under it.
  final bool trimSheet;

  /// Whether the map controls (layer + recenter) move into the strip — keeping
  /// their current vertical height — instead of hugging the screen edge.
  final bool controlsInStrip;

  /// Each floating button's own nudge off its default spot. Always carries an
  /// entry for every [CoverButton] (zero when untouched).
  final Map<CoverButton, CoverButtonOffset> offsets;

  /// One button's offset (zero when not set).
  CoverButtonOffset offsetFor(CoverButton b) => offsets[b] ?? (dx: 0.0, dy: 0.0);

  factory CoverHomeConfig.fromMap(Object? raw) {
    final m = raw is Map ? raw : const <dynamic, dynamic>{};
    return CoverHomeConfig(
      enabled: m['enabled'] == true,
      stripSide: _sideOf(m['stripSide']),
      stripWidth: _clampWidth(m['stripWidth']),
      trimSheet: m['trimSheet'] != false,
      controlsInStrip: m['controlsInStrip'] != false,
      offsets: _offsetsOf(m['buttons']),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'enabled': enabled,
        'stripSide': stripSide == CoverStripSide.left ? 'left' : 'right',
        'stripWidth': stripWidth,
        'trimSheet': trimSheet,
        'controlsInStrip': controlsInStrip,
        'buttons': _offsetsToMap(offsets),
      };
}

/// The off-by-default config (a brand-new blob, or one without the key).
Map<String, dynamic> defaultCoverHomeMap() => CoverHomeConfig.fromMap(null).toMap();

/// Cleans a stored (or half-typed) config into the shape the rest of the code
/// relies on; anything unreadable falls back to the defaults.
Map<String, dynamic> normalizeCoverHome(Object? raw) => CoverHomeConfig.fromMap(raw).toMap();

/// The cover-home config in [settings].
CoverHomeConfig coverHomeFromSettings(Map<String, dynamic> settings) => CoverHomeConfig.fromMap(settings[coverHomeKey]);

/// Whether the admin has turned the cover layout on.
bool coverHomeEnabled(Map<String, dynamic> settings) => coverHomeFromSettings(settings).enabled;

/// Whether the cover-home layout should be used for the window the app is in
/// right now. True ONLY on an iPhone Duo folded onto its cover screen, with the
/// layout switched on:
///
/// * [ios] (and not [web]) rules out every non-iOS flip/fold and the web — they
///   keep the current build's behaviour;
/// * [isFoldedCoverSize] rules out ordinary iPhones, tablets and the Duo's
///   unfolded inner display — on iOS it only ever matches the Duo's cover,
///   which carries a wide horizontal safe-area inset no ordinary iPhone has in
///   portrait.
///
/// Pure: the caller passes the platform and the live window metrics.
bool duoCoverHomeActive({
  required bool ios,
  required bool web,
  required double width,
  required double height,
  required double horizontalInset,
  required CoverHomeConfig config,
}) =>
    config.enabled && ios && !web && isFoldedCoverSize(width, height, horizontalInset, web: web);

// --- mutators (the admin editor, next slice) --------------------------------

Map<String, dynamic> _withCover(Map<String, dynamic> s, Map<String, dynamic> patch) =>
    <String, dynamic>{...s, coverHomeKey: {...normalizeCoverHome(s[coverHomeKey]), ...patch}};

Map<String, dynamic> setCoverHomeEnabled(Map<String, dynamic> s, bool on) => _withCover(s, {'enabled': on});

Map<String, dynamic> setCoverHomeStripSide(Map<String, dynamic> s, CoverStripSide side) =>
    _withCover(s, {'stripSide': side == CoverStripSide.left ? 'left' : 'right'});

Map<String, dynamic> setCoverHomeStripWidth(Map<String, dynamic> s, double width) =>
    _withCover(s, {'stripWidth': _clampWidth(width)});

Map<String, dynamic> setCoverHomeTrimSheet(Map<String, dynamic> s, bool on) => _withCover(s, {'trimSheet': on});

Map<String, dynamic> setCoverHomeControlsInStrip(Map<String, dynamic> s, bool on) =>
    _withCover(s, {'controlsInStrip': on});

/// Sets one button's offset (clamped), leaving the other buttons as they are.
Map<String, dynamic> setCoverButtonOffset(Map<String, dynamic> s, CoverButton b, double dx, double dy) {
  final next = <CoverButton, CoverButtonOffset>{
    ...coverHomeFromSettings(s).offsets,
    b: (dx: _clampOffset(dx), dy: _clampOffset(dy)),
  };
  return _withCover(s, {'buttons': _offsetsToMap(next)});
}

/// Nudges one button by [ddx]/[ddy] (an up/down/left/right tap), clamped.
Map<String, dynamic> nudgeCoverButton(Map<String, dynamic> s, CoverButton b, double ddx, double ddy) {
  final o = coverHomeFromSettings(s).offsetFor(b);
  return setCoverButtonOffset(s, b, o.dx + ddx, o.dy + ddy);
}

/// Puts one button back on its default spot.
Map<String, dynamic> resetCoverButton(Map<String, dynamic> s, CoverButton b) => setCoverButtonOffset(s, b, 0, 0);
