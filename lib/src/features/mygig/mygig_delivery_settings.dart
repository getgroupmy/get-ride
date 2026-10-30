// myGiG Delivery settings (migration 0332): the driver's own values for
// myGiG deliveries: get.ride's rates for their vehicle or their own (when
// the admin allows, within the limits), waiting, the return charge, the
// item types they take, the longest delivery, COD and recipient pays, and
// how the price shows. The server keeps every value within the admin's.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mygig.dart';
import '../../core/mygig_delivery.dart';
import '../../data/mygig_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';

const mygigDeliverySettingsPath = '/drive/mygig/delivery/settings';

class MygigDeliverySettingsScreen extends ConsumerStatefulWidget {
  const MygigDeliverySettingsScreen({super.key});

  @override
  ConsumerState<MygigDeliverySettingsScreen> createState() => _MygigDeliverySettingsScreenState();
}

class _MygigDeliverySettingsScreenState extends ConsumerState<MygigDeliverySettingsScreen> {
  MygigDeliveryPrefs? _p;

  Future<void> _save() async {
    final p = _p;
    if (p == null) return;
    try {
      final saved = await ref.read(mygigRepositoryProvider).saveDeliveryPrefs(p);
      if (!mounted) return;
      setState(() => _p = saved);
      ref.invalidate(mygigDeliveryConfigProvider);
      await showAppNotice(
        id: 'notice.mygig',
        context: context,
        kind: NoticeKind.success,
        title: 'Delivery settings saved',
        message: 'Used from your next myGiG delivery. Values above get.ride’s limits were brought within them.',
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(mygigDeliveryConfigProvider(mygigAt(null, null)));
    return Scaffold(
      appBar: AppBar(title: const Text('Delivery settings')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(mygigDeliveryConfigProvider),
        data: (c) {
          _p ??= c.prefs;
          return MygigDeliveryPrefsForm(config: c, prefs: _p!, onChanged: (p) => setState(() => _p = p), onSave: _save);
        },
      ),
    );
  }
}

/// The form itself (also tested on its own).
class MygigDeliveryPrefsForm extends StatelessWidget {
  const MygigDeliveryPrefsForm({super.key, required this.config, required this.prefs, required this.onChanged, required this.onSave});
  final MygigDeliveryConfig config;
  final MygigDeliveryPrefs prefs;
  final ValueChanged<MygigDeliveryPrefs> onChanged;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = config.settings;
    final p = prefs;
    final g = config.gcard;
    final lim = s.limits;
    double lim0(String k, double f) => lim[k] is num ? (lim[k] as num).toDouble() : f;
    Widget sec(IconData i, String title) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Row(children: [Icon(i, size: 20), const SizedBox(width: 8), Text(title, style: t.textTheme.titleSmall)]),
    );
    Widget field(String key, String label, double value, ValueChanged<double> set, {bool whole = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: _NumField(key: ValueKey('mygig-dprefs-$key'), label: label, value: value, whole: whole, onChanged: set),
    );
    return ResponsiveCenter(
      maxWidth: 640,
      child: ListView(
        key: const ValueKey('mygig-delivery-settings'),
        padding: const EdgeInsets.all(16),
        children: [
          Text('Your own values for myGiG deliveries with your ${config.vehicleName.toLowerCase()}. '
              'Senders see the price before they accept.', style: t.textTheme.bodySmall),
          sec(Icons.payments_outlined, 'Delivery rates'),
          if (s.allowOwnRates) ...[
            RadioGroup<bool>(
              groupValue: p.own,
              onChanged: (v) => onChanged(p.copyWith({'own': v ?? false})),
              child: Column(children: [
                RadioListTile<bool>(
                  key: const ValueKey('mygig-dprefs-getride'),
                  value: false,
                  title: const Text('get.ride delivery rates'),
                  subtitle: Text('${g.line}; Medium +${mygigMoney(g.extra('medium'))}, Large +${mygigMoney(g.extra('large'))}'),
                ),
                const RadioListTile<bool>(
                  key: ValueKey('mygig-dprefs-own'),
                  value: true,
                  title: Text('My own delivery rates'),
                  subtitle: Text('Set them below'),
                ),
              ]),
            ),
            if (p.own) ...[
              field('base', 'Base (RM)', p.rates.base, (v) => onChanged(p.withRate('base', v))),
              field('perKm', 'Per km (RM)', p.rates.perKm, (v) => onChanged(p.withRate('perKm', v))),
              field('min', 'Minimum (RM)', p.rates.min, (v) => onChanged(p.withRate('min', v))),
              for (final k in const ['medium', 'large', 'bulky'])
                if (s.sizeFits(k, config.vehicle))
                  field(k, '${mygigDeliverySizeName(k)} extra (RM)', p.rates.extra(k), (v) => onChanged(p.withRate(k, v))),
              field('freeKg', 'Free weight (kg)', p.rates.freeKg, (v) => onChanged(p.withRate('freeKg', v)), whole: true),
              field('perKg', 'Then per kg (RM)', p.rates.perKg, (v) => onChanged(p.withRate('perKg', v))),
              field('fragile', 'Fragile (RM)', p.rates.fragile, (v) => onChanged(p.withRate('fragile', v))),
              field('extraDrop', 'Each extra drop-off (RM)', p.rates.extraDrop, (v) => onChanged(p.withRate('extraDrop', v))),
              Text('Allowed by get.ride: base up to ${mygigMoney(lim0('base', 20))}, per km ${mygigMoney(lim0('perKmMin', 0.5))} '
                  'to ${mygigMoney(lim0('perKmMax', 3))}, each extra up to ${mygigMoney(lim0('extraMax', 30))}.',
                  style: t.textTheme.bodySmall),
            ],
          ] else
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('get.ride delivery rates'),
              subtitle: Text('${g.line}. Your partner type uses get.ride’s rates.'),
            ),
          sec(Icons.hourglass_top, 'Waiting at the pickup or a drop-off'),
          if (s.allowOwnWait) ...[
            SwitchListTile(
              key: const ValueKey('mygig-dprefs-wait-own'),
              contentPadding: EdgeInsets.zero,
              value: p.waitOwn,
              title: const Text('My own waiting charge'),
              subtitle: Text(p.waitOwn ? 'Set it below' : 'get.ride’s: ${s.waitFreeMin.round()} min free, then ${mygigMoney(s.waitPerMin)} a minute'),
              onChanged: (v) => onChanged(p.copyWith({'waitOwn': v})),
            ),
            if (p.waitOwn) ...[
              field('waitFree', 'Free (min)', p.waitFree.toDouble(), (v) => onChanged(p.copyWith({'waitFree': v.round()})), whole: true),
              field('waitPerMin', 'Then per minute (RM)', p.waitPerMin, (v) => onChanged(p.copyWith({'waitPerMin': v}))),
              Text('Up to ${mygigMoney(lim0('waitMax', 1))} a minute (set by get.ride).', style: t.textTheme.bodySmall),
            ],
          ] else
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('get.ride waiting charge'),
              subtitle: Text('${s.waitFreeMin.round()} min free, then ${mygigMoney(s.waitPerMin)} a minute.'),
            ),
          sec(Icons.keyboard_return, 'Returns'),
          field('returnPct', 'Return charge (% of the return fare)', p.returnPct.toDouble(),
              (v) => onChanged(p.copyWith({'returnPct': v.round()})), whole: true),
          Text('When the recipient refuses or isn’t there. The sender pays it, from their in-app account or their deposit; '
              'up to ${s.returnPctMax.round()}% (set by get.ride).', style: t.textTheme.bodySmall),
          sec(Icons.category_outlined, 'What you carry'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final type in s.itemTypes)
              FilterChip(
                key: ValueKey('mygig-dprefs-type-$type'),
                label: Text(type),
                selected: !p.offTypes.contains(type),
                onSelected: (on) => onChanged(p.copyWith({
                  'offTypes': on ? (p.offTypes.toList()..remove(type)) : [...p.offTypes, type],
                })),
              ),
          ]),
          Text('Tap to switch an item type off. Sizes follow your vehicle (get.ride’s list).', style: t.textTheme.bodySmall),
          field('maxKm', 'Longest delivery (km)', p.maxKm.toDouble(), (v) => onChanged(p.copyWith({'maxKm': v.round()})), whole: true),
          sec(Icons.point_of_sale, 'Payments you take'),
          SwitchListTile(
            key: const ValueKey('mygig-dprefs-cod'),
            contentPadding: EdgeInsets.zero,
            value: p.takeCod,
            title: const Text('Cash on delivery'),
            subtitle: const Text('Collect the item’s price from the recipient'),
            onChanged: (v) => onChanged(p.copyWith({'takeCod': v})),
          ),
          SwitchListTile(
            key: const ValueKey('mygig-dprefs-recipient'),
            contentPadding: EdgeInsets.zero,
            value: p.takeRecipientPays,
            title: const Text('Recipient pays'),
            subtitle: const Text('The recipient pays the delivery at the door'),
            onChanged: (v) => onChanged(p.copyWith({'takeRecipientPays': v})),
          ),
          Text('These only narrow what get.ride allows; get.ride’s rules for senders without the app still apply.',
              style: t.textTheme.bodySmall),
          sec(Icons.receipt_long_outlined, 'How the price shows'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: p.showTax,
            title: const Text('Show service tax as its own line'),
            subtitle: const Text('Off: one price that includes the tax'),
            onChanged: (v) => onChanged(p.copyWith({'showTax': v})),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: p.roundUp,
            title: const Text('Round up to whole ringgit'),
            subtitle: Text(p.roundUp ? 'RM16.37 shows as RM17' : 'Off: shows cents'),
            onChanged: (v) => onChanged(p.copyWith({'roundUp': v})),
          ),
          const SizedBox(height: 16),
          BusyButton.filled(
            key: const ValueKey('mygig-dprefs-save'),
            icon: const Icon(Icons.check),
            onPressed: onSave,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _NumField extends StatefulWidget {
  const _NumField({super.key, required this.label, required this.value, required this.onChanged, this.whole = false});
  final String label;
  final double value;
  final bool whole;
  final ValueChanged<double> onChanged;

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final _c = TextEditingController(
      text: widget.whole ? widget.value.round().toString() : widget.value.toStringAsFixed(2));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    keyboardType: TextInputType.numberWithOptions(decimal: !widget.whole),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(widget.whole ? r'[0-9]' : r'[0-9.]'))],
    decoration: InputDecoration(labelText: widget.label),
    onChanged: (v) {
      final n = double.tryParse(v);
      if (n != null && n >= 0) widget.onChanged(n);
    },
  );
}
