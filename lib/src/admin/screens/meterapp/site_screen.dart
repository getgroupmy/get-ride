// Admin → Settings → App Settings (Expo `admin-settings-site`).
//
// The Expo screen keeps theme palettes, icon / splash previews and the default
// start location on the admin's own device (AsyncStorage key
// `app-settings-v1`); nothing in the apps reads it back. This port keeps the
// same JSON under the same key in shared_preferences and says so. The shared,
// public app values (`settings_entries` category `site-settings`, name/value
// rows) are listed underneath so they stay editable from this app.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import '../../widgets/admin_widgets.dart';
import 'pick_image.dart';
import 'site_logic.dart';

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

final _siteValuesProvider =
    FutureProvider.autoDispose((ref) => ref.watch(adminRepositoryProvider).settings(siteValuesCategory));

class AdminSiteSettingsScreen extends ConsumerStatefulWidget {
  const AdminSiteSettingsScreen({super.key});

  @override
  ConsumerState<AdminSiteSettingsScreen> createState() => _AdminSiteSettingsScreenState();
}

class _AdminSiteSettingsScreenState extends ConsumerState<AdminSiteSettingsScreen> {
  Map<String, dynamic>? _s;
  String _mode = 'light';
  final Map<String, TextEditingController> _ctl = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    Map<String, dynamic> s;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(siteSettingsStorageKey);
      s = mergeSiteSettings(raw == null ? null : jsonDecode(raw));
    } catch (_) {
      s = defaultSiteSettings();
    }
    if (mounted) _adopt(s);
  }

  void _adopt(Map<String, dynamic> s) {
    for (final c in _ctl.values) {
      c.dispose();
    }
    _ctl.clear();
    for (final mode in ['light', 'dark']) {
      for (final (key, _) in paletteFields) {
        _ctl['$mode.$key'] = TextEditingController(text: '${(s[mode] as Map)[key]}');
      }
    }
    for (final k in ['splashBgColor', 'startLat', 'startLng']) {
      _ctl[k] = TextEditingController(text: '${s[k]}');
    }
    setState(() => _s = s);
  }

  Map<String, dynamic> _collect() => {
        ..._s!,
        for (final mode in ['light', 'dark'])
          mode: {for (final (key, _) in paletteFields) key: _ctl['$mode.$key']!.text.trim()},
        for (final k in ['splashBgColor', 'startLat', 'startLng']) k: _ctl[k]!.text.trim(),
      };

  Future<void> _save() async {
    final s = _collect();
    final err = validateSiteSettings(s);
    if (err != null) {
      showError(context, err);
      return;
    }
    await runAdminAction(context, () async {
      final p = await SharedPreferences.getInstance();
      await p.setString(siteSettingsStorageKey, jsonEncode(s));
      _s = s;
    }, success: 'Saved on this device');
  }

  Future<void> _pick(String key) async {
    final img = await pickImage();
    if (img == null) return;
    setState(() => _s = {..._collect(), key: 'data:${img.contentType};base64,${base64Encode(img.bytes)}'});
  }

  Widget _colorField(String label, String key) {
    final c = _ctl[key]!;
    final color = hexToColor(c.text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        enabled: ref.watch(pageAccessProvider(sitePage)) == AccessLevel.edit,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label,
          hintText: '#RRGGBB',
          isDense: true,
          errorText: color == null ? 'Invalid hex colour' : null,
          prefixIcon: Padding(
            padding: const EdgeInsets.all(10),
            child: CircleAvatar(radius: 10, backgroundColor: color ?? Colors.transparent),
          ),
        ),
      ),
    );
  }

  Widget _preview(String? uri, IconData placeholder, {Color? bg}) {
    Widget? img;
    if (uri != null && uri.startsWith('data:') && uri.contains(',')) {
      try {
        img = Image.memory(base64Decode(uri.substring(uri.indexOf(',') + 1)), fit: BoxFit.cover);
      } catch (_) {}
    } else if (uri != null && uri.startsWith('http')) {
      img = Image.network(uri, fit: BoxFit.cover);
    }
    return Container(
      width: 72,
      height: 72,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bg ?? Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: img ?? Icon(placeholder),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(sitePage)) == AccessLevel.edit;
    final s = _s;
    final t = Theme.of(context);
    return AdminPage(
      title: 'App Settings',
      page: sitePage,
      actions: [
        if (canEdit)
          IconButton(
            tooltip: 'Restore defaults',
            icon: const Icon(Icons.restart_alt),
            onPressed: () async {
              if (await confirm(context, 'Reset', 'Restore all defaults?', ok: 'Reset')) _adopt(defaultSiteSettings());
            },
          ),
        if (canEdit) BusyIconButton(tooltip: 'Save', icon: const Icon(Icons.save_outlined), onPressed: s == null ? null : _save),
      ],
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
              ResponsiveCenter(
                maxWidth: 720,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.phone_android),
                      title: Text('Stored on this device only'),
                      subtitle: Text('Theme, preview images and start location are kept on this device, exactly as '
                          'the Expo app does. To change what every user sees, use App Icon, Splash Screen and Display '
                          'Settings.'),
                    ),
                  ),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text('Theme Colors', style: t.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'light', label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                            ButtonSegment(value: 'dark', label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                          ],
                          selected: {_mode},
                          onSelectionChanged: (v) => setState(() => _mode = v.first),
                        ),
                        const SizedBox(height: 8),
                        for (final (key, label) in paletteFields) _colorField(label, '$_mode.$key'),
                      ]),
                    ),
                  ),
                  Card(
                    child: ListTile(
                      leading: _preview(s['appIconUri'] as String?, Icons.image_outlined),
                      title: const Text('App Icon'),
                      subtitle: const Text('Square PNG. 1024×1024 recommended.'),
                      trailing: canEdit
                          ? BusyButton.text(
                              onPressed: () => _pick('appIconUri'),
                              child: Text(s['appIconUri'] != null ? 'Replace' : 'Upload'),
                            )
                          : null,
                    ),
                  ),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(children: [
                        ListTile(
                          leading: _preview(s['splashIconUri'] as String?, Icons.auto_awesome,
                              bg: hexToColor(_ctl['splashBgColor']!.text)),
                          title: const Text('Splash Screen'),
                          subtitle: const Text('Splash icon shown on app launch.'),
                          trailing: canEdit
                              ? BusyButton.text(
                                  onPressed: () => _pick('splashIconUri'),
                                  child: Text(s['splashIconUri'] != null ? 'Replace' : 'Upload'),
                                )
                              : null,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _colorField('Splash Background', 'splashBgColor'),
                        ),
                      ]),
                    ),
                  ),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Default Start Location', style: t.textTheme.titleMedium),
                        Text("Used before the user's location is captured.", style: t.textTheme.bodySmall),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _ctl['startLat'],
                              enabled: canEdit,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                              decoration: const InputDecoration(labelText: 'Latitude', hintText: '3.139003'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _ctl['startLng'],
                              enabled: canEdit,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                              decoration: const InputDecoration(labelText: 'Longitude', hintText: '101.686855'),
                            ),
                          ),
                        ]),
                      ]),
                    ),
                  ),
                  if (canEdit)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: BusyButton.filled(onPressed: _save, icon: const Icon(Icons.save_outlined), child: const Text('Save')),
                    ),
                  const SizedBox(height: 16),
                  _SiteValues(canEdit: canEdit),
                  const SizedBox(height: 40),
                ]),
              ),
            ]),
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
