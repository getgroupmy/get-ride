import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ev_wizard.dart' show evMoney, evPaymentsDue, paymentReceivedPatch;
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'commerce_data.dart';
import 'commerce_logic.dart';
import 'commerce_widgets.dart';
import 'ev_orders.dart';

Color _toneColor(BuildContext context, Object? status) => switch (evOrderStatusTone(status)) {
      EvOrderStatusTone.success => Colors.green,
      EvOrderStatusTone.accent => Theme.of(context).colorScheme.primary,
      EvOrderStatusTone.info => const Color(0xFF3B82F6),
      EvOrderStatusTone.error => Theme.of(context).colorScheme.error,
      EvOrderStatusTone.warning => const Color(0xFFF59E0B),
    };

class _ToneChip extends StatelessWidget {
  const _ToneChip(this.status);
  final Object? status;

  @override
  Widget build(BuildContext context) {
    final c = _toneColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(evOrderStatusLabel(status), style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// TEKSI EV orders back office: review orders, assign a Delivery Advisor,
/// set the status and submit the handover checklist (`ev_orders`).
class EvOrdersScreen extends ConsumerStatefulWidget {
  const EvOrdersScreen({super.key});
  static const page = 'admin-orders';

  @override
  ConsumerState<EvOrdersScreen> createState() => _EvOrdersScreenState();
}

class _EvOrdersScreenState extends ConsumerState<EvOrdersScreen> {
  String _filter = 'all';
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(evOrdersProvider);
    return AdminPage(
      title: 'TEKSI EV Orders',
      page: EvOrdersScreen.page,
      actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(evOrdersProvider))],
      body: AsyncView(
        value: orders,
        onRetry: () => ref.invalidate(evOrdersProvider),
        data: (all) {
          final stats = evOrderStats(all.map((o) => o.values));
          final filters = {
            'all': 'All (${stats['total']})',
            'refit': 'Re-fit (${stats['refit']})',
            for (final s in evOrderStatuses) s: '${evOrderStatusLabels[s]} (${stats[s]})',
          };
          final rows = all.where((o) => evOrderMatches(o.values, o.id, _filter, _q)).toList();
          return Column(children: [
            FilterBar(
              filters: filters,
              selected: _filter,
              onSelected: (k) => setState(() => _filter = k),
              onSearch: (v) => setState(() => _q = v),
              hint: 'Search by customer, vehicle, order ID',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('${stats['total']} total · ${stats['pending']} awaiting DA',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? const EmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: 'No orders',
                      message: 'New EV orders submitted by users will appear here for review and DA assignment.',
                    )
                  : ResponsiveCenter(
                      maxWidth: 900,
                      child: ListView(padding: const EdgeInsets.only(top: 4, bottom: 32), children: [
                        for (final o in rows)
                          Card(
                            child: ListTile(
                              leading: const CircleAvatar(child: Icon(Icons.bolt)),
                              title: Text('${o.values['customerName'] ?? 'Customer'}'),
                              subtitle: Text(
                                '${o.values['vehicle'] ?? 'TEKSI EV'} · RM${groupedNumber(toNum(o.values['total']))}\n'
                                '${o.values['advisorName'] != null && '${o.values['advisorName']}'.isNotEmpty ? 'DA: ${o.values['advisorName']}' : 'Order #${shortOrderId(o.id)}'}',
                              ),
                              isThreeLine: true,
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  _ToneChip(o.values['status']),
                                  if (_truthy(o.values['wheelsSwapped']))
                                    const Padding(
                                      padding: EdgeInsets.only(top: 4),
                                      child: Icon(Icons.build_outlined, size: 14, color: Color(0xFFF59E0B)),
                                    ),
                                ],
                              ),
                              onTap: () => showAdminSheet<void>(
                                context,
                                title: '${o.values['customerName'] ?? 'Customer'} · #${shortOrderId(o.id)}',
                                builder: (_) => _OrderDetail(orderId: o.id),
                              ),
                            ),
                          ),
                      ]),
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

bool _truthy(Object? v) => v != null && v != false && v != '' && v != 0;

String _str(Object? v, [String fallback = '—']) {
  final s = v == null ? '' : '$v';
  return s.isEmpty ? fallback : s;
}

class _OrderDetail extends ConsumerWidget {
  const _OrderDetail({required this.orderId});
  final String orderId;

  Future<void> _patch(BuildContext context, WidgetRef ref, Map<String, dynamic> patch, {String? success}) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(commerceRepositoryProvider).patchEvOrder(orderId, patch),
      success: success,
    );
    if (ok) ref.invalidate(evOrdersProvider);
  }

  Future<void> _assign(BuildContext context, WidgetRef ref, Map<String, dynamic> v) async {
    final advisors = await ref.read(commerceEntriesProvider('ev-delivery-advisors').future).catchError((Object e) {
      if (context.mounted) showError(context, e);
      return <Entry>[];
    });
    if (!context.mounted) return;
    final picked = await showDialog<Entry>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Assign Delivery Advisor · ${advisors.length} configured'),
        children: [
          if (advisors.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No DAs configured. Add advisors in Settings → TEKSI EV → Delivery Advisors.'),
            ),
          for (final a in advisors)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, a),
              child: ListTile(
                leading: const Icon(Icons.how_to_reg_outlined),
                title: Text(_str(a.values['name'], 'Advisor')),
                subtitle: Text('${_str(a.values['dealership'], '')} · ${_str(a.values['city'], '')}, ${_str(a.values['country'], '')}\n'
                    '${_str(a.values['daNumber'], a.id)} · ${_str(a.values['contact'], '')}'),
                isThreeLine: true,
                trailing: v['advisorId'] == a.id ? const Icon(Icons.check) : null,
              ),
            ),
        ],
      ),
    );
    if (picked == null || !context.mounted) return;
    await _patch(context, ref, advisorAssignmentPatch(picked.id, picked.values, DateTime.now()),
        success: '${_str(picked.values['name'], 'Advisor')} has been assigned to this order.');
  }

  Future<void> _checklist(BuildContext context, WidgetRef ref, Map<String, dynamic> v) async {
    final template = await ref.read(commerceEntriesProvider('ev-delivery-checklist').future).catchError((Object e) {
      if (context.mounted) showError(context, e);
      return <Entry>[];
    });
    if (!context.mounted) return;
    final draft = buildChecklistDraft(
      [for (final c in template) _str(c.values['name'] ?? c.values['title'], 'Item')],
      v,
    );
    final result = await showFormDialog<List<EvChecklistResult>>(context, (_) => _ChecklistForm(draft: draft));
    if (result == null || !context.mounted) return;
    await _patch(context, ref, checklistSubmissionPatch(result, v['status'], DateTime.now()),
        success: 'Checklist submitted. The customer can now review it and accept handover in the app.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(evOrdersProvider).value ?? const <EvOrderRow>[];
    final order = orders.where((o) => o.id == orderId).firstOrNull;
    if (order == null) return const Center(child: CircularProgressIndicator());
    final canEdit = ref.watch(pageAccessProvider(EvOrdersScreen.page)) == AccessLevel.edit;
    final v = order.values;
    final t = Theme.of(context);
    Widget heading(String s) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 6),
          child: Text(s, style: t.textTheme.titleSmall),
        );

    // Gallery from the ordered vehicle's catalogue entry.
    final vehicles = ref.watch(commerceEntriesProvider('ev-vehicle-details')).value ?? const <Entry>[];
    final veh = vehicles.where((x) => x.id == '${v['vehicleId'] ?? ''}').firstOrNull;
    final gallery = veh == null
        ? const <(String, String)>[]
        : [
            for (final u in parseStringList(veh.values['exteriorImages'])) (u, 'Exterior'),
            for (final u in parseStringList(veh.values['interiorImages'])) (u, 'Interior'),
            for (final u in parseStringList(veh.values['storageImages'])) (u, 'Storage'),
          ];

    final ownerType = '${v['ownerType'] ?? ''}';
    final rawIdType = '${v['ownerIdType'] ?? ''}';
    final isCompany = ownerType == 'company' || rawIdType.startsWith('company+');
    final idType = rawIdType.replaceFirst('company+', '');
    final ft = '${v['financeType'] ?? ''}';
    final submitted = isChecklistSubmitted(v);
    final accepted = isChecklistAccepted(v);
    final checklistTemplate = ref.watch(commerceEntriesProvider('ev-delivery-checklist')).value ?? const <Entry>[];
    final items = buildChecklistDraft(
      [for (final c in checklistTemplate) _str(c.values['name'] ?? c.values['title'], 'Item')],
      v,
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(alignment: Alignment.centerLeft, child: _ToneChip(v['status'])),
      heading('Vehicle'),
      DetailTable({
        'Model': _str(v['vehicle']),
        'Exterior': _str(v['exteriorColor']),
        'Interior': _str(v['interiorColor']),
        'Wheels': _truthy(v['wheelsSwapped']) && _truthy(v['factoryWheels'])
            ? '${_str(v['wheels'])} (was ${v['factoryWheels']})'
            : _str(v['wheels']),
        'VIN': _truthy(v['vin']) ? '${v['vin']}' : null,
        'Total': 'RM${groupedNumber(toNum(v['total']))}',
        'Placed': dateText(order.createdAt),
      }),
      if (_truthy(v['wheelsSwapped']))
        Card(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
          child: ListTile(
            leading: const Icon(Icons.build_outlined, color: Color(0xFFF59E0B)),
            title: Text('Re-fit required: wheels swapped from ${_str(v['factoryWheels'], 'factory')} to ${_str(v['wheels'])}.'),
          ),
        ),
      if (gallery.isNotEmpty)
        SizedBox(
          height: 110,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final g in gallery)
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 8),
                child: Column(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(8), child: StoredImage(g.$1, width: 120, height: 80)),
                  Text(g.$2, style: t.textTheme.labelSmall),
                ]),
              ),
          ]),
        ),
      heading('Customer'),
      DetailTable({
        'Name': _str(v['customerName']),
        'Phone': _str(v['customerPhone']),
        'Email': _truthy(v['customerEmail']) ? '${v['customerEmail']}' : null,
      }),
      if (ownerType.isNotEmpty || _truthy(v['ownerFullName']) || _truthy(v['companyName'])) ...[
        heading('Registered owner'),
        DetailTable({
          'Type': switch (ownerType) {
            'self' => 'My Self',
            'other' => 'Other Individual',
            'company' => 'Company',
            _ => '—',
          },
          if (isCompany) 'Company': _str(v['companyName']),
          if (isCompany) 'Reg #': _str(v['companyRegNo']),
          if (isCompany) 'Co. addr': _str(v['companyAddress']),
          if (ownerType == 'other' && _truthy(v['ownerRelationship'])) 'Relation': '${v['ownerRelationship']}',
          'Full name': _str(v['ownerFullName']),
          'ID type': idType == 'passport' ? 'Passport' : idType == 'national' ? 'National ID' : _str(idType),
          'Issued in': _truthy(v['ownerIdCountry']) ? '${v['ownerIdCountry']}' : null,
          'ID #': _str(v['ownerIdNumber']),
          'Address': _str(v['ownerAddress']),
        }),
        Wrap(spacing: 8, children: [
          for (final (key, label) in [('ownerIdImage', 'ID document'), ('ownerPhoto', 'Owner photo')])
            if (_truthy(v[key]))
              Column(children: [
                ClipRRect(borderRadius: BorderRadius.circular(8), child: StoredImage('${v[key]}', width: 120, height: 80, placeholder: Icons.badge_outlined)),
                Text(label, style: t.textTheme.labelSmall),
              ]),
        ]),
      ],
      if ('${v['plateTransfer'] ?? ''}'.isNotEmpty) ...[
        heading('Number plate'),
        DetailTable({
          'Transfer': v['plateTransfer'] == 'yes' ? 'Yes — transferring' : 'No — new plate',
          if (v['plateTransfer'] == 'yes') 'Plate #': _str(v['plateNumber']),
        }),
      ],
      if (ft.isNotEmpty) ...[
        heading('Financing'),
        DetailTable({
          'Method': switch (ft) { 'cash' => 'Cash', 'hp' => 'Hire Purchase', 'leasing' => 'Leasing', _ => ft },
          'Plan': _truthy(v['financePlan']) ? '${v['financePlan']}' : null,
          if (ft == 'cash')
            'Balance': evFlag(v['cashBalancePaid'])
                ? 'Paid · RM${groupedNumber(toNum(v['balancePaidAmount']))}'
                : evFlag(v['cashBalanceConfirmed'])
                    ? 'Due · RM${groupedNumber(toNum(v['balanceDueAmount']))}'
                    : 'Not confirmed',
          if (ft == 'leasing' && '${v['leasingAddonRequired'] ?? ''}'.isNotEmpty)
            'Add-on': v['leasingAddonRequired'] == 'yes' ? 'Required' : 'Not required',
          if (ft == 'leasing' && v['leasingAddonRequired'] == 'yes')
            'Add-on pay': evFlag(v['leasingAddonPaid'])
                ? 'Paid · RM${groupedNumber(toNum(v['leasingAddonAmount']))}'
                : evFlag(v['leasingAddonConfirmed'])
                    ? 'Due · RM${groupedNumber(toNum(v['leasingAddonAmount']))}'
                    : 'Not confirmed',
        }),
      ],
      if (evPaymentsDue(v).isNotEmpty) ...[
        heading('Payments'),
        // Nothing is charged in the app: each sum is recorded as due, and is
        // marked received here once TEKSI has collected it.
        for (final p in evPaymentsDue(v))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(p.received ? Icons.check_circle : Icons.schedule,
                color: p.received ? Colors.green : const Color(0xFFF59E0B)),
            title: Text('${p.label} · ${evMoney(p.amount, p.currency)}'),
            subtitle: Text(p.received ? 'Received' : 'Due'),
            trailing: !p.received && canEdit
                ? BusyButton.text(
                    onPressed: () => _patch(context, ref, paymentReceivedPatch(p.key, v, DateTime.now()),
                        success: '${p.label} recorded as received.'),
                    child: const Text('Mark received'),
                  )
                : null,
          ),
      ],
      if (_truthy(v['deliveryDate'])) ...[
        heading('Delivery'),
        DetailTable({'Delivery': '${v['deliveryDate']}'}),
      ],
      heading('Delivery checklist'),
      Row(children: [
        Icon(accepted ? Icons.assignment_turned_in_outlined : Icons.assignment_outlined,
            size: 18, color: accepted ? Colors.green : submitted ? t.colorScheme.primary : const Color(0xFFF59E0B)),
        const SizedBox(width: 6),
        Text(accepted ? 'Customer accepted' : submitted ? 'Submitted — awaiting customer' : 'Not submitted'),
      ]),
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('No checklist items configured. Add them in Settings → TEKSI EV → Delivery Checklist.'),
        )
      else
        for (final it in items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(it.done ? Icons.check : Icons.close, color: it.done ? Colors.green : const Color(0xFFF59E0B)),
            title: Text(it.name),
            subtitle: it.note.isEmpty ? null : Text(it.note),
          ),
      if (!accepted && canEdit)
        BusyButton.outlined(
          onPressed: () => _checklist(context, ref, v),
          icon: const Icon(Icons.fact_check_outlined),
          child: Text(submitted ? 'Update checklist' : 'Complete checklist'),
        ),
      heading('Delivery Advisor'),
      if (_truthy(v['advisorId'])) ...[
        DetailTable({
          'Name': _str(v['advisorName']),
          'DA #': _str(v['advisorDaNumber'] ?? v['advisorId']),
          'Dealer': _str(v['advisorDealership']),
          'Contact': _str(v['advisorContact']),
          'Email': _str(v['advisorEmail']),
          'Location': '${_str(v['advisorCity'], '')}, ${_str(v['advisorState'], '')}, ${_str(v['advisorCountry'], '')}',
        }),
        if (canEdit)
          BusyButton.outlined(
            onPressed: () => _assign(context, ref, v),
            icon: const Icon(Icons.swap_horiz),
            child: const Text('Reassign DA'),
          ),
      ] else if (canEdit)
        BusyButton.filled(
          onPressed: () => _assign(context, ref, v),
          icon: const Icon(Icons.how_to_reg_outlined),
          child: const Text('Assign Delivery Advisor'),

        )
      else
        const Text('No advisor assigned.'),
      heading('Status'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in evOrderStatuses)
          ChoiceChip(
            label: Text(evOrderStatusLabels[s]!),
            selected: normalizeEvOrderStatus(v['status']) == s,
            selectedColor: _toneColor(context, s).withValues(alpha: 0.25),
            onSelected: canEdit ? (_) => _patch(context, ref, {'status': s}) : null,
          ),
      ]),
    ]);
  }
}

