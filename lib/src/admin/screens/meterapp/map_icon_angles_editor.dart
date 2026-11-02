// Media Gallery › Upload › Map Icon › Multi-angle (migration 0336): one
// vehicle drawn from several directions. The admin picks how many angles
// (8, 16, 24, 36 or 72) and fills each slot one at a time, or uploads a ZIP
// with one picture per angle (core/map_icon_angles.dart reads the headings
// from the file names). A grid shows every frame, missing ones marked, and
// a spin preview shows which frame a heading picks.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../../core/background_removal.dart';
import '../../../core/map_icon_angles.dart';
import 'media_upload_dialog.dart' show Checkerboard, MediaFile, mediaFilePickerProvider;

/// Asks for a ZIP of frames; null when cancelled. Overridden in tests.
final mediaZipPickerProvider = Provider<Future<MediaFile?> Function()>((ref) => () async {
  final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['zip']);
  final f = files.firstOrNull;
  if (f == null) return null;
  return (bytes: await f.readAsBytes(), name: f.name);
});

/// One angle's picture as chosen: kept as sent until Save processes it.
class AngleFrame {
  AngleFrame({required this.deg, required this.name, required this.bytes, required this.mime, required this.small});

  /// Whole degrees, 0-359, as stored.
  final int deg;
  final String name;
  final Uint8List bytes;
  final String mime;

  /// A small copy for the grid.
  final img.Image small;

  /// The small copy after "Remove background", as PNG.
  Uint8List? after;
}

/// The picture types an angle may be.
const _frameMimes = {'image/png', 'image/jpeg', 'image/webp'};

String? _frameMime(String name) {
  final dot = name.lastIndexOf('.');
  return switch (dot < 0 ? '' : name.substring(dot + 1).toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    _ => null,
  };
}

/// The frames of a ZIP read off the UI thread when it is big.
Future<({List<ZipFrame> frames, String? error, bool spread})> _readZip(Uint8List bytes) =>
    bytes.length < 512 * 1024 ? Future.value(readZipFrames(bytes)) : compute(readZipFrames, bytes);

class MapIconAnglesEditor extends ConsumerStatefulWidget {
  const MapIconAnglesEditor({
    super.key,
    required this.remove,
    required this.strength,
    required this.onChanged,
    this.enabled = true,
    this.onZipName,
  });

  /// "Remove background" and its strength, for the previews.
  final bool remove;
  final double strength;
  final bool enabled;

  /// The frames on the chosen angles, by heading, after every change.
  final ValueChanged<List<AngleFrame>> onChanged;

  /// A ZIP was read: its file name, to suggest a name.
  final ValueChanged<String>? onZipName;

  @override
  ConsumerState<MapIconAnglesEditor> createState() => _MapIconAnglesEditorState();
}

class _MapIconAnglesEditorState extends ConsumerState<MapIconAnglesEditor> {
  /// The angles offered: a count, or null for the ZIP's own.
  int? _count = mapIconDefaultFrames;
  List<int> _zipDegrees = const [];
  final _frames = <int, AngleFrame>{};
  String? _error, _note;
  bool _busy = false;

  List<double> get _slots => _count == null ? [for (final d in _zipDegrees) d.toDouble()] : mapIconSlots(_count!);

  @override
  void didUpdateWidget(MapIconAnglesEditor old) {
    super.didUpdateWidget(old);
    if (old.remove != widget.remove || old.strength != widget.strength) {
      for (final f in _frames.values) {
        f.after = null;
        _after(f);
      }
    }
  }

  void _after(AngleFrame f) => f.after ??= previewAfter(f.small, remove: widget.remove, strength: widget.strength);

  void _changed() {
    final degs = {for (final s in _slots) storedDegree(s)};
    _frames.removeWhere((d, _) => !degs.contains(d));
    widget.onChanged([for (final d in (_frames.keys.toList()..sort())) _frames[d]!]);
  }

