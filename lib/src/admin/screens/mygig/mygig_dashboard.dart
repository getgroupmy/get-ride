// Admin › Operations › myGiG dashboard and myGiG bookings (migration 0331),
// page admin-mygig: today's myGiG rides, takings, how passengers accepted
// (app, link, driver's phone), no-shows; flagged rides (above the price
// guard, numbers with many myGiG rides, drivers at the daily limit); the
// reassign history; e-Invoice requests to send (no e-Invoice connection to
// LHDN MyInvois exists yet); and every myGiG booking (later trips and hire by
// time) with filters, which part B left visible only to driver and passenger.
// 0332: myGiG Delivery (mygig_delivery_admin.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/mygig.dart' show formatDayDate, mygigAdminPage, mygigMoney;
import '../../../core/mygig_extras.dart';
import '../../../core/mygig_hire.dart' show MygigBooking;
import '../../../data/live_tables.dart';
import '../../../data/mygig_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'mygig_delivery_admin.dart';

const mygigDashboardAdminPath = '/admin/m/mygig-dashboard';
const mygigBookingsAdminPath = '/admin/m/mygig-bookings';

final _dashboardProvider = FutureProvider.autoDispose.family<MygigDashboard, DateTime>((ref, day) {
  ref.watchLive(mygigReassignsTable);
  return ref.watch(mygigRepositoryProvider).adminDashboard(day: day);
});

class MygigDashboardAdminScreen extends ConsumerStatefulWidget {
  const MygigDashboardAdminScreen({super.key});

  @override
  ConsumerState<MygigDashboardAdminScreen> createState() => _MygigDashboardAdminScreenState();
}

class _MygigDashboardAdminScreenState extends ConsumerState<MygigDashboardAdminScreen> {
  DateTime _day = DateUtils.dateOnly(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(mygigAdminPage)) == AccessLevel.edit;
    final today = DateUtils.dateOnly(DateTime.now());
    return AdminPage(
      title: 'myGiG dashboard',
      page: mygigAdminPage,
      body: AsyncView(
        value: ref.watch(_dashboardProvider(_day)),
        onRetry: () => ref.invalidate(_dashboardProvider(_day)),
        data: (d) => ListView(
          key: const ValueKey('mygig-admin-dashboard'),
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              IconButton(
                tooltip: 'Day before',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _day = _day.subtract(const Duration(days: 1))),
              ),
              Expanded(
                child: Text(_day == today ? 'Today' : formatDayDate(_day), textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton(
                tooltip: 'Next day',
                icon: const Icon(Icons.chevron_right),
                onPressed: _day == today ? null : () => setState(() => _day = _day.add(const Duration(days: 1))),
              ),
            ]),
            MygigDashboardTiles(dashboard: d),
            const SizedBox(height: 16),
            MygigFlagsCard(dashboard: d),
            const SizedBox(height: 16),
            MygigReassignHistory(reassigns: d.reassigns),
            const SizedBox(height: 16),
            MygigEinvoiceList(
              items: d.einvoices,
              canEdit: canEdit,
              onChanged: () => ref.invalidate(_dashboardProvider(_day)),
            ),
            // 0332: myGiG Delivery, with the Money safety panel.
            const SizedBox(height: 24),
            MygigDeliveryAdminSection(day: _day, canEdit: canEdit),
          ],
        ),
      ),
    );
  }
}

class MygigDashboardTiles extends StatelessWidget {
  const MygigDashboardTiles({super.key, required this.dashboard});
  final MygigDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final d = dashboard;
    final tiles = [
      ('Rides', '${d.rides}'),
      ('Completed', '${d.completed}'),
      ('Takings', mygigMoney(d.takings)),
      ('No-shows', '${d.noShows}'),
      ('In the app', d.share(d.viaApp)),
      ('By link', d.share(d.viaLink)),
      ('On driver’s phone', d.share(d.viaHere)),
      ('Reassigned', '${d.reassigned}'),
    ];
    final t = Theme.of(context);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (label, value) in tiles)
        SizedBox(
          width: 160,
          child: Card(
            key: ValueKey('mygig-tile-$label'),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: t.textTheme.bodySmall),
                Text(value, style: t.textTheme.titleLarge),
              ]),
            ),
          ),
        ),
    ]);
  }
}

