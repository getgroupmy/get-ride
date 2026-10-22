// Admin → Display Settings → Media Gallery: every icon, image and logo the
// app uses (built in, uploaded here, or set on another page), where each one
// is used, and the admin's own uploads. A tile opens its details (a side
// panel on a wide screen, a sheet on a phone): the big preview, each place
// it is used as a link to that admin page, and Delete for an upload nothing
// uses. Upload adds one (media_upload_dialog.dart).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config.dart';
import '../../../core/format.dart' show formatDateTime;
import '../../../core/media_assets.dart';
import '../../../core/media_usage.dart';
import '../../../data/live_tables.dart';
import '../../../data/media_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/net_image.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'display_screen.dart' show displayPage, lucide, lucideIcons;
import 'media_upload_dialog.dart';

/// The gallery's address (under Display Settings).
const mediaGalleryPath = '/admin/m/media-gallery';

/// What the gallery shows: the uploads and where every picture is used.
class MediaGalleryData {
  const MediaGalleryData({this.assets = const [], this.usage = const {}});
  final List<MediaAsset> assets;
  final Map<String, List<MediaUse>> usage;
}

/// The uploads and the usage index, read again whenever a setting that
/// could point at a picture changes.
final mediaGalleryProvider = FutureProvider.autoDispose<MediaGalleryData>((ref) async {
  for (final t in const ['media_assets', 'admin_display_settings', 'settings_entries', 'app_settings', 'app_branding']) {
    ref.watchLive(t);
  }
  final repo = ref.watch(mediaRepositoryProvider);
  final assets = await repo.list();
  return MediaGalleryData(assets: assets, usage: mediaUsageIndex(await repo.usageInput(assets)));
});

/// The public address of an upload's file, on this app's project.
String mediaFileUrl(String path) => mediaPublicUrl(AppConfig.supabaseUrl, path);

/// From this width the details sit beside the grid.
const _sidePanelFrom = 900.0;

class AdminMediaGalleryScreen extends ConsumerStatefulWidget {
  const AdminMediaGalleryScreen({super.key});

  @override
  ConsumerState<AdminMediaGalleryScreen> createState() => _AdminMediaGalleryScreenState();
}

