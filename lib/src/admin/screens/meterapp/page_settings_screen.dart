// Admin → Settings → App Page Settings: every page, sheet and modal in the
// app (page_inventory.g.dart), each with a live preview and the values the
// admin can change -- text size, curves, heights, icon sizes, colours for
// light and dark, and the items of the home screen and the fare sheet.
// Saved values apply on every open app at once (core/page_styles.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app.dart' show appTheme;
import '../../../core/page_inventory.g.dart';
import '../../../core/page_styles.dart';
import '../../../core/fare.dart' show RideService;
import '../../../data/page_styles_repository.dart';
import '../../../features/ride/confirm_parts.dart' show FareInfoSheet;
import '../../../features/ride/home_parts.dart' show HomeSearchPill, VehicleTypeBar;
import '../../../providers.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';

const pageSettingsPage = 'admin-settings-page-styles';

/// The app-wide entry at the top of the list.
const appWideEntry = SurfaceEntry(appSurface, SurfaceKind.page, 'App-wide (every page, sheet and modal)', '');

/// [surfaces] matching [query] (title, address or file) and [kind] (null for
/// all). Pure.
List<SurfaceEntry> filterSurfaces(List<SurfaceEntry> surfaces, String query, SurfaceKind? kind) {
  final q = query.trim().toLowerCase();
  return [
    for (final s in surfaces)
      if ((kind == null || s.kind == kind) &&
          (q.isEmpty || '${s.title} ${s.path ?? ''} ${s.file} ${s.id}'.toLowerCase().contains(q)))
        s,
  ];
}

String kindLabel(SurfaceKind k) => switch (k) {
  SurfaceKind.page => 'Page',
  SurfaceKind.sheet => 'Bottom sheet',
  SurfaceKind.modal => 'Modal',
};

IconData kindIcon(SurfaceKind k) => switch (k) {
  SurfaceKind.page => Icons.web_asset,
  SurfaceKind.sheet => Icons.call_to_action_outlined,
  SurfaceKind.modal => Icons.picture_in_picture_outlined,
};

class AdminPageSettingsScreen extends ConsumerStatefulWidget {
  const AdminPageSettingsScreen({super.key});

  @override
  ConsumerState<AdminPageSettingsScreen> createState() => _AdminPageSettingsScreenState();
}

class _AdminPageSettingsScreenState extends ConsumerState<AdminPageSettingsScreen> {
  final _query = TextEditingController();
  SurfaceKind? _kind;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(SurfaceEntry s) => Navigator.of(context).push(
    AppPageRoute<void>(id: 'admin-page-settings.editor', builder: (_) => PageStyleEditor(surface: s)),
  );

