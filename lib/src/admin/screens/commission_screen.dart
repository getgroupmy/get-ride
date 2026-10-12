import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/commission.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../profile_search.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';

final commissionRatesProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('commission_rates');
  return ref.watch(adminRepositoryProvider).commissionRates();
});

const commissionLevels = ['master', 'country', 'state', 'city', 'suburb', 'user'];

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
    final result = await showDialog<Map<String, dynamic>>(
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
    return AdminPage(
      title: 'Commission rates',
      module: 'commission',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add rate'),
      ),
      body: AsyncView(
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
                    'master. With no rules at all, ${(defaultCommissionRate * 100).toStringAsFixed(0)}% applies.'),
              ),
            ),
            if (sorted.isEmpty) const EmptyState(icon: Icons.percent, title: 'No commission rules yet'),
            for (final r in sorted)
              Card(
                child: BusyListTile(
                  leading: CircleAvatar(child: Text('${r['level']}'.substring(0, 1).toUpperCase())),
                  title: Text('${(((r['rate'] as num?) ?? 0) * 100).toStringAsFixed(2)}% · ${r['level']}'),
                  subtitle: Text(commissionScopeLabel(r)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    _ActiveSwitch(key: ValueKey('commission-active-${r['id']}'), row: r, canEdit: canEdit),
                    if (canEdit)
                      BusyIconButton(
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

class _RateDialog extends StatefulWidget {
  const _RateDialog({this.row, required this.searchPeople});
  final Map<String, dynamic>? row;

  /// Finds the people a per-user rule can be about.
  final Future<List<Map<String, dynamic>>> Function(String query) searchPeople;

  @override
  State<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends State<_RateDialog> {
  late String _level = (widget.row?['level'] as String?) ?? 'country';
  late bool _active = widget.row?['active'] != false;
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
    final needed = requiredScope(_level).toSet();
    Navigator.pop(context, {
      'id': widget.row?['id'],
      'level': _level,
      'rate': double.parse((pct / 100).toStringAsFixed(4)),
      'active': _active,
      for (final k in ['country', 'state', 'city', 'suburb', 'user_id'])
        k: needed.contains(k) ? _fields[k]!.text.trim() : null,
      'user_label': _level == 'user' && _fields['user_label']!.text.trim().isNotEmpty ? _fields['user_label']!.text.trim() : null,
    });
  }

  @override
  Widget build(BuildContext context) {
    final needed = requiredScope(_level);
    return AlertDialog(
      title: Text(widget.row == null ? 'Add commission rate' : 'Edit commission rate'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: _level,
              decoration: const InputDecoration(labelText: 'Level'),
              items: [for (final l in commissionLevels) DropdownMenuItem(value: l, child: Text(l))],
              onChanged: (v) => setState(() => _level = v ?? _level),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Rate (%)', suffixText: '%'),
            ),
            for (final k in needed) ...[
              const SizedBox(height: 12),
              if (k == 'user_id')
                _personPicker(context)
              else
                TextField(
                  controller: _fields[k],
                  decoration: InputDecoration(labelText: k[0].toUpperCase() + k.substring(1)),
                ),
            ],
            if (_level == 'user') ...[
              const SizedBox(height: 12),
              TextField(controller: _fields['user_label'], decoration: const InputDecoration(labelText: 'Label (optional)')),
            ],
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
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
