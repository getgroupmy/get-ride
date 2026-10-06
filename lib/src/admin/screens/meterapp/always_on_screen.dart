// Admin → Settings → Always ON (Expo `admin-settings-always-on`).
//
// The set of Expo routes on which a device keeps its screen awake, stored as
// the single `settings_entries` row (category `always-on-pages`, fixed id
// below) with `values.routes` a JSON-encoded array of route names — the same
// shape `utils/alwaysOnStore.ts` reads, so the Expo app keeps working.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../providers.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../../data/live_tables.dart';

const alwaysOnPage = 'admin-settings-always-on';
const alwaysOnCategory = 'always-on-pages';
const alwaysOnRowId = '616c7761-7973-4f6e-8000-000000000001';

const defaultAlwaysOnRoutes = ['partner-teksi', 'partner-ehailing', 'meter-digital'];

const alwaysOnCatalog = [
  ('partner-teksi', 'Teksi Driver Permit', 'Partner Teksi console — Start Pickup / Meter'),
  ('partner-ehailing', 'Partner e-Hailing', 'Live incoming-request queue for online partners'),
  ('meter-digital', 'Meter Digital', 'In-app taxi meter, read off a dash mount all shift'),
  ('ride-running', 'Ride Running (Partner)', "Partner's active-trip screen with live navigation"),
  ('ride-tracking', 'Ride Tracking (Rider)', 'Rider watches the driver approach on the map'),
  ('ride-confirm', 'Ride Confirm (Rider)', 'Rider waits for a partner to accept the request'),
  ('navigation', 'Navigation', 'Turn-by-turn navigation view'),
  ('vehicle-information', 'Vehicle Information', 'Live OBD-II vehicle telemetry'),
  ('obd2-reader', 'OBD-II (CANBus) Reader', 'Pairing / selecting the vehicle reader'),
  ('support-call', 'Support Call', 'Active in-app support call'),
  ('wallet-scan', 'Wallet Scan', 'QR payment scanner held up at the counter'),
  ('wallet-show-code', 'Wallet Show Code', "Rider's payment QR shown to be scanned"),
];

// --- Pure helpers (alwaysOnStore.ts) -----------------------------------------

/// A pathname or route name as its bare first segment (`index` for root).
String normalizeAlwaysOnRoute(String? input) {
  if (input == null) return '';
  final trimmed = input.trim();
  if (trimmed.isEmpty) return '';
  final seg = trimmed.replaceFirst(RegExp(r'^/+'), '').split(RegExp(r'[?#]')).first.split('/').first;
  return seg.isEmpty ? 'index' : seg;
}

List<String> sanitizeAlwaysOnRoutes(Object? routes) {
  if (routes is! List) return [];
  final out = <String>[];
  for (final r in routes) {
    final n = normalizeAlwaysOnRoute(r is String ? r : '');
    if (n.isNotEmpty && !out.contains(n)) out.add(n);
  }
  return out;
}

bool isRouteAlwaysOn(String? pathname, List<String> routes) {
  final current = normalizeAlwaysOnRoute(pathname);
  if (current.isEmpty) return false;
  return routes.any((r) => normalizeAlwaysOnRoute(r) == current);
}

/// A stored `values.routes` (JSON string, array or comma list) as routes.
List<String> parseStoredAlwaysOnRoutes(Object? raw) {
  if (raw is List) return sanitizeAlwaysOnRoutes(raw);
  if (raw is String) {
    final s = raw.trim();
    if (s.isEmpty) return [];
    try {
      final parsed = jsonDecode(s);
      if (parsed is List) return sanitizeAlwaysOnRoutes(parsed);
      return [];
    } catch (_) {
      return sanitizeAlwaysOnRoutes(s.split(','));
    }
  }
  return [];
}

// --- IO --------------------------------------------------------------------------

class AlwaysOnConfig {
  const AlwaysOnConfig(this.routes, {required this.configured, this.updatedAt});
  final List<String> routes;
  final bool configured;
  final String? updatedAt;
}

class AlwaysOnStore {
  AlwaysOnStore(this._db);
  final SupabaseClient _db;

  Future<AlwaysOnConfig> fetch() async {
    final row = await _db
        .from('settings_entries')
        .select('id, values, updated_at')
        .eq('category', alwaysOnCategory)
        .eq('id', alwaysOnRowId)
        .maybeSingle();
    if (row == null) return const AlwaysOnConfig(defaultAlwaysOnRoutes, configured: false);
    return AlwaysOnConfig(
      parseStoredAlwaysOnRoutes((row['values'] as Map?)?['routes']),
      configured: true,
      updatedAt: row['updated_at'] as String?,
    );
  }

