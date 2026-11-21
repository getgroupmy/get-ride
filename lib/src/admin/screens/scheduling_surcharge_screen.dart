// Admin → Advance-booking surcharge (migration 0415): per service type AND
// region (Country / State / City / Suburb, plus one master), a flat amount
// and/or a percentage of the fare charged on a future-dated ("Later") booking.
// Scoped and resolved like the commission rate / ride-display rule; with no
// row the booking falls back to the global scheduled-rides fee.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart' show formatMoney;
import '../../core/scheduling_surcharge.dart';
import '../../data/app_display_repository.dart' show rideServicesProvider;
import '../../data/live_tables.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import 'geo/geo_data.dart' show regionsProvider;
import 'geo/geo_logic.dart' show RegionEntry, RegionLevel, regionNamesAt;

final schedulingSurchargeAdminProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('scheduling_surcharge_rates');
  return ref.watch(adminRepositoryProvider).schedulingSurchargeRates();
});

const schedulingSurchargeLevels = ['master', 'country', 'state', 'city', 'suburb'];

const _allServices = '__all__';

String schedulingSurchargeLevelLabel(Object? level) => switch ('$level') {
      '' || 'null' => 'Unknown',
      final l => '${l[0].toUpperCase()}${l.substring(1)}',
    };

/// The rate in words: "RM 5.00 + 10%", "RM 5.00", "10%", or "No surcharge".
String schedulingSurchargeFeeLabel(Map<String, dynamic> r) {
  final fixed = (r['fee_fixed'] as num?)?.toDouble() ?? 0;
  final percent = (r['fee_percent'] as num?)?.toDouble() ?? 0;
  final parts = [
    if (fixed > 0) formatMoney(fixed),
    if (percent > 0) '${percent == percent.roundToDouble() ? percent.toInt() : percent}%',
  ];
  return parts.isEmpty ? 'No surcharge' : parts.join(' + ');
}

/// "All services", or the service name.
String schedulingSurchargeServiceLabel(Map<String, dynamic> r) {
  final s = (r['service'] as String?)?.trim();
  return s == null || s.isEmpty ? 'All services' : s;
}

