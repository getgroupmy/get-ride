import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/commission.dart';
import '../../core/format.dart' show formatDateTime;
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../profile_search.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';
import '../../widgets/page_style_host.dart';
import 'commission_promotions_tabs.dart';
import 'commission_settings_tabs.dart';
import 'geo/geo_data.dart' show regionsProvider;
import 'geo/geo_logic.dart' show RegionEntry, RegionLevel, regionNamesAt;
import '../../widgets/search_select.dart';

final commissionRatesProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('commission_rates');
  return ref.watch(adminRepositoryProvider).commissionRates();
});

/// Every change to a rate (0216), newest first.
final commissionHistoryProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('commission_rates');
  return ref.watch(adminRepositoryProvider).commissionHistory();
});

/// Completed trips never charged (0216); empty where the database doesn't
/// have the list yet.
final unchargedCommissionsProvider = FutureProvider.autoDispose((ref) async {
  ref.watchLive('commission_rates');
  try {
    return await ref.watch(adminRepositoryProvider).unchargedCommissions();
  } catch (_) {
    return const <Map<String, dynamic>>[];
  }
});

const commissionLevels = ['master', 'country', 'state', 'city', 'suburb', 'user'];

/// A commission level in words: `master` → "Master", `user` → "One person".
String commissionLevelLabel(Object? level) => switch ('$level') {
      'user' => 'One person',
      '' || 'null' => 'Unknown',
      final l => '${l[0].toUpperCase()}${l.substring(1)}',
    };

String _pct(Object? rate) => '${(((rate as num?) ?? 0) * 100).toStringAsFixed(2)}%';

/// One history row in words: "Added 12.00% · city (Kajang, Selangor)",
/// "Changed rate 12.00% → 10.00%, priority 0 → 5", "Deleted …". Pure.
String commissionHistoryLine(Map<String, dynamic> h) {
  final before = h['old_row'] is Map ? Map<String, dynamic>.from(h['old_row'] as Map) : null;
  final after = h['new_row'] is Map ? Map<String, dynamic>.from(h['new_row'] as Map) : null;
  String rule(Map<String, dynamic> r) => '${_pct(r['rate'])} · ${r['level']} (${commissionScopeLabel(r)})';
  // Tiers (0218) and promotions (0224) share the history: "Added promotion "Raya week"".
  final kind = '${h['op']}'.split(':');
  if (kind.length == 2) {
    final what = kind.first == 'promo' ? 'promotion' : 'tier';
    final name = (after ?? before)?['name'];
    final called = name == null ? '' : ' "$name"';
    return switch (kind.last) {
      'insert' => 'Added $what$called',
      'delete' => 'Deleted $what$called',
      _ => 'Changed $what$called',
    };
  }
  switch (h['op']) {
    case 'insert':
      return after == null ? 'Added' : 'Added ${rule(after)}';
    case 'delete':
      return before == null ? 'Deleted' : 'Deleted ${rule(before)}';
  }
  if (before == null || after == null) return 'Changed';
  final changes = <String>[
    if (before['rate'] != after['rate']) 'rate ${_pct(before['rate'])} → ${_pct(after['rate'])}',
    if (before['active'] != after['active']) after['active'] == true ? 'turned on' : 'turned off',
    if ((before['priority'] ?? 0) != (after['priority'] ?? 0)) 'priority ${before['priority'] ?? 0} → ${after['priority'] ?? 0}',
    if (before['level'] != after['level']) 'level ${before['level']} → ${after['level']}',
    if (commissionScopeLabel(before) != commissionScopeLabel(after))
      'scope ${commissionScopeLabel(before)} → ${commissionScopeLabel(after)}',
    if ((before['note'] ?? '') != (after['note'] ?? '')) 'note "${after['note'] ?? ''}"',
  ];
  return changes.isEmpty ? 'Saved ${rule(after)} (no change)' : 'Changed ${rule(before)}: ${changes.join(', ')}';
}

/// Which geography fields a level needs (mirrors Expo `validateCommissionInput`).
List<String> requiredScope(String level) => switch (level) {
      'country' => ['country'],
      'state' => ['country', 'state'],
      'city' => ['country', 'state', 'city'],
      'suburb' => ['country', 'state', 'city', 'suburb'],
      'user' => ['user_id'],
      _ => [],
    };