  Future<List<String>> save(List<String> routes) async {
    final clean = sanitizeAlwaysOnRoutes(routes);
    await _db.from('settings_entries').upsert({
      'id': alwaysOnRowId,
      'category': alwaysOnCategory,
      'values': {'routes': jsonEncode(clean)},
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'id');
    return clean;
  }
}

final alwaysOnStoreProvider = Provider((ref) => AlwaysOnStore(ref.watch(supabaseProvider)));
final _configProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('settings_entries');
  return ref.watch(alwaysOnStoreProvider).fetch();
});

// --- Screen -------------------------------------------------------------------------

class AdminAlwaysOnScreen extends ConsumerStatefulWidget {
  const AdminAlwaysOnScreen({super.key});

  @override
  ConsumerState<AdminAlwaysOnScreen> createState() => _AdminAlwaysOnScreenState();
}

class _AdminAlwaysOnScreenState extends ConsumerState<AdminAlwaysOnScreen> {
  List<String>? _enabled;
  List<String> _saved = [];
  List<String> _custom = [];
  final _newRoute = TextEditingController();
  bool _saving = false;

  static final _catalogRoutes = {for (final c in alwaysOnCatalog) c.$1};

  @override
  void dispose() {
    _newRoute.dispose();
    super.dispose();
  }

  void _adopt(List<String> routes) {
    _enabled = [...routes];
    _saved = [...routes];
    _custom = routes.where((r) => !_catalogRoutes.contains(r)).toList();
  }

  bool get _dirty {
    final a = [...?_enabled]..sort();
    final b = [..._saved]..sort();
    return a.join(',') != b.join(',');
  }

  void _toggle(String route, bool on) => setState(() {
        final e = _enabled!;
        if (on && !e.contains(route)) e.add(route);
        if (!on) e.remove(route);
      });

  void _add() {
    final route = normalizeAlwaysOnRoute(_newRoute.text);
    if (route.isEmpty) {
      showError(context, 'Enter a page route, e.g. “navigation” or “ride-running”.');
      return;
    }
    setState(() {
      if (!_catalogRoutes.contains(route) && !_custom.contains(route)) _custom.add(route);
      if (!_enabled!.contains(route)) _enabled!.add(route);
      _newRoute.clear();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    List<String>? saved;
    final ok = await runAdminAction(context, () async {
      saved = await ref.read(alwaysOnStoreProvider).save(_enabled!);
    }, success: 'Saved. Every device applies it within a few seconds.');
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok && saved != null) _adopt(saved!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(alwaysOnPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    return AdminPage(
      title: 'Always ON',
      page: alwaysOnPage,
      floatingActionButton: _enabled != null && _dirty
          ? FloatingActionButton.extended(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving…' : 'Save'),
            )
          : null,
      body: AsyncView(
        value: ref.watch(_configProvider),
        onRetry: () => ref.invalidate(_configProvider),
        data: (config) {
          if (_enabled == null) _adopt(config.routes);
          final rows = [
            for (final c in alwaysOnCatalog) (c.$1, c.$2, c.$3, false),
            for (final r in _custom) (r, r, 'Custom page added by an admin', true),
          ];
          return ListView(padding: const EdgeInsets.fromLTRB(0, 16, 0, 96), children: [
            ResponsiveCenter(
              maxWidth: 760,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.wb_sunny_outlined, color: Colors.orange),
                    title: const Text('Keep the screen awake on selected pages'),
                    subtitle: Text('On the pages you switch on, the device screen will never dim, lock or sleep while '
                        'that page is open. It returns to normal auto-sleep as soon as the user leaves.'
                        '${config.configured ? '' : ' Not configured yet — the built-in defaults apply.'}'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                  child: Text('Pages', style: t.textTheme.titleMedium),
                ),
                Card(
                  child: Column(children: [
                    for (final (route, label, desc, custom) in rows)
                      SwitchListTile(
                        title: Text(label),
                        subtitle: Text('$desc\n/$route'),
                        isThreeLine: true,
                        secondary: custom && canEdit
                            ? IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => setState(() {
                                  _custom.remove(route);
                                  _enabled!.remove(route);
                                }),
                              )
                            : const Icon(Icons.wb_sunny_outlined),
                        value: _enabled!.contains(route),
                        onChanged: canEdit ? (v) => _toggle(route, v) : null,
                      ),
                  ]),
                ),
                if (canEdit) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
                    child: Text('Add a page', style: t.textTheme.titleMedium),
                  ),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _newRoute,
                        autocorrect: false,
                        onSubmitted: (_) => _add(),
                        decoration: const InputDecoration(hintText: 'Page route, e.g. navigation'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add')),
                  ]),
                  const SizedBox(height: 4),
                  Text('Enter the page name from its URL (the part after the slash). Adding a page turns it on.',
                      style: t.textTheme.bodySmall),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() {
                        _enabled = [...defaultAlwaysOnRoutes];
                        _custom = defaultAlwaysOnRoutes.where((r) => !_catalogRoutes.contains(r)).toList();
                      }),
                      child: const Text('Restore defaults'),
                    ),
                  ),
                ],
              ]),
            ),
          ]);
        },
      ),
    );
  }
}