  @override
  Widget build(BuildContext context) {
    final styles = ref.watch(pageStylesProvider).value ?? PageStyles.none;
    final shown = filterSurfaces(pageInventory, _query.text, _kind);
    final t = Theme.of(context);
    final areas = <String, List<SurfaceEntry>>{};
    for (final s in shown) {
      areas.putIfAbsent(s.area, () => []).add(s);
    }
    Widget tile(SurfaceEntry s) => ListTile(
      key: ValueKey('page-settings-tile-${s.id}'),
      leading: Icon(kindIcon(s.kind)),
      title: Text(s.title),
      subtitle: Text(
        s.id == appSurface ? 'Every value here applies wherever a page, sheet or modal has none of its own' : '${kindLabel(s.kind)} · ${s.path ?? s.file}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: styles.has(s.id) ? const Chip(label: Text('Edited'), visualDensity: VisualDensity.compact) : const Icon(Icons.chevron_right),
      onTap: () => _open(s),
    );
    final counts = {for (final k in SurfaceKind.values) k: pageInventory.where((s) => s.kind == k).length};
    return AdminPage(
      title: 'App Page Settings',
      page: pageSettingsPage,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 48),
        children: [
          ResponsiveCenter(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('The look of every page, sheet and modal'),
                    subtitle: Text(
                      '${counts[SurfaceKind.page]} pages, ${counts[SurfaceKind.sheet]} bottom sheets and '
                      '${counts[SurfaceKind.modal]} modals. Open one to see it and change its text size, curves, '
                      'heights, icons and colours (light and dark). Saved changes show on every open app at once.',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(child: tile(appWideEntry)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                  child: TextField(
                    key: const ValueKey('page-settings-search'),
                    controller: _query,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search pages, sheets and modals'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(label: const Text('All'), selected: _kind == null, onSelected: (_) => setState(() => _kind = null)),
                    for (final k in SurfaceKind.values)
                      ChoiceChip(
                        key: ValueKey('page-settings-kind-${k.name}'),
                        label: Text('${kindLabel(k)}s (${counts[k]})'),
                        selected: _kind == k,
                        onSelected: (_) => setState(() => _kind = _kind == k ? null : k),
                      ),
                  ],
                ),
                for (final area in const ['Rider & shared', 'Driver', 'Admin panel'])
                  if (areas[area] case final list?) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                      child: Text('$area (${list.length})', style: t.textTheme.titleMedium),
                    ),
                    Card(child: Column(children: [for (final s in list) tile(s)])),
                  ],
                if (shown.isEmpty)
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Nothing matches'))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One surface's values: a live preview and the controls, saved together.
class PageStyleEditor extends ConsumerStatefulWidget {
  const PageStyleEditor({super.key, required this.surface});

  final SurfaceEntry surface;

  @override
  ConsumerState<PageStyleEditor> createState() => _PageStyleEditorState();
}

class _PageStyleEditorState extends ConsumerState<PageStyleEditor> {
  Map<String, Object?>? _draft;
  Brightness _preview = Brightness.light;
  SurfaceKind _appKind = SurfaceKind.page;
  bool _saving = false;

  String get _id => widget.surface.id;
  bool get _appWide => _id == appSurface;

  Map<String, Object?> _stored(PageStyles s) => Map<String, Object?>.from(s.values[_id] ?? const {});

  /// The (key as kept, token, kind) rows this surface edits.
  List<(String, StyleToken, SurfaceKind)> get _rows => _appWide
      ? [for (final (k, t) in appTokens) (appKey(k, t.key), t, k)]
      : [for (final t in tokensOf(widget.surface)) (t.key, t, widget.surface.kind)];

  Future<void> _save(Map<String, Object?> draft) async {
    setState(() => _saving = true);
    final ok = await runAdminAction(context, () async {
      await savePageStyle(ref.read(supabaseProvider), _id, draft);
      ref.invalidate(pageStylesProvider);
    }, success: 'Saved — every open app shows it now');
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) setState(() => _draft = null);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(pageSettingsPage)) == AccessLevel.edit;
    final stored = ref.watch(pageStylesProvider).value ?? PageStyles.none;
    final draft = _draft ?? _stored(stored);
    final styles = stored.withSurface(_id, draft);
    final dirty = _draft != null;
    void set(String key, Object? v) => setState(() {
      final next = Map<String, Object?>.from(draft);
      if (v == null) {
        next.remove(key);
      } else {
        next[key] = v;
      }
      _draft = next;
    });
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final preview = _PreviewPane(
      surface: widget.surface,
      styles: styles,
      brightness: _preview,
      appKind: _appKind,
      onBrightness: (b) => setState(() => _preview = b),
      onAppKind: (k) => setState(() => _appKind = k),
    );
    final controls = _Controls(
      rows: _rows,
      draft: draft,
      styles: styles,
      surface: _id,
      enabled: canEdit,
      onSet: set,
    );
    return AdminPage(
      title: widget.surface.title,
      page: pageSettingsPage,
      actions: [
        if (canEdit && draft.isNotEmpty)
          TextButton(
            key: const ValueKey('page-settings-reset'),
            onPressed: _saving ? null : () => setState(() => _draft = {}),
            child: const Text('Reset all'),
          ),
      ],
      floatingActionButton: dirty
          ? FloatingActionButton.extended(
              key: const ValueKey('page-settings-save'),
              onPressed: _saving ? null : () => _save(draft),
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving…' : 'Save'),
            )
          : null,
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 380, child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: preview)),
                const VerticalDivider(width: 1),
                Expanded(child: controls),
              ],
            )
          : NestedScrollView(
              headerSliverBuilder: (_, _) => [
                SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(12), child: preview)),
              ],
              body: controls,
            ),
    );
  }
}

/// The phone-sized preview and its light/dark switch.
class _PreviewPane extends StatelessWidget {
  const _PreviewPane({
    required this.surface,
    required this.styles,
    required this.brightness,
    required this.appKind,
    required this.onBrightness,
    required this.onAppKind,
  });

