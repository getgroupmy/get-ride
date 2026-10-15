// Admin → Settings → Maps (migration 0200): for riders and partners on each
// kind of device, which map tiles they see and which providers answer place
// search, address lookup and routes (in order), and which saved API key
// each provider uses. Applies live, without an app release.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/map_profile.dart';
import '../../../data/geo_service.dart' show defaultCenter;
import '../../../data/map_profile_repository.dart' show GeoProxy;
import '../../../providers.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'maps_data.dart';
import 'maps_logic.dart';

/// How the page's Test asks `geo` as a given role and device (overridden in
/// tests).
abstract class MapTestProbe {
  Future<Map<String, dynamic>?> ask(String role, String device, Map<String, String> params);
}

class _GeoProbe implements MapTestProbe {
  _GeoProbe(this._ref);
  final Ref _ref;

  @override
  Future<Map<String, dynamic>?> ask(String role, String device, Map<String, String> params) => GeoProxy(
    () => _ref.read(supabaseProvider),
    role: () => role,
    device: MapDevice.values.byName(device),
  ).get(params);
}

final mapTestProbeProvider = Provider<MapTestProbe>((ref) => _GeoProbe(ref));

class AdminMapsScreen extends ConsumerStatefulWidget {
  const AdminMapsScreen({super.key});

  @override
  ConsumerState<AdminMapsScreen> createState() => _AdminMapsScreenState();
}

class _AdminMapsScreenState extends ConsumerState<AdminMapsScreen> {
  MapSettings? _stored;
  MapSettings? _draft;
  String _role = 'rider';
  bool _saving = false;

  bool get _canEdit => ref.watch(pageAccessProvider(mapsPage)) == AccessLevel.edit;

  void _edit(MapSettings next) => setState(() => _draft = next);