class _AdminMediaGalleryScreenState extends ConsumerState<AdminMediaGalleryScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: MediaKind.values.length, vsync: this)
    ..addListener(() {
      if (!_tabs.indexIsChanging) setState(() => _selected = null);
    });
  final _search = TextEditingController();
  GalleryFilter _filter = GalleryFilter.all;
  String? _selected;

  MediaKind get _kind => MediaKind.values[_tabs.index];

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _upload() async {
    final asset = await showMediaUploadDialog(context, kind: _kind);
    if (asset == null || !mounted) return;
    ref.invalidate(mediaGalleryProvider);
    setState(() {
      _tabs.index = asset.kind.index;
      _filter = GalleryFilter.uploaded;
      _selected = asset.ref;
    });
  }

  void _open(GalleryItem item, bool wide) {
    setState(() => _selected = item.key);
    if (wide) return;
    showAppSheet<void>(
      id: 'admin.media-details',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          // The sheet follows the live data: a delete or a new use shows.
          final data = ref.watch(mediaGalleryProvider).value;
          final items = data == null ? const <GalleryItem>[] : _items(data);
          final current = items.where((i) => i.key == item.key).firstOrNull;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: current == null
                ? const Padding(padding: EdgeInsets.all(24), child: Text('This item is gone.'))
                : MediaDetails(item: current, inSheet: true),
          );
        },
      ),
    );
  }

  List<GalleryItem> _items(MediaGalleryData d) =>
      galleryItems(builtInIcons: lucideIcons.keys, assets: d.assets, usage: d.usage);

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    return AdminPage(
      title: 'Media Gallery',
      page: displayPage,
      actions: [
        if (canEdit)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              key: const ValueKey('media-upload'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: _upload,
              icon: const Icon(Icons.upload),
              label: const Text('Upload'),
            ),
          ),
      ],
      bottom: TabBar(
        controller: _tabs,
        tabs: [for (final k in MediaKind.values) Tab(key: ValueKey('media-tab-${k.id}'), text: k.plural)],
      ),
      body: AsyncView(
        value: ref.watch(mediaGalleryProvider),
        onRetry: () => ref.invalidate(mediaGalleryProvider),
        data: (d) => LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= _sidePanelFrom;
            final items = _items(d);
            final shown = filterGallery(items, kind: _kind, filter: _filter, query: _search.text);
            final selected = items.where((i) => i.key == _selected && i.kind == _kind).firstOrNull;
            final grid = _grid(context, shown, selected, wide);
            if (!wide) return grid;
            final t = Theme.of(context);
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: grid),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 340,
                child: ColoredBox(
                  color: t.colorScheme.surfaceContainerLow,
                  child: SingleChildScrollView(
                    key: const ValueKey('media-side-panel'),
                    padding: const EdgeInsets.all(16),
                    child: selected == null
                        ? Text('Tap an item to see where it is used.', style: TextStyle(color: mutedTextColor(t)))
                        : MediaDetails(item: selected),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, List<GalleryItem> shown, GalleryItem? selected, bool wide) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    return CustomScrollView(slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        sliver: SliverToBoxAdapter(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              key: const ValueKey('media-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: "Search by name or where it's used",
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(_search.clear),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final f in GalleryFilter.values)
                ChoiceChip(
                  key: ValueKey('media-filter-${f.name}'),
                  label: Text(f.label),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
            ]),
          ]),
        ),
      ),
      if (shown.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'No ${_kind.plural.toLowerCase()} match.',
              key: const ValueKey('media-empty'),
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 132,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.78,
            ),
            itemCount: shown.length,
            itemBuilder: (_, i) => MediaTile(
              item: shown[i],
              selected: selected?.key == shown[i].key,
              onTap: () => _open(shown[i], wide),
            ),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        sliver: SliverToBoxAdapter(
          child: Text(
            "Built-in icons, images and logos come with the app and can't be deleted. Uploads can be picked "
            'wherever an icon or picture is chosen: side menu items, home boxes, vehicle services and Ride Options.',
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ),
    ]);
  }
}

/// One tile: the picture, its name, how many places use it and "Where
/// used" or "Unused".
class MediaTile extends StatelessWidget {
  const MediaTile({super.key, required this.item, required this.selected, required this.onTap});

