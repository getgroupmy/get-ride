/// Multi-angle map icons (migration 0336): one vehicle drawn from several
/// directions, one frame per compass heading, kept in `media_assets.angles`
/// as `[{deg, path}]` with the files at `map_icon/<id>/<ddd>.png`.
///
/// Pure: the frame list, the slots the upload dialog offers, how a ZIP's
/// file names become headings, and which frame a car heading shows.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One frame of a multi-angle map icon: the vehicle seen heading [deg]
/// (0 = facing north / up the screen, clockwise), in the bucket at [path].
class MediaAngle {
  const MediaAngle(this.deg, this.path);

  /// Whole degrees, 0-359.
  final int deg;
  final String path;

  Map<String, dynamic> toJson() => {'deg': deg, 'path': path};

  /// The frames in a stored `angles` value, sorted by heading, the bad ones
  /// left out; empty for anything that isn't a list.
  static List<MediaAngle> listFrom(Object? raw) {
    if (raw is! List) return const [];
    final out = <int, MediaAngle>{};
    for (final f in raw) {
      if (f is! Map) continue;
      final d = f['deg'], p = f['path'];
      if (d is! num || p is! String || p.trim().isEmpty) continue;
      final deg = d.round();
      if (deg < 0 || deg > 359) continue;
      out.putIfAbsent(deg, () => MediaAngle(deg, p.trim()));
    }
    return out.values.toList()..sort((a, b) => a.deg.compareTo(b.deg));
  }

  @override
  bool operator ==(Object other) => other is MediaAngle && other.deg == deg && other.path == path;

  @override
  int get hashCode => Object.hash(deg, path);

  @override
  String toString() => 'MediaAngle($deg, $path)';
}

/// The fewest and most frames a multi-angle icon has (the server checks
/// the same).
const mapIconMinFrames = 2;
const mapIconMaxFrames = 72;

/// The frame counts the upload dialog offers, and the one it starts on.
const mapIconFrameCounts = [8, 16, 24, 36, 72];
const mapIconDefaultFrames = 16;

/// The largest frame, and the largest ZIP, the dialog takes.
const mapIconFrameMaxBytes = 2 * 1024 * 1024;
const mapIconZipMaxBytes = 20 * 1024 * 1024;

/// The headings of [count] frames spread evenly round the compass, from 0°:
/// 0, 22.5, 45, … for 16.
List<double> mapIconSlots(int count) => [for (var i = 0; i < count; i++) 360 * i / count];

/// [deg] as stored: whole degrees, 0-359 (22.5 is kept as 23).
int storedDegree(num deg) => ((deg % 360).round()) % 360;

/// "0°", "22.5°", "45°": a heading as the dialog writes it.
String degreeLabel(num deg) {
  final d = deg % 360;
  final whole = d.roundToDouble() == d;
  return '${whole ? d.round() : d.toStringAsFixed(1)}°';
}

/// Where frame [deg] of upload [id] goes in the bucket:
/// `map_icon/<id>/<ddd>.png` (or `.webp`).
String mapIconFramePath(String id, int deg, String mime) =>
    'map_icon/$id/${deg.toString().padLeft(3, '0')}.${mime == 'image/webp' ? 'webp' : 'png'}';

/// How far apart two headings are round the compass, 0-180.
double headingGap(double a, double b) {
  final d = ((a - b) % 360 + 360) % 360;
  return d > 180 ? 360 - d : d;
}

/// The frame of [frames] nearest [heading] (degrees, any value: it wraps
/// round 360, so 350° picks the 0° frame over the 315° one). A tie goes to
/// the lower heading. Null when there are no frames.
MediaAngle? nearestAngle(List<MediaAngle> frames, double heading) {
  MediaAngle? best;
  var gap = double.infinity;
  for (final f in frames) {
    final g = headingGap(heading, f.deg.toDouble());
    if (g < gap - 1e-9 || (g <= gap + 1e-9 && best != null && f.deg < best.deg)) {
      best = f;
      gap = g;
    }
  }
  return best;
}

// ---- A ZIP of frames -------------------------------------------------------------------------------------

/// One picture of a ZIP and the heading it was given.
typedef ZipFrameName = ({String name, int deg});

/// How a ZIP's file names became headings: [frames] in heading order, or
/// [error] (plain words, for the dialog). [spread] when the names were a
/// plain sequence and the frames were spread evenly round 360°.
class ZipFrameMapping {
  const ZipFrameMapping._(this.frames, this.error, {this.spread = false, this.skipped = 0});
  const ZipFrameMapping.error(String error) : this._(const [], error);

  final List<ZipFrameName> frames;
  final String? error;
  final bool spread;

  /// Files left out: __MACOSX, hidden files, folders.
  final int skipped;

  bool get ok => error == null;
}

/// The picture types a frame may be.
const _frameExtensions = {'png', 'jpg', 'jpeg', 'webp'};

String _baseName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isEmpty ? path : parts.last;
}

