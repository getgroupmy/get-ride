// Admin > Display Settings > Ride Options > Freight settings (migration
// 0267): how long a driver's cancel after pickup waits for the sender before
// it is approved, how the recipient is sent the tracking link (SMS through
// the gateway, WhatsApp), and the prohibited items senders confirm they
// don't send. Kept in app_settings 'freight' (set_freight_config); the
// waiting fee, the cancel fee and the declared value cap are by place, under
// Charges and where offered.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/freight.dart';
import '../../../data/freight_repository.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import 'display_screen.dart' show displayPage;

class FreightSettingsScreen extends ConsumerStatefulWidget {
  const FreightSettingsScreen({super.key});

  @override
  ConsumerState<FreightSettingsScreen> createState() => _FreightSettingsScreenState();
}

class _FreightSettingsScreenState extends ConsumerState<FreightSettingsScreen> {
  final _item = TextEditingController();

  @override
  void dispose() {
    _item.dispose();
    super.dispose();
  }

  Future<void> _save(FreightConfig next) async {
    try {
      await ref.read(freightRepositoryProvider).saveConfig(next);
      ref.invalidate(freightConfigProvider);
      if (mounted) showInfo(context, 'Saved');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Freight settings')),
      body: AsyncView(
        value: ref.watch(freightConfigProvider),
        onRetry: () => ref.invalidate(freightConfigProvider),
        data: (c) => ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
          ResponsiveCenter(
            maxWidth: 820,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                key: const ValueKey('freight-settings-cancel'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Cancel after pickup', style: t.textTheme.titleMedium),
                    Text(
                      'Once the goods are picked up, the driver asks the sender to cancel. If the sender doesn\'t '
                      'answer in this time, it is approved.',
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: Text('${c.cancelApproveMinutes} min', key: const ValueKey('freight-cancel-minutes'))),
                      IconButton(
                        key: const ValueKey('freight-cancel-minutes-down'),
                        tooltip: 'Less',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: !canEdit || c.cancelApproveMinutes <= 1
                            ? null
                            : () => _save(c.copyWith(cancelApproveMinutes: c.cancelApproveMinutes - 1)),
                      ),
                      IconButton(
                        key: const ValueKey('freight-cancel-minutes-up'),
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
                key: const ValueKey('freight-settings-recipient'),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Text("The recipient's tracking link", style: t.textTheme.titleMedium),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                    child: Text(
                      'Sent when the trip starts. SMS goes out on the gateway phone of the outbound support message '
                      'route (SMS / WhatsApp settings); WhatsApp through the Business API set on the freight-notify '
                      'function.',
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                  for (final ch in FreightConfig.channels)
                    BusySwitchListTile(
                      key: ValueKey('freight-channel-$ch'),
                      title: Text(ch == 'sms' ? 'SMS' : 'WhatsApp'),
                      value: c.recipientChannels.contains(ch),
                      onChanged: canEdit
                          ? (v) => _save(c.copyWith(
                                recipientChannels: v ? {...c.recipientChannels, ch} : ({...c.recipientChannels}..remove(ch)),
                              ))
                          : null,
                    ),
                ]),
              ),
              Card(
                key: const ValueKey('freight-settings-prohibited'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Prohibited items', style: t.textTheme.titleMedium),
                    Text(
                      'Senders confirm their cargo has none of these before they book.',
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    if (canEdit)
                      Row(children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('freight-prohibited-new'),
                            controller: _item,
                            maxLength: 120,
                            decoration: const InputDecoration(labelText: 'Add an item'),
                            onSubmitted: (_) => _add(c),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('freight-prohibited-add'),
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
                              key: ValueKey('freight-prohibited-$i'),
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

  Future<void> _add(FreightConfig c) async {
    final next = withProhibitedItem(c.prohibitedItems, _item.text);
    if (identical(next, c.prohibitedItems)) return;
    _item.clear();
    await _save(c.copyWith(prohibitedItems: next));
  }
}