  final SurfaceEntry surface;
  final PageStyles styles;
  final Brightness brightness;
  final SurfaceKind appKind;
  final ValueChanged<Brightness> onBrightness;
  final ValueChanged<SurfaceKind> onAppKind;

  @override
  Widget build(BuildContext context) {
    final appWide = surface.id == appSurface;
    return Column(
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            SegmentedButton<Brightness>(
              segments: const [
                ButtonSegment(value: Brightness.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
                ButtonSegment(value: Brightness.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
              ],
              selected: {brightness},
              onSelectionChanged: (s) => onBrightness(s.first),
            ),
            if (appWide)
              SegmentedButton<SurfaceKind>(
                segments: [for (final k in SurfaceKind.values) ButtonSegment(value: k, label: Text(kindLabel(k)))],
                selected: {appKind},
                onSelectionChanged: (s) => onAppKind(s.first),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 520,
          child: FittedBox(
            child: SurfacePreview(
              key: const ValueKey('page-settings-preview'),
              surface: appWide ? _sample(appKind) : surface,
              styles: styles,
              brightness: brightness,
            ),
          ),
        ),
      ],
    );
  }

  /// A surface with no values of its own, to show the app-wide ones.
  static SurfaceEntry _sample(SurfaceKind k) => switch (k) {
    SurfaceKind.page => const SurfaceEntry('route:/__preview', SurfaceKind.page, 'Any page', ''),
    SurfaceKind.sheet => const SurfaceEntry('sheet:__preview', SurfaceKind.sheet, 'Any bottom sheet', ''),
    SurfaceKind.modal => const SurfaceEntry('modal:__preview', SurfaceKind.modal, 'Any modal', ''),
  };
}

/// [surface] drawn in a phone frame under [styles], in [brightness]: the real
/// home items and fare sheet where it is one of those, a sample otherwise.
class SurfacePreview extends StatelessWidget {
  const SurfacePreview({super.key, required this.surface, required this.styles, required this.brightness});

  final SurfaceEntry surface;
  final PageStyles styles;
  final Brightness brightness;

  static const size = Size(360, 720);