  void _setCount(int? c) => setState(() {
    _count = c;
    _error = null;
    _note = null;
    _changed();
  });

  /// [bytes] as a frame for [deg], or the reason it can't be one.
  (AngleFrame?, String?) _frame(int deg, String name, Uint8List bytes) {
    final mime = _frameMime(name);
    if (mime == null || !_frameMimes.contains(mime)) {
      return (null, '"$name" is not a PNG, JPG or WebP picture.');
    }
    if (bytes.length > mapIconFrameMaxBytes) {
      return (null, '"$name" is over ${mapIconFrameMaxBytes ~/ (1024 * 1024)} MB. Each angle must be smaller.');
    }
    final small = previewImage(bytes, maxSide: 96);
    if (small == null) return (null, '"$name" could not be read as a picture.');
    final f = AngleFrame(deg: deg, name: name, bytes: bytes, mime: mime, small: small);
    _after(f);
    return (f, null);
  }

  Future<void> _uploadOne(double slot) async {
    final picked = await ref.read(mediaFilePickerProvider)();
    if (picked == null || !mounted) return;
    final (f, problem) = _frame(storedDegree(slot), picked.name, picked.bytes);
    setState(() {
      _error = problem;
      _note = null;
      if (f != null) _frames[f.deg] = f;
      _changed();
    });
  }

  Future<void> _uploadZip() async {
    final picked = await ref.read(mediaZipPickerProvider)();
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    final read = await _readZip(picked.bytes);
    if (!mounted) return;
    if (read.error != null) {
      return setState(() {
        _busy = false;
        _error = read.error;
        _note = null;
      });
    }
    final frames = <int, AngleFrame>{};
    for (final z in read.frames) {
      final (f, problem) = _frame(z.deg, z.name, z.bytes);
      if (f == null) {
        return setState(() {
          _busy = false;
          _error = problem;
          _note = null;
        });
      }
      frames[f.deg] = f;
    }
    setState(() {
      _busy = false;
      _error = null;
      _count = null;
      _zipDegrees = frames.keys.toList()..sort();
      _frames
        ..clear()
        ..addAll(frames);
      _note = read.spread
          ? '${frames.length} angles read from the ZIP. Their names had no angles, so they are spread evenly round 360° in name order.'
          : '${frames.length} angles read from the ZIP, each from the number in its name.';
      _changed();
    });
    widget.onZipName?.call(picked.name);
  }