class AdminSchedulingSurchargeScreen extends ConsumerWidget {
  const AdminSchedulingSurchargeScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Map<String, dynamic>? row]) async {
    final result = await showAppDialog<Map<String, dynamic>>(
      id: 'scheduling-surcharge.edit',
      context: context,
      builder: (_) => _RateDialog(row: row),
    );
    if (result == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveSchedulingSurchargeRate(result),
      success: 'Surcharge saved',
    );
    if (ok) ref.invalidate(schedulingSurchargeAdminProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(moduleAccessProvider('scheduling-surcharge')) == AccessLevel.edit;
    return AdminPage(
      title: 'Advance-booking surcharge',
      module: 'scheduling-surcharge',
      body: AsyncView(
        value: ref.watch(schedulingSurchargeAdminProvider),
        onRetry: () => ref.invalidate(schedulingSurchargeAdminProvider),
        data: (rows) {
          final sorted = [...rows]
            ..sort((a, b) => schedulingSurchargeLevels
                .indexOf('${a['level']}')
                .compareTo(schedulingSurchargeLevels.indexOf('${b['level']}')));
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              clipBehavior: Clip.antiAlias,
              child: Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: const ExpansionTile(
                  key: ValueKey('scheduling-surcharge-how'),
                  leading: Icon(Icons.info_outline),
                  title: Text('How the surcharge works'),
                  childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Charged on a future-dated ("Later") booking only. For the pickup region and service, '
                      'the most specific active rate wins: a service-specific row beats an all-service one, and '
                      'suburb > city > state > country > master (everywhere). Set a flat amount, a percentage of '
                      'the fare, or both. With no rate here, the booking uses the global scheduling fee on the '
                      'Scheduled rides card. Changes apply live on riders\' phones.',
                      key: ValueKey('scheduling-surcharge-how-text'),
                    ),
                  ],
                ),
              ),
            ),
            if (canEdit)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('scheduling-surcharge-add'),
                    onPressed: () => _edit(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Add surcharge'),
                  ),
                ),
              ),
            if (sorted.isEmpty)
              const EmptyState(icon: Icons.schedule_outlined, title: 'No surcharge overrides yet'),
            for (final r in sorted)
              Card(
                child: BusyListTile(
                  leading: CircleAvatar(child: Text('${r['level']}'.substring(0, 1).toUpperCase())),
                  title: Text(
                    '${schedulingSurchargeServiceLabel(r)} · ${schedulingSurchargeFeeLabel(r)}',
                    key: ValueKey('scheduling-surcharge-fee-${r['id']}'),
                    maxLines: 1,
                  ),
                  subtitle: Text([
                    schedulingSurchargeLevelLabel(r['level']),
                    schedulingSurchargeScopeLabel(r),
                    if (((r['priority'] as num?) ?? 0) != 0) 'Priority ${r['priority']}',
                    if ('${r['note'] ?? ''}'.trim().isNotEmpty) '${r['note']}'.trim(),
                  ].where((s) => s.trim().isNotEmpty).join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    _ActiveSwitch(key: ValueKey('scheduling-surcharge-active-${r['id']}'), row: r, canEdit: canEdit),
                    if (canEdit)
                      BusyIconButton(
                        tooltip: 'Delete surcharge',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (!await confirm(context, 'Delete surcharge?', schedulingSurchargeScopeLabel(r),
                              ok: 'Delete')) {
                            return;
                          }
                          if (!context.mounted) return;
                          if (await runAdminAction(context,
                              () => ref.read(adminRepositoryProvider).deleteSchedulingSurchargeRate(r['id'] as String))) {
                            ref.invalidate(schedulingSurchargeAdminProvider);
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

/// The on/off switch on a rate's row: saves the moment it moves and goes back
/// if the database refuses.
class _ActiveSwitch extends ConsumerStatefulWidget {
  const _ActiveSwitch({super.key, required this.row, required this.canEdit});
  final Map<String, dynamic> row;
  final bool canEdit;

  @override
  ConsumerState<_ActiveSwitch> createState() => _ActiveSwitchState();
}

class _ActiveSwitchState extends ConsumerState<_ActiveSwitch> {
  bool? _pending;

  Future<void> _set(bool v) async {
    setState(() => _pending = v);
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).setSchedulingSurchargeRateActive(widget.row['id'] as String, v),
      success: v ? 'Surcharge turned on' : 'Surcharge turned off',
    );
    if (ok) ref.invalidate(schedulingSurchargeAdminProvider);
    if (mounted) setState(() => _pending = null);
  }

  @override
  void didUpdateWidget(_ActiveSwitch old) {
    super.didUpdateWidget(old);
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
  const _RateDialog({this.row});
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends ConsumerState<_RateDialog> {
  late String _level = (widget.row?['level'] as String?) ?? 'country';
  late String _service = (widget.row?['service'] as String?)?.trim().isNotEmpty == true
      ? (widget.row!['service'] as String).trim()
      : _allServices;
  late bool _active = widget.row?['active'] != false;
  late final _fixed = TextEditingController(text: _plain(widget.row?['fee_fixed']));
  late final _percent = TextEditingController(text: _plain(widget.row?['fee_percent']));
  late final _priority = TextEditingController(text: '${widget.row?['priority'] ?? 0}');
  late final _note = TextEditingController(text: widget.row?['note'] as String?);
  late final _fields = {
    for (final k in ['country', 'state', 'city', 'suburb'])
      k: TextEditingController(text: widget.row?[k] as String?),
  };
  String? _error;

  static String _plain(Object? v) {
    final n = (v as num?)?.toDouble() ?? 0;
    return n == 0 ? '' : (n == n.roundToDouble() ? n.toInt().toString() : n.toString());
  }

  @override
  void dispose() {
    _fixed.dispose();
    _percent.dispose();
    _priority.dispose();
    _note.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final fixed = double.tryParse(_fixed.text.trim().isEmpty ? '0' : _fixed.text.trim());
    final percent = double.tryParse(_percent.text.trim().isEmpty ? '0' : _percent.text.trim());
    if (fixed == null || fixed < 0 || fixed > 1000) {
      setState(() => _error = 'The flat amount must be 0–1000.');
      return;
    }
    if (percent == null || percent < 0 || percent > 100) {
      setState(() => _error = 'The percentage must be 0–100.');
      return;
    }
    for (final k in schedulingSurchargeRequiredScope(_level)) {
      if (_fields[k]!.text.trim().isEmpty) {
        setState(() => _error = 'Enter the $k.');
        return;
      }
    }
    final priority = int.tryParse(_priority.text.trim());
    if (priority == null) {
      setState(() => _error = 'Priority must be a whole number (0 when unsure).');
      return;
    }
    final needed = schedulingSurchargeRequiredScope(_level).toSet();
    Navigator.pop(context, {
      'id': widget.row?['id'],
      'level': _level,
      'service': _service == _allServices ? null : _service,
      'fee_fixed': fixed,
      'fee_percent': percent,
      'active': _active,
      'priority': priority,
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      for (final k in ['country', 'state', 'city', 'suburb'])
        k: needed.contains(k) ? _fields[k]!.text.trim() : null,
    });
  }

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
        key: ValueKey('scheduling-surcharge-$k'),
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
      key: ValueKey('scheduling-surcharge-$k-${_fields['country']!.text}/${_fields['state']!.text}/${_fields['city']!.text}'),
      isExpanded: true,
      initialValue: selected,
      decoration: InputDecoration(labelText: title),
      hint: Text('Choose a $k'),
      items: [for (final o in all) DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis))],
      onChanged: (v) => setState(() {
        _fields[k]!.text = v ?? '';
        const order = ['country', 'state', 'city', 'suburb'];
        for (final below in order.skip(order.indexOf(k) + 1)) {
          _fields[below]!.clear();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final needed = schedulingSurchargeRequiredScope(_level);
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final services = ref.watch(rideServicesProvider).value ?? const [];
    final serviceNames = {for (final s in services) s.name}.toList()..sort();
    // Keep the stored service selectable even if its catalogue entry is gone.
    if (_service != _allServices && !serviceNames.contains(_service)) serviceNames.add(_service);
    return AlertDialog(
      title: Text(widget.row == null ? 'Add surcharge' : 'Edit surcharge'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SearchableDropdownFormField<String>(
              key: const ValueKey('scheduling-surcharge-service'),
              isExpanded: true,
              initialValue: _service,
              decoration: const InputDecoration(labelText: 'Service'),
              items: [
                const DropdownMenuItem(value: _allServices, child: Text('All services')),
                for (final s in serviceNames) DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _service = v ?? _allServices),
            ),
            const SizedBox(height: 12),
            SearchableDropdownFormField<String>(
              key: const ValueKey('scheduling-surcharge-level'),
              isExpanded: true,
              initialValue: _level,
              decoration: const InputDecoration(labelText: 'Region level'),
              items: [
                for (final l in schedulingSurchargeLevels)
                  DropdownMenuItem(value: l, child: Text(l == 'master' ? 'Everywhere' : schedulingSurchargeLevelLabel(l)))
              ],
              onChanged: (v) => setState(() => _level = v ?? _level),
            ),
            for (final k in needed) ...[
              const SizedBox(height: 12),
              _place(k, regions),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('scheduling-surcharge-fixed'),
              controller: _fixed,
              textInputAction: TextInputAction.next,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Flat amount',
                prefixText: 'RM ',
                helperText: 'A fixed surcharge, 0–1000 (leave blank for none)',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('scheduling-surcharge-percent'),
              controller: _percent,
              textInputAction: TextInputAction.next,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Percentage of the fare',
                suffixText: '%',
                helperText: '0–100 (leave blank for none)',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('scheduling-surcharge-priority'),
              textInputAction: TextInputAction.next,
              controller: _priority,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(
                labelText: 'Priority',
                helperText: 'Higher wins between rates at the same level',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('scheduling-surcharge-note'),
              controller: _note,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
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
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('scheduling-surcharge-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