class MygigFlagsCard extends StatelessWidget {
  const MygigFlagsCard({super.key, required this.dashboard});
  final MygigDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final d = dashboard;
    final t = Theme.of(context);
    final rows = <Widget>[
      for (final f in d.priceGuard)
        ListTile(
          leading: const Icon(Icons.warning_amber_outlined),
          title: const Text('Price above the guard'),
          subtitle: Text('${f['driver'] ?? 'Driver'} · ${f['from'] ?? ''} to ${f['to'] ?? ''} · '
              '${mygigMoney((f['total'] as num?)?.toDouble() ?? 0)} (app ${mygigMoney((f['appPrice'] as num?)?.toDouble() ?? 0)})'),
        ),
      for (final f in d.repeatNumbers)
        ListTile(
          leading: const Icon(Icons.flag_outlined),
          title: const Text('Number with many myGiG rides'),
          subtitle: Text('${f['phone']} · ${f['rides']} rides with ${f['driver'] ?? 'one driver'} in 7 days'),
        ),
      for (final f in d.dailyLimit)
        ListTile(
          leading: const Icon(Icons.hail),
          title: const Text('Driver at the daily limit'),
          subtitle: Text('${f['driver'] ?? 'Driver'} · ${f['rides']} of ${f['limit']} today'),
        ),
    ];
    return Card(
      key: const ValueKey('mygig-flags'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Flagged rides', style: t.textTheme.titleMedium)),
        if (rows.isEmpty)
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text('Nothing flagged.'))
        else
          ListSearchFilter(
            count: rows.length,
            hint: 'Filter flagged rides',
            builder: (_, q) => Column(children: [
              for (final r in rows)
                if (q.isEmpty || _text(r).toLowerCase().contains(q.toLowerCase())) r,
            ]),
          ),
      ]),
    );
  }

  static String _text(Widget w) => w is ListTile
      ? '${(w.title as Text?)?.data ?? ''} ${(w.subtitle as Text?)?.data ?? ''}'
      : '';
}

class MygigReassignHistory extends StatelessWidget {
  const MygigReassignHistory({super.key, required this.reassigns});
  final List<MygigReassign> reassigns;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('mygig-reassign-history'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Reassigns', style: t.textTheme.titleMedium)),
        if (reassigns.isEmpty)
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text('No reassigns yet.'))
        else
          ListSearchFilter(
            count: reassigns.length,
            hint: 'Filter by driver or reason',
            builder: (_, q) => Column(children: [
              for (final r in reassigns)
                if (q.isEmpty || '${r.from.name} ${r.to.name} ${r.reason}'.toLowerCase().contains(q.toLowerCase()))
                  ExpansionTile(
                    key: ValueKey('mygig-reassign-row-${r.id}'),
                    title: Text('${r.from.name} to ${r.to.name} · ${r.reason}'),
                    subtitle: Text('${r.kindName} · ${_stage(r.stage)}'
                        '${r.moved > 0 ? ' · ${mygigMoney(r.moved)} moved' : ''}${r.kept > 0 ? ' · ${mygigMoney(r.kept)} kept' : ''}'),
                    children: [
                      for (final s in r.steps)
                        ListTile(
                          dense: true,
                          title: Text(mygigReassignStepText(s)),
                          subtitle: Text(_when(s['at'])),
                        ),
                    ],
                  ),
            ]),
          ),
      ]),
    );
  }

  static String _stage(MygigReassignStage s) => switch (s) {
    MygigReassignStage.driver => 'waiting for the new driver',
    MygigReassignStage.passenger => 'waiting for the passenger',
    MygigReassignStage.done => 'handed over',
    MygigReassignStage.declined => 'declined',
    MygigReassignStage.kept => 'kept by the first driver',
    MygigReassignStage.cancelled => 'cancelled, no charge',
    MygigReassignStage.expired => 'no answer',
    MygigReassignStage.stopped => 'stopped',
  };

  static String _when(Object? at) {
    final d = DateTime.tryParse('${at ?? ''}')?.toLocal();
    if (d == null) return '';
    return '${formatDayDate(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

class MygigEinvoiceList extends ConsumerWidget {
  const MygigEinvoiceList({super.key, required this.items, required this.canEdit, required this.onChanged});
  final List<Map<String, dynamic>> items;
  final bool canEdit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('mygig-einvoices'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('e-Invoice requests', style: t.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('There is no e-Invoice connection to LHDN MyInvois yet: send each one, then mark it sent.',
              style: t.textTheme.bodySmall),
        ),
        if (items.isEmpty)
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text('No requests.'))
        else
          ListSearchFilter(
            count: items.length,
            hint: 'Filter by name or email',
            builder: (_, q) => Column(children: [
              for (final e in items)
                if (q.isEmpty || '${e['name']} ${e['email']}'.toLowerCase().contains(q.toLowerCase()))
                  ListTile(
                    key: ValueKey('mygig-einvoice-${e['id']}'),
                    title: Text('${e['name']} · ${mygigMoney((e['amount'] as num?)?.toDouble() ?? 0)}'),
                    subtitle: Text([
                      e['email'],
                      if (e['tin'] != null) 'TIN ${e['tin']}' else '${e['idType'] ?? 'ID'} ${e['idNo'] ?? ''}',
                      'Driver ${e['driver'] ?? ''}',
                      switch (e['state']) { 'sent' => 'Sent', 'rejected' => 'Rejected', _ => 'To send' },
                    ].whereType<String>().join(' · ')),
                    trailing: canEdit && e['state'] == 'requested'
                        ? TextButton(
                            key: ValueKey('mygig-einvoice-sent-${e['id']}'),
                            onPressed: () async {
                              final ok = await runAdminAction(context,
                                  () => ref.read(mygigRepositoryProvider).adminEinvoiceSet('${e['id']}', 'sent'),
                                  success: 'Marked sent');
                              if (ok) onChanged();
                            },
                            child: const Text('Mark sent'),
                          )
                        : null,
                  ),
            ]),
          ),
      ]),
    );
  }
}

