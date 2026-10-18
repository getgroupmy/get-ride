// Admin → App Settings → App updates: latest and minimum version per
// platform, the Force update switch, and the versions accounts are on.
// Saved into the `app-version-setting` rows the apps' update gate reads live
// (features/shell/update_gate.dart): a phone below the minimum, or below the
// latest while Force update is on, gets "Update required" in place of the
// whole app until it is updated.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/live_tables.dart';
import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import '../../widgets/admin_widgets.dart';
import 'app_updates_logic.dart';
import '../../../widgets/page_style_host.dart';

final _appUpdateRowsProvider = FutureProvider.autoDispose<List<SettingEntry>>((ref) {
  ref.watchLive('settings_entries');
  return ref.watch(adminRepositoryProvider).settings(appVersionCategory);
});

/// Accounts' recorded versions; null on a database without migration 0176.
final _installedVersionsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>?>((ref) async {
  ref.watchAdminLive('profiles');
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('profiles')
        .select('app_version, app_platform')
        .not('app_version', 'is', null)
        .limit(20000);
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  } catch (_) {
    return null;
  }
});

class AppUpdatesCard extends ConsumerWidget {
  const AppUpdatesCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(_appUpdateRowsProvider),
      onRetry: () => ref.invalidate(_appUpdateRowsProvider),
      data: (rows) => _AppUpdatesForm(rows: rows, canEdit: canEdit),
    );
  }
}

class _AppUpdatesForm extends ConsumerStatefulWidget {
  const _AppUpdatesForm({required this.rows, required this.canEdit});

  final List<SettingEntry> rows;
  final bool canEdit;

  @override
  ConsumerState<_AppUpdatesForm> createState() => _AppUpdatesFormState();
}

class _AppUpdatesFormState extends ConsumerState<_AppUpdatesForm> {
  final _latest = {for (final p in appUpdatePlatforms) p: TextEditingController()};
  final _min = {for (final p in appUpdatePlatforms) p: TextEditingController()};
  bool _force = false;
  String _adopted = '';

  /// The stored state as text, so another admin's save is picked up while
  /// this card has no unsaved edits.
  String _signature(List<SettingEntry> rows) => [
    for (final p in appUpdatePlatforms) ...[
      '${appUpdateRowFor(rows, p)?.values['version'] ?? ''}',
      '${appUpdateRowFor(rows, p)?.values['minVersion'] ?? ''}',
    ],
    '${forceUpdateOn(rows)}',
  ].join('|');

  String get _current => [
    for (final p in appUpdatePlatforms) ...[_latest[p]!.text.trim(), _min[p]!.text.trim()],
    '$_force',
  ].join('|');

  void _adopt(List<SettingEntry> rows) {
    for (final p in appUpdatePlatforms) {
      final v = appUpdateRowFor(rows, p)?.values;
      _latest[p]!.text = '${v?['version'] ?? ''}';
      _min[p]!.text = '${v?['minVersion'] ?? ''}';
    }
    _force = forceUpdateOn(rows);
    _adopted = _signature(rows);
  }

  @override
  void initState() {
    super.initState();
    _adopt(widget.rows);
  }

  @override
  void didUpdateWidget(_AppUpdatesForm old) {
    super.didUpdateWidget(old);
    if (_current == _adopted && _signature(widget.rows) != _adopted) _adopt(widget.rows);
  }

