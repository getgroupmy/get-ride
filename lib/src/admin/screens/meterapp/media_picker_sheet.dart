// The one picker every admin icon or picture slot opens: the Media
// Gallery's built-in icons and uploads of the slot's kind, with search,
// "Default" to clear the slot's override, and Upload from inside the sheet.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config.dart';
import '../../../core/icon_pack.dart';
import '../../../core/media_assets.dart';
import '../../../core/media_usage.dart';
import '../../../data/media_repository.dart';
import '../../../widgets/common.dart' show mutedTextColor;
import '../../../widgets/media_image.dart';
import '../../../widgets/page_style_host.dart';
import 'media_gallery_screen.dart' show MediaPreview, mediaGalleryProvider;
import 'media_upload_dialog.dart';

/// What a slot stores for a picked upload: its reference (`media:<id>`), or
/// for a slot older apps or other services read as a web address, the
/// file's public address (the gallery still counts it by its path).
enum MediaStore { ref, url }

/// Opens the picker for a [kind] slot. Answers what to store: a built-in
/// icon's name, `media:<id>` (or the file's address with [MediaStore.url]),
/// '' for "Default" (the slot's own), or null when closed. [current] is
/// marked. [builtIns] offers the built-in icons (icon slots only).
Future<String?> showMediaPicker(
  BuildContext context, {
  required MediaKind kind,
  String? current,
  String? title,
  bool offerDefault = true,
  String defaultLabel = 'Default',
  bool builtIns = true,
  MediaStore store = MediaStore.ref,
  Set<MediaKind>? alsoKinds,
}) => showAppSheet<String>(
  id: 'admin.media-picker',
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => FractionallySizedBox(
    heightFactor: 0.85,
    child: MediaPickerSheet(
      kind: kind,
      current: current,
      title: title ?? 'Choose ${kind == MediaKind.icon ? 'an icon' : 'a${kind == MediaKind.image ? 'n image' : ' logo'}'}',
      offerDefault: offerDefault,
      defaultLabel: defaultLabel,
      builtIns: builtIns && kind == MediaKind.icon,
      store: store,
      kinds: {kind, ...?alsoKinds},
    ),
  ),
);

class MediaPickerSheet extends ConsumerStatefulWidget {
  const MediaPickerSheet({
    super.key,
    required this.kind,
    this.current,
    this.title = 'Choose',
    this.offerDefault = true,
    this.defaultLabel = 'Default',
    this.builtIns = true,
    this.store = MediaStore.ref,
    Set<MediaKind>? kinds,
  }) : kinds = kinds ?? const {};

  /// The kind uploaded from here.
  final MediaKind kind;

  /// The uploads offered: [kind] and these.
  final Set<MediaKind> kinds;
  final String? current;
  final String title;
  final bool offerDefault;
  final String defaultLabel;
  final bool builtIns;
  final MediaStore store;

  @override
  ConsumerState<MediaPickerSheet> createState() => _MediaPickerSheetState();
}