String commissionScopeLabel(Map<String, dynamic> r) => switch (r['level']) {
      'master' => 'Platform default',
      'user' => 'User: ${r['user_label'] ?? r['user_id']}',
      _ => [r['suburb'], r['city'], r['state'], r['country']].whereType<String>().where((s) => s.isNotEmpty).join(', '),
    };

class AdminCommissionScreen extends ConsumerWidget {
  const AdminCommissionScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Map<String, dynamic>? row]) async {
    final result = await showAppDialog<Map<String, dynamic>>(id: 'commission.edit',
      context: context,
      builder: (_) => _RateDialog(row: row, searchPeople: ref.read(adminRepositoryProvider).searchPeople),
    );
    if (result == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveCommissionRate(result),
      success: 'Rate saved',
    );
    if (ok) ref.invalidate(commissionRatesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(moduleAccessProvider('commission')) == AccessLevel.edit;
    return DefaultTabController(
      length: 5,
      child: AdminPage(
      title: 'Commission',
      module: 'commission',
      bottom: const TabBar(
        tabs: [
          Tab(key: ValueKey('commission-tab-rates'), text: 'Rates'),
          Tab(key: ValueKey('commission-tab-settings'), text: 'Settings'),
          Tab(key: ValueKey('commission-tab-tiers'), text: 'Tiers'),
          Tab(key: ValueKey('commission-tab-promotions'), text: 'Promotions'),
          Tab(key: ValueKey('commission-tab-reports'), text: 'Reports'),
        ],
        isScrollable: true,
        tabAlignment: TabAlignment.start,
      ),
      actions: [
        IconButton(
          key: const ValueKey('commission-history'),
          tooltip: 'Change history',
          icon: const Icon(Icons.history),
          onPressed: () => showAdminSheet<void>(context, title: 'Change history', builder: (_) => const _HistoryList()),
        ),
      ],
      body: TabBarView(children: [
      AsyncView(
        value: ref.watch(commissionRatesProvider),
        onRetry: () => ref.invalidate(commissionRatesProvider),
        data: (rows) {
          final sorted = [...rows]
            ..sort((a, b) => commissionLevels.indexOf('${a['level']}').compareTo(commissionLevels.indexOf('${b['level']}')));
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('How rates are chosen'),
                subtitle: Text('The most specific active rule wins: user → suburb → city → state → country → '
                    'master. Between rules at the same level, the higher priority wins, then the one naming more '
                    'of its parents, then the newest. Places are matched by the region map where a region has an '
                    'outline, otherwise by name. The rate is locked when the driver accepts the trip. With no '
                    'rules at all, ${(defaultCommissionRate * 100).toStringAsFixed(0)}% applies.'),
              ),
            ),
            _UnchargedCard(canEdit: canEdit),
            // Only for admins who may change rates.
            if (canEdit)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('commission-add'),
                    onPressed: () => _edit(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Add rate'),
                  ),
                ),
              ),
            if (sorted.isEmpty) const EmptyState(icon: Icons.percent, title: 'No commission rules yet'),
            for (final r in sorted)
              Card(
                child: BusyListTile(
                  leading: CircleAvatar(child: Text('${r['level']}'.substring(0, 1).toUpperCase())),
                  title: Text('${_pct(r['rate'])} · ${commissionLevelLabel(r['level'])}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                    commissionScopeLabel(r),
                    if (((r['priority'] as num?) ?? 0) != 0) 'Priority ${r['priority']}',
                    if ('${r['note'] ?? ''}'.trim().isNotEmpty) '${r['note']}'.trim(),
                  ].join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    _ActiveSwitch(key: ValueKey('commission-active-${r['id']}'), row: r, canEdit: canEdit),
                    if (canEdit)
                      BusyIconButton(
                        tooltip: 'Delete rule',
                        icon: const Icon(Icons.delete_outline),

                        onPressed: () async {
                          if (!await confirm(context, 'Delete rule?', commissionScopeLabel(r), ok: 'Delete')) return;
                          if (!context.mounted) return;
                          if (await runAdminAction(
                              context, () => ref.read(adminRepositoryProvider).deleteCommissionRate(r['id'] as String))) {
                            ref.invalidate(commissionRatesProvider);
                          }
                        },
                      ),
                  ]),
                  onTap: canEdit ? () => _edit(context, ref, r) : null,
                ),
              ),
          ]);
        },
      ),
      CommissionSettingsTab(canEdit: canEdit),
      CommissionTiersTab(canEdit: canEdit),
      CommissionPromotionsTab(canEdit: canEdit),
      const CommissionReportsTab(),
      ]),
    ),
    );
  }
}