class _ChecklistForm extends StatefulWidget {
  const _ChecklistForm({required this.draft});
  final List<EvChecklistResult> draft;

  @override
  State<_ChecklistForm> createState() => _ChecklistFormState();
}

class _ChecklistFormState extends State<_ChecklistForm> {
  late final List<EvChecklistResult> _items = [...widget.draft];

  Future<void> _submit() async {
    if (_items.isEmpty) {
      showInfo(context, 'Add handover items in Settings → TEKSI EV → Delivery Checklist first.');
      return;
    }
    final outstanding = _items.where((x) => !x.done).length;
    if (outstanding > 0 &&
        !await confirm(
          context,
          'Submit with open items?',
          '$outstanding item${outstanding == 1 ? ' is' : 's are'} still unticked. The customer will see them as pending.',
          ok: 'Submit anyway',
        )) {
      return;
    }
    if (mounted) Navigator.pop(context, _items);
  }

  @override
  Widget build(BuildContext context) => FormDialogScaffold(
        title: 'Delivery checklist',
        saveLabel: 'Submit to customer',
        onSave: _submit,
        children: [
          const Text('Tick each item and add any notes, then submit for the customer to accept.'),
          const SizedBox(height: 12),
          if (_items.isEmpty)
            const Text('No checklist items configured. Add them in Settings → TEKSI EV → Delivery Checklist.'),
          for (var i = 0; i < _items.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 12, 12),
                child: Column(children: [
                  CheckboxListTile(
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(_items[i].name),
                    value: _items[i].done,
                    onChanged: (v) => setState(() => _items[i] = _items[i].copyWith(done: v ?? false)),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: TextFormField(
                      initialValue: _items[i].note,
                      decoration: const InputDecoration(hintText: 'Note (optional)', isDense: true),
                      onChanged: (t) => _items[i] = _items[i].copyWith(note: t),
                    ),
                  ),
                ]),
              ),
            ),
        ],
      );
}
