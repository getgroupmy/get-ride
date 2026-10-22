// Admin > Display Settings > Ride Options > Courier settings (migration
// 0268): who gets the confirmation code (SMS or WhatsApp to the recipient,
// with the tracking link, and / or shown to the sender), the kilos of the
// S / M / L parcel sizes, how long a courier's cancel after pickup waits for
// the sender, and the prohibited items. Kept in app_settings 'courier'
// (set_courier_config); the waiting fee, the cancel fee and the most value a
// sender may declare are by place, under Charges and where offered. The
// vehicles' own weight and size limits are on Admin > Vehicle Services.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/courier.dart';
import '../../../core/freight.dart' show withProhibitedItem;
import '../../../data/freight_repository.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import 'display_screen.dart' show displayPage;

class CourierSettingsScreen extends ConsumerStatefulWidget {
  const CourierSettingsScreen({super.key});

  @override
  ConsumerState<CourierSettingsScreen> createState() => _CourierSettingsScreenState();
}

class _CourierSettingsScreenState extends ConsumerState<CourierSettingsScreen> {
  final _item = TextEditingController();

  @override
  void dispose() {
    _item.dispose();
    super.dispose();
  }

  Future<void> _save(CourierConfig next) async {
    try {
      await ref.read(freightRepositoryProvider).saveCourierConfig(next);
      ref.invalidate(courierConfigProvider);
      if (mounted) showInfo(context, 'Saved');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _editKg(CourierConfig c, ParcelSize p) async {
    final kg = await showAppDialog<double>(id: 'display.courier-parcel-kg',
      context: context,
      builder: (_) => _KgDialog(size: p, initial: c.kgOf(p)),
    );
    if (kg == null || !mounted) return;
    await _save(c.copyWith(parcelKg: {...c.parcelKg, p: kg}));
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    Widget head(String title, String hint) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: t.textTheme.titleMedium),
        Text(hint, style: t.textTheme.bodySmall?.copyWith(color: muted)),
      ]),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Courier settings')),
      body: AsyncView(
        value: ref.watch(courierConfigProvider),
        onRetry: () => ref.invalidate(courierConfigProvider),
        data: (c) => ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
          ResponsiveCenter(
            maxWidth: 820,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                key: const ValueKey('courier-settings-code'),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  head(
                    'Confirmation code',
                    'Every delivery gets a 4-digit code; the courier enters it to finish. SMS goes out on the gateway '
                        'phone of the outbound support message route, WhatsApp through the Business API set on the '
                        'freight-notify function, with the tracking link when the courier picks up. With neither, the '
                        'sender always sees the code.',
                  ),
                  for (final ch in CourierConfig.channels)
                    BusySwitchListTile(
                      key: ValueKey('courier-channel-$ch'),
                      title: Text(courierChannelLabel(ch)),
                      value: c.codeChannels.contains(ch),
                      onChanged: canEdit
                          ? (v) {
                              final next = v ? {...c.codeChannels, ch} : ({...c.codeChannels}..remove(ch));
                              if (next.isEmpty) {
                                showInfo(context, 'Keep at least one way for the code to reach someone.');
                                return Future.value();
                              }
                              return _save(c.copyWith(codeChannels: next));
                            }
                          : null,
                    ),
                ]),
              ),
              Card(
                key: const ValueKey('courier-settings-sizes'),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  head(
                    'Parcel sizes',
                    'The most each size may weigh. A sender only sees the vehicles whose Max load (Admin > Vehicle '
                        'Services) carries it.',
                  ),
                  for (final p in ParcelSize.values)
                    ListTile(
                      key: ValueKey('courier-size-${p.id}'),
                      title: Text(p.id),
                      subtitle: Text('up to ${trimKg(c.kgOf(p))} kg', key: ValueKey('courier-size-kg-${p.id}')),
                      trailing: canEdit ? const Icon(Icons.edit_outlined) : null,
                      onTap: canEdit ? () => _editKg(c, p) : null,
                    ),
                ]),
              ),
              Card(
                key: const ValueKey('courier-settings-cancel'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Cancel after pickup', style: t.textTheme.titleMedium),
                    Text(
                      'Once the parcel is picked up, the courier asks the sender to cancel. If the sender doesn\'t '
                      'answer in this time, it is approved.',
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: Text('${c.cancelApproveMinutes} min', key: const ValueKey('courier-cancel-minutes'))),
                      IconButton(
                        key: const ValueKey('courier-cancel-minutes-down'),
                        tooltip: 'Less',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: !canEdit || c.cancelApproveMinutes <= 1
                            ? null
                            : () => _save(c.copyWith(cancelApproveMinutes: c.cancelApproveMinutes - 1)),
                      ),
                      IconButton(
                        key: const ValueKey('courier-cancel-minutes-up'),
                        tooltip: 'More',
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: !canEdit || c.cancelApproveMinutes >= 60
                            ? null
                            : () => _save(c.copyWith(cancelApproveMinutes: c.cancelApproveMinutes + 1)),
                      ),
                    ]),
                  ]),
                ),
              ),
              Card(
                key: const ValueKey('courier-settings-prohibited'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Prohibited items', style: t.textTheme.titleMedium),
                    Text(
                      'Senders confirm their parcel has none of these before they book.',
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    if (canEdit)
                      Row(children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('courier-prohibited-new'),
                            controller: _item,
                            maxLength: 120,
                            decoration: const InputDecoration(labelText: 'Add an item'),
                            onSubmitted: (_) => _add(c),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('courier-prohibited-add'),
                          tooltip: 'Add',
                          icon: const Icon(Icons.add),
                          onPressed: () => _add(c),
                        ),
                      ]),
                    ListSearchFilter(
                      count: c.prohibitedItems.length,
                      hint: 'Search items',
                      builder: (context, q) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final i in c.prohibitedItems)
                          if (q.isEmpty || searchSelectMatches(i, q))
                            ListTile(
                              key: ValueKey('courier-prohibited-$i'),
                              contentPadding: EdgeInsets.zero,
                              title: Text(i),
                              trailing: canEdit
                                  ? IconButton(
                                      tooltip: 'Remove',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _save(c.copyWith(
                                        prohibitedItems: [for (final x in c.prohibitedItems) if (x != i) x],
                                      )),
                                    )
                                  : null,
                            ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _add(CourierConfig c) async {
    final next = withProhibitedItem(c.prohibitedItems, _item.text);
    if (identical(next, c.prohibitedItems)) return;
    _item.clear();
    await _save(c.copyWith(prohibitedItems: next));
  }
}

/// The kilos of one parcel size: 0.1 to 1,000.
class _KgDialog extends StatefulWidget {
  const _KgDialog({required this.size, required this.initial});
  final ParcelSize size;
  final double initial;

  @override
  State<_KgDialog> createState() => _KgDialogState();
}

class _KgDialogState extends State<_KgDialog> {
  late final _text = TextEditingController(text: trimKg(widget.initial));
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final v = double.tryParse(_text.text.trim());
    if (v == null || v < 0.1 || v > 1000) return setState(() => _problem = 'Enter 0.1 to 1,000 kg.');
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Size ${widget.size.id}'),
    content: TextField(
      key: const ValueKey('courier-size-kg-field'),
      controller: _text,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,1}'))],
      decoration: InputDecoration(labelText: 'Up to', suffixText: 'kg', errorText: _problem),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(key: const ValueKey('courier-size-kg-save'), onPressed: _save, child: const Text('Save')),
    ],
  );
}