/// Completed trips whose commission was never charged (a failed charge is
/// kept on the trip, 0216), with "Charge now". Hidden while there are none.
class _UnchargedCard extends ConsumerWidget {
  const _UnchargedCard({required this.canEdit});
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(unchargedCommissionsProvider).value ?? const <Map<String, dynamic>>[];
    if (rows.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final failed = rows.where((r) => '${r['error'] ?? ''}'.isNotEmpty).length;
    return Card(
      key: const ValueKey('commission-uncharged'),
      color: t.colorScheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.warning_amber_rounded, color: t.colorScheme.onErrorContainer),
        title: Text(
          '${rows.length} completed trip${rows.length == 1 ? '' : 's'} not charged commission',
          style: TextStyle(color: t.colorScheme.onErrorContainer),
        ),
        subtitle: Text(
          failed == 0 ? 'Charge them now at their locked or current rate.' : '$failed failed to charge; see the trip.',
          style: TextStyle(color: t.colorScheme.onErrorContainer),
        ),
        trailing: canEdit
            ? BusyIconButton(
                key: const ValueKey('commission-charge-now'),
                tooltip: 'Charge now',
                icon: Icon(Icons.bolt, color: t.colorScheme.onErrorContainer),
                onPressed: () async {
                  final repo = ref.read(adminRepositoryProvider);
                  ({int charged, int failed})? r;
                  await runAdminAction(context, () async => r = await repo.chargeUnchargedCommissions());
                  ref.invalidate(unchargedCommissionsProvider);
                  if (r != null && context.mounted) {
                    showInfo(context, '${r!.charged} charged${r!.failed > 0 ? ', ${r!.failed} failed again' : ''}.');
                  }
                },
              )
            : null,
      ),
    );
  }
}

/// Every change to the rates, newest first.
class _HistoryList extends ConsumerWidget {
  const _HistoryList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return AsyncView(
      value: ref.watch(commissionHistoryProvider),
      onRetry: () => ref.invalidate(commissionHistoryProvider),
      data: (rows) {
        if (rows.isEmpty) return const EmptyState(icon: Icons.history, title: 'No changes recorded yet');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final h in rows)
              ListTile(
                key: ValueKey('commission-history-${h['id']}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(switch ('${h['op']}'.split(':').last) {
                  'insert' => Icons.add_circle_outline,
                  'delete' => Icons.delete_outline,
                  _ => Icons.edit_outlined,
                }),
                title: Text(commissionHistoryLine(h)),
                subtitle: Text(
                  [
                    formatDateTime(DateTime.tryParse('${h['changed_at']}')?.toLocal()),
                    if (h['changed_by'] != null) 'by ${h['changed_by']}',
                  ].join(' · '),
                  style: t.textTheme.bodySmall,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The on/off switch on a rule's row: saves the moment it moves (Expo
/// toggled `active` on the list) and goes back if the database refuses.
class _ActiveSwitch extends ConsumerStatefulWidget {
  const _ActiveSwitch({super.key, required this.row, required this.canEdit});
  final Map<String, dynamic> row;
  final bool canEdit;

  @override
  ConsumerState<_ActiveSwitch> createState() => _ActiveSwitchState();
}

class _ActiveSwitchState extends ConsumerState<_ActiveSwitch> {
  /// The value being saved; null when the row's own value is shown.
  bool? _pending;

  Future<void> _set(bool v) async {
    setState(() => _pending = v);
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).setCommissionRateActive(widget.row['id'] as String, v),
      success: v ? 'Rule turned on' : 'Rule turned off',
    );
    if (ok) ref.invalidate(commissionRatesProvider);
    if (mounted) setState(() => _pending = null);
  }

  @override
  void didUpdateWidget(_ActiveSwitch old) {
    super.didUpdateWidget(old);
    // The re-read landed: show what the database now says.
    if (old.row['active'] != widget.row['active']) _pending = null;
  }

  @override
  Widget build(BuildContext context) {
    final active = _pending ?? widget.row['active'] != false;
    return Tooltip(
      message: active ? 'Active' : 'Inactive',
      child: Switch(
        value: active,
        onChanged: widget.canEdit && _pending == null && widget.row['id'] != null ? _set : null,
      ),
    );
  }
}

class _RateDialog extends ConsumerStatefulWidget {
  const _RateDialog({this.row, required this.searchPeople});
  final Map<String, dynamic>? row;