  Future<void> _save() async {
    final d = _draft;
    if (d == null) return;
    final conflicts = d.googleConflicts;
    if (conflicts.isNotEmpty) {
      showInfo(context, 'Google search or address lookup needs Google map tiles: ${conflicts.join(', ')}.');
      return;
    }
    setState(() => _saving = true);
    final ok = await runAdminAction(context, () async {
      final saved = await ref.read(mapsRepositoryProvider).save(d);
      if (mounted) setState(() => _stored = _draft = saved);
    }, success: 'Map settings saved. Apps pick it up within a minute.');
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) ref.invalidate(adminMapSettingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(adminMapSettingsProvider);
    // A change saved elsewhere replaces the page's copy, unless it has edits.
    final fresh = loaded.value;
    if (fresh != null && fresh != _stored) {
      if (_draft == null || _draft == _stored) _draft = fresh;
      _stored = fresh;
    }
    final dirty = _draft != null && _draft != _stored;
    return DefaultTabController(
      length: 3,
      child: AdminPage(
        title: 'Maps',
        page: mapsPage,
        bottom: const TabBar(
          tabs: [
            Tab(key: ValueKey('maps-tab-devices'), text: 'Devices'),
            Tab(key: ValueKey('maps-tab-keys'), text: 'Keys'),
            Tab(key: ValueKey('maps-tab-usage'), text: 'Usage'),
          ],
        ),
        actions: [
          if (dirty)
            TextButton(
              key: const ValueKey('maps-discard'),
              onPressed: _saving ? null : () => setState(() => _draft = _stored),
              child: const Text('Discard'),
            ),
        ],
        floatingActionButton: dirty
            ? FloatingActionButton.extended(
                key: const ValueKey('maps-save'),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(_saving ? 'Saving…' : 'Save'),
              )
            : null,
        body: AsyncView(
          value: loaded,
          onRetry: () => ref.invalidate(adminMapSettingsProvider),
          data: (_) => TabBarView(
            children: [
              _DevicesTab(
                settings: _draft!,
                role: _role,
                canEdit: _canEdit,
                onRole: (r) => setState(() => _role = r),
                onChanged: _edit,
              ),
              _KeysTab(settings: _draft!, canEdit: _canEdit, onChanged: _edit),
              const _UsageTab(),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Devices ------------------------------------------------------------------------------------

class _DevicesTab extends ConsumerWidget {
  const _DevicesTab({
    required this.settings,
    required this.role,
    required this.canEdit,
    required this.onRole,
    required this.onChanged,
  });

  final MapSettings settings;
  final String role;
  final bool canEdit;
  final ValueChanged<String> onRole;
  final ValueChanged<MapSettings> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final conflicts = settings.googleConflicts;
    final keys = ref.watch(adminMapApiKeysProvider).value;
    // Synced from GitHub: `geo` uses these when Admin → API Keys has none.
    final synced = ref.watch(adminMapFallbackSlotsProvider).value ?? const <String>{};
    final missing = keys == null
        ? const <String>[]
        : [
            for (final s in mapKeySlots)
              if (settings.usedKeySlots.contains(s.id) &&
                  !mapKeyUsable(keys, settings.keyRef(s.id)) &&
                  !synced.contains(s.id))
                s.label,
          ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        Text(
          'Choose what riders and partners get on each kind of device. "Built in" keeps what the app was '
          'built with. Searches and routes try each provider in order until one answers.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          key: const ValueKey('maps-role'),
          segments: [
            for (final r in mapRoles)
              ButtonSegment(
                value: r,
                label: Text(mapRoleLabel(r)),
                icon: Icon(r == 'partner' ? Icons.local_taxi_outlined : Icons.person_outline),
              ),
          ],
          selected: {role},
          onSelectionChanged: (v) => onRole(v.first),
        ),
        if (conflicts.isNotEmpty)
          _Notice(
            key: const ValueKey('maps-google-warning'),
            icon: Icons.gavel_outlined,
            error: true,
            text:
                "Google's terms: its place search and address lookup may only be shown on Google's map. "
                'Set Google for Map and Map (dark mode), or pick another provider: ${conflicts.join(', ')}.',
          ),
        if (missing.isNotEmpty)
          _Notice(
            key: const ValueKey('maps-missing-keys'),
            icon: Icons.key_off_outlined,
            text:
                'No active key yet for ${missing.join(', ')}. Until there is one, those choices fall back '
                'to the next provider (or what is built in). Add one in Admin → API Keys, or for Google '
                'add it to GitHub and run Actions → Sync map keys.',
          ),
        for (final d in mapDevices)
          _DeviceCard(
            key: ValueKey('maps-device-$role-$d'),
            role: role,
            device: d,
            profile: settings.profile(role, d),
            canEdit: canEdit,
            onChanged: (p) => onChanged(settings.withProfile(role, d, p)),
            onCopyToAll: () => onChanged(settings.copiedToAllDevices(role, d)),
          ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.text, this.error = false});
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final bg = error ? s.errorContainer : s.tertiaryContainer;
    final fg = error ? s.onErrorContainer : s.onTertiaryContainer;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: bg,
      child: ListTile(
        leading: Icon(icon, color: fg),
        title: Text(text, style: TextStyle(color: fg)),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    super.key,
    required this.role,
    required this.device,
    required this.profile,
    required this.canEdit,
    required this.onChanged,
    required this.onCopyToAll,
  });

  final String role;
  final String device;
  final MapProfileSetting profile;
  final bool canEdit;
  final ValueChanged<MapProfileSetting> onChanged;
  final VoidCallback onCopyToAll;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget heading(String s) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(s, style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
    );
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(switch (device) {
                  'android' => Icons.android,
                  'ios' => Icons.phone_iphone,
                  'web' => Icons.public,
                  _ => Icons.desktop_windows_outlined,
                }),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    mapDeviceLabel(device),
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  key: ValueKey('maps-test-$device'),
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Test'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => MapTestDialog(role: role, device: device, profile: profile),
                  ),
                ),
                if (canEdit)
                  IconButton(
                    key: ValueKey('maps-copy-$device'),
                    tooltip: 'Use these for every device',
                    icon: const Icon(Icons.copy_all_outlined),
                    onPressed: onCopyToAll,
                  ),
              ],
            ),
            heading('Map tiles'),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final slot in tileSlots)
                  SizedBox(
                    width: 240,
                    child: _Choice(
                      key: ValueKey('maps-tile-$device-$slot'),
                      label: tileSlotLabel(slot),
                      value: profile.tiles[slot] ?? 'app',
                      options: tileOptions[slot]!,
                      optionLabel: (p) => mapProviderLabel(p, slot: slot),
                      enabled: canEdit,
                      onChanged: (v) => onChanged(profile.withTile(slot, v)),
                    ),
                  ),
              ],
            ),
            heading('Place search'),
            _Order(
              id: 'maps-search-$device',
              value: profile.search,
              options: placeProviders,
              enabled: canEdit,
              onChanged: (v) => onChanged(profile.copyWith(search: v)),
            ),
            heading('Address lookup (reverse geocoding)'),
            _Order(
              id: 'maps-reverse-$device',
              value: profile.reverse,
              options: placeProviders,
              enabled: canEdit,
              onChanged: (v) => onChanged(profile.copyWith(reverse: v)),
            ),
            heading('Routes and ETA'),
            _Order(
              id: 'maps-routing-$device',
              value: profile.routing,
              options: routeProviders,
              enabled: canEdit,
              onChanged: (v) => onChanged(profile.copyWith(routing: v)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.optionLabel,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final String Function(String) optionLabel;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label, isDense: true),
    items: [
      for (final o in options)
        DropdownMenuItem(
          value: o,
          child: Text(optionLabel(o), overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
  );
}

/// First, then (optional) second and third provider to ask.
class _Order extends StatelessWidget {
  const _Order({
    required this.id,
    required this.value,
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  final String id;
  final List<String> value;
  final List<String> options;
  final bool enabled;
  final ValueChanged<List<String>> onChanged;

  static const _none = '';

  @override
  Widget build(BuildContext context) {
    const names = ['First', 'Then', 'Then'];
    final slots = <Widget>[];
    for (var i = 0; i < 3; i++) {
      // A later step only once the one before is set.
      if (i > value.length) break;
      final current = i < value.length ? value[i] : _none;
      final taken = {...value}..remove(current);
      slots.add(
        SizedBox(
          width: 240,
          child: DropdownButtonFormField<String>(
            key: ValueKey('$id-$i'),
            initialValue: current,
            isExpanded: true,
            decoration: InputDecoration(labelText: i == 0 ? names[i] : '${names[i]} (optional)', isDense: true),
            items: [
              if (i > 0) const DropdownMenuItem(value: _none, child: Text('—')),
              for (final o in options)
                if (!taken.contains(o))
                  DropdownMenuItem(
                    value: o,
                    child: Text(
                      '${mapProviderLabel(o)}${freeProviders.contains(o) ? '' : ' · key'}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
            ],
            onChanged: !enabled
                ? null
                : (v) {
                    final next = [...value];
                    if (v == null || v == _none) {
                      next.removeRange(i, next.length);
                    } else if (i < next.length) {
                      next[i] = v;
                    } else {
                      next.add(v);
                    }
                    onChanged(next);
                  },
          ),
        ),
      );
    }
    return Wrap(spacing: 12, runSpacing: 12, children: slots);
  }
}

// ---- Keys ---------------------------------------------------------------------------------------

class _KeysTab extends ConsumerWidget {
  const _KeysTab({required this.settings, required this.canEdit, required this.onChanged});

  final MapSettings settings;
  final bool canEdit;
  final ValueChanged<MapSettings> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final used = settings.usedKeySlots;
    final synced = ref.watch(adminMapFallbackSlotsProvider).value ?? const <String>{};
    return AsyncView(
      value: ref.watch(adminMapApiKeysProvider),
      onRetry: () => ref.invalidate(adminMapApiKeysProvider),
      data: (providers) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Text(
            'Keys are kept in API Keys; here you pick which one each provider uses. Search, address and '
            'route keys stay on the server. Map tile keys are sent to devices (a map has to send them), so '
            "restrict them to the app's Android package, iOS bundle and website in the provider's console.",
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('maps-open-api-keys'),
              icon: const Icon(Icons.vpn_key_outlined),
              label: const Text('Open API Keys'),
              onPressed: () => context.push('/admin/m/api-keys'),
            ),
          ),
          Card(
            key: const ValueKey('maps-google-api'),
            margin: const EdgeInsets.only(top: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Google place search and routes', style: t.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Google has a new and an old API for each. Pick the one your key has turned on, or New with Old '
                    'as the fallback. Address lookup has one version.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    // Keyed by the value so Discard shows the stored choice again.
                    key: ValueKey('maps-google-api-${settings.googleApi}'),
                    initialValue: settings.googleApi,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Google API', isDense: true),
                    items: [
                      for (final (id, label) in mapGoogleApis)
                        DropdownMenuItem(
                          value: id,
                          child: Text(label, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: canEdit ? (v) => v == null ? null : onChanged(settings.withGoogleApi(v)) : null,
                  ),
                ],
              ),
            ),
          ),
          for (final slot in mapKeySlots)
            _KeyRow(
              key: ValueKey('maps-key-${slot.id}'),
              slot: slot,
              choices: mapKeyChoices(providers, slot, settings.keyRef(slot.id)),
              current: settings.keyRef(slot.id),
              inUse: used.contains(slot.id),
              usable: mapKeyUsable(providers, settings.keyRef(slot.id)),
              synced: synced.contains(slot.id),
              canEdit: canEdit,
              onChanged: (ref) => onChanged(settings.withKey(slot.id, ref)),
            ),
        ],
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({
    super.key,
    required this.slot,
    required this.choices,
    required this.current,
    required this.inUse,
    required this.usable,
    this.synced = false,
    required this.canEdit,
    required this.onChanged,
  });

  final MapKeySlot slot;
  final List<MapKeyChoice> choices;
  final String current;
  final bool inUse;
  final bool usable;

  /// No key here, but `geo` has one synced from GitHub.
  final bool synced;
  final bool canEdit;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final (icon, color, status) = !inUse
        ? (Icons.remove_circle_outline, s.outline, 'Not used')
        : usable
        ? (Icons.check_circle_outline, s.primary, 'In use')
        : synced
        ? (Icons.check_circle_outline, s.primary, 'In use, key from GitHub')
        : (Icons.error_outline, s.error, 'In use, no active key');
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(slot.label, style: Theme.of(context).textTheme.titleSmall)),
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 4),
                Text(status, style: TextStyle(color: color)),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: current,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Key', isDense: true),
              items: [
                for (final c in choices)
                  DropdownMenuItem(
                    value: c.ref,
                    child: Text(c.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: canEdit ? (v) => v == null ? null : onChanged(v) : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Usage --------------------------------------------------------------------------------------

class _UsageTab extends ConsumerWidget {
  const _UsageTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return AsyncView(
      value: ref.watch(adminMapUsageProvider),
      onRetry: () => ref.invalidate(adminMapUsageProvider),
      data: (rows) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Calls through the server in the last 30 days (search, address lookup, routes, Google map '
            'sessions). Cached answers cost nothing; Google answers are never cached. Map tiles and '
            'OpenStreetMap lookups go straight from the device and are not counted.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            Text('No calls yet.', key: const ValueKey('maps-usage-empty'), style: t.textTheme.bodyMedium)
          else
            Card(
              child: Column(
                children: [
                  for (final r in rows)
                    ListTile(
                      key: ValueKey('maps-usage-${r.provider}-${r.kind}'),
                      title: Text('${mapProviderLabel(r.provider)} · ${_kindLabel(r.kind)}'),
                      subtitle: Text('${r.cached} cached · ${r.failures} failed'),
                      trailing: Text('${r.calls}', style: t.textTheme.titleMedium),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _kindLabel(String k) => switch (k) {
  'search' => 'place search',
  'reverse' => 'address lookup',
  'routing' => 'routes',
  'tiles' => 'map sessions',
  _ => k,
};

// ---- Test ---------------------------------------------------------------------------------------

/// Asks `geo` as [role] on [device], with the saved settings: the tiles it
/// resolves (one tile drawn from each) and each keyed provider's answer.
class MapTestDialog extends ConsumerStatefulWidget {
  const MapTestDialog({super.key, required this.role, required this.device, required this.profile});

  final String role;
  final String device;
  final MapProfileSetting profile;

  @override
  ConsumerState<MapTestDialog> createState() => _MapTestDialogState();
}

class _Result {
  const _Result(this.label, {required this.ok, required this.detail});
  final String label;
  final bool ok;
  final String detail;
}

class _MapTestDialogState extends ConsumerState<MapTestDialog> {
  MapProfile? _resolved;
  String? _error;
  final _results = <_Result>[];
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final probe = ref.read(mapTestProbeProvider);
    final at = defaultCenter;
    try {
      _resolved = MapProfile.fromJson(await probe.ask(widget.role, widget.device, {'action': 'profile'}));
    } catch (e) {
      _error = errorText(e);
    }
    if (mounted) setState(() {});
    final p = widget.profile;
    final checks = <(String, Map<String, String>, bool Function(Map<String, dynamic>?))>[
      for (final s in p.search)
        if (!freeProviders.contains(s))
          (
            '${mapProviderLabel(s)} · place search',
            {'action': 'search', 'provider': s, 'q': 'KLCC', 'lat': '${at.latitude}', 'lng': '${at.longitude}'},
            (b) => ((b?['places'] as List?) ?? const []).isNotEmpty,
          ),
      for (final s in p.reverse)
        if (!freeProviders.contains(s))
          (
            '${mapProviderLabel(s)} · address lookup',
            {'action': 'reverse', 'provider': s, 'lat': '${at.latitude}', 'lng': '${at.longitude}'},
            (b) => b?['place'] is Map,
          ),
      for (final s in p.routing)
        if (!freeProviders.contains(s))
          (
            '${mapProviderLabel(s)} · route',
            {
              'action': 'route',
              'provider': s,
              'points': '${at.latitude},${at.longitude};${at.latitude + 0.02},${at.longitude + 0.02}',
            },
            (b) => b?['route'] is Map,
          ),
    ];
    for (final (label, params, ok) in checks) {
      final sw = Stopwatch()..start();
      try {
        final body = await probe.ask(widget.role, widget.device, params);
        final good = ok(body);
        _results.add(
          _Result(label, ok: good, detail: good ? '${sw.elapsedMilliseconds} ms' : '${body?['error'] ?? 'No answer'}'),
        );
      } catch (e) {
        _results.add(_Result(label, ok: false, detail: errorText(e)));
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = _resolved;
    final at = defaultCenter;
    Widget tile(String slot, MapTileSpec? spec) => ListTile(
      key: ValueKey('maps-test-tile-$slot'),
      contentPadding: EdgeInsets.zero,
      leading: SizedBox.square(
        dimension: 48,
        child: spec == null
            ? const Icon(Icons.layers_outlined)
            : ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  sampleTileUrl(spec.url, at.latitude, at.longitude),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: t.colorScheme.error),
                ),
              ),
      ),
      title: Text(tileSlotLabel(slot)),
      subtitle: Text(spec == null ? 'Built in' : tileHost(spec.url)),
    );
    return AlertDialog(
      key: const ValueKey('maps-test-dialog'),
      title: Text('Test · ${mapRoleLabel(widget.role)} · ${mapDeviceLabel(widget.device)}'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              'Uses the saved settings, from this device.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'The geo service did not answer: $_error',
                  key: const ValueKey('maps-test-error'),
                  style: TextStyle(color: t.colorScheme.error),
                ),
              ),
            if (r != null) ...[
              tile('light', r.light),
              tile('dark', r.dark),
              tile('satellite', r.satellite),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.traffic_outlined),
                title: const Text('Traffic'),
                subtitle: Text(
                  r.traffic == null
                      ? 'Built in'
                      : r.traffic!.off
                      ? 'Off'
                      : tileHost(r.traffic!.url!),
                ),
              ),
            ],
            for (final x in _results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  x.ok ? Icons.check_circle_outline : Icons.error_outline,
                  color: x.ok ? t.colorScheme.primary : t.colorScheme.error,
                ),
                title: Text(x.label),
                subtitle: Text(x.detail),
              ),
            if (_running)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
