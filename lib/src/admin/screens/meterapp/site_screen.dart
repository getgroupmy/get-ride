// Admin → Settings → App Settings: the one page for what every user's app
// takes from the single `app_branding` row, live — the app icon, the splash
// screen, the theme colours and where maps open — plus the shared
// `site-settings` name / value rows. (It replaces the separate App Icon and
// Splash Screen pages, and the Expo screen's device-only copy of the same
// fields, which no app ever read.)
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_branding.dart';
import '../../../data/branding_cache.dart';
import '../../../features/shell/brand_splash.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import '../../widgets/admin_widgets.dart';
import 'branding_screens.dart';
import 'pick_image.dart';
import 'site_logic.dart';
import '../../../data/live_tables.dart';

const sitePage = 'admin-settings-site';

const siteValuesCategory = SettingsCategory(
  key: 'site-settings',
  page: sitePage,
  title: 'App values',
  subtitle: 'Public name / value settings',
  table: 'settings_entries',
  fields: [
    SettingsField('name', 'Name', FieldKind.text, required: true),
    SettingsField('value', 'Value', FieldKind.text),
  ],
);

final _siteValuesProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('settings_entries');
  return ref.watch(adminRepositoryProvider).settings(siteValuesCategory);
});

class AdminSiteSettingsScreen extends ConsumerStatefulWidget {
  const AdminSiteSettingsScreen({super.key});

  @override
  ConsumerState<AdminSiteSettingsScreen> createState() => _AdminSiteSettingsScreenState();
}

class _AdminSiteSettingsScreenState extends ConsumerState<AdminSiteSettingsScreen> {
  final Map<String, TextEditingController> _ctl = {};
  bool _loaded = false;
  String _mode = 'light';

  /// The splash picture: one picked and not yet uploaded, else the stored URL.
  PickedImage? _splashPicked;
  String? _splashUrl;

  /// The icon: one picked and not yet published, or "use the default".
  PickedImage? _iconPicked;
  bool _iconCleared = false;

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _adopt(AppBranding b) {
    for (final c in _ctl.values) {
      c.dispose();
    }
    _ctl.clear();
    _adopted = appSettingsFields(b);
    for (final e in _adopted.entries) {
      _ctl[e.key] = TextEditingController(text: e.value);
    }
    _splashUrl = b.splashImageUrl;
    _adoptedSplash = b.splashImageUrl;
    _splashPicked = null;
  }

  /// The stored settings the form was last filled from.
  Map<String, String> _adopted = const {};
  String? _adoptedSplash;

  /// Whether the form differs from what it was filled from (unsaved edits).
  bool get _edited => !mapEquals(_fields, _adopted) || _splashPicked != null || _splashUrl != _adoptedSplash;

  Map<String, String> get _fields => {for (final e in _ctl.entries) e.key: e.value.text};

  /// What the splash previews show: the form as it stands.
  AppBranding get _draft {
    final f = _fields;
    String? hex(String k) => isValidHex(f[k] ?? '') ? f[k]!.trim() : null;
    return AppBranding(
      splashImageUrl: _splashPicked != null ? 'https://preview' : _splashUrl,
      splashBgLight: hex('splash.light'),
      splashBgDark: hex('splash.dark'),
    );
  }

  /// Edit rights on this page or on either page it absorbed.
  bool get _canEdit => [
    sitePage,
    'admin-settings-app-icon',
    'admin-settings-splash',
  ].any((p) => ref.watch(pageAccessProvider(p)) == AccessLevel.edit);