String _ext(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// Whether [path] in a ZIP is something a computer added, not a frame:
/// the Mac's __MACOSX folder and ._ copies, any hidden file or folder
/// (.DS_Store), Windows' Thumbs.db and desktop.ini, or a folder itself.
bool isZipJunk(String path) {
  if (path.endsWith('/') || path.endsWith('\\')) return true;
  final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return true;
  if (parts.any((p) => p == '__MACOSX' || p.startsWith('.'))) return true;
  final base = parts.last.toLowerCase();
  return base == 'thumbs.db' || base == 'desktop.ini';
}

/// Compares two names as people read them: "frame_2" before "frame_10".
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final pa = re.allMatches(a.toLowerCase()).toList(), pb = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final x = pa[i].group(0)!, y = pb[i].group(0)!;
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

/// The last number in [name]'s base name without its extension
/// (`car_045.png` 45, `angle-090.webp` 90, `blue2_180.png` 180); null when
/// it has none.
int? numberInName(String name) {
  final base = _baseName(name);
  final dot = base.lastIndexOf('.');
  final stem = dot < 0 ? base : base.substring(0, dot);
  final all = RegExp(r'\d+').allMatches(stem).toList();
  if (all.isEmpty) return null;
  return int.tryParse(all.last.group(0)!);
}

/// Gives each picture in a ZIP ([paths], every entry's name) its heading:
///  * __MACOSX, hidden files and folders are left out;
///  * anything else that isn't a PNG, JPG or WebP is refused, as are more
///    than 72 pictures or fewer than 2;
///  * a number in each name is its heading (`car_045.png`, `45.png`,
///    `angle-090.webp`), 0-359, no heading twice;
///  * names that are just a sequence (`frame_01` … `frame_16`: numbers
///    counting up by one from 0 or 1, or no numbers at all) are spread
///    evenly round 360° in name order.
ZipFrameMapping mapZipFrameNames(List<String> paths) {
  final pictures = <String>[];
  final notPictures = <String>[];
  var skipped = 0;
  for (final p in paths) {
    if (isZipJunk(p)) {
      skipped++;
      continue;
    }
    if (_frameExtensions.contains(_ext(p))) {
      pictures.add(p);
    } else {
      notPictures.add(_baseName(p));
    }
  }
  if (notPictures.isNotEmpty) {
    final shown = notPictures.take(3).join(', ');
    final more = notPictures.length > 3 ? ' and ${notPictures.length - 3} more' : '';
    return ZipFrameMapping.error(
      'The ZIP has files that are not pictures: $shown$more. Keep only PNG, JPG or WebP frames in it.',
    );
  }
  if (pictures.length > mapIconMaxFrames) {
    return ZipFrameMapping.error(
      'The ZIP has ${pictures.length} pictures. A map icon takes at most $mapIconMaxFrames angles.',
    );
  }
  if (pictures.length < mapIconMinFrames) {
    return ZipFrameMapping.error(pictures.isEmpty
        ? 'The ZIP has no PNG, JPG or WebP pictures in it.'
        : 'The ZIP has only one picture. A multi-angle icon needs at least $mapIconMinFrames.');
  }
  pictures.sort((a, b) => naturalCompare(_baseName(a), _baseName(b)));
  final numbers = [for (final p in pictures) numberInName(p)];
  final sorted = numbers.whereType<int>().toList()..sort();
  final allNumbered = sorted.length == pictures.length;
  final counting = allNumbered &&
      (sorted.first == 0 || sorted.first == 1) &&
      sorted.last - sorted.first == sorted.length - 1 &&
      sorted.toSet().length == sorted.length &&
      // 0, 1 alone could as well be degrees; three or more counting up by
      // one from 0 or 1 can't sensibly be.
      sorted.length > 2;
  if (allNumbered && !counting) {
    final out = <ZipFrameName>[];
    final seen = <int, String>{};
    for (var i = 0; i < pictures.length; i++) {
      final n = numbers[i]!;
      final name = _baseName(pictures[i]);
      if (n > 359) {
        return ZipFrameMapping.error('"$name" says $n°. Headings go from 0 to 359.');
      }
      final twice = seen[n];
      if (twice != null) {
        return ZipFrameMapping.error('"$twice" and "$name" are both $n°. Give each angle its own picture.');
      }
      seen[n] = name;
      out.add((name: pictures[i], deg: n));
    }
    out.sort((a, b) => a.deg.compareTo(b.deg));
    return ZipFrameMapping._(out, null, skipped: skipped);
  }
  final n = pictures.length;
  return ZipFrameMapping._(
    [for (var i = 0; i < n; i++) (name: pictures[i], deg: storedDegree(360 * i / n))],
    null,
    spread: true,
    skipped: skipped,
  );
}

/// A frame read from a ZIP.
typedef ZipFrame = ({String name, int deg, Uint8List bytes});

/// The frames in ZIP [bytes], or an error in plain words (a ZIP over
/// 20 MB, one that can't be opened, a picture over 2 MB, or one of
/// [mapZipFrameNames]'s).
({List<ZipFrame> frames, String? error, bool spread}) readZipFrames(Uint8List bytes) {
  ({List<ZipFrame> frames, String? error, bool spread}) fail(String e) => (frames: const [], error: e, spread: false);
  if (bytes.length > mapIconZipMaxBytes) {
    return fail('The ZIP is over ${mapIconZipMaxBytes ~/ (1024 * 1024)} MB. Make it smaller, or upload the angles one at a time.');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return fail('This file could not be opened as a ZIP.');
  }
  if (archive.files.isEmpty) return fail('This file could not be opened as a ZIP.');
  final entries = {for (final f in archive.files) f.name: f};
  final names = [for (final f in archive.files) f.isFile ? f.name : '${f.name}/'];
  final mapping = mapZipFrameNames(names);
  if (!mapping.ok) return fail(mapping.error!);
  final out = <ZipFrame>[];
  for (final f in mapping.frames) {
    final entry = entries[f.name]!;
    if (entry.size > mapIconFrameMaxBytes) {
      return fail('"${_baseName(f.name)}" is over ${mapIconFrameMaxBytes ~/ (1024 * 1024)} MB. Each angle must be smaller.');
    }
    final data = entry.content;
    if (data.length > mapIconFrameMaxBytes) {
      return fail('"${_baseName(f.name)}" is over ${mapIconFrameMaxBytes ~/ (1024 * 1024)} MB. Each angle must be smaller.');
    }
    out.add((name: _baseName(f.name), deg: f.deg, bytes: data));
  }
  return (frames: out, error: null, spread: mapping.spread);
}
