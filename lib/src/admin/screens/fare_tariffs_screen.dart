import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/fare_tariff.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';

final fareTariffRowsProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepositoryProvider).fareTariffs());

/// Admin → Fare tariffs (migration 0109): what bookings are quoted at, by
/// place. The narrowest card that matches the pickup wins; without any, the
/// built-in TEKSI tariff in ringgit.
class AdminFareTariffsScreen extends ConsumerWidget {
  const AdminFareTariffsScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [FareTariff? card]) async {
    final result = await showDialog<FareTariff>(
      context: context,
      builder: (_) => _TariffDialog(card: card),
    );
    if (result == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveFareTariff(fareTariffRow(result)),
      success: 'Tariff saved',
    );
    if (ok) ref.invalidate(fareTariffRowsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(moduleAccessProvider('fare-tariffs')) == AccessLevel.edit;
    return AdminPage(
      title: 'Fare tariffs',
      module: 'fare-tariffs',
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => _edit(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add tariff'),
            )
          : null,
      body: AsyncView(
        value: ref.watch(fareTariffRowsProvider),
        onRetry: () => ref.invalidate(fareTariffRowsProvider),
        data: (rows) {
          final cards = [for (final r in rows) FareTariff.fromRow(r)]
            ..sort((a, b) => fareTariffLevels.indexOf(a.level).compareTo(fareTariffLevels.indexOf(b.level)));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Card(
                child: ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('How a booking is priced'),
                  subtitle: Text(
                    'The most specific active card for the pickup wins: suburb → city → state → country → '
                    'everywhere. Fare = the larger of the minimum fare and (base + per km + per minute) × the '
                    "service's multiplier, plus the booking fee, in the card's currency. With no card, the built-in "
                    'TEKSI tariff applies in ringgit. Meter Digital keeps its own rate cards.',
                  ),
                ),
              ),
              if (cards.isEmpty) const EmptyState(icon: Icons.price_change_outlined, title: 'No tariffs yet'),
              for (final c in cards)
                Card(
                  key: ValueKey('tariff-${c.id}'),
                  child: BusyListTile(
                    leading: CircleAvatar(child: Text(c.level.substring(0, 1).toUpperCase())),
                    title: Text([c.scope, if (c.label != null) c.label!].join(' · ')),
                    subtitle: Text(describeFareTariff(c)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!c.active) const StatusChip('inactive'),
                        if (canEdit)
                          BusyIconButton(
                            tooltip: 'Delete',

                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              if (!await confirm(context, 'Delete tariff?', c.scope, ok: 'Delete')) return;
                              if (!context.mounted) return;
                              if (await runAdminAction(
                                context,
                                () => ref.read(adminRepositoryProvider).deleteFareTariff(c.id!),
                              )) {
                                ref.invalidate(fareTariffRowsProvider);
                              }
                            },
                          ),
                      ],
                    ),
                    onTap: canEdit ? () => _edit(context, ref, c) : null,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TariffDialog extends StatefulWidget {
  const _TariffDialog({this.card});
  final FareTariff? card;

  @override
  State<_TariffDialog> createState() => _TariffDialogState();
}

class _TariffDialogState extends State<_TariffDialog> {
  late String _level = widget.card?.level ?? 'country';
  late bool _active = widget.card?.active ?? true;
  late final _text = {
    'country': TextEditingController(text: widget.card?.country),
    'state': TextEditingController(text: widget.card?.state),
    'city': TextEditingController(text: widget.card?.city),
    'suburb': TextEditingController(text: widget.card?.suburb),
    'label': TextEditingController(text: widget.card?.label),
    'currency': TextEditingController(text: widget.card?.currency ?? 'MYR'),
  };
  late final _money = {
    'base': TextEditingController(text: _show(widget.card?.baseFare)),
    'km': TextEditingController(text: _show(widget.card?.perKm)),
    'min': TextEditingController(text: _show(widget.card?.perMinute)),
    'minimum': TextEditingController(text: _show(widget.card?.minimumFare)),
    'fee': TextEditingController(text: _show(widget.card?.bookingFee)),
  };
  String? _error;

  static String _show(double? v) => v == null || v == 0 ? '' : v.toString();

  @override
  void dispose() {
    for (final c in [..._text.values, ..._money.values]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _n(String k) {
    final t = _money[k]!.text.trim();
    if (t.isEmpty) return 0;
    final v = double.tryParse(t);
    return v == null || v < 0 ? null : v;
  }

  void _save() {
    final values = {for (final k in _money.keys) k: _n(k)};
    if (values.values.any((v) => v == null)) {
      setState(() => _error = 'Charges are numbers of 0 or more.');
      return;
    }
    final card = FareTariff(
      id: widget.card?.id,
      level: _level,
      country: _text['country']!.text,
      state: _text['state']!.text,
      city: _text['city']!.text,
      suburb: _text['suburb']!.text,
      label: _text['label']!.text,
      currency: _text['currency']!.text.trim().toUpperCase(),
      baseFare: values['base']!,
      perKm: values['km']!,
      perMinute: values['min']!,
      minimumFare: values['minimum']!,
      bookingFee: values['fee']!,
      active: _active,
    );
    final problem = fareTariffProblem(card);
    if (problem != null) return setState(() => _error = problem);
    Navigator.pop(context, card);
  }

  @override
  Widget build(BuildContext context) {
    final depth = fareTariffLevels.indexOf(_level);
    Widget money(String k, String label) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        key: ValueKey('tariff-$k'),
        controller: _money[k],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, hintText: '0'),
      ),
    );
    return AlertDialog(
      title: Text(widget.card == null ? 'Add fare tariff' : 'Edit fare tariff'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('tariff-level'),
                initialValue: _level,
                decoration: const InputDecoration(labelText: 'Applies to'),
                items: [
                  for (final l in fareTariffLevels)
                    DropdownMenuItem(value: l, child: Text(l == 'master' ? 'Everywhere (master)' : l)),
                ],
                onChanged: (v) => setState(() => _level = v ?? _level),
              ),
              for (final (i, k) in const [(1, 'country'), (2, 'state'), (3, 'city'), (4, 'suburb')])
                if (depth >= i)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      key: ValueKey('tariff-$k'),
                      controller: _text[k],
                      decoration: InputDecoration(labelText: k[0].toUpperCase() + k.substring(1)),
                    ),
                  ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TextField(
                  key: const ValueKey('tariff-currency'),
                  controller: _text['currency'],
                  maxLength: 3,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Currency (ISO code)', counterText: ''),
                ),
              ),
              money('base', 'Base fare'),
              money('km', 'Per km'),
              money('min', 'Per minute'),
              money('minimum', 'Minimum fare'),
              money('fee', 'Booking fee'),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TextField(
                  controller: _text['label'],
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Label (optional)', counterText: ''),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
              if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey('tariff-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('tariff-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
