// Admin → App Settings → Cancel and no-show (migration 0269): city ride
// cancel and no-show fees by place (Default, or a country, state, city or
// suburb, as Ride Options' charges are kept), and the driver cancel-rate
// limit that pauses their offers.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/city_cancel.dart';
import '../../data/city_ride_repository.dart';
import '../../data/live_tables.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../widgets/admin_widgets.dart';
import 'ride_offers_card.dart' show AdminNumberField;

final _cancelPlacesProvider = FutureProvider.autoDispose<List<CancelPlace>>((ref) async {
  ref.watchLive('ride_cancel_places');
  return ref.watch(cityRideRepositoryProvider).cancelPlaces();
});

/// The field labels, in the card's order.
const cancelRuleLabels = {
  'freeMinutes': 'Free cancel after accept (min)',
  'lateFee': 'Late cancel fee (after the free time, before arrival)',
  'arrivedFee': 'Cancel after the driver arrived',
  'noShowMinutes': 'No-show after waiting (min)',
  'noShowFee': 'No-show fee',
};

class CancelRulesCard extends ConsumerStatefulWidget {
  const CancelRulesCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<CancelRulesCard> createState() => _CancelRulesCardState();
}

class _CancelRulesCardState extends ConsumerState<CancelRulesCard> {
  final _limit = TextEditingController();
  final _days = TextEditingController();
  final _pause = TextEditingController();
  final _minRides = TextEditingController();
  DriverCancelLimit? _loaded;

