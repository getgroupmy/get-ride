// Admin → Commission → Settings and Tiers (migration 0218).
//
// Settings: whether GET.credit may go below zero (and how far) before a
// driver can't take work, what commission is charged on (the fare plus each
// surcharge ticked, tolls, other charges), and the meter / TEKSI switch.
// Tiers: lower rates for drivers who reach a number of trips, fare earnings
// or online hours over 7 or 30 days, or a rating; each can be turned off.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/commission_settings.dart';
import '../../data/live_tables.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';

/// The surcharges a meter hire carries, as the base names them (0219).
const meterSurchargeNames = ['Airport surcharge', 'Bags & passengers'];

final commissionConfigProvider = FutureProvider.autoDispose<CommissionConfig>((ref) {
  ref.watchLive('app_settings');
  return ref.watch(adminRepositoryProvider).commissionConfig();
});

final commissionTiersProvider = FutureProvider.autoDispose<List<CommissionTier>>((ref) {
  ref.watchLive('commission_tiers');
  return ref.watch(adminRepositoryProvider).commissionTiers();
});

/// Surcharge names seen on trips; empty when unreadable.
final commissionSurchargeNamesProvider = FutureProvider.autoDispose<List<({String name, int trips})>>((ref) async {
  try {
    return await ref.watch(adminRepositoryProvider).surchargeNamesSeen();
  } catch (_) {
    return const [];
  }
});

