import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/commission.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';

final commissionRatesProvider =
    FutureProvider.autoDispose((ref) => ref.watch(adminRepositoryProvider).commissionRates());

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
      builder: (_) => _RateDialog(row: row),
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
                child: ListTile(
                  leading: CircleAvatar(child: Text('${r['level']}'.substring(0, 1).toUpperCase())),
                  title: Text('${(((r['rate'] as num?) ?? 0) * 100).toStringAsFixed(2)}% · ${r['level']}'),
                  subtitle: Text(commissionScopeLabel(r)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (r['active'] == false) const StatusChip('inactive'),
                    if (canEdit)
                      IconButton(
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

class _RateDialog extends StatefulWidget {
  const _RateDialog({this.row});
  final Map<String, dynamic>? row;

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

  void _save() {
    final pct = double.tryParse(_rate.text.trim());
    if (pct == null || pct < 0 || pct >= 100) {
      setState(() => _error = 'Rate must be between 0% and 99.99%.');
      return;
    }
    for (final k in requiredScope(_level)) {
      if (_fields[k]!.text.trim().isEmpty) {
        setState(() => _error = 'Enter the ${k.replaceAll('_', ' ')}.');
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
              TextField(
                controller: _fields[k],
                decoration: InputDecoration(labelText: k == 'user_id' ? 'User ID (profile UUID)' : k[0].toUpperCase() + k.substring(1)),
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