  final GalleryItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final n = item.uses.length;
    final tileColor = cs.surfaceContainerLow;
    final muted = mutedTextColor(t, background: tileColor);
    return Material(
      key: ValueKey('media-tile-${item.key}'),
      color: tileColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? cs.primary : cs.outlineVariant, width: selected ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 14, 6, 8),
            child: Column(children: [
              Expanded(child: Center(child: MediaPreview(item: item, size: item.kind == MediaKind.icon ? 32 : 48))),
              const SizedBox(height: 6),
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall,
              ),
              if (item.source == MediaSource.uploaded)
                Text('Uploaded', style: t.textTheme.labelSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
              Text(
                n > 0 ? 'Where used' : 'Unused',
                key: ValueKey('media-tile-state-${item.key}'),
                style: t.textTheme.labelSmall?.copyWith(color: n > 0 ? cs.primary : muted),
              ),
            ]),
          ),
          Positioned(
            top: 5,
            right: 6,
            child: Container(
              key: ValueKey('media-tile-count-${item.key}'),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: n > 0 ? cs.primaryContainer : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$n',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: n > 0 ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A gallery item's picture, [size] high (a built-in icon as the icon, the
/// rest fitted in a box about that size), as it shows in [dark] mode (the
/// theme's when null).
class MediaPreview extends StatelessWidget {
  const MediaPreview({super.key, required this.item, required this.size, this.dark});

  final GalleryItem item;
  final double size;
  final bool? dark;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isDark = dark ?? t.brightness == Brightness.dark;
    final wide = item.kind == MediaKind.icon ? size : size * 1.6;
    Widget fallback() => Icon(Icons.broken_image_outlined, size: size * 0.8, color: t.colorScheme.outline);
    if (item.iconName != null) return Icon(lucide(item.iconName), size: size);
    if (item.key == wordmarkKey) {
      return SizedBox(width: wide, height: size, child: const FittedBox(child: BrandMark()));
    }
    if (item.assetPath != null) {
      return Image.asset(
        isDark ? item.assetDarkPath ?? item.assetPath! : item.assetPath!,
        width: size,
        height: size,
        errorBuilder: (_, _, _) => fallback(),
      );
    }
    final a = item.asset;
    if (a != null) {
      final path = a.pathFor(dark: isDark);
      if (a.isSvg || path == null) return _SvgBadge(size: size);
      final image = NetImage(mediaFileUrl(path), width: wide, height: size, fit: BoxFit.contain, fallback: fallback());
      // "Follow the theme colour": drawn in the icon colour.
      return a.tint
          ? ColorFiltered(colorFilter: ColorFilter.mode(IconTheme.of(context).color ?? t.colorScheme.onSurface, BlendMode.srcIn), child: image)
          : image;
    }
    final uri = item.uri;
    if (uri != null && uri.startsWith('data:')) {
      try {
        return Image.memory(
          UriData.parse(uri).contentAsBytes(),
          width: wide,
          height: size,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => fallback(),
        );
      } catch (_) {
        return fallback();
      }
    }
    if (uri != null && uri.startsWith('http')) {
      if (uri.toLowerCase().split('?').first.endsWith('.svg')) return _SvgBadge(size: size);
      return NetImage(uri, width: wide, height: size, fit: BoxFit.contain, fallback: fallback());
    }
    return fallback();
  }
}

/// An SVG upload: kept as it is; the app shows a placeholder for it until it
/// can draw SVG.
class _SvgBadge extends StatelessWidget {
  const _SvgBadge({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(border: Border.all(color: cs.outline), borderRadius: BorderRadius.circular(6)),
      child: FittedBox(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Text('SVG', style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurfaceVariant)),
        ),
      ),
    );
  }
}

/// An item's details: the big preview, its name, where it comes from, each
/// place it is used (a link to that admin page), and Delete for an upload.
class MediaDetails extends ConsumerWidget {
  const MediaDetails({super.key, required this.item, this.inSheet = false});

  final GalleryItem item;

  /// In the phone's sheet: following a link closes it first.
  final bool inSheet;

  String get _source => switch (item.source) {
    MediaSource.builtIn => 'Built into the app',
    MediaSource.uploaded => 'Uploaded',
    MediaSource.found => 'Set on its own page',
  };