// ---- Settings ----------------------------------------------------------------------------------
class CommissionSettingsTab extends ConsumerStatefulWidget {
  const CommissionSettingsTab({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<CommissionSettingsTab> createState() => _CommissionSettingsTabState();
}

class _CommissionSettingsTabState extends ConsumerState<CommissionSettingsTab> {
  CommissionConfig? _stored;
  CommissionConfig? _draft;
  bool _saving = false;
  final _limit = TextEditingController();
  final _extra = TextEditingController();

  @override
  void dispose() {
    _limit.dispose();
    _extra.dispose();
    super.dispose();
  }

  void _set(CommissionConfig c) => setState(() => _draft = c);

  void _toggleSurcharge(String name, bool on) {
    final names = [..._draft!.baseSurcharges]..remove(name);
    if (on) names.add(name);
    _set(_draft!.copyWith(baseSurcharges: names));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await runAdminAction(context, () async {
      final saved = await ref.read(adminRepositoryProvider).saveCommissionConfig(_draft!);
      if (mounted) setState(() => _stored = _draft = saved);
    }, success: 'Commission settings saved');
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(commissionConfigProvider);
    final fresh = loaded.value;
    if (fresh != null && fresh != _stored) {
      if (_draft == null || _draft == _stored) {
        _draft = fresh;
        _limit.text = fresh.negativeLimit == 0 ? '' : fresh.negativeLimit.toStringAsFixed(2);
      }
      _stored = fresh;
    }
    return AsyncView(
      value: loaded,
      onRetry: () => ref.invalidate(commissionConfigProvider),
      data: (_) {
        final c = _draft!;
        final t = Theme.of(context);
        final muted = t.colorScheme.onSurfaceVariant;
        final edit = widget.canEdit && !_saving;
        final seen = ref.watch(commissionSurchargeNamesProvider).value ?? const [];
        // Names ticked before but not on a trip this year stay listed, so they can be unticked.
        final names = <String, int>{
          for (final n in c.baseSurcharges) n: 0,
          // The meter's own charges, for meter / TEKSI hires (0219).
          for (final n in meterSurchargeNames) n: 0,
          for (final n in seen) n.name: n.trips,
        };
        Widget heading(String text, [String? note]) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, style: t.textTheme.titleSmall),
              if (note != null) Text(note, style: t.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ),
        );
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            ResponsiveCenter(
              maxWidth: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (c != _stored && widget.canEdit)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            key: const ValueKey('commission-settings-discard'),
                            onPressed: _saving ? null : () => setState(() => _draft = _stored),
                            child: const Text('Discard'),
                          ),
                          FilledButton.icon(
                            key: const ValueKey('commission-settings-save'),
                            onPressed: _saving ? null : _save,
                            icon: const Icon(Icons.save_outlined),
                            label: Text(_saving ? 'Saving…' : 'Save'),
                          ),
                        ],
                      ),
                    ),
                  heading('GET.credit below zero',
                      'Commission is taken from GET.credit. A driver below the line can\'t go online, offer on or '
                      'take a trip until they top up; a trip they are on finishes as usual.'),
                  SwitchListTile(
                    key: const ValueKey('commission-allow-negative'),
                    contentPadding: EdgeInsets.zero,
                    value: c.allowNegativeCredit,
                    title: const Text('Allow GET.credit below zero'),
                    subtitle: Text(c.allowNegativeCredit
                        ? (c.negativeLimit > 0
                            ? 'Down to RM -${c.negativeLimit.toStringAsFixed(2)}'
                            : 'No limit (as before)')
                        : 'Drivers must keep RM 0 or more to take work'),
                    onChanged: edit ? (v) => _set(_draft!.copyWith(allowNegativeCredit: v)) : null,
                  ),
                  if (c.allowNegativeCredit)
                    TextField(
                      key: const ValueKey('commission-negative-limit'),
                      controller: _limit,
                      enabled: edit,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(
                        labelText: 'How far below zero (RM)',
                        hintText: 'Blank or 0: no limit',
                        prefixText: 'RM -',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => _set(_draft!.copyWith(negativeLimit: double.tryParse(v.trim()) ?? 0)),
                    ),
                  heading('What commission is charged on',
                      'Always the fare. Tick the surcharges, tolls and other charges to charge commission on too. '
                      'Taxes and GET.ride\'s own fees (scheduling, late cancellation) are never included.'),
                  CheckboxListTile(
                    key: const ValueKey('commission-base-tolls'),
                    contentPadding: EdgeInsets.zero,
                    value: c.baseTolls,
                    title: const Text('Tolls'),
                    onChanged: edit ? (v) => _set(_draft!.copyWith(baseTolls: v ?? false)) : null,
                  ),
                  CheckboxListTile(
                    key: const ValueKey('commission-base-other'),
                    contentPadding: EdgeInsets.zero,
                    value: c.baseOtherCharges,
                    title: const Text('Other charges the driver adds'),
                    onChanged: edit ? (v) => _set(_draft!.copyWith(baseOtherCharges: v ?? false)) : null,
                  ),
                  if (names.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('No surcharges on trips in the last year.', style: TextStyle(color: muted)),
                    ),
                  for (final e in names.entries)
                    CheckboxListTile(
                      key: ValueKey('commission-base-${e.key}'),
                      contentPadding: EdgeInsets.zero,
                      value: c.baseSurcharges.contains(e.key),
                      title: Text(e.key),
                      subtitle: e.value > 0 ? Text('${e.value} trips in the last year') : null,
                      onChanged: edit ? (v) => _toggleSurcharge(e.key, v ?? false) : null,
                    ),
                  if (widget.canEdit)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('commission-base-add'),
                            controller: _extra,
                            enabled: edit,
                            decoration: const InputDecoration(labelText: 'Another surcharge name (as on the trip)'),
                          ),
                        ),
                        TextButton(
                          onPressed: edit
                              ? () {
                                  final n = _extra.text.trim();
                                  if (n.isEmpty || c.baseSurcharges.contains(n)) return;
                                  _extra.clear();
                                  _toggleSurcharge(n, true);
                                }
                              : null,
                          child: const Text('Add'),
                        ),
                      ],
                    ),
                  heading('Meter and TEKSI street hails'),
                  SwitchListTile(
                    key: const ValueKey('commission-meter'),
                    contentPadding: EdgeInsets.zero,
                    value: c.meterCommission,
                    title: const Text('Charge commission on meter / TEKSI trips'),
                    subtitle: const Text('Each hire is sent from the driver\'s phone when it ends (or when '
                        'they are next online) and charged then, at the rate for where it began, on the fare plus '
                        'what is ticked above: "Tolls" for the meter\'s tolls & charges, "Airport surcharge" and '
                        '"Bags & passengers". Hires sent while this is off are not charged later.'),
                    onChanged: edit ? (v) => _set(_draft!.copyWith(meterCommission: v)) : null,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---- Tiers -------------------------------------------------------------------------------------
class CommissionTiersTab extends ConsumerWidget {
  const CommissionTiersTab({super.key, required this.canEdit});
  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, [CommissionTier? tier, int position = 0]) async {
    final result = await showAppDialog<CommissionTier>(
      id: 'commission.tier',
      context: context,
      builder: (_) => _TierDialog(tier: tier, position: position),
    );
    if (result == null || !context.mounted) return;
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).saveCommissionTier(result),
        success: 'Tier saved')) {
      ref.invalidate(commissionTiersProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return AsyncView(
      value: ref.watch(commissionTiersProvider),
      onRetry: () => ref.invalidate(commissionTiersProvider),
      data: (tiers) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          ResponsiveCenter(
            maxWidth: 760,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'A driver who meets a tier pays less. Of the tiers they meet, the lowest rate wins. Trips, '
                  'earnings and hours count the last 7 or 30 days at the moment they accept a trip, and the rate '
                  'is kept for that trip. A personal rate set for one driver is not lowered.',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                const SizedBox(height: 8),
                if (canEdit)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('commission-tier-add'),
                      onPressed: () => _edit(context, ref, null, tiers.length),
                      icon: const Icon(Icons.add),
                      label: const Text('Add tier'),
                    ),
                  ),
                const SizedBox(height: 8),
                if (tiers.isEmpty)
                  const EmptyState(icon: Icons.workspace_premium_outlined, title: 'No tiers yet'),
                for (final tier in tiers)
                  Card(
                    child: ListTile(
                      key: ValueKey('commission-tier-${tier.id}'),
                      leading: Icon(Icons.workspace_premium_outlined,
                          color: tier.active ? t.colorScheme.primary : t.colorScheme.outline),
                      title: Text(tier.name),
                      subtitle: Text(
                        [tier.condition, tier.effect, if (tier.note.isNotEmpty) tier.note].join(' · '),
                        style: TextStyle(color: muted),
                      ),
                      onTap: canEdit ? () => _edit(context, ref, tier) : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            key: ValueKey('commission-tier-active-${tier.id}'),
                            value: tier.active,
                            onChanged: canEdit
                                ? (v) async {
                                    if (await runAdminAction(context,
                                        () => ref.read(adminRepositoryProvider).saveCommissionTier(tier.copyWith(active: v)))) {
                                      ref.invalidate(commissionTiersProvider);
                                    }
                                  }
                                : null,
                          ),
                          if (canEdit)
                            BusyIconButton(
                              key: ValueKey('commission-tier-delete-${tier.id}'),
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                if (!await confirm(context, 'Delete tier?', tier.name, ok: 'Delete')) return;
                                if (!context.mounted) return;
                                if (await runAdminAction(
                                    context, () => ref.read(adminRepositoryProvider).deleteCommissionTier(tier.id!))) {
                                  ref.invalidate(commissionTiersProvider);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TierDialog extends StatefulWidget {
  const _TierDialog({this.tier, required this.position});
  final CommissionTier? tier;
  final int position;

  @override
  State<_TierDialog> createState() => _TierDialogState();
}

class _TierDialogState extends State<_TierDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.tier?.name ?? '');
  late final _threshold = TextEditingController(text: _num(widget.tier?.threshold));
  late final _value = TextEditingController(text: widget.tier == null ? '' : _num(widget.tier!.value * 100));
  late final _note = TextEditingController(text: widget.tier?.note ?? '');
  late TierMetric _metric = widget.tier?.metric ?? TierMetric.trips;
  late int _window = widget.tier?.windowDays ?? 7;
  late String _adjust = widget.tier?.adjust ?? 'rate';
  late bool _active = widget.tier?.active ?? true;

  static String _num(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));

  @override
  void dispose() {
    _name.dispose();
    _threshold.dispose();
    _value.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final decimal = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
    return AlertDialog(
      title: Text(widget.tier == null ? 'Add tier' : 'Edit tier'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  key: const ValueKey('tier-name'),
                  controller: _name,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Gold driver'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Give the tier a name' : null,
                ),
                DropdownButtonFormField<TierMetric>(
                  key: const ValueKey('tier-metric'),
                  isExpanded: true,
                  initialValue: _metric,
                  decoration: const InputDecoration(labelText: 'Driver reaches'),
                  items: [for (final m in TierMetric.values) DropdownMenuItem(value: m, child: Text(m.label))],
                  onChanged: (v) => setState(() => _metric = v ?? _metric),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const ValueKey('tier-threshold'),
                  controller: _threshold,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: decimal,
                  decoration: InputDecoration(
                    labelText: 'At least',
                    hintText: _metric == TierMetric.rating ? 'e.g. 4.8' : 'e.g. 50',
                  ),
                  validator: (v) {
                    final n = double.tryParse((v ?? '').trim());
                    if (n == null || n < 0) return 'Enter a number';
                    if (_metric == TierMetric.rating && n > 5) return 'Ratings go up to 5';
                    return null;
                  },
                ),
                if (_metric.windowed) ...[
                  const SizedBox(height: 12),
                  SegmentedButton<int>(
                    key: const ValueKey('tier-window'),
                    segments: const [
                      ButtonSegment(value: 7, label: Text('Last 7 days')),
                      ButtonSegment(value: 30, label: Text('Last 30 days')),
                    ],
                    selected: {_window},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => setState(() => _window = v.first),
                  ),
                ],
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  key: const ValueKey('tier-adjust'),
                  segments: const [
                    ButtonSegment(value: 'rate', label: Text('Rate of at most')),
                    ButtonSegment(value: 'minus', label: Text('Points off the rate')),
                  ],
                  selected: {_adjust},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() => _adjust = v.first),
                ),
                TextFormField(
                  key: const ValueKey('tier-value'),
                  controller: _value,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: decimal,
                  decoration: InputDecoration(
                    labelText: _adjust == 'rate' ? 'Rate (%)' : 'Off the rate (%)',
                    suffixText: '%',
                  ),
                  validator: (v) {
                    final n = double.tryParse((v ?? '').trim());
                    return n == null || n < 0 || n >= 100 ? 'Between 0 and 99.99' : null;
                  },
                ),
                TextFormField(
                  key: const ValueKey('tier-note'),
                  controller: _note,
                  maxLength: 300,
                  decoration: const InputDecoration(labelText: 'Note (optional)'),
                ),
                SwitchListTile(
                  key: const ValueKey('tier-active'),
                  contentPadding: EdgeInsets.zero,
                  value: _active,
                  title: const Text('On'),
                  onChanged: (v) => setState(() => _active = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('tier-save'),
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(
              context,
              CommissionTier(
                id: widget.tier?.id,
                name: _name.text.trim(),
                active: _active,
                metric: _metric,
                windowDays: _window,
                threshold: double.parse(_threshold.text.trim()),
                adjust: _adjust,
                value: double.parse((double.parse(_value.text.trim()) / 100).toStringAsFixed(4)),
                note: _note.text.trim(),
                position: widget.tier?.position ?? widget.position,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