class _MediaPickerSheetState extends ConsumerState<MediaPickerSheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _value(MediaAsset a) {
    final path = a.path ?? a.darkPath;
    // The project's own address (not a fallback route the app may be on).
    return widget.store == MediaStore.url && path != null ? mediaPublicUrl(AppConfig.supabaseUrl, path) : a.ref;
  }

  bool _isCurrent(GalleryItem i) {
    final c = widget.current?.trim() ?? '';
    if (c.isEmpty) return false;
    final a = i.asset;
    if (a != null) return c == a.ref || [a.path, a.darkPath].any((p) => p != null && mediaPathInUrl(c) == p);
    return i.iconName == c || (i.assetPath != null && i.key == c);
  }

  Future<void> _upload() async {
    final asset = await showMediaUploadDialog(context, kind: widget.kind, lockKind: true);
    if (asset == null || !mounted) return;
    ref.invalidate(mediaAssetsProvider);
    ref.invalidate(mediaGalleryProvider);
    Navigator.of(context).pop(_value(asset));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final assets = ref.watch(mediaAssetsProvider);
    final q = _search.text.trim().toLowerCase();
    final kinds = {widget.kind, ...widget.kinds};
    final items = <GalleryItem>[
      for (final a in assets.value ?? const <MediaAsset>[])
        if (kinds.contains(a.kind))
          GalleryItem(key: a.ref, kind: a.kind, name: a.name, source: MediaSource.uploaded, asset: a),
      if (widget.builtIns)
        for (final n in builtInIconData.keys)
          GalleryItem(key: iconKey(n), kind: MediaKind.icon, name: iconDisplayName(n), source: MediaSource.builtIn, iconName: n),
      // The icon pack: full-colour pictures, for icon and picture slots
      // that keep a reference (not those that store a file's address).
      if (widget.store == MediaStore.ref && (kinds.contains(MediaKind.icon) || kinds.contains(MediaKind.image)))
        for (final n in iconPack)
          GalleryItem(key: packRef(n), kind: MediaKind.icon, name: packDisplayName(n), source: MediaSource.builtIn, assetPath: packAsset(n)),
    ].where((i) => q.isEmpty || '${i.name} ${i.iconName ?? ''}'.toLowerCase().contains(q)).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
        child: Row(children: [
          Expanded(child: Text(widget.title, style: t.textTheme.titleLarge)),
          TextButton.icon(
            key: const ValueKey('media-picker-upload'),
            onPressed: _upload,
            icon: const Icon(Icons.upload),
            label: const Text('Upload'),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          key: const ValueKey('media-picker-search'),
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Search',
            prefixIcon: Icon(Icons.search),
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
      ),
      if (widget.offerDefault)
        ListTile(
          key: const ValueKey('media-picker-default'),
          leading: const Icon(Icons.restart_alt),
          title: Text(widget.defaultLabel),
          trailing: (widget.current ?? '').trim().isEmpty ? const Icon(Icons.check) : null,
          onTap: () => Navigator.of(context).pop(''),
        ),
      if (assets.isLoading && !assets.hasValue) const LinearProgressIndicator(),
      Expanded(
        child: items.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Nothing here yet. Upload one.',
                    key: const ValueKey('media-picker-empty'),
                    style: TextStyle(color: muted),
                  ),
                ),
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 112,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.9,
                ),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final item = items[i];
                  final on = _isCurrent(item);
                  return Material(
                    key: ValueKey('media-picker-${item.key}'),
                    color: t.colorScheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: on ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: on ? 2 : 1),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(item.asset != null ? _value(item.asset!) : item.iconName ?? item.key),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Column(children: [
                          Expanded(child: Center(child: MediaPreview(item: item, size: item.kind == MediaKind.icon ? 30 : 44))),
                          Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                              style: t.textTheme.bodySmall),
                          if (item.source == MediaSource.uploaded)
                            Text('Uploaded', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.primary)),
                        ]),
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

/// A picture slot in an admin form: its preview, Choose (the picker) and
/// Remove. [value] is what the slot stores.
class MediaField extends StatelessWidget {
  const MediaField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.kind = MediaKind.image,
    this.aspect = 1,
    this.enabled = true,
    this.store = MediaStore.ref,
    this.fallback = Icons.image_outlined,
    this.fieldKey,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final MediaKind kind;
  final double aspect;
  final bool enabled;
  final MediaStore store;
  final IconData fallback;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const size = 72.0;
    return Padding(
      key: fieldKey,
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.labelLarge),
        const SizedBox(height: 8),
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: size * aspect,
              height: size,
              color: t.colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: kind == MediaKind.icon && !value.startsWith('http') && !value.startsWith('data:')
                  ? MediaIcon(value, fallback: fallback, size: 36)
                  : MediaImage(value, width: size * aspect, height: size, fit: BoxFit.cover,
                      fallback: Icon(fallback, color: t.colorScheme.onSurfaceVariant, size: size * 0.5)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                key: const ValueKey('media-field-choose'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: enabled
                    ? () async {
                        final v = await showMediaPicker(context,
                            kind: kind, current: value, title: label, offerDefault: false, store: store);
                        if (v != null && v.isNotEmpty) onChanged(v);
                      }
                    : null,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(value.isEmpty ? 'Choose' : 'Change'),
              ),
              if (value.isNotEmpty)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                  onPressed: enabled ? () => onChanged('') : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove'),
                ),
            ]),
          ),
        ]),
      ]),
    );
  }
}