  Future<void> _save() async {
    final f = _fields;
    final err = validateAppSettings(f);
    if (err != null) {
      showError(context, err);
      return;
    }
    final store = ref.read(brandingStoreProvider);
    final ok = await runAdminAction(context, () async {
      final picked = _splashPicked;
      final url = picked != null ? await store.upload(picked, 'splash') : _splashUrl;
      await store.update({...appSettingsPatch(f), 'splash_image_url': url});
      _splashUrl = url;
      _splashPicked = null;
      // Saved: what the form holds is now what is stored.
      _adopted = f;
      _adoptedSplash = url;
    }, success: 'Saved — every user\'s app now uses it');
    if (!mounted) return;
    setState(() {});
    if (ok) ref.invalidate(brandingProvider);
  }

  Future<void> _publishIcon(String? stored) async {
    if (_iconPicked == null && !(_iconCleared && stored != null)) {
      showInfo(context, 'Pick a new icon image first.');
      return;
    }
    final store = ref.read(brandingStoreProvider);
    final ok = await runAdminAction(context, () async {
      final url = _iconPicked != null ? await store.upload(_iconPicked!, 'icon') : null;
      await store.update({'app_icon_url': url, 'icon_changed_at': DateTime.now().toUtc().toIso8601String()});
    });
    if (!mounted || !ok) return;
    setState(() {
      _iconPicked = null;
      _iconCleared = false;
    });
    ref.invalidate(brandingProvider);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline),
        title: const Text('App icon published'),
        content: const Text('The website\'s tab icon has changed, and every user of the app sees a one-time '
            '"App icon updated" popup. The icon on phones\' home screens changes with the next App Release build.'),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
      ),
    );
  }

  Widget _section(String title, String subtitle, List<Widget> children) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(subtitle, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }

  /// A colour field: blank is the app's default ([fallback], when known).
  Widget _colorField(String key, String label, {String? fallback, List<String> presets = const []}) {
    final c = _ctl[key]!;
    final text = c.text.trim();
    final color = hexToColor(text.isEmpty ? (fallback ?? '') : text);
    final bad = text.isNotEmpty && !isValidHex(text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          key: ValueKey('app-settings-$key'),
          controller: c,
          enabled: _canEdit,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: label,
            hintText: fallback == null ? 'Default' : 'Default $fallback',
            isDense: true,
            errorText: bad ? 'Use #RRGGBB' : null,
            prefixIcon: Padding(
              padding: const EdgeInsets.all(10),
              child: CircleAvatar(
                radius: 10,
                backgroundColor: color ?? Colors.transparent,
                child: color == null ? const Icon(Icons.auto_awesome, size: 12) : null,
              ),
            ),
            suffixIcon: text.isEmpty || !_canEdit
                ? null
                : IconButton(
                    tooltip: 'Use the default',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(c.clear),
                  ),
          ),
        ),
        if (presets.isNotEmpty && _canEdit)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in presets)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => c.text = p),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: hexToColor(p),
                      shape: BoxShape.circle,
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                  ),
                ),
            ]),
          ),
      ]),
    );
  }

  Widget _iconSection(AppBranding stored) {
    final url = _iconCleared ? null : stored.appIconUrl;
    final bytes = _iconPicked?.bytes;
    final hasIcon = bytes != null || url != null;
    final t = Theme.of(context);
    return _section(
      'App Icon',
      'The website\'s tab icon changes as soon as it is published, and every app user is told once with a popup. '
          'The icon on phones\' home screens is part of the installed app: the next App Release build uses it.',
      [
        Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, spacing: 16, children: [
          BrandingImageBox(bytes: bytes, url: url, size: 120, radius: 28),
          BrandingImageBox(bytes: bytes, url: url, size: 64, radius: 16),
          BrandingImageBox(bytes: bytes, url: url, size: 40, radius: 10),
        ]),
        const SizedBox(height: 8),
        Text(
          'Square PNG, 1024×1024, no transparency.${hasIcon ? '' : ' No custom icon: the built-in one is used.'}',
          textAlign: TextAlign.center,
          style: t.textTheme.bodySmall,
        ),
        if (_canEdit) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            BusyButton.tonal(
              key: const ValueKey('app-icon-upload'),
              icon: const Icon(Icons.upload),
              onPressed: () async {
                final img = await pickImage();
                if (img != null) setState(() => _iconPicked = img);
              },
              child: Text(hasIcon ? 'Replace icon' : 'Upload icon'),
            ),
            if (hasIcon)
              TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Use default'),
                onPressed: () => setState(() {
                  _iconPicked = null;
                  _iconCleared = true;
                }),
              ),
            BusyButton.filled(
              key: const ValueKey('app-icon-publish'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.publish),
              onPressed: _iconPicked == null && !(_iconCleared && stored.appIconUrl != null)
                  ? null
                  : () => _publishIcon(stored.appIconUrl),
              child: const Text('Publish to all users'),
            ),
          ]),
        ],
      ],
    );
  }

  Widget _splashSection() {
    final t = Theme.of(context);
    final draft = _draft;
    final preview = CachedBranding(draft, _splashPicked?.bytes);
    Widget phone(bool dark, String label) => Column(children: [
          Container(
            width: 130,
            height: 230,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: t.colorScheme.outlineVariant),
            ),
            child: SplashView(cached: preview, latest: _splashPicked == null ? draft : null, dark: dark),
          ),
          const SizedBox(height: 6),
          Text(label, style: t.textTheme.labelMedium),
        ]);
    final hasImage = _splashPicked != null || _splashUrl != null;
    return _section(
      'Splash Screen',
      'Shown for ${splashHold.inSeconds} seconds when the Android and iOS apps start. Without a picture '
          '"GET." is shown. The website has no splash screen.',
      [
        Wrap(alignment: WrapAlignment.center, spacing: 16, runSpacing: 16, children: [
          phone(false, 'Light mode'),
          phone(true, 'Dark mode'),
        ]),
        if (_canEdit) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
            BusyButton.tonal(
              key: const ValueKey('splash-upload'),
              icon: const Icon(Icons.upload),
              onPressed: () async {
                final img = await pickImage();
                if (img != null) setState(() => _splashPicked = img);
              },
              child: Text(hasImage ? 'Replace image' : 'Upload image'),
            ),
            if (hasImage)
              TextButton.icon(
                key: const ValueKey('splash-clear'),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove image'),
                onPressed: () => setState(() {
                  _splashPicked = null;
                  _splashUrl = null;
                }),
              ),
          ]),
        ],
        const SizedBox(height: 8),
        _colorField('splash.light', 'Background — light mode', fallback: '#FFFFFF', presets: splashPresetColors),
        _colorField('splash.dark', 'Background — dark mode', fallback: '#000000', presets: splashPresetColors),
      ],
    );
  }

  Widget _themeSection() {
    return _section(
      'Theme Colors',
      'The app\'s colours, separately for light and dark mode. Blank keeps the app\'s own; Text, Border and Error '
          'are otherwise worked out from the Accent.',
      [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'light', label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
            ButtonSegment(value: 'dark', label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
          ],
          selected: {_mode},
          onSelectionChanged: (v) => setState(() => _mode = v.first),
        ),
        const SizedBox(height: 8),
        for (final k in themeColorKeys)
          _colorField(
            '$_mode.$k',
            themeColorLabels[k]!,
            fallback: _mode == 'light' ? themeColorDefaults[k]!.light : themeColorDefaults[k]!.dark,
          ),
      ],
    );
  }

  Widget _startSection() {
    return _section(
      'Default Start Location',
      'Where maps open before the user\'s location is known. Blank is Kuala Lumpur.',
      [
        Row(children: [
          Expanded(
            child: TextField(
              key: const ValueKey('app-settings-startLat'),
              controller: _ctl['startLat'],
              enabled: _canEdit,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Latitude', hintText: '3.139003'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const ValueKey('app-settings-startLng'),
              controller: _ctl['startLng'],
              enabled: _canEdit,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Longitude', hintText: '101.686855'),
            ),
          ),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _canEdit;
    return AdminPage(
      title: 'App Settings',
      page: sitePage,
      actions: [
        if (canEdit)
          BusyIconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.save_outlined),
            onPressed: _loaded ? _save : null,
          ),
      ],
      body: AsyncView(
        value: ref.watch(brandingProvider),
        onRetry: () => ref.invalidate(brandingProvider),
        data: (row) {
          final stored = AppBranding.fromRow(row);
          // Filled once, then again whenever the stored settings change (an
          // other admin's save) while this form has no unsaved edits.
          if (!_loaded || (!_edited && !mapEquals(appSettingsFields(stored), _adopted))) {
            _loaded = true;
            _adopt(stored);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() {});
            });
          }
          return ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            ResponsiveCenter(
              maxWidth: 720,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.public),
                    title: Text('Applies to every user'),
                    subtitle: Text('Saved here, these change every user\'s app straight away — no update or '
                        'relaunch needed — except the home-screen icon, which comes with the next App Release.'),
                  ),
                ),
                _iconSection(stored),
                _splashSection(),
                _themeSection(),
                _startSection(),
                if (canEdit)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: BusyButton.filled(
                      key: const ValueKey('app-settings-save'),
                      onPressed: _save,
                      icon: const Icon(Icons.save_outlined),
                      child: const Text('Save splash, colours & start location'),
                    ),
                  ),
                const SizedBox(height: 16),
                _SiteValues(canEdit: canEdit),
                const SizedBox(height: 40),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

