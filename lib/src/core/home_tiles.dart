/// The home page's added sections (Display Settings → Home page): a tile row
/// (a heading, then square tiles with a caption under each, scrolling
/// sideways, and a last "see all" tile), a wide tile row (wider tiles with a
/// second line and a corner label, such as a route, its price and its time)
/// and promo cards (small coloured cards with words). Each tile opens its own
/// page and can be switched off. Pure.
library;

import 'home_layout.dart';
import 'service_boxes.dart' show BoxAnchor, argbHex, badgeFills, badgeInks, parseArgb;

/// Tile backgrounds the admin picks from (none: the box colour).
const tileBackgrounds = [
  0xFFF1F0EC, 0xFFC6F135, 0xFFFFE1D3, 0xFFD6E8FF, 0xFFDDF7C9, 0xFFFFF0B8, 0xFFEAD9FF, 0xFF2E5D7A, 0xFF7A4A2E, 0xFF1E2127,
];

/// Corner label colours: the badge's.
const tileLabelFills = badgeFills;
const tileLabelInks = badgeInks;

/// Tiles across the screen; a little of the next one shows past them.
const tilesAcrossChoices = [2, 3, 4];

/// Picture size, % of the picture's height: 30 to 140, 80 unless set.
const tilePictureMin = 30;
const tilePictureMax = 140;
const tilePictureDefault = 80;

/// A wide tile's picture is this much as high as it is wide.
const wideTileAspect = 0.56;

/// The gap between tiles.
const tileGap = 8.0;

/// How wide each tile is in a row [available] wide showing [across] of
/// them and a sliver of the next.
double tileWidth(double available, int across) => (available - tileGap * across) / (across + 0.15);

class HomeTile {
  const HomeTile(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id'] ?? ''}';
  bool get on => raw['on'] != false;

  String _s(String k) => '${raw[k] ?? ''}'.trim();

  /// The words under the tile (on a promo card, on it).
  String get caption => _s('caption');

  /// A wide tile's second line ("From RM 180").
  String get sub => _s('sub');

  /// The corner label ("2 hours", "-20%"); empty for none.
  String get label => _s('label');
  int get labelFill => parseArgb(raw['labelBg']) ?? 0xFF1E2127;
  int get labelInk => parseArgb(raw['labelFg']) ?? 0xFFFFFFFF;
  BoxAnchor get labelAt => BoxAnchor.of(raw['labelAt'], BoxAnchor.bottomRight);

  String? get iconName => _s('iconName').isEmpty ? null : _s('iconName');

  /// A picture that fills the tile; the icon stands in without one.
  String? get imageUri => _s('imageUri').isEmpty ? null : _s('imageUri');

  /// The tile's background; null for the box colour.
  int? get background => parseArgb(raw['bg']);

  double get size {
    final v = raw['size'];
    final n = v is num ? v.toDouble() : double.tryParse('$v');
    return (n ?? tilePictureDefault).clamp(tilePictureMin, tilePictureMax).toDouble();
  }

  /// Where a tap goes in this app; null shows Coming Soon.
  String? get route => _s('route').isEmpty ? null : _s('route');

  HomeTile copyWith(Map<String, dynamic> patch) => HomeTile({...raw, ...patch}..removeWhere((k, v) => v == null));
}

/// A tile row's or wide tile row's heading and settings, and any section's
/// tiles (in order, switched off ones too).
extension HomeTileSection on HomeSection {
  String get title => '${raw['title'] ?? ''}'.trim();
  String? get headingIcon => '${raw['iconName'] ?? ''}'.trim().isEmpty ? null : '${raw['iconName']}'.trim();
  String? get headingRoute => '${raw['route'] ?? ''}'.trim().isEmpty ? null : '${raw['route']}'.trim();

  int get across {
    final v = raw['across'];
    final n = v is num ? v.round() : int.tryParse('$v');
    final d = type == HomeSectionType.wide ? 2 : 3;
    return tilesAcrossChoices.contains(n) ? n! : d;
  }

  /// The last tile's words ("Order groceries"); empty for none. It opens
  /// what the heading opens.
  String get seeAll => '${raw['seeAll'] ?? ''}'.trim();

  List<HomeTile> get tiles => [
        if (raw['items'] is List)
          for (final t in raw['items'] as List)
            if (t is Map) HomeTile(Map<String, dynamic>.from(t)),
      ];

  List<HomeTile> get shownTiles => [for (final t in tiles) if (t.on) t];
}

String _id(String p) => '$p-${DateTime.now().microsecondsSinceEpoch}';

/// A new section of [type] (a tile row, wide tile row or promo cards) with
/// one tile to start from.
HomeSection newTileSection(HomeSectionType type) => HomeSection({
      'id': _id(type.key),
      'type': type.key,
      'on': true,
      if (type != HomeSectionType.promos) ...{'title': 'New section', 'across': type == HomeSectionType.wide ? 2 : 3},
      'items': [newTile(type).raw],
    });

/// A new tile, closed (Coming Soon) until it is given a page.
HomeTile newTile(HomeSectionType type) => HomeTile({
      'id': _id('tile'),
      'on': true,
      'caption': type == HomeSectionType.promos ? 'New card' : 'New tile',
      'iconName': 'Package',
      if (type == HomeSectionType.promos) 'bg': argbHex(0xFFFFE1D3),
    });

/// The section's tiles set to [tiles].
HomeSection withTiles(HomeSection s, List<HomeTile> tiles) => s.copyWith({'items': [for (final t in tiles) t.raw]});
