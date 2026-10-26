/// The home page's service boxes as the admin lays them out (Display
/// Settings → Home page → Service boxes): rows of a chosen shape, any number
/// of boxes filling their places in order, each box's picture size and
/// place, and a badge whose words take turns, flipping over. Pure.
library;

import 'dart:math' as math;

/// The shape of one row of boxes: its places, left to right, and whether
/// each is tall (two short rows high).
enum BoxRowKind {
  one('k1', 'One wide', [false]),
  two('k2', 'Two', [false, false]),
  three('k3', 'Three', [false, false, false]),
  twoTall('k2t', 'Two tall', [true, true]),
  bigLeft('kbl', 'Big left', [true, false, false]),
  bigRight('kbr', 'Big right', [true, false, false]);

  const BoxRowKind(this.key, this.label, this.tall);
  final String key;
  final String label;

  /// Per place, in fill order: for Big left / Big right the big box first,
  /// then the two beside it, top then bottom.
  final List<bool> tall;

  int get places => tall.length;

  static BoxRowKind of(Object? key) => values.firstWhere((k) => k.key == key, orElse: () => two);
}

/// Ready-made layouts the admin starts from.
const boxRowPresets = <String, List<String>>{
  'Two big': ['k2t', 'k2'],
  'Big left': ['kbl', 'k2'],
  'Big right': ['kbr', 'k2'],
  'Big left + three': ['kbl', 'k3'],
  'Rows of two': ['k2', 'k2', 'k2'],
};

/// The home screen's boxes before rows: the big box on the left with two
/// beside it, then a row of two.
const legacyBoxRows = ['kbl', 'k2'];

/// Heights, in logical pixels: a short place, and the gap between places
/// (a tall place is two short ones and the gap).
const boxShortHeight = 100.0;
const boxGap = 10.0;
const boxTallHeight = boxShortHeight * 2 + boxGap;

/// One place in the grid: its row, its position in the row, and its height.
typedef BoxPlace = ({int row, int index, bool tall, String name});

List<BoxRowKind> boxRowsOf(Object? raw) => [
      if (raw is List)
        for (final k in raw) BoxRowKind.of(k),
    ];

/// Every place, in fill order, named for the admin ("Row 1 · big left").
List<BoxPlace> boxPlaces(List<BoxRowKind> rows) => [
      for (var r = 0; r < rows.length; r++)
        for (var i = 0; i < rows[r].places; i++)
          (row: r, index: i, tall: rows[r].tall[i], name: 'Row ${r + 1}${_placeName(rows[r], i)}'),
    ];

String _placeName(BoxRowKind k, int i) => switch (k) {
      BoxRowKind.one => '',
      BoxRowKind.two || BoxRowKind.twoTall => const [' · left', ' · right'][i],
      BoxRowKind.three => const [' · left', ' · middle', ' · right'][i],
      BoxRowKind.bigLeft => const [' · big left', ' · right top', ' · right bottom'][i],
      BoxRowKind.bigRight => const [' · big right', ' · left top', ' · left bottom'][i],
    };

/// Where a picture or a badge sits: a corner, an edge's middle or the centre.
enum BoxAnchor {
  topLeft('tl', -1, -1),
  topCenter('tc', 0, -1),
  topRight('tr', 1, -1),
  centerLeft('cl', -1, 0),
  center('cc', 0, 0),
  centerRight('cr', 1, 0),
  bottomLeft('bl', -1, 1),
  bottomCenter('bc', 0, 1),
  bottomRight('br', 1, 1);

  const BoxAnchor(this.key, this.x, this.y);
  final String key;

  /// -1 left / top, 0 middle, 1 right / bottom.
  final int x, y;

  static BoxAnchor of(Object? key, [BoxAnchor fallback = bottomRight]) =>
      values.firstWhere((a) => a.key == key, orElse: () => fallback);

  /// The four corners a badge can take.
  static const corners = [topLeft, topRight, bottomLeft, bottomRight];
}

/// One word of a badge and its colours (ARGB).
class BadgeWord {
  const BadgeWord(this.text, {this.fill = badgeRed, this.ink = 0xFFFFFFFF});

  final String text;
  final int fill;
  final int ink;

  factory BadgeWord.fromJson(Object? raw) {
    if (raw is String) return BadgeWord(raw);
    if (raw is! Map) return const BadgeWord('');
    return BadgeWord(
      '${raw['t'] ?? ''}'.trim(),
      fill: parseArgb(raw['bg']) ?? badgeRed,
      ink: parseArgb(raw['fg']) ?? 0xFFFFFFFF,
    );
  }

  Map<String, dynamic> toJson() => {'t': text, 'bg': argbHex(fill), 'fg': argbHex(ink)};

  @override
  bool operator ==(Object other) => other is BadgeWord && other.text == text && other.fill == fill && other.ink == ink;

  @override
  int get hashCode => Object.hash(text, fill, ink);
}

const badgeRed = 0xFFE5483F;
const badgeGreen = 0xFF2E7D32;
const badgeGrey = 0xFF6B6F78;