  /// Finds the people a per-user rule can be about.
  final Future<List<Map<String, dynamic>>> Function(String query) searchPeople;

  @override
  ConsumerState<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends ConsumerState<_RateDialog> {
  late String _level = (widget.row?['level'] as String?) ?? 'country';
  late bool _active = widget.row?['active'] != false;
  late final _priority = TextEditingController(text: '${widget.row?['priority'] ?? 0}');
  late final _note = TextEditingController(text: widget.row?['note'] as String?);
  late final _rate = TextEditingController(
    text: widget.row == null ? '' : (((widget.row!['rate'] as num?) ?? 0) * 100).toString(),
  );
  late final _fields = {
    for (final k in ['country', 'state', 'city', 'suburb', 'user_id', 'user_label'])
      k: TextEditingController(text: widget.row?[k] as String?),
  };
  String? _error;

  // Person search for a per-user rule.
  final _query = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>>? _results;
  bool _searching = false;
  String? _searchError;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _priority.dispose();
    _note.dispose();
    super.dispose();
  }

  void _queryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _search(String q) async {
    _debounce?.cancel();
    if (!isProfileUuid(q) && peopleSearchTerm(q) == null) {
      setState(() {
        _results = null;
        _searchError = null;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final rows = await widget.searchPeople(q);
      if (!mounted || _query.text != q) return; // a newer search is on its way
      setState(() {
        _results = rows;
        _searchError = null;
      });
    } catch (e) {
      if (mounted && _query.text == q) setState(() => _searchError = errorText(e));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _pick(Map<String, dynamic> p) => setState(() {
        _fields['user_id']!.text = '${p['id']}';
        _fields['user_label']!.text = personLabel(p);
        _query.clear();
        _results = null;
        _error = null;
      });

  Widget _personPicker(BuildContext context) {
    final t = Theme.of(context);
    final id = _fields['user_id']!.text.trim();
    final label = _fields['user_label']!.text.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (id.isNotEmpty)
        ListTile(
          key: const ValueKey('commission-person-selected'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.person_outline),
          title: Text(label.isEmpty ? id : label),
          subtitle: Text(id),
          trailing: IconButton(
            tooltip: 'Choose someone else',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              _fields['user_id']!.clear();
              _fields['user_label']!.clear();
            }),
          ),
        ),
      TextField(
        key: const ValueKey('commission-person-search'),
        controller: _query,
        decoration: InputDecoration(
          labelText: id.isEmpty ? 'Find person' : 'Find someone else',
          helperText: 'Name, phone, email, account ID or profile ID',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searching
              ? const Padding(padding: EdgeInsets.all(12), child: BusySpinner(size: 16))
              : null,
        ),
        textInputAction: TextInputAction.search,
        onChanged: _queryChanged,
        onSubmitted: _search,
      ),
      if (_searchError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_searchError!, style: TextStyle(color: t.colorScheme.error)),
        )
      else if (_results != null && _results!.isEmpty)
        const Padding(padding: EdgeInsets.only(top: 8), child: Text('No one matches that search.'))
      else if (_results != null)
        for (final p in _results!)
          ListTile(
            key: ValueKey('commission-person-${p['id']}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(personLabel(p)),
            subtitle: personDetails(p).isEmpty ? null : Text(personDetails(p)),
            onTap: () => _pick(p),
          ),
    ]);
  }