  @override
  void dispose() {
    for (final c in [_limit, _days, _pause, _minRides]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(DriverCancelLimit l) {
    if (_loaded == l) return;
    _loaded = l;
    _limit.text = '${l.limitPercent}';
    _days.text = '${l.days}';
    _pause.text = '${l.pauseMinutes}';
    _minRides.text = '${l.minRides}';
  }

  DriverCancelLimit? _draft() {
    final a = AdminNumberField.read(_limit, 1, 100);
    final b = AdminNumberField.read(_days, 1, 30);
    final c = AdminNumberField.read(_pause, 1, 1440);
    final d = AdminNumberField.read(_minRides, 1, 100);
    if (a == null || b == null || c == null || d == null) return null;
    return DriverCancelLimit(limitPercent: a.toInt(), days: b.toInt(), pauseMinutes: c.toInt(), minRides: d.toInt());
  }

  Future<void> _saveLimit() async {
    final d = _draft();
    if (d == null) {
      showInfo(context, 'Check the numbers: each must be within its limits.');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(cityRideRepositoryProvider).saveConfig('driverCancel', d.toJson()),
      success: 'Driver cancel limit saved',
    );
    if (ok && mounted) ref.invalidate(cityRideConfigProvider);
  }

  Future<void> _edit(CancelPlace? place, List<CancelPlace> all) async {
    final saved = await showAppDialog<CancelPlace>(
      id: 'admin.cancel-place',
      context: context,
      builder: (_) => _CancelPlaceDialog(place: place, defaults: all.where((p) => p.isDefault).firstOrNull),
    );
    if (saved == null || !mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(cityRideRepositoryProvider).saveCancelPlace(saved),
      success: 'Cancel rules saved',
    );
    if (ok && mounted) ref.invalidate(_cancelPlacesProvider);
  }

  Future<void> _delete(CancelPlace p) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(cityRideRepositoryProvider).deleteCancelPlace(p.id!),
      success: 'Removed ${p.label}',
    );
    if (ok && mounted) ref.invalidate(_cancelPlacesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Card(
      key: const ValueKey('cancel-rules-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Cancel and no-show', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'City rides, by place like Ride Options: the smallest place that sets a rule wins, else Default. '
              'The fee is taken from GET.wallet and goes to the driver less commission; if the wallet is short '
              'it is added to the rider\'s next trip. Cancels with a safety reason (driver not moving, car '
              'doesn\'t match) are always free.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            AsyncView(
              value: ref.watch(_cancelPlacesProvider),
              onRetry: () => ref.invalidate(_cancelPlacesProvider),
              data: (places) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in places)
                    ListTile(
                      key: ValueKey('cancel-place-${p.isDefault ? 'default' : p.id}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(p.isDefault ? Icons.public : Icons.place_outlined),
                      title: Text(p.label),
                      subtitle: Text(
                        p.rules.isEmpty
                            ? 'Uses the place above'
                            : [
                                for (final k in CancelRules.keys)
                                  if (p.rules[k] case final v?) '${_short[k]} ${_num(v)}',
                              ].join(' · '),
                      ),
                      trailing: widget.canEdit
                          ? Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                tooltip: 'Edit',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _edit(p, places),
                              ),
                              if (!p.isDefault)
                                IconButton(
                                  tooltip: 'Remove',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _delete(p),
                                ),
                            ])
                          : null,
                    ),
                  if (widget.canEdit)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('cancel-place-add'),
                        icon: const Icon(Icons.add),
                        label: const Text('Add a place'),
                        onPressed: () => _edit(null, places),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 24),
            Text('Driver cancel limit', style: t.textTheme.titleSmall),
            Text(
              'A driver whose own cancels pass the limit can\'t send offers for a while. Drivers see their rate '
              'on the trip screen. No-shows don\'t count.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            AsyncView(
              value: ref.watch(cityRideConfigProvider),
              onRetry: () => ref.invalidate(cityRideConfigProvider),
              data: (c) {
                _load(c.driverCancel);
                final draft = _draft();
                void edited() => setState(() {});
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AdminNumberField(
                      key: const ValueKey('driver-cancel-limit'),
                      controller: _limit,
                      label: 'Cancel-rate limit (%)',
                      min: 1,
                      max: 100,
                      enabled: widget.canEdit,
                      onChanged: edited,
                    ),
                    const SizedBox(height: 8),
                    AdminNumberField(
                      key: const ValueKey('driver-cancel-days'),
                      controller: _days,
                      label: 'Over the last (days)',
                      min: 1,
                      max: 30,
                      enabled: widget.canEdit,
                      onChanged: edited,
                    ),
                    const SizedBox(height: 8),
                    AdminNumberField(
                      key: const ValueKey('driver-cancel-pause'),
                      controller: _pause,
                      label: 'Pause offers for (min)',
                      min: 1,
                      max: 1440,
                      enabled: widget.canEdit,
                      onChanged: edited,
                    ),
                    const SizedBox(height: 8),
                    AdminNumberField(
                      key: const ValueKey('driver-cancel-min-rides'),
                      controller: _minRides,
                      label: 'Only once they have taken (rides)',
                      min: 1,
                      max: 100,
                      enabled: widget.canEdit,
                      onChanged: edited,
                    ),
                    const SizedBox(height: 12),
                    if (widget.canEdit)
                      BusyButton.filled(
                        key: const ValueKey('driver-cancel-save'),
                        onPressed: draft == c.driverCancel ? null : _saveLimit,
                        icon: const Icon(Icons.save_outlined),
                        child: const Text('Save driver cancel limit'),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

const _short = {
  'freeMinutes': 'Free',
  'lateFee': 'Late',
  'arrivedFee': 'Arrived',
  'noShowMinutes': 'No-show after',
  'noShowFee': 'No-show',
};

String _inheritHint(double? d) => d == null ? 'Empty uses the place above' : 'Empty uses the place above (Default ${_num(d)})';

String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// Adds a place, or edits one place's rules. An empty field uses the place above.
class _CancelPlaceDialog extends StatefulWidget {
  const _CancelPlaceDialog({this.place, this.defaults});
  final CancelPlace? place;
  final CancelPlace? defaults;

  @override
  State<_CancelPlaceDialog> createState() => _CancelPlaceDialogState();
}

class _CancelPlaceDialogState extends State<_CancelPlaceDialog> {
  late String _level = widget.place?.level ?? 'country';
  late final _names = {
    'country': TextEditingController(text: widget.place?.country ?? ''),
    'state': TextEditingController(text: widget.place?.state ?? ''),
    'city': TextEditingController(text: widget.place?.city ?? ''),
    'suburb': TextEditingController(text: widget.place?.suburb ?? ''),
  };
  late final _rules = {
    for (final k in CancelRules.keys)
      k: TextEditingController(text: widget.place?.rules[k] == null ? '' : _num(widget.place!.rules[k]!)),
  };

  @override
  void dispose() {
    for (final c in [..._names.values, ..._rules.values]) {
      c.dispose();
    }
    super.dispose();
  }

  static const _levels = ['country', 'state', 'city', 'suburb'];

  List<String> get _named => _levels.sublist(0, _levels.indexOf(_level) + 1);

  CancelPlace? _result() {
    final rules = <String, double>{};
    for (final e in _rules.entries) {
      final s = e.value.text.trim();
      if (s.isEmpty) continue;
      final v = double.tryParse(s);
      if (v == null || v < 0 || v > (e.key.endsWith('Minutes') ? 120 : 1000)) return null;
      rules[e.key] = v;
    }
    final p = widget.place;
    if (p != null) {
      return CancelPlace(id: p.id, level: p.level, country: p.country, state: p.state, city: p.city, suburb: p.suburb, rules: rules);
    }
    if (_named.any((l) => _names[l]!.text.trim().isEmpty)) return null;
    String? n(String l) => _named.contains(l) ? _names[l]!.text.trim() : null;
    return CancelPlace(level: _level, country: n('country'), state: n('state'), city: n('city'), suburb: n('suburb'), rules: rules);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.place;
    final result = _result();
    return AlertDialog(
      title: Text(p == null ? 'Add a place' : p.label),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (p == null) ...[
                SearchableDropdownFormField<String>(
                  key: const ValueKey('cancel-place-level'),
                  initialValue: _level,
                  decoration: const InputDecoration(labelText: 'Place'),
                  items: const [
                    DropdownMenuItem(value: 'country', child: Text('Country')),
                    DropdownMenuItem(value: 'state', child: Text('State')),
                    DropdownMenuItem(value: 'city', child: Text('City')),
                    DropdownMenuItem(value: 'suburb', child: Text('Suburb')),
                  ],
                  onChanged: (v) => setState(() => _level = v ?? _level),
                ),
                for (final l in _named)
                  TextField(
                    key: ValueKey('cancel-place-$l'),
                    controller: _names[l],
                    decoration: InputDecoration(
                      labelText: '${l[0].toUpperCase()}${l.substring(1)}',
                      helperText: l == _named.first ? 'As the Country / States / Cities tables name it' : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                const SizedBox(height: 12),
              ],
              for (final k in CancelRules.keys)
                TextField(
                  key: ValueKey('cancel-rule-$k'),
                  controller: _rules[k],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: cancelRuleLabels[k],
                    hintText: p?.isDefault ?? false ? null : _inheritHint(widget.defaults?.rules[k]),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('cancel-place-save'),
          onPressed: result == null ? null : () => Navigator.pop(context, result),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