/// The badge colours the admin picks from, and the word colours.
const badgeFills = [
  badgeRed, badgeGrey, 0xFF1E2127, 0xFFFFFFFF, 0xFFC6F135, 0xFF1F6FEB, badgeGreen, 0xFFF2B33D, 0xFF7C6CF0, 0xFFE57AA6,
];
const badgeInks = [0xFFFFFFFF, 0xFF1B1D22, 0xFFC6F135, badgeRed];

/// The badge a box shows while it isn't open: SOON in grey.
const soonBadge = [BadgeWord('SOON', fill: badgeGrey)];

/// The NEW badge the old switch put on the first box.
const newBadgeWords = [BadgeWord('NEW')];

int? parseArgb(Object? raw) {
  if (raw is int) return raw;
  var s = '${raw ?? ''}'.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) s = 'FF$s';
  if (s.length != 8) return null;
  return int.tryParse(s, radix: 16);
}

String argbHex(int argb) {
  final hex = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
  return hex.startsWith('FF') ? '#${hex.substring(2)}' : '#$hex';
}

/// Picture size, as a share of the box's height: 30% to 160%.
const boxPictureMin = 30;
const boxPictureMax = 160;
const boxPictureDefault = 75;

/// How far the picture moves from its place: -60% to 60% of the box.
const boxShiftMax = 60;

/// Badge word size 9 to 20, 12 unless set; each word 1 to 6 seconds.
const badgeSizeMin = 9.0;
const badgeSizeMax = 20.0;
const badgeSizeDefault = 12.0;
const badgeSecondsMin = 1.0;
const badgeSecondsMax = 6.0;
const badgeSecondsDefault = 2.0;

/// How far the badge moves from its corner, in points.
const badgeShiftMin = -10.0;
const badgeShiftMax = 60.0;

/// How one box looks, read from its stored map (what's not set stays as
/// the home screen drew boxes before).
class BoxLook {
  const BoxLook(this.raw);

  final Map<String, dynamic> raw;

  double _num(String k, double fallback, double lo, double hi) {
    final v = raw[k];
    final n = v is num ? v.toDouble() : double.tryParse('$v');
    return n == null || !n.isFinite ? fallback : n.clamp(lo, hi).toDouble();
  }

  /// Picture size, % of the box's height.
  double get size => _num('size', boxPictureDefault.toDouble(), boxPictureMin.toDouble(), boxPictureMax.toDouble());

  BoxAnchor get anchor => BoxAnchor.of(raw['anchor']);

  /// Sideways and down, % of the box's width and height.
  double get shiftX => _num('x', 0, -boxShiftMax.toDouble(), boxShiftMax.toDouble());
  double get shiftY => _num('y', 0, -boxShiftMax.toDouble(), boxShiftMax.toDouble());

  /// Null: the box's badge as before (SOON while closed, NEW on the first
  /// box with the old switch); false: none; true: the admin's words.
  bool? get badgeOn => raw['badgeOn'] is bool ? raw['badgeOn'] as bool : null;

  List<BadgeWord> get badgeWords => [
        if (raw['badgeWords'] is List)
          for (final w in raw['badgeWords'] as List)
            if (BadgeWord.fromJson(w).text.isNotEmpty) BadgeWord.fromJson(w),
      ];

  bool get flip => raw['flip'] != false;
  double get flipSeconds => _num('flipSecs', badgeSecondsDefault, badgeSecondsMin, badgeSecondsMax);
  double get badgeSize => _num('badgeSize', badgeSizeDefault, badgeSizeMin, badgeSizeMax);
  BoxAnchor get badgeAt => BoxAnchor.of(raw['badgeAt'], BoxAnchor.topRight);
  double get badgeX => _num('badgeX', 0, badgeShiftMin, badgeShiftMax);
  double get badgeY => _num('badgeY', 0, badgeShiftMin, badgeShiftMax);
}

/// The words a badge shows in turn: one when flipping is off.
List<BadgeWord> badgeTurns(List<BadgeWord> words, {required bool flip}) =>
    words.isEmpty ? const [] : (flip ? words : [words.first]);

/// Which word shows [elapsed] after the badge appeared, each for [seconds].
int badgeWordAt(Duration elapsed, int count, double seconds) {
  if (count < 2) return 0;
  final step = math.max(1, (seconds * 1000).round());
  return (elapsed.inMilliseconds ~/ step) % count;
}

/// The places a box's picture takes in a box [w] wide and [h] high:
/// (left, top, side) in logical pixels. It may run past the edges; the box
/// trims it.
({double left, double top, double side}) boxPictureRect(BoxLook look, double w, double h) {
  final side = h * look.size / 100;
  const pad = 14.0;
  // Under the title when it sits at the top.
  const titleRoom = 40.0;
  final a = look.anchor;
  final left = switch (a.x) {
        -1 => pad,
        0 => (w - side) / 2,
        _ => w - side,
      } +
      look.shiftX / 100 * w;
  final top = switch (a.y) {
        -1 => titleRoom,
        0 => (h - side) / 2,
        _ => h - side,
      } +
      look.shiftY / 100 * h;
  return (left: left, top: top, side: side);
}