  static const _services = [
    RideService('Ride', 'Affordable everyday rides', 1, 4),
    RideService('Comfort', 'Roomier cars', 1.2, 4),
    RideService('XL', 'Up to 6 seats', 1.5, 6),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = appTheme(brightness);
    final s = SurfaceStyle(styles, surface.id, surface.kind);
    return Container(
      width: size.width + 16,
      height: size.height + 16,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(36)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(size: size, padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
          child: Theme(
            data: theme,
            child: PageStyleScope(
              styles: styles,
              child: Material(
                color: theme.scaffoldBackgroundColor,
                child: switch (surface.kind) {
                  SurfaceKind.page => SurfaceFrame(id: surface.id, child: _page(surface, theme)),
                  SurfaceKind.sheet => _overPage(theme, s, _sheet(surface, s, theme)),
                  SurfaceKind.modal => _overPage(theme, s, _modal(surface)),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A dimmed sample page under a sheet or modal.
  Widget _overPage(ThemeData theme, SurfaceStyle s, Widget over) {
    final dim = s.number('dim') / 100;
    return Stack(
      fit: StackFit.expand,
      children: [
        SurfaceFrame(id: 'route:/__under', child: _samplePage('Page', theme)),
        ColoredBox(color: Colors.black.withValues(alpha: dim)),
        over,
      ],
    );
  }

  Widget _page(SurfaceEntry e, ThemeData theme) {
    if (e.id != homeSurface) return _samplePage(e.title, theme);
    return Builder(
      builder: (context) {
        final style = SurfaceStyle.ofPage(context);
        final t = Theme.of(context);
        return Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: t.brightness == Brightness.dark
                      ? const [Color(0xFF1F2933), Color(0xFF111820)]
                      : const [Color(0xFFE8EEF2), Color(0xFFD5DEE5)],
                ),
              ),
              child: Center(child: Icon(Icons.map_outlined, size: 64, color: t.colorScheme.outline)),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                elevation: 8,
                color: style.setColor('mapSheetColor', t.brightness) ?? t.colorScheme.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(style.number('mapSheetRadius'))),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: style.setColor('handleColor', t.brightness) ?? t.colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      VehicleTypeBar(services: _services, selected: _services.first, onSelect: (_) {}),
                      const SizedBox(height: 12),
                      HomeSearchPill(onTap: () {}),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _samplePage(String title, ThemeData theme) => Scaffold(
    appBar: AppBar(title: Text(title), leading: const BackButton()),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.directions_car_outlined),
            title: const Text('A card on this page'),
            subtitle: const Text('Its text, icon and corners follow the values on the right'),
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
        const SizedBox(height: 12),
        const TextField(decoration: InputDecoration(labelText: 'An input box')),
        const SizedBox(height: 12),
        const Text('Body text reads like this, at the text size set for this page.'),
        const SizedBox(height: 16),
        FilledButton(onPressed: () {}, child: const Text('Main button')),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () {}, child: const Text('Other button')),
      ],
    ),
  );

  Widget _sheet(SurfaceEntry e, SurfaceStyle s, ThemeData theme) {
    final b = theme.brightness;
    final radius = s.number('topRadius');
    final tallest = s.number('maxHeight') / 100;
    final content = e.id == fareInfoSurface
        ? const FareInfoSheet(
            service: RideService('Ride', '', 1, 4),
            rates: ['Base fare: RM4', 'Fare per km: RM1', 'Fare per minute: RM0.20', 'Minimum fare: RM7'],
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Builder(
              builder: (c) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(e.title, style: Theme.of(c).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Text('What this sheet says reads like this, at the text size set for it.'),
                  const SizedBox(height: 12),
                  const ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.check_circle_outline), title: Text('A choice')),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: () {}, child: const Text('OK')),
                ],
              ),
            ),
          );
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * tallest),
        child: Material(
          color: s.setColor('background', b) ?? theme.bottomSheetTheme.backgroundColor ?? theme.colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(radius))),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (s.isSet('showHandle') ? s.toggle('showHandle') : true)
                  Container(
                    width: 32,
                    height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 22),
                    decoration: BoxDecoration(
                      color: SurfaceStyle(styles, 'route:/__under', SurfaceKind.page).setColor('handleColor', b) ??
                          theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                SurfaceFrame(id: e.id, child: content),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modal(SurfaceEntry e) => Center(
    child: SurfaceFrame(
      id: e.id,
      child: Builder(
        builder: (c) => AlertDialog(
          title: Text(e.title),
          content: const Text('What this modal says reads like this, at the text size set for it.'),
          actions: [
            TextButton(onPressed: () {}, child: const Text('Cancel')),
            FilledButton(onPressed: () {}, child: const Text('OK')),
          ],
        ),
      ),
    ),
  );
}

