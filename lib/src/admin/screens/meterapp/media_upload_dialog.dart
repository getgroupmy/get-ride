// Media Gallery → Upload: an icon, an image or a logo (light and dark
// versions), with the background taken off on this device when asked
// (core/background_removal.dart), a before/after preview on a checkerboard,
// and "Follow the theme colour" for a one-colour icon.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../../core/background_removal.dart';
import '../../../core/media_assets.dart';
import '../../../data/media_repository.dart';
import '../../../widgets/page_style_host.dart';

/// One chosen file.
typedef MediaFile = ({Uint8List bytes, String name});

/// Asks for one file of a type the gallery takes; null when cancelled.
/// Overridden in tests.
final mediaFilePickerProvider = Provider<Future<MediaFile?> Function()>((ref) => () async {
  final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: mediaExtensions);
  final f = files.firstOrNull;
  if (f == null) return null;
  return (bytes: await f.readAsBytes(), name: f.name);
});

/// Makes a file into what is kept, off the UI thread. Overridden in tests.
final mediaProcessorProvider = Provider<Future<ProcessedMedia> Function(MediaJob job)>(
  (ref) => (job) => compute(processMediaJob, job),
);

/// The Upload dialog; the new upload, or null when cancelled.
Future<MediaAsset?> showMediaUploadDialog(BuildContext context, {MediaKind kind = MediaKind.icon, bool lockKind = false}) =>
    showAppDialog<MediaAsset>(
      id: 'admin.media-upload',
      context: context,
      builder: (_) => MediaUploadDialog(initialKind: kind, lockKind: lockKind),
    );

/// A chosen file, its small copy for the preview, and the preview after.
class _Pick {
  _Pick(this.file, this.mime, this.small);
  final MediaFile file;
  final String mime;
  final img.Image? small;
  Uint8List? before, after;

  bool get svg => mime == 'image/svg+xml';
}

class MediaUploadDialog extends ConsumerStatefulWidget {
  const MediaUploadDialog({super.key, this.initialKind = MediaKind.icon, this.lockKind = false});

  final MediaKind initialKind;

  /// Opened from a picker that takes one kind: the kind can't change.
  final bool lockKind;

  @override
  ConsumerState<MediaUploadDialog> createState() => _MediaUploadDialogState();
}

class _MediaUploadDialogState extends ConsumerState<MediaUploadDialog> {
  late MediaKind _kind = widget.initialKind;
  late bool _remove = _kind.removeBackgroundByDefault;
  double _strength = removalStrengthDefault;
  bool _tint = false;
  _Pick? _light, _dark;
  final _name = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _isLogo => _kind == MediaKind.logo;

  void _setKind(MediaKind k) => setState(() {
    _kind = k;
    _remove = k.removeBackgroundByDefault;
    if (k != MediaKind.icon) _tint = false;
    if (k != MediaKind.logo) _dark = null;
    _error = null;
    _refreshPreviews();
  });

  Future<void> _choose({bool dark = false}) async {
    final f = await ref.read(mediaFilePickerProvider)();
    if (f == null || !mounted) return;
    final mime = mediaMimeFor(f.name);
    if (mime == null) return setState(() => _error = 'Use a PNG, JPG, WebP or SVG file.');
    if (_kind == MediaKind.image && mime == 'image/svg+xml') {
      return setState(() => _error = 'Use a PNG, JPG or WebP file for an image.');
    }
    if (f.bytes.length > _kind.maxBytes) {
      return setState(() => _error = 'Over ${_kind.maxLabel}. Pick a smaller file.');
    }
    if (mime == 'image/svg+xml') {
      final problem = svgProblem(f.bytes);
      if (problem != null) return setState(() => _error = problem);
    }
    // A big file is read off the UI thread.
    final small = mime == 'image/svg+xml'
        ? null
        : f.bytes.length < 300 * 1024
        ? previewImage(f.bytes)
        : await compute(previewImage, f.bytes);
    if (!mounted) return;
    if (mime != 'image/svg+xml' && small == null) {
      return setState(() => _error = 'This file could not be read as a picture.');
    }
    setState(() {
      _error = null;
      final p = _Pick(f, mime, small);
      if (dark) {
        _dark = p;
      } else {
        _light = p;
      }
      if (_name.text.trim().isEmpty) {
        final base = f.name.replaceFirst(RegExp(r'\.[A-Za-z0-9]+$'), '').replaceAll(RegExp(r'[_-]+'), ' ').trim();
        _name.text = base.length > mediaNameMax ? base.substring(0, mediaNameMax) : base;
      }
      _refreshPreviews();
    });
  }

