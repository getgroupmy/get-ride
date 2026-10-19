// Admin → App Settings → Home-screen icon (app_settings 'app_icon',
// core/app_icons.dart): follow the schedule or fix one icon for everyone,
// whether Settings shows the App icon row, whether passengers and drivers
// may pick their own, and the schedule itself (the first window covering a
// day wins). The icons are built into the app;
// changes here reach every phone the next time the app is opened.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_icons.dart';
import '../../../data/app_icon_service.dart';
import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';

class AppIconCard extends ConsumerStatefulWidget {
  const AppIconCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<AppIconCard> createState() => _AppIconCardState();
}

class _AppIconCardState extends ConsumerState<AppIconCard> {
  AppIconConfig? _stored;
  AppIconConfig? _draft;

  AppIconConfig _load(AppIconConfig stored) {
    if (_stored == null || (_draft == _stored && !identical(stored, _stored))) {
      _stored = stored;
      _draft = stored;
    }
    return _draft!;
  }

  void _edit(AppIconConfig next) => setState(() => _draft = next);

  Future<void> _save() async {
    final c = _draft;
    if (c == null) return;
    final ok = await runAdminAction(
      context,
      () => saveAppIconConfig(ref.read(supabaseProvider), c),
      success: 'Home-screen icon saved',
    );
    if (ok && mounted) {
      _stored = null;
      ref.invalidate(appIconConfigProvider);
    }
  }

  Future<void> _editWindow({int? index}) async {
    final c = _draft!;
    final w = await showAppDialog<IconWindow>(id: 'app-icon.edit-window',
      context: context,
      builder: (_) => _WindowDialog(window: index == null ? null : c.schedule[index]),
    );
    if (w == null) return;
    final list = [...c.schedule];
    if (index == null) {
      list.add(w);
    } else {
      list[index] = w;
    }
    _edit(c.copyWith(schedule: list));
  }

  void _move(int from, int to) {
    final list = [..._draft!.schedule];
    list.insert(to, list.removeAt(from));
    _edit(_draft!.copyWith(schedule: list));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final edit = widget.canEdit;
    return Card(
      key: const ValueKey('app-icon-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(appIconConfigProvider),
          onRetry: () => ref.invalidate(appIconConfigProvider),
          data: (stored) {
            final c = _load(stored);
            final today = c.automatic ? scheduledAppIcon(c, DateTime.now()) : c.fixedIcon;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Home-screen icon', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'The icons below come with the app, each in light and dark. Phones switch the next time the app '
                  'is opened (iPhone shows a short notice). Today, for most users: ${appIconById(today)!.name}.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                SwitchListTile(
                  key: const ValueKey('app-icon-auto'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Change automatically'),
                  subtitle: const Text('Follow the schedule below; off, everyone gets one icon.'),
                  value: c.automatic,
                  onChanged: edit ? (v) => _edit(c.copyWith(automatic: v)) : null,
                ),
                if (!c.automatic)
                  SearchableDropdownFormField<String>(
                    key: const ValueKey('app-icon-fixed'),
                    initialValue: c.fixedIcon,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Icon for everyone'),
                    items: [for (final i in appIcons) DropdownMenuItem(value: i.id, child: _IconLabel(i))],
                    onChanged: edit ? (v) => _edit(c.copyWith(fixedIcon: v)) : null,
                  ),
                SwitchListTile(
                  key: const ValueKey('app-icon-show-in-settings'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show "App icon" in Settings'),
                  subtitle: Text(
                    c.showInSettings
                        ? 'Passengers and drivers see Settings > App icon.'
                        : 'Hidden: everyone follows the icon set here, whatever they picked before.',
                  ),
                  value: c.showInSettings,
                  onChanged: edit ? (v) => _edit(c.copyWith(showInSettings: v)) : null,
                ),
                SwitchListTile(
                  key: const ValueKey('app-icon-allow-choice'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Let passengers and drivers choose'),
                  subtitle: Text(
                    c.showInSettings
                        ? '"Automatic" is the default there; off, the page only shows the icons.'
                        : 'Only with "App icon" shown in Settings.',
                  ),
                  value: c.allowUserChoice,
                  onChanged: edit && c.showInSettings ? (v) => _edit(c.copyWith(allowUserChoice: v)) : null,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: Text('Schedule (top wins)', style: t.textTheme.labelLarge)),
                    if (edit)
                      Flexible(
                        child: TextButton(
                        key: const ValueKey('app-icon-reset'),
                        onPressed: () => _edit(c.copyWith(schedule: defaultIconSchedule)),
                        child: const Text('Standard schedule'),
                      )),
                  ],
                ),
                for (final (i, w) in c.schedule.indexed)
                  ListTile(
                    key: ValueKey('app-icon-window-$i'),
                    contentPadding: EdgeInsets.zero,
                    leading: _Thumb(appIconById(w.icon)!),
                    title: Text(appIconById(w.icon)!.name),
                    subtitle: Text(
                      [w.describe, if (w.regions.isNotEmpty) 'only in ${w.regions.join(', ')}'].join(' · '),
                    ),
                    enabled: w.enabled,
                    onTap: edit ? () => _editWindow(index: i) : null,
                    trailing: !edit
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: w.enabled,
                                onChanged: (v) {
                                  final list = [...c.schedule]..[i] = w.copyWith(enabled: v);
                                  _edit(c.copyWith(schedule: list));
                                },
                              ),
                              PopupMenuButton<String>(
                                onSelected: (a) => switch (a) {
                                  'up' => _move(i, i - 1),
                                  'down' => _move(i, i + 1),
                                  _ => _edit(c.copyWith(schedule: [...c.schedule]..removeAt(i))),
                                },
                                itemBuilder: (_) => [
                                  if (i > 0) const PopupMenuItem(value: 'up', child: Text('Move up')),
                                  if (i < c.schedule.length - 1)
                                    const PopupMenuItem(value: 'down', child: Text('Move down')),
                                  const PopupMenuItem(value: 'remove', child: Text('Remove')),
                                ],
                              ),
                            ],
                          ),
                  ),
                if (edit) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('app-icon-add'),
                      icon: const Icon(Icons.add),
                      label: const Text('Add a window'),
                      onPressed: () => _editWindow(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  BusyButton.filled(
                    key: const ValueKey('app-icon-save'),
                    onPressed: _draft == _stored ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save home-screen icon'),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb(this.icon);

  final AppIconDef icon;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(9),
    child: Image.asset(
      icon.preview(dark: Theme.of(context).brightness == Brightness.dark),
      width: 40,
      height: 40,
      errorBuilder: (_, _, _) => const SizedBox.square(dimension: 40, child: Icon(Icons.apps)),
    ),
  );
}

class _IconLabel extends StatelessWidget {
  const _IconLabel(this.icon);

  final AppIconDef icon;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox.square(dimension: 28, child: _Thumb(icon)),
      const SizedBox(width: 10),
      Flexible(child: Text(icon.name, overflow: TextOverflow.ellipsis)),
    ],
  );
}