/// The values, grouped, each with where it comes from and a way back.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.rows,
    required this.draft,
    required this.styles,
    required this.surface,
    required this.enabled,
    required this.onSet,
  });

  final List<(String, StyleToken, SurfaceKind)> rows;
  final Map<String, Object?> draft;
  final PageStyles styles;
  final String surface;
  final bool enabled;
  final void Function(String key, Object? value) onSet;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final groups = <String, List<(String, StyleToken, SurfaceKind)>>{};
    for (final r in rows) {
      final group = surface == appSurface ? '${kindLabel(r.$3)}s · ${r.$2.group}' : r.$2.group;
      groups.putIfAbsent(group, () => []).add(r);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      children: [
        for (final g in groups.entries) ...[
          Padding(padding: const EdgeInsets.fromLTRB(4, 12, 4, 4), child: Text(g.key, style: t.textTheme.titleMedium)),
          Card(child: Column(children: [for (final r in g.value) _row(context, r)])),
        ],
      ],
    );
  }

  /// Where [key]'s value comes from now.
  String _origin(String key, SurfaceKind kind) {
    if (draft.containsKey(key)) return surface == appSurface ? 'App-wide' : 'Set here';
    if (surface != appSurface && styles.values[appSurface]?[appKey(kind, key)] != null) return 'App-wide';
    return 'App default';
  }

  Widget _row(BuildContext context, (String, StyleToken, SurfaceKind) r) {
    final (key, token, kind) = r;
    // The token as this surface resolves it (app-wide rows: as any surface
    // of their kind with nothing of its own would).
    final at = surface == appSurface ? '__any' : surface;
    final reset = draft.containsKey(key) || draft.containsKey(darkKey(key))
        ? IconButton(
            key: ValueKey('page-style-reset-$key'),
            tooltip: 'Back to ${surface == appSurface ? 'the app default' : 'app-wide / default'}',
            icon: const Icon(Icons.restart_alt),
            onPressed: enabled
                ? () {
                    onSet(key, null);
                    if (token.kind == StyleKind.color) onSet(darkKey(key), null);
                  }
                : null,
          )
        : null;
    switch (token.kind) {
      case StyleKind.number:
        final v = styles.number(at, kind, token);
        final digits = token.step < 1 ? 2 : 0;
        return ListTile(
          title: Text(token.label),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Slider(
                key: ValueKey('page-style-$key'),
                value: v,
                min: token.min,
                max: token.max,
                divisions: ((token.max - token.min) / token.step).round(),
                label: v.toStringAsFixed(digits),
                onChanged: enabled ? (n) => onSet(key, double.parse(n.toStringAsFixed(digits))) : null,
              ),
              Text('${v.toStringAsFixed(digits)} ${token.unit} · ${_origin(key, kind)}'),
            ],
          ),
          trailing: reset,
        );
      case StyleKind.toggle:
        return SwitchListTile(
          key: ValueKey('page-style-$key'),
          title: Text(token.label),
          subtitle: Text(_origin(key, kind)),
          value: styles.toggle(at, kind, token),
          onChanged: enabled ? (on) => onSet(key, on ? 1 : 0) : null,
          secondary: reset,
        );
      case StyleKind.color:
        Widget swatch(Brightness b) {
          final c = styles.color(at, kind, token, b);
          final storeKey = b == Brightness.dark ? darkKey(key) : key;
          return InkWell(
            key: ValueKey('page-style-$storeKey'),
            borderRadius: BorderRadius.circular(8),
            onTap: !enabled
                ? null
                : () async {
                    final picked = await pickStyleColor(context, c, b == Brightness.dark ? 'Dark mode' : 'Light mode');
                    if (picked != null) onSet(storeKey, picked.isEmpty ? null : picked);
                  },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 24,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Theme.of(context).colorScheme.outline),
                    ),
                    child: c == null ? const Icon(Icons.auto_awesome, size: 14) : null,
                  ),
                  Text(b == Brightness.dark ? 'Dark' : 'Light', style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
          );
        }

        return ListTile(
          title: Text(token.label),
          subtitle: Text(
            '${_origin(key, kind)}${styles.color(at, kind, token, Brightness.light) == null ? ' · theme colour' : ''}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [swatch(Brightness.light), swatch(Brightness.dark), ?reset],
          ),
        );
    }
  }
}

/// Presets offered by the colour picker.
const styleColorPresets = <int>[
  0xFFFFFFFF, 0xFFF3F4F6, 0xFFE5E7EB, 0xFF9CA3AF, 0xFF4B5563, 0xFF1F2937, 0xFF111827, 0xFF000000,
  0xFF2DABE2, 0xFF5468FF, 0xFF2B2E8C, 0xFFD8EEFB, 0xFF10B981, 0xFFF59E0B, 0xFFEF4444, 0xFFEC4899,
];

/// Asks for a colour: `#AARRGGBB`, '' to clear it, null when cancelled.
Future<String?> pickStyleColor(BuildContext context, Color? current, String title) {
  final hex = TextEditingController(text: current == null ? '' : styleHex(current));
  return showAppDialog<String>(
    id: 'admin-page-settings.colour',
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        final preview = styleColor(hex.text);
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in styleColorPresets)
                      InkWell(
                        key: ValueKey('style-color-${p.toRadixString(16)}'),
                        onTap: () => set(() => hex.text = styleHex(Color(p))),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Color(p),
                            shape: BoxShape.circle,
                            border: Border.all(color: Theme.of(c).colorScheme.outline),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('style-color-hex'),
                  controller: hex,
                  decoration: InputDecoration(
                    labelText: 'Colour (#RRGGBB or #AARRGGBB)',
                    suffixIcon: Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircleAvatar(radius: 10, backgroundColor: preview ?? Colors.transparent),
                    ),
                  ),
                  onChanged: (_) => set(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, ''), child: const Text('Use default')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('style-color-ok'),
              onPressed: preview == null ? null : () => Navigator.pop(c, styleHex(preview)),
              child: const Text('OK'),
            ),
          ],
        );
      },
    ),
  );
}