  void _refreshPreviews() {
    for (final p in [?_light, ?_dark]) {
      final small = p.small;
      if (small == null) continue;
      p.before ??= img.encodePng(small);
      p.after = previewAfter(small, remove: _remove, strength: _strength);
    }
  }

  bool get _canSave =>
      !_saving && (_light != null || _dark != null) && mediaNameProblem(_name.text) == null;

  Future<void> _save() async {
    final problem = mediaNameProblem(_name.text);
    if (problem != null) return setState(() => _error = problem);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final process = ref.read(mediaProcessorProvider);
      Future<ProcessedMedia?> run(_Pick? p) async => p == null
          ? null
          : process(MediaJob(
              bytes: p.file.bytes,
              mime: p.mime,
              kind: _kind,
              removeBackground: _remove && !p.svg,
              strength: _strength,
            ));
      final light = await run(_light);
      final dark = await run(_dark);
      final asset = await ref.read(mediaRepositoryProvider).save(
        kind: _kind,
        name: _name.text,
        light: light,
        dark: dark,
        tint: _tint,
      );
      if (mounted) Navigator.of(context).pop(asset);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is FormatException ? e.message : 'Could not save: $e';
        });
      }
    }
  }

  String get _hint => switch (_kind) {
    MediaKind.icon => 'PNG, JPG, WebP or SVG, up to 2 MB. Saved as a 256 × 256 transparent PNG; an SVG is kept as it is.',
    MediaKind.image => 'PNG, JPG or WebP, up to 5 MB. Saved at most 1600 px wide as WebP, its shape kept.',
    MediaKind.logo => 'A light and a dark version, either one optional. PNG, JPG, WebP or SVG, up to 2 MB each. '
        'Saved as a transparent PNG; an SVG is kept as it is.',
  };

  Widget _fileRow(String label, _Pick? p, {bool dark = false}) => Row(children: [
    OutlinedButton.icon(
      key: ValueKey(dark ? 'media-choose-dark' : 'media-choose'),
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
      onPressed: _saving ? null : () => _choose(dark: dark),
      icon: const Icon(Icons.attach_file),
      label: Text(label),
    ),
    const SizedBox(width: 10),
    Expanded(
      child: Text(
        p?.file.name ?? 'No file chosen',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
    if (p != null)
      IconButton(
        tooltip: 'Remove file',
        icon: const Icon(Icons.close),
        onPressed: _saving ? null : () => setState(() => dark ? (_dark = null) : (_light = null)),
      ),
  ]);

  Widget _preview(_Pick? p, {String? caption, bool dark = false}) {
    final t = Theme.of(context);
    Widget box(Widget child, {bool checker = false, Key? key}) => Container(
      key: key,
      width: 132,
      height: 132,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.colorScheme.outlineVariant),
        color: checker ? null : t.colorScheme.surfaceContainerHighest,
      ),
      child: checker ? CustomPaint(painter: Checkerboard.of(context), child: Center(child: child)) : Center(child: child),
    );
    Widget note(String s) => Padding(
      padding: const EdgeInsets.all(8),
      child: Text(s, textAlign: TextAlign.center, style: t.textTheme.bodySmall),
    );
    final tag = dark ? '-dark' : '';
    final before = p == null
        ? note('No file yet')
        : p.svg
        ? note('SVG: kept as it is')
        : Image.memory(p.before!, fit: BoxFit.contain, gaplessPlayback: true);
    final after = p == null
        ? note('Background removed')
        : p.svg
        ? note('SVG: kept as it is')
        : Image.memory(p.after!, key: ValueKey('media-after-image$tag'), fit: BoxFit.contain, gaplessPlayback: true);
    Widget fig(Widget b, String cap) => Column(mainAxisSize: MainAxisSize.min, children: [
      b,
      const SizedBox(height: 4),
      Text(cap, style: t.textTheme.labelSmall),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (caption != null) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(caption, style: t.textTheme.labelLarge)),
      Wrap(spacing: 12, runSpacing: 8, children: [
        fig(box(before, key: ValueKey('media-before$tag')), 'Before'),
        fig(box(after, checker: true, key: ValueKey('media-after$tag')), 'After (checkered = transparent)'),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final onlySvg = [?_light, ?_dark].isNotEmpty && [?_light, ?_dark].every((p) => p.svg);
    return AlertDialog(
      title: const Text('Upload'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!widget.lockKind)
              SegmentedButton<MediaKind>(
                key: const ValueKey('media-upload-kind'),
                segments: [
                  for (final k in MediaKind.values)
                    ButtonSegment(value: k, label: Text(k.label, key: ValueKey('media-upload-kind-${k.id}'))),
                ],
                selected: {_kind},
                onSelectionChanged: _saving ? null : (s) => _setKind(s.first),
              ),
            const SizedBox(height: 8),
            Text(_hint, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            if (_isLogo) ...[
              _fileRow('Light version', _light),
              _fileRow('Dark version', _dark, dark: true),
            ] else
              _fileRow('Choose file', _light),
            const SizedBox(height: 12),
            _preview(_light, caption: _isLogo ? 'Light version' : null),
            if (_isLogo) ...[const SizedBox(height: 12), _preview(_dark, caption: 'Dark version', dark: true)],
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('media-remove-bg'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Remove background'),
              subtitle: Text(onlySvg
                  ? 'An SVG is kept as it is'
                  : 'Takes off the plain colour round the edges. Works well on logos and icons, less on photos'),
              value: _remove && !onlySvg,
              onChanged: _saving || onlySvg ? null : (v) => setState(() {
                _remove = v;
                _refreshPreviews();
              }),
            ),
            Row(children: [
              const Text('Removal strength'),
              Expanded(
                child: Slider(
                  key: const ValueKey('media-strength'),
                  min: removalStrengthMin,
                  max: removalStrengthMax,
                  value: _strength,
                  label: _strength.round().toString(),
                  onChanged: !_remove || _saving || onlySvg
                      ? null
                      : (v) => setState(() {
                          _strength = v;
                          _refreshPreviews();
                        }),
                ),
              ),
            ]),
            if (_kind == MediaKind.icon)
              SwitchListTile(
                key: const ValueKey('media-tint'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Follow the theme colour'),
                subtitle: const Text("For a one-colour icon: drawn in the theme's icon colour, in light and dark mode"),
                value: _tint,
                onChanged: _saving ? null : (v) => setState(() => _tint = v),
              ),
            TextField(
              key: const ValueKey('media-upload-name'),
              controller: _name,
              maxLength: mediaNameMax,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Pharmacy cross', counterText: ''),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, key: const ValueKey('media-upload-error'), style: TextStyle(color: t.colorScheme.error)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('media-upload-save'),
          onPressed: _canSave ? _save : null,
          child: _saving
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text('Save ${_kind.label.toLowerCase()}'),
        ),
      ],
    );
  }
}

/// The checkerboard behind a transparent picture, in the theme's light or
/// dark greys.
class Checkerboard extends CustomPainter {
  const Checkerboard(this.a, this.b, {this.cell = 8});

  factory Checkerboard.of(BuildContext context) => Theme.of(context).brightness == Brightness.dark
      ? const Checkerboard(Color(0xFF1D2632), Color(0xFF151C26))
      : const Checkerboard(Color(0xFFE9EDF2), Color(0xFFFFFFFF));

  final Color a, b;
  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = b);
    final p = Paint()..color = a;
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = ((y / cell).floor().isEven ? 0.0 : cell); x < size.width; x += cell * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), p);
      }
    }
  }

  @override
  bool shouldRepaint(Checkerboard old) => old.a != a || old.b != b || old.cell != cell;
}