// ---- Bookings ----------------------------------------------------------------------------------------

typedef _BookingsKey = ({String kind, String status, String search});

final _bookingsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, _BookingsKey>((ref, k) {
  ref.watchLive(mygigBookingsTable);
  return ref.watch(mygigRepositoryProvider).adminBookings(kind: k.kind, status: k.status, search: k.search);
});

class MygigBookingsAdminScreen extends ConsumerStatefulWidget {
  const MygigBookingsAdminScreen({super.key});

  @override
  ConsumerState<MygigBookingsAdminScreen> createState() => _MygigBookingsAdminScreenState();
}

class _MygigBookingsAdminScreenState extends ConsumerState<MygigBookingsAdminScreen> {
  String _kind = '';
  String _status = 'open';
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final key = (kind: _kind, status: _status, search: _search);
    final t = Theme.of(context);
    return AdminPage(
      title: 'myGiG bookings',
      page: mygigAdminPage,
      body: ListView(
        key: const ValueKey('mygig-admin-bookings'),
        padding: const EdgeInsets.all(16),
        children: [
          Text('Later trips and hire by time drivers booked with myGiG.', style: t.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (k, l) in mygigBookingKinds)
              ChoiceChip(
                key: ValueKey('mygig-bookings-kind-$k'),
                label: Text(l),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (k, l) in mygigBookingStatuses)
              ChoiceChip(
                key: ValueKey('mygig-bookings-status-$k'),
                label: Text(l),
                selected: _status == k,
                onSelected: (_) => setState(() => _status = k),
              ),
          ]),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('mygig-bookings-search'),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Search passenger, phone or driver'),
            onSubmitted: (v) => setState(() => _search = v.trim()),
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: ref.watch(_bookingsProvider(key)),
            onRetry: () => ref.invalidate(_bookingsProvider(key)),
            data: (rows) => rows.isEmpty
                ? const Padding(padding: EdgeInsets.all(16), child: Text('No myGiG bookings match.'))
                : ListSearchFilter(
                    count: rows.length,
                    hint: 'Filter these bookings',
                    builder: (_, q) => Column(children: [
                      for (final r in rows)
                        if (q.isEmpty || '${r['name']} ${r['phone']} ${r['driverName']}'.toLowerCase().contains(q.toLowerCase()))
                          _BookingRow(row: r),
                    ]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _BookingRow extends StatelessWidget {
  const _BookingRow({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final b = MygigBooking(row);
    final now = DateTime.now();
    final t = Theme.of(context);
    final fee = (row['cancelFee'] as num?)?.toDouble() ?? 0;
    return Card(
      key: ValueKey('mygig-admin-booking-${b.id}'),
      child: ExpansionTile(
        title: Text('${b.title} · ${b.whenText(now)}'),
        subtitle: Text('${row['name'] ?? 'Passenger'} with ${row['driverName'] ?? 'driver'} · ${mygigMoney(b.price)} · ${b.statusText}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(b.whatText),
          Text(b.payText, style: t.textTheme.bodySmall),
          if (row['phone'] != null) Text('Phone ${row['phone']}', style: t.textTheme.bodySmall),
          if (fee > 0) Text('Late-cancel fee ${mygigMoney(fee)} (${row['cancelFeeStatus']})', style: t.textTheme.bodySmall),
          if (row['history'] is List && (row['history'] as List).isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('History', style: t.textTheme.titleSmall),
            for (final h in (row['history'] as List).whereType<Map>())
              Text('${MygigReassignHistory._when(h['at'])} · ${mygigReassignStepText(Map<String, dynamic>.from(h))}',
                  style: t.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