  @override
  void dispose() {
    for (final c in [..._latest.values, ..._min.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    for (final p in appUpdatePlatforms) {
      final problem = appUpdateProblem(_latest[p]!.text, _min[p]!.text);
      if (problem != null) {
        showError(context, '${appUpdatePlatformLabel(p)}: $problem');
        return;
      }
    }
    if (_force && !forceUpdateOn(widget.rows)) {
      final ok = await showAppDialog<bool>(id: 'app-updates.save',
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Turn on Force update?'),
          content: Text(
            'Every phone below iOS ${_latest['ios']!.text.trim()} or Android ${_latest['android']!.text.trim()} '
            'will show "Update required" and nothing else until it is updated.\n\n'
            'Only do this once those versions are live in the App Store and Google Play, '
            'or nobody on an older build can use the app.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Turn on'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final repo = ref.read(adminRepositoryProvider);
    final saved = await runAdminAction(context, () async {
      for (final p in appUpdatePlatforms) {
        final row = appUpdateRowFor(widget.rows, p);
        final values = appUpdateValues(
          row?.values,
          platform: p,
          latest: _latest[p]!.text,
          min: _min[p]!.text,
          force: _force,
        );
        await repo.saveSetting(appVersionCategory, id: row?.id, values: values);
      }
    }, success: 'Saved — phones apply it straight away');
    if (!mounted || !saved) return;
    ref.invalidate(_appUpdateRowsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final edited = _current != _adopted;
    return Card(
      key: const ValueKey('app-updates-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('App updates', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'The newest version in the stores, and the oldest one still allowed. A phone below the minimum '
              'must update before it can be used; one below the latest is offered the update.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            for (final p in appUpdatePlatforms)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 72,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(appUpdatePlatformLabel(p), style: t.textTheme.titleSmall),
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        key: ValueKey('app-updates-latest-$p'),
                        controller: _latest[p],
                        enabled: widget.canEdit,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(labelText: 'Latest', hintText: '1.4.6', isDense: true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        key: ValueKey('app-updates-min-$p'),
                        controller: _min[p],
                        enabled: widget.canEdit,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(labelText: 'Minimum', hintText: 'None', isDense: true),
                      ),
                    ),
                  ],
                ),
              ),
            SwitchListTile(
              key: const ValueKey('app-updates-force'),
              contentPadding: EdgeInsets.zero,
              value: _force,
              onChanged: widget.canEdit ? (v) => setState(() => _force = v) : null,
              title: const Text('Force update'),
              subtitle: Text(
                _force
                    ? 'Every phone below the latest version is stopped on "Update required" — nothing else in '
                          'the app can be used until it is updated.'
                    : 'Off: only phones below the minimum are stopped; the rest may update later.',
              ),
            ),
            if (widget.canEdit) ...[
              const SizedBox(height: 8),
              BusyButton.filled(
                key: const ValueKey('app-updates-save'),
                onPressed: edited ? _save : null,
                icon: const Icon(Icons.save_outlined),
                child: const Text('Save app updates'),
              ),
            ],
            const SizedBox(height: 16),
            Text('Installed versions', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            _InstalledVersions(
              latest: {
                for (final p in appUpdatePlatforms)
                  if (appUpdateRowFor(widget.rows, p)?.values['version'] case final v?) p: '$v',
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _InstalledVersions extends ConsumerWidget {
  const _InstalledVersions({required this.latest});

  final Map<String, String> latest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return AsyncView(
      value: ref.watch(_installedVersionsProvider),
      onRetry: () => ref.invalidate(_installedVersionsProvider),
      data: (rows) {
        if (rows == null) {
          return Text(
            'Shown once migration 0176 is applied: each account records its version at every launch.',
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          );
        }
        final counts = installedVersionCounts(rows, latest);
        if (counts.isEmpty) {
          return Text(
            'No versions recorded yet. Accounts record theirs the next time they open the app (1.4.6 and later).',
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          );
        }
        return Column(
          children: [
            for (final c in counts)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  c.behind ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                  color: c.behind ? t.colorScheme.error : t.colorScheme.primary,
                ),
                title: Text('${appUpdatePlatformLabel(c.platform)} ${c.version}'),
                subtitle: c.behind ? const Text('Below the latest') : null,
                trailing: Text(c.accounts == 1 ? '1 account' : '${c.accounts} accounts'),
              ),
          ],
        );
      },
    );
  }
}