  void _save() {
    final pct = double.tryParse(_rate.text.trim());
    if (pct == null || pct < 0 || pct >= 100) {
      setState(() => _error = 'Rate must be between 0% and 99.99%.');
      return;
    }
    for (final k in requiredScope(_level)) {
      if (_fields[k]!.text.trim().isEmpty) {
        setState(() => _error = k == 'user_id' ? 'Choose the person this rate is for.' : 'Enter the $k.');
        return;
      }
    }
    final priority = int.tryParse(_priority.text.trim());
    if (priority == null) {
      setState(() => _error = 'Priority must be a whole number (0 when unsure).');
      return;
    }
    final needed = requiredScope(_level).toSet();
    Navigator.pop(context, {
      'priority': priority,
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      'id': widget.row?['id'],
      'level': _level,
      'rate': double.parse((pct / 100).toStringAsFixed(4)),
      'active': _active,
      for (final k in ['country', 'state', 'city', 'suburb', 'user_id'])
        k: needed.contains(k) ? _fields[k]!.text.trim() : null,
      'user_label': _level == 'user' && _fields['user_label']!.text.trim().isNotEmpty ? _fields['user_label']!.text.trim() : null,
    });
  }

  /// A place field: picked from Admin -> Country / States / Cities (so its
  /// name is the one the server matches), typed where that level has none.
  Widget _place(String k, List<RegionEntry> regions) {
    const levels = {
      'country': RegionLevel.country,
      'state': RegionLevel.state,
      'city': RegionLevel.city,
      'suburb': RegionLevel.suburb,
    };
    final title = k[0].toUpperCase() + k.substring(1);
    final options = regionNamesAt(
      regions,
      levels[k]!,
      country: _fields['country']!.text,
      state: _fields['state']!.text,
      city: _fields['city']!.text,
    );
    final value = _fields[k]!.text.trim();
    if (options.isEmpty) {
      return TextField(
        key: ValueKey('commission-$k'),
        controller: _fields[k],
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: title,
          helperText: 'Not on Country / States / Cities yet',
          helperMaxLines: 2,
        ),
      );
    }
    final all = [...options, if (value.isNotEmpty && !options.any((o) => o.toLowerCase() == value.toLowerCase())) value];
    final selected = all.where((o) => o.toLowerCase() == value.toLowerCase()).firstOrNull;
    return SearchableDropdownFormField<String>(
      key: ValueKey('commission-$k-${_fields['country']!.text}/${_fields['state']!.text}/${_fields['city']!.text}'),
      isExpanded: true,
      initialValue: selected,
      decoration: InputDecoration(labelText: title),
      hint: Text('Choose a $k'),
      items: [for (final o in all) DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis))],
      onChanged: (v) => setState(() {
        _fields[k]!.text = v ?? '';
        // A new parent clears the places under it.
        const order = ['country', 'state', 'city', 'suburb'];
        for (final below in order.skip(order.indexOf(k) + 1)) {
          _fields[below]!.clear();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final needed = requiredScope(_level);
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    return AlertDialog(
      title: Text(widget.row == null ? 'Add commission rate' : 'Edit commission rate'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SearchableDropdownFormField<String>(
              key: const ValueKey('commission-level'),
              isExpanded: true,
              initialValue: _level,
              decoration: const InputDecoration(labelText: 'Level'),
              items: [for (final l in commissionLevels) DropdownMenuItem(value: l, child: Text(commissionLevelLabel(l)))],
              onChanged: (v) => setState(() => _level = v ?? _level),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('commission-rate'),
              textInputAction: TextInputAction.next,
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Rate (%)', suffixText: '%'),
            ),
            for (final k in needed) ...[
              const SizedBox(height: 12),
              if (k == 'user_id') _personPicker(context) else _place(k, regions),
            ],
            if (_level == 'user') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _fields['user_label'],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Label (optional)'),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('commission-priority'),
              textInputAction: TextInputAction.next,
              controller: _priority,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(
                labelText: 'Priority',
                helperText: 'Higher wins between rules at the same level',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('commission-note'),
              controller: _note,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                helperText: 'Why this rate; kept in the change history',
                helperMaxLines: 2,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
      ),
      // Cancel and Save side by side, as on the other dialogs: Save keeps
      // its own width rather than the theme's full-width button, which
      // stacked them.
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('commission-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
