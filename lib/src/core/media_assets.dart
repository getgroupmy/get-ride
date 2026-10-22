/// Admin → Display Settings → Media Gallery: the icons, images and logos an
/// admin uploads (table `media_assets`, files in the public `media` bucket,
/// migration 0273), and how the rest of the app points at one.
///
/// A setting that uses an upload stores `media:<id>` (a side menu item's
/// icon, a home box's picture, a vehicle service's image, a Ride Option's
/// picture); the app looks the id up in `media_assets` and shows the file
/// from the bucket's public address. Pure.
library;

import 'icon_pack.dart';

/// What an upload is for: an icon (a 256 × 256 transparent PNG, or an SVG),
/// an image (at most 1600 px wide), or a logo (light and dark versions).
enum MediaKind {
  icon('Icon', 'Icons'),
  image('Image', 'Images'),
  logo('Logo', 'Logos');

  const MediaKind(this.label, this.plural);

  /// As shown: "Icon", "Image", "Logo".
  final String label;

  /// The gallery's tab: "Icons", "Images", "Logos".
  final String plural;

  /// The stored value (`media_assets.kind`).
  String get id => name;

  static MediaKind? byId(Object? v) {
    for (final k in values) {
      if (k.id == v) return k;
    }
    return null;
  }

  /// The largest file the upload dialog takes for this kind.
  int get maxBytes => this == MediaKind.image ? 5 * 1024 * 1024 : 2 * 1024 * 1024;

  /// "2 MB" / "5 MB", for the dialog.
  String get maxLabel => '${maxBytes ~/ (1024 * 1024)} MB';

  /// Whether "Remove background" starts on: icons and logos yes, images no.
  bool get removeBackgroundByDefault => this != MediaKind.image;
}

/// The public bucket the files are in.
const mediaBucket = 'media';

/// The table the records are in.
const mediaAssetsTable = 'media_assets';

/// The prefix of a stored reference to an upload.
const mediaRefPrefix = 'media:';

/// `media:<id>`.
String mediaRef(String id) => '$mediaRefPrefix$id';

/// The id in a `media:<id>` reference; null for anything else.
String? mediaRefId(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  if (!t.startsWith(mediaRefPrefix)) return null;
  final id = t.substring(mediaRefPrefix.length).trim();
  return id.isEmpty ? null : id;
}

/// Whether [v] is drawn from the Media Gallery: a `media:<id>` upload or
/// a `pack:<name>` icon of the built-in pack.
bool isMediaRef(Object? v) => mediaRefId(v) != null || packRefName(v) != null;

/// The file types the dialog takes, by extension.
const mediaExtensions = ['png', 'jpg', 'jpeg', 'webp', 'svg'];

/// The content type of a file named [name] (by its extension); null for a
/// type the gallery does not take.
String? mediaMimeFor(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    _ => null,
  };
}

/// The extension a file of [mime] is stored under.
String mediaExtFor(String mime) => switch (mime) {
  'image/jpeg' => 'jpg',
  'image/webp' => 'webp',
  'image/svg+xml' => 'svg',
  _ => 'png',
};

/// Where an upload's file goes in the bucket: `<kind>/<id>.<ext>`, or
/// `<kind>/<id>-dark.<ext>` for a logo's dark version. The id is in the path,
/// so a search for the id also finds a setting that kept the file's address.
String mediaPath(MediaKind kind, String id, String mime, {bool dark = false}) =>
    '${kind.id}/$id${dark ? '-dark' : ''}.${mediaExtFor(mime)}';

/// The public address of [path] in the bucket on the project at [baseUrl].
String mediaPublicUrl(String baseUrl, String path) {
  final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  return '$base/storage/v1/object/public/$mediaBucket/$path';
}

/// The bucket path in a public address of a file in the `media` bucket; null
/// for any other address.
String? mediaPathInUrl(String url) {
  const marker = '/storage/v1/object/public/$mediaBucket/';
  final i = url.indexOf(marker);
  if (i < 0) return null;
  final rest = url.substring(i + marker.length).split('?').first;
  return rest.isEmpty ? null : Uri.decodeComponent(rest);
}

/// One upload (a `media_assets` row).
class MediaAsset {
  const MediaAsset({
    required this.id,
    required this.kind,
    required this.name,
    this.path,
    this.darkPath,
    this.mime = 'image/png',
    this.width,
    this.height,
    this.bytes,
    this.tint = false,
    this.createdAt,
  });

  final String id;
  final MediaKind kind;
  final String name;

  /// The file (a logo's light version); null for a logo with a dark one only.
  final String? path;

  /// A logo's dark-mode version.
  final String? darkPath;
  final String mime;
  final int? width, height, bytes;

  /// "Follow the theme colour": a one-colour icon drawn in the theme's icon
  /// colour instead of its own.
  final bool tint;
  final DateTime? createdAt;

  /// The stored reference: `media:<id>`.
  String get ref => mediaRef(id);

  bool get isSvg => mime == 'image/svg+xml';

  /// The file for [dark] mode: a logo's dark version in dark mode when it has
  /// one, else whichever it has.
  String? pathFor({required bool dark}) => dark ? (darkPath ?? path) : (path ?? darkPath);

  static MediaAsset? fromRow(Map<String, dynamic> r) {
    final kind = MediaKind.byId(r['kind']);
    final id = r['id'];
    if (kind == null || id is! String || id.isEmpty) return null;
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    int? n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    final path = s(r['path']), dark = s(r['dark_path']);
    if (path == null && dark == null) return null;
    return MediaAsset(
      id: id,
      kind: kind,
      name: s(r['name']) ?? 'Untitled',
      path: path,
      darkPath: dark,
      mime: s(r['mime']) ?? 'image/png',
      width: n(r['width']),
      height: n(r['height']),
      bytes: n(r['bytes']),
      tint: r['tint'] == true,
      createdAt: DateTime.tryParse('${r['created_at'] ?? ''}'),
    );
  }

  Map<String, dynamic> toRow() => {
    'id': id,
    'kind': kind.id,
    'name': name,
    'path': path,
    'dark_path': darkPath,
    'mime': mime,
    'width': width,
    'height': height,
    'bytes': bytes,
    'tint': tint,
  };
}

/// The longest name an upload may have.
const mediaNameMax = 80;

/// What is wrong with [name] for an upload, or null.
String? mediaNameProblem(String name) {
  final t = name.trim();
  if (t.isEmpty) return 'Give it a name.';
  if (t.length > mediaNameMax) return 'Keep the name under $mediaNameMax characters.';
  return null;
}
