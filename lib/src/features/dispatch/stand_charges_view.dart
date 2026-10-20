// A stand's charges (migration 0251): the stand fee (fixed or % of the fare,
// paid by the customer or the driver) and the platform's fee from the stand.
// Admins set everything, and who sets the stand fee; a stand admin sets the
// fee only when the admin lets them, and sees the platform fee. The server
// enforces the same (dispatch_set_stand_fee, the stands' write policy).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dispatch.dart';
import '../../data/dispatch_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/search_select.dart';
import 'dispatch_console.dart' show dispatchErrorText;

/// The stand's statement for the last [days] days.
final standStatementProvider = FutureProvider.autoDispose.family<StandStatement, ({String stand, int days})>((ref, k) {
  final to = DateTime.now().add(const Duration(minutes: 1));
  return ref.watch(dispatchRepositoryProvider).statement(k.stand, to.subtract(Duration(days: k.days)), to);
});

class StandChargesView extends ConsumerStatefulWidget {
  const StandChargesView({super.key, required this.stands, required this.admin, this.editable = true, this.onSaved});

  final List<DispatchStand> stands;

  /// An admin: every setting; else a stand admin.
  final bool admin;

  /// False: shown, not changed (a read-only grant).
  final bool editable;
  final VoidCallback? onSaved;

  @override
  ConsumerState<StandChargesView> createState() => _StandChargesViewState();
}

class _StandChargesViewState extends ConsumerState<StandChargesView> {
  late String _standId = widget.stands.first.id;
  late StandFee _fee = _stand.fee;
  late final _amount = TextEditingController(text: _num(_fee.value));
  late final _platform = TextEditingController(text: _num(_fee.platformValue));
  final _example = TextEditingController(text: '25');
  bool _busy = false;

  static String _num(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);

  DispatchStand get _stand => widget.stands.firstWhere((s) => s.id == _standId, orElse: () => widget.stands.first);

  @override
  void dispose() {
    _amount.dispose();
    _platform.dispose();
    _example.dispose();
    super.dispose();
  }

  void _pick(String id) => setState(() {
    _standId = id;
    _fee = _stand.fee;
    _amount.text = _num(_fee.value);
    _platform.text = _num(_fee.platformValue);
  });

  StandFee get _current => StandFee(
    type: _fee.type,
    value: double.tryParse(_amount.text.trim()) ?? 0,
    payer: _fee.payer,
    setByStand: _fee.setByStand,
    platformType: _fee.platformType,
    platformValue: double.tryParse(_platform.text.trim()) ?? 0,
  );