/// Adds or edits one window.
class _WindowDialog extends StatefulWidget {
  const _WindowDialog({this.window});

  final IconWindow? window;

  @override
  State<_WindowDialog> createState() => _WindowDialogState();
}

class _WindowDialogState extends State<_WindowDialog> {
  late String _icon = widget.window?.icon ?? 'payday';
  late IconWindowKind _kind = widget.window?.kind ?? IconWindowKind.annual;
  late final _start = TextEditingController(text: widget.window?.start ?? '');
  late final _end = TextEditingController(text: widget.window?.end ?? '');
  late final _regions = TextEditingController(text: widget.window?.regions.join(', ') ?? '');

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _regions.dispose();
    super.dispose();
  }

  IconWindow get _window => IconWindow(
    icon: _icon,
    kind: _kind,
    start: _start.text.trim(),
    end: _end.text.trim(),
    regions: [
      for (final r in _regions.text.split(','))
        if (r.trim().isNotEmpty) r.trim(),
    ],
    enabled: widget.window?.enabled ?? true,
  );

  String get _format => switch (_kind) {
    IconWindowKind.annual => 'MM-DD, e.g. 12-27',
    IconWindowKind.dated => 'YYYY-MM-DD, e.g. 2027-02-06',
    IconWindowKind.monthly => 'Day of the month, e.g. 25',
  };

  @override
  Widget build(BuildContext context) {
    final w = _window;
    return AlertDialog(
      title: Text(widget.window == null ? 'Add a window' : 'Edit window'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SearchableDropdownFormField<String>(
              key: const ValueKey('app-icon-window-icon'),
              initialValue: _icon,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Icon'),
              items: [for (final i in appIcons) DropdownMenuItem(value: i.id, child: _IconLabel(i))],
              onChanged: (v) => setState(() => _icon = v ?? _icon),
            ),
            const SizedBox(height: 8),
            SearchableDropdownFormField<IconWindowKind>(
              key: const ValueKey('app-icon-window-kind'),
              initialValue: _kind,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Repeats'),
              items: const [
                DropdownMenuItem(value: IconWindowKind.annual, child: Text('Every year')),
                DropdownMenuItem(value: IconWindowKind.dated, child: Text('Once (exact dates)')),
                DropdownMenuItem(value: IconWindowKind.monthly, child: Text('Every month')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            TextField(
              key: const ValueKey('app-icon-window-start'),
              controller: _start,
              decoration: InputDecoration(labelText: 'From', helperText: _format),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const ValueKey('app-icon-window-end'),
              controller: _end,
              decoration: const InputDecoration(labelText: 'To (included)'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const ValueKey('app-icon-window-regions'),
              controller: _regions,
              decoration: const InputDecoration(
                labelText: 'Only in (optional)',
                helperText: 'States or countries, separated by commas',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('app-icon-window-done'),
          onPressed: w.valid ? () => Navigator.pop(context, w) : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}