  Future<void> _delete(BuildContext context, WidgetRef ref, MediaAsset asset) async {
    if (!await confirm(context, 'Delete ${item.kind.label.toLowerCase()}', 'Delete "${item.name}"? This can\'t be undone.',
        ok: 'Delete')) {
      return;
    }
    if (!context.mounted) return;
    // Checked again on fresh data first: a place may have started using it.
    MediaGalleryData fresh;
    try {
      fresh = await ref.refresh(mediaGalleryProvider.future);
    } catch (e) {
      if (context.mounted) showError(context, e);
      return;
    }
    if (!context.mounted) return;
    if (mediaAssetInUse(asset, fresh.usage)) {
      showInfo(context, "Can't delete: it is in use. Change those places to another icon first.");
      return;
    }
    final ok = await runAdminAction(context, () => ref.read(mediaRepositoryProvider).delete(asset), success: 'Deleted');
    if (!ok) return;
    ref.invalidate(mediaGalleryProvider);
    if (inSheet && context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final muted = mutedTextColor(t);
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final a = item.asset;
    final uses = item.uses;
    final facts = [
      _source,
      if (a?.createdAt != null) formatDateTime(a!.createdAt!.toLocal()),
      if (a?.width != null && a?.height != null) '${a!.width} × ${a.height} px',
      if (a?.bytes != null) _size(a!.bytes!),
      if (a?.isSvg ?? false) 'SVG, kept as it is',
      if (a?.tint ?? false) 'Follows the theme colour',
    ];

    return Column(
      key: ValueKey('media-details-${item.key}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _bigPreview(context),
        const SizedBox(height: 12),
        Text(item.name, key: const ValueKey('media-details-name'), style: t.textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(facts.join(' · '), style: t.textTheme.bodySmall?.copyWith(color: muted)),
        const SizedBox(height: 16),
        Text(
          uses.isEmpty ? 'Not used anywhere.' : 'Used in ${uses.length} ${uses.length == 1 ? 'place' : 'places'}',
          key: const ValueKey('media-details-uses'),
          style: t.textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        for (final (i, u) in uses.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: cs.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: cs.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('media-use-$i'),
                onTap: () {
                  final router = GoRouter.of(context);
                  if (inSheet) Navigator.of(context).pop();
                  router.push(u.location);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    Expanded(child: Text(u.label)),
                    const SizedBox(width: 8),
                    Icon(Icons.open_in_new, size: 18, color: cs.primary, semanticLabel: 'Open'),
                  ]),
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        switch (item.source) {
          MediaSource.uploaded => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            OutlinedButton.icon(
              key: const ValueKey('media-delete'),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.error,
                side: BorderSide(color: item.deletable && canEdit ? cs.error : cs.outlineVariant),
              ),
              onPressed: item.deletable && canEdit && a != null ? () => _delete(context, ref, a) : null,
              icon: const Icon(Icons.delete_outline),
              label: Text('Delete ${item.kind.label.toLowerCase()}'),
            ),
            if (!item.deletable)
              Container(
                key: const ValueKey('media-delete-blocked'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  "Can't delete: it is in use. Change those places to another icon first.",
                  style: TextStyle(color: cs.onErrorContainer),
                ),
              )
            else if (!canEdit)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Only admins who can edit Display Settings can delete it.',
                    style: t.textTheme.bodySmall?.copyWith(color: muted)),
              ),
          ]),
          MediaSource.builtIn => Text(
            "Built-in ${item.kind.plural.toLowerCase()} can't be deleted.",
            key: const ValueKey('media-builtin-note'),
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
          MediaSource.found => Text(
            'Uploaded on the page that uses it: change or remove it there.',
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
        },
      ],
    );
  }

  Widget _bigPreview(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget box(Widget child, {Color? color, double w = 96, double h = 96}) => Container(
      width: w,
      height: h,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color ?? cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: child,
    );
    if (item.kind == MediaKind.logo) {
      // Both versions, each on its own mode's background.
      Widget side(bool dark) => Column(children: [
        Theme(
          data: dark ? ThemeData(brightness: Brightness.dark) : ThemeData(brightness: Brightness.light),
          child: Builder(
            builder: (c) => box(
              MediaPreview(item: item, size: 48, dark: dark),
              color: dark ? const Color(0xFF121821) : Colors.white,
              w: 130,
              h: 84,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(dark ? 'Dark mode' : 'Light mode', style: Theme.of(context).textTheme.labelSmall),
      ]);
      return Wrap(spacing: 10, runSpacing: 10, children: [side(false), side(true)]);
    }
    if (item.kind == MediaKind.image) return box(MediaPreview(item: item, size: 110), w: 220, h: 136);
    return box(MediaPreview(item: item, size: 52));
  }
}

String _size(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).ceil()} KB';

/// For a found `data:` picture: its bytes (tests use it).
List<int>? dataUriBytes(String uri) {
  try {
    return uri.startsWith('data:') ? base64Decode(uri.substring(uri.indexOf(',') + 1)) : null;
  } catch (_) {
    return null;
  }
}