  Future<void> _save() async {
    final fee = _current;
    if ((fee.type == FeeType.percent && fee.value > 100) ||
        (fee.platformType == FeeType.percent && fee.platformValue > 100)) {
      showError(context, 'A percentage is 0 to 100.');
      return;
    }
    setState(() => _busy = true);
    final repo = ref.read(dispatchRepositoryProvider);
    try {
      if (widget.admin) {
        await repo.saveStandCharges(_standId, fee);
      } else {
        await repo.setStandFee(_standId, fee);
      }
      ref.invalidate(dispatchRolesProvider);
      widget.onSaved?.call();
      if (mounted) showInfo(context, 'Charges saved');
    } catch (e) {
      if (mounted) showError(context, dispatchErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final canFee = widget.editable && canSetStandFee(admin: widget.admin, standAdmin: _stand.isStandAdmin, fee: _fee);
    final canPlatform = widget.editable && widget.admin;
    final fee = _current;
    final split = fee.splitFor(double.tryParse(_example.text.trim()) ?? 0);
    String rm(double v) => 'RM ${v.toStringAsFixed(2)}';

    Widget amountField(TextEditingController c, String label, bool enabled, {required bool percent, Key? key}) =>
        SizedBox(
          width: 120,
          child: TextField(
            key: key,
            controller: c,
            enabled: enabled,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              border: const OutlineInputBorder(),
              prefixText: percent ? null : 'RM ',
              suffixText: percent ? '%' : null,
            ),
          ),
        );

    final feeCard = Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.admin ? 'Stand fee' : 'Stand fee · ${_stand.shortName}', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (widget.stands.length > 1)
              SearchableDropdownFormField<String>(
                key: const ValueKey('charges-stand'),
                initialValue: _standId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Stand', border: OutlineInputBorder(), isDense: true),
                items: [for (final s in widget.stands) DropdownMenuItem(value: s.id, child: Text(s.name))],
                onChanged: (v) => v == null ? null : _pick(v),
              ),
            if (widget.admin) ...[
              const SizedBox(height: 8),
              Text("Who sets this stand's fee", style: muted),
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    key: const ValueKey('setby-admin'),
                    label: const Text('Admin'),
                    selected: !_fee.setByStand,
                    onSelected: canPlatform ? (_) => setState(() => _fee = _copy(setByStand: false)) : null,
                  ),
                  ChoiceChip(
                    key: const ValueKey('setby-stand'),
                    label: const Text('Stand admin'),
                    selected: _fee.setByStand,
                    onSelected: canPlatform ? (_) => setState(() => _fee = _copy(setByStand: true)) : null,
                  ),
                ],
              ),
              Text(
                _fee.setByStand
                    ? 'The stand admin sets it; you can still change it.'
                    : 'Only admins set it; the stand admin just sees it.',
                style: muted,
              ),
            ] else
              Text(canFee ? "You set your stand's fee." : 'Your fee is set by the admin.', style: muted),
            const SizedBox(height: 10),
            Text('Fee per order', style: muted),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final ft in FeeType.values)
                  ChoiceChip(
                    key: ValueKey('fee-${ft.name}'),
                    label: Text(switch (ft) {
                      FeeType.none => 'None',
                      FeeType.fixed => 'Fixed',
                      FeeType.percent => '% of fare',
                    }),
                    selected: _fee.type == ft,
                    onSelected: canFee ? (_) => setState(() => _fee = _copy(type: ft)) : null,
                  ),
                if (_fee.type != FeeType.none)
                  amountField(
                    _amount,
                    'Stand fee',
                    canFee,
                    percent: _fee.type == FeeType.percent,
                    key: const ValueKey('fee-amount'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text('Who pays it', style: muted),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  key: const ValueKey('payer-customer'),
                  label: const Text('Customer (added to the fare)'),
                  selected: _fee.payer == FeePayer.customer,
                  onSelected: canFee ? (_) => setState(() => _fee = _copy(payer: FeePayer.customer)) : null,
                ),
                ChoiceChip(
                  key: const ValueKey('payer-driver'),
                  label: const Text('Driver (taken from their earnings)'),
                  selected: _fee.payer == FeePayer.driver,
                  onSelected: canFee ? (_) => setState(() => _fee = _copy(payer: FeePayer.driver)) : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );

    final platformCard = Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Platform fee from the stand', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text("What GET.ride takes from the stand for each order, out of the stand's fee.", style: muted),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ChoiceChip(
                  key: const ValueKey('platform-percent'),
                  label: const Text('% of the stand fee'),
                  selected: _fee.platformType == FeeType.percent,
                  onSelected: canPlatform ? (_) => setState(() => _fee = _copy(platformType: FeeType.percent)) : null,
                ),
                ChoiceChip(
                  key: const ValueKey('platform-fixed'),
                  label: const Text('Fixed per order'),
                  selected: _fee.platformType == FeeType.fixed,
                  onSelected: canPlatform ? (_) => setState(() => _fee = _copy(platformType: FeeType.fixed)) : null,
                ),
                amountField(
                  _platform,
                  'Platform fee',
                  canPlatform,
                  percent: _fee.platformType == FeeType.percent,
                  key: const ValueKey('platform-amount'),
                ),
              ],
            ),
            if (!widget.admin) Text('Set by the admin.', style: muted),
            const SizedBox(height: 10),
            DecoratedBox(
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('Example, fare '),
                        amountField(_example, 'Fare', true, percent: false, key: const ValueKey('example-fare')),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Customer pays ${rm(split.customer)} · driver gets ${rm(split.driver)}',
                      key: const ValueKey('example-split'),
                    ),
                    Text(
                      'Stand fee ${rm(split.fee)}: the platform takes ${rm(split.platform)}, stand keeps ${rm(split.stand)}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "Stand earnings and platform fees show on the stand's statement; the driver's commission still applies "
              'as usual.',
              style: muted,
            ),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (_, c) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (c.maxWidth >= 860)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: feeCard),
                const SizedBox(width: 16),
                Expanded(child: platformCard),
              ],
            )
          else ...[
            feeCard,
            const SizedBox(height: 16),
            platformCard,
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('charges-save'),
              onPressed: _busy || !(canPlatform || canFee) ? null : _save,
              child: const Text('Save charges'),
            ),
          ),
          const SizedBox(height: 16),
          StandStatementCard(standId: _standId),
        ],
      ),
    );
  }

  StandFee _copy({FeeType? type, FeePayer? payer, bool? setByStand, FeeType? platformType}) => StandFee(
    type: type ?? _fee.type,
    value: _fee.value,
    payer: payer ?? _fee.payer,
    setByStand: setByStand ?? _fee.setByStand,
    platformType: platformType ?? _fee.platformType,
    platformValue: _fee.platformValue,
  );
}

/// The stand's statement: the last 30 days' finished orders and the totals.
class StandStatementCard extends ConsumerWidget {
  const StandStatementCard({super.key, required this.standId, this.days = 30});
  final String standId;
  final int days;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final async = ref.watch(standStatementProvider((stand: standId, days: days)));
    final s = async.value;
    String rm(double v) => 'RM ${v.toStringAsFixed(2)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Statement · last $days days', style: t.textTheme.titleMedium),
            if (async.isLoading && s == null) const LinearProgressIndicator(),
            if (async.hasError && s == null) Text("You can't see this stand's statement.", style: muted),
            if (s != null) ...[
              const SizedBox(height: 6),
              Text(
                '${s.total('orders').round()} orders · fares ${rm(s.total('fares'))} · stand fees ${rm(s.total('fees'))} · '
                'platform ${rm(s.total('platform'))} · stand keeps ${rm(s.total('stand'))}',
                key: const ValueKey('statement-totals'),
              ),
              Text('Taken at the counter: ${rm(s.total('counter'))}', style: muted),
              const SizedBox(height: 6),
              ListSearchFilter(
                count: s.orders.length,
                hint: 'Search tickets',
                fieldKey: const ValueKey('statement-search'),
                builder: (_, q) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final o in s.orders.reversed)
                      if (q.isEmpty || '${o['ticket_no']} ${o['driver']}'.toLowerCase().contains(q.toLowerCase()))
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${o['ticket_no']} · ${o['driver'] ?? ''}'),
                          subtitle: Text(
                            'Fare ${rm((o['fare'] as num? ?? 0).toDouble())} · fee ${rm((o['fee'] as num? ?? 0).toDouble())} · '
                            'platform ${rm((o['platform'] as num? ?? 0).toDouble())}',
                          ),
                          trailing: Text(rm((o['stand'] as num? ?? 0).toDouble())),
                        ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