/// The shared `site-settings` name / value rows.
class _SiteValues extends ConsumerWidget {
  const _SiteValues({required this.canEdit});
  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, [SettingEntry? e]) async {
    final name = TextEditingController(text: '${e?.values['name'] ?? ''}');
    final value = TextEditingController(text: '${e?.values['value'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(e == null ? 'Add value' : 'Edit value'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            TextField(controller: value, decoration: const InputDecoration(labelText: 'Value')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    final input = {'name': name.text, 'value': value.text};
    name.dispose();
    value.dispose();
    if (ok != true || !context.mounted) return;
    final res = coerceValues(siteValuesCategory.fields, input);
    if (res.error != null) {
      showError(context, res.error!);
      return;
    }
    final repo = ref.read(adminRepositoryProvider);
    final values = e == null ? res.values : {...e.values, ...res.values};
    if (await runAdminAction(context, () => repo.saveSetting(siteValuesCategory, id: e?.id, values: values), success: 'Saved')) {
      ref.invalidate(_siteValuesProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('Shared app values', style: t.textTheme.titleMedium)),
        if (canEdit) BusyButton.text(onPressed: () => _edit(context, ref), icon: const Icon(Icons.add), child: const Text('Add')),
      ]),
      Text('Name / value pairs in the shared settings (category site-settings), visible to every device.',
          style: t.textTheme.bodySmall),
      AsyncView(
        value: ref.watch(_siteValuesProvider),
        onRetry: () => ref.invalidate(_siteValuesProvider),
        data: (rows) => Column(children: [
          if (rows.isEmpty) const ListTile(title: Text('No values')),
          for (final e in rows)
            Card(
              child: BusyListTile(
                title: Text('${e.values['name'] ?? ''}'),
                subtitle: Text('${e.values['value'] ?? ''}'),
                onTap: canEdit ? () => _edit(context, ref, e) : null,
                trailing: canEdit
                    ? BusyIconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (!await confirm(context, 'Delete value?', '${e.values['name'] ?? ''}', ok: 'Delete')) return;
                          if (!context.mounted) return;
                          if (await runAdminAction(
                              context, () => ref.read(adminRepositoryProvider).deleteSetting(siteValuesCategory, e.id))) {
                            ref.invalidate(_siteValuesProvider);
                          }
                        },
                      )
                    : null,
              ),
            ),
        ]),
      ),
    ]);
  }
}
