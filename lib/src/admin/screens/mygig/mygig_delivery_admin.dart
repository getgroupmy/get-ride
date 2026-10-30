// myGiG Delivery on the admin's myGiG dashboard (migration 0332), page
// admin-mygig: the day's deliveries (delivered, returned, COD collected,
// how many recipients paid, the average fare, deposits held and refunds
// to make on the gateway), the Money safety panel (no setting leaves
// get.ride or the driver unpaid), returns waiting for support to decide
// (a note is required; the driver never keeps the parcel), and the list of
// deliveries going, needing support or a refund.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/mygig.dart' show mygigMoney;
import '../../../core/mygig_delivery.dart';
import '../../../data/mygig_repository.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../widgets/admin_widgets.dart';

final _statsProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, DateTime>(
  (ref, day) => ref.watch(mygigRepositoryProvider).adminDeliveryStats(day: day),
);

final _listProvider = FutureProvider.autoDispose.family<List<MygigDelivery>, String>(
  (ref, filter) => ref.watch(mygigRepositoryProvider).adminDeliveries(filter: filter),
);

/// The Default rule's delivery settings, for the Money safety panel's numbers.
final _settingsProvider = FutureProvider.autoDispose<MygigDeliverySettings>((ref) async {
  final rules = await ref.watch(mygigRepositoryProvider).rules();
  final def = rules.where((r) => r['level'] == 'default').firstOrNull;
  final s = def?['settings'] is Map ? Map<String, dynamic>.from(def!['settings'] as Map) : <String, dynamic>{};
  return MygigDeliverySettings(s['delivery'] is Map ? Map<String, dynamic>.from(s['delivery'] as Map) : const {});
});

class MygigDeliveryAdminSection extends ConsumerStatefulWidget {
  const MygigDeliveryAdminSection({super.key, required this.day, required this.canEdit});
  final DateTime day;
  final bool canEdit;

  @override
  ConsumerState<MygigDeliveryAdminSection> createState() => _MygigDeliveryAdminSectionState();
}

class _MygigDeliveryAdminSectionState extends ConsumerState<MygigDeliveryAdminSection> {
  String _filter = 'open';

  Future<void> _decide(MygigDeliveryReturn r) async {
    final c = TextEditingController();
    final note = await showAppDialog<String>(
      id: 'mygig.delivery-decide',
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Support decides: it goes back'),
        content: TextField(
          key: const ValueKey('mygig-delivery-decide-note'),
          controller: c,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'What was decided (who was called, what they said)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    if (note == null || note.trim().length < 3 || !mounted) return;
    final ok = await runAdminAction(context, () => ref.read(mygigRepositoryProvider).adminDeliveryDecide(r.id, note.trim()),
        success: 'The driver can start the return');
    if (ok && mounted) ref.invalidate(_listProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stats = ref.watch(_statsProvider(widget.day)).value;
    final list = ref.watch(_listProvider(_filter));
    final s = ref.watch(_settingsProvider).value ?? const MygigDeliverySettings({});
    num n(String k) => (stats?[k] as num?) ?? 0;
    final tiles = [
      ('Deliveries', '${n('deliveries')}'),
      ('Delivered', '${n('delivered')}'),
      ('Returned', '${n('returned')}'),
      ('COD collected', mygigMoney(n('cod').toDouble())),
      ('Recipient paid', '${n('recipientPaidPct')}%'),
      ('Avg fare', mygigMoney(n('avgFare').toDouble())),
      ('Deposits held', mygigMoney(n('depositsHeld').toDouble())),
      ('To refund', mygigMoney(n('refundDue').toDouble())),
      ('Waiting for support', '${n('support')}'),
    ];
    return Column(
      key: const ValueKey('mygig-admin-delivery'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('myGiG Delivery', style: t.textTheme.titleLarge),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (label, value) in tiles)
            SizedBox(
              width: 160,
              child: Card(
                key: ValueKey('mygig-delivery-tile-$label'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: t.textTheme.bodySmall),
                    Text(value, style: t.textTheme.titleLarge),
                  ]),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 16),
        MygigMoneySafetyPanel(settings: s),
        const SizedBox(height: 16),
        Text('Deliveries', style: t.textTheme.titleMedium),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          key: const ValueKey('mygig-delivery-filter'),
          segments: const [
            ButtonSegment(value: 'open', label: Text('Going')),
            ButtonSegment(value: 'support', label: Text('Support')),
            ButtonSegment(value: 'refunds', label: Text('To refund')),
            ButtonSegment(value: 'all', label: Text('All')),
          ],
          selected: {_filter},
          onSelectionChanged: (v) => setState(() => _filter = v.first),
        ),
        AsyncView(
          value: list,
          onRetry: () => ref.invalidate(_listProvider(_filter)),
          data: (rows) => rows.isEmpty
              ? const Padding(padding: EdgeInsets.all(16), child: Text('None.'))
              : Column(children: [
                  for (final d in rows) _row(t, d),
                ]),
        ),
      ],
    );
  }

  Widget _row(ThemeData t, MygigDelivery d) {
    final waiting = d.returns.where((r) => r.support || (!r.senderAck && !r.done)).toList();
    final refund = (d.money['refundDue'] as num?)?.toDouble() ?? 0;
    final short = (d.money['inAppShort'] as num?)?.toDouble() ?? 0;
    return Card(
      key: ValueKey('mygig-delivery-row-${d.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${d.type} · ${d.senderName} · ${mygigMoney(d.total)} · ${d.status}', style: t.textTheme.titleSmall),
          Text('${d.raw['driverName'] ?? 'Driver'} · ${d.drops.length} drop-off${d.drops.length > 1 ? 's' : ''} · '
              '${d.recipientPays ? 'recipient pays' : 'sender pays'} · seal ${d.sealCode}', style: t.textTheme.bodySmall),
          if (refund > 0) Text('Refund ${mygigMoney(refund)} on the gateway (the guarantee fee kept).', style: t.textTheme.bodySmall),
          if (short > 0) Text('${mygigMoney(short)} still owed in the app by the sender.', style: t.textTheme.bodySmall),
          for (final r in waiting)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(r.support ? Icons.support_agent : Icons.hourglass_top),
              title: Text('${r.failed ? 'Failed' : 'Sent back'} · drop-off ${r.n} · ${r.reason}'),
              subtitle: Text(r.support ? 'The sender didn’t answer in time: support decides' : 'Waiting for the sender'),
              trailing: widget.canEdit && r.support
                  ? BusyButton.tonal(onPressed: () => _decide(r), child: const Text('It goes back'))
                  : null,
            ),
        ]),
      ),
    );
  }
}

/// The Money safety panel: what keeps get.ride and the driver paid.
class MygigMoneySafetyPanel extends StatelessWidget {
  const MygigMoneySafetyPanel({super.key, required this.settings});
  final MygigDeliverySettings settings;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('mygig-money-safety'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          leading: Icon(Icons.shield_outlined, color: t.colorScheme.primary),
          title: const Text('Money safety: no losses to get.ride or the driver'),
          subtitle: const Text('No setting leaves either unpaid. Options that could (get.ride or the driver covering a return, '
              'recipient pays without a guarantee, COD for senders without the app) don’t exist.'),
        ),
        for (final (title, body) in mygigMoneySafety(settings))
          ListTile(
            dense: true,
            leading: Icon(Icons.check_circle, color: t.colorScheme.primary),
            title: Text(title),
            subtitle: Text(body),
          ),
      ]),
    );
  }
}