  Widget _slot(double slot) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final deg = storedDegree(slot);
    final f = _frames[deg];
    final on = widget.enabled && !_busy;
    return Container(
      key: ValueKey('map-angle-slot-$deg'),
      width: 104,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: f == null ? cs.error : cs.outlineVariant),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(degreeLabel(slot), style: t.textTheme.labelMedium),
        const SizedBox(height: 4),
        Container(
          width: 64,
          height: 64,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
          child: f == null
              ? Center(
                  child: Text('Missing',
                      key: ValueKey('map-angle-missing-$deg'),
                      style: t.textTheme.labelSmall?.copyWith(color: cs.error)),
                )
              : CustomPaint(
                  painter: Checkerboard.of(context),
                  child: Image.memory(f.after!, key: ValueKey('map-angle-image-$deg'), fit: BoxFit.contain, gaplessPlayback: true),
                ),
        ),
        const SizedBox(height: 2),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Flexible(
            child: TextButton(
              key: ValueKey('map-angle-upload-$deg'),
              style: TextButton.styleFrom(minimumSize: const Size(0, 32), padding: const EdgeInsets.symmetric(horizontal: 4)),
              onPressed: on ? () => _uploadOne(slot) : null,
              child: Text(f == null ? 'Upload' : 'Replace'),
            ),
          ),
          if (f != null)
            IconButton(
              key: ValueKey('map-angle-clear-$deg'),
              tooltip: 'Clear',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: on
                  ? () => setState(() {
                      _frames.remove(deg);
                      _changed();
                    })
                  : null,
              icon: const Icon(Icons.close),
            ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final slots = _slots;
    final have = _frames.length;
    final on = widget.enabled && !_busy;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('Angles', style: t.textTheme.labelLarge),
      const SizedBox(height: 4),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final c in mapIconFrameCounts)
          ChoiceChip(
            key: ValueKey('map-angles-count-$c'),
            label: Text('$c'),
            selected: _count == c,
            onSelected: on ? (_) => _setCount(c) : null,
          ),
        ChoiceChip(
          key: const ValueKey('map-angles-count-zip'),
          label: const Text('From the ZIP'),
          selected: _count == null,
          onSelected: on ? (_) => _setCount(null) : null,
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        OutlinedButton.icon(
          key: const ValueKey('map-angles-zip'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: on ? _uploadZip : null,
          icon: _busy
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.folder_zip_outlined),
          label: const Text('Upload ZIP'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'One picture per angle, up to $mapIconMaxFrames. Name them by angle (car_045.png) '
            'or in order (frame_01, frame_02 …). Up to ${mapIconZipMaxBytes ~/ (1024 * 1024)} MB.',
            style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ]),
      if (_note != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_note!, key: const ValueKey('map-angles-note'), style: t.textTheme.bodySmall),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_error!, key: const ValueKey('map-angles-error'), style: TextStyle(color: cs.error)),
        ),
      const SizedBox(height: 10),
      Text(
        slots.isEmpty
            ? 'Upload a ZIP to fill the angles.'
            : '$have of ${slots.length} angles. ${have < mapIconMinFrames ? 'Add at least $mapIconMinFrames to save.' : 'Missing angles show the nearest one.'}',
        key: const ValueKey('map-angles-count'),
        style: t.textTheme.bodySmall,
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final s in slots) _slot(s)]),
      if (have > 0) ...[
        const SizedBox(height: 12),
        MapIconSpin(
          degrees: _frames.keys.toList()..sort(),
          frame: (deg, size) => _frames[deg]?.after == null
              ? const SizedBox.shrink()
              : Image.memory(_frames[deg]!.after!, width: size, height: size, fit: BoxFit.contain, gaplessPlayback: true),
        ),
      ],
    ]);
  }
}

/// The spin preview: a slider over the car's heading and the frame that
/// heading shows (the nearest one, drawn as it is, not turned).
class MapIconSpin extends StatefulWidget {
  const MapIconSpin({super.key, required this.degrees, required this.frame, this.size = 88});

  /// The headings that have a frame.
  final List<int> degrees;
  final Widget Function(int deg, double size) frame;
  final double size;

  @override
  State<MapIconSpin> createState() => _MapIconSpinState();
}

class _MapIconSpinState extends State<MapIconSpin> {
  double _heading = 0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final picked = nearestAngle([for (final d in widget.degrees) MediaAngle(d, '')], _heading);
    return Container(
      key: const ValueKey('map-icon-spin'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Row(children: [
        Container(
          width: widget.size,
          height: widget.size,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
          child: CustomPaint(
            painter: Checkerboard.of(context),
            child: Center(
              child: picked == null
                  ? const SizedBox.shrink()
                  : KeyedSubtree(key: ValueKey('map-icon-spin-frame-${picked.deg}'), child: widget.frame(picked.deg, widget.size)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Spin preview', style: t.textTheme.labelLarge),
            Slider(
              key: const ValueKey('map-icon-spin-heading'),
              min: 0,
              max: 359,
              divisions: 359,
              value: _heading,
              label: '${_heading.round()}°',
              onChanged: (v) => setState(() => _heading = v),
            ),
            Text(
              picked == null
                  ? 'No angles yet'
                  : 'Heading ${_heading.round()}° shows the ${picked.deg}° picture',
              key: const ValueKey('map-icon-spin-label'),
              style: t.textTheme.bodySmall,
            ),
          ]),
        ),
      ]),
    );
  }
}
