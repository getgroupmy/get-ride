// Admin › People › Business accounts (migration 0313): the applications and
// accounts by status, and one account: its SSM document and details,
// approve / suspend / reactivate / reject, its overrides of the defaults,
// its rules and members (as its Admins set them), the business wallet and
// the invoices (PDF, CSV, mark paid).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/business_accounts.dart';
import '../../../data/business_repository.dart';
import '../../../features/business/business_invoice_files.dart';
import '../../../features/business/business_widgets.dart';
import '../../../widgets/common.dart';
import '../../../widgets/in_app_page.dart' show openStoredFile;
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'business_values_editor.dart';

const businessAccountsPath = '/admin/m/business-accounts';
const businessAccountAdminPath = '/admin/m/business-account';
const businessDefaultsPath = '/admin/m/business-defaults';

const _filters = [('pending', 'Waiting'), ('active', 'Active'), ('suspended', 'Suspended'), ('rejected', 'Not approved'), ('', 'All')];

class BusinessAccountsAdminScreen extends ConsumerStatefulWidget {
  const BusinessAccountsAdminScreen({super.key});

  @override
  ConsumerState<BusinessAccountsAdminScreen> createState() => _BusinessAccountsAdminScreenState();
}

class _BusinessAccountsAdminScreenState extends ConsumerState<BusinessAccountsAdminScreen> {
  String _status = 'pending';

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(businessAccountsPage)) == AccessLevel.edit;
    final async = ref.watch(adminBusinessAccountsProvider);
    return AdminPage(
      title: 'Business accounts',
      page: businessAccountsPage,
      actions: [
        IconButton(
          key: const ValueKey('biz-open-defaults'),
          tooltip: 'Defaults per region',
          icon: const Icon(Icons.tune),
          onPressed: () => context.push(businessDefaultsPath),
        ),
        if (canEdit)
          IconButton(
            key: const ValueKey('biz-issue-now'),
            tooltip: 'Issue last month\'s invoices now',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () async {
              int n = 0;
              final ok = await runAdminAction(context, () async => n = await ref.read(businessRepositoryProvider).issueInvoices());
              if (ok && context.mounted) showInfo(context, n == 0 ? 'No invoices were due.' : '$n invoices issued.');
            },
          ),
      ],
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(adminBusinessAccountsProvider),
        data: (all) {
          final list = [for (final a in all) if (_status.isEmpty || a.status == _status) a];
          return ListView(padding: const EdgeInsets.all(16), children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (id, label) in _filters)
                ChoiceChip(
                  key: ValueKey('biz-filter-${id.isEmpty ? 'all' : id}'),
                  label: Text('$label (${id.isEmpty ? all.length : all.where((a) => a.status == id).length})'),
                  selected: _status == id,
                  onSelected: (_) => setState(() => _status = id),
                ),
            ]),
            ListSearchFilter(
              count: list.length,
              hint: 'Search name, SSM number, state or applicant',
              builder: (context, q) {
                final shown = [
                  for (final a in list)
                    if (q.isEmpty ||
                        '${a.name} ${a.regNo} ${a.place} ${a.applicant ?? ''} ${a.applicantPhone ?? ''}'
                            .toLowerCase()
                            .contains(q.toLowerCase()))
                      a,
                ];
                if (shown.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No business accounts here.', textAlign: TextAlign.center),
                  );
                }
                return Column(children: [
                  for (final a in shown)
                    Card(
                      child: ListTile(
                        key: ValueKey('biz-row-${a.id}'),
                        leading: const Icon(Icons.business_center_outlined),
                        title: Text(a.name),
                        subtitle: Text([
                          'SSM ${a.regNo}',
                          if (a.place.isNotEmpty) a.place,
                          '${a.members} ${a.members == 1 ? 'member' : 'members'}',
                          if (a.applicant != null) 'by ${a.applicant}',
                        ].join(' · ')),
                        trailing: BusinessStatusPill(a.status),
                        onTap: () => context.push('$businessAccountAdminPath?id=${a.id}'),
                      ),
                    ),
                ]);
              },
            ),
          ]);
        },
      ),
    );
  }
}

// ---- One account --------------------------------------------------------------------------------------------
final _adminAccountProvider = FutureProvider.autoDispose.family<AdminBusinessAccount?, String>((ref, id) async {
  final all = await ref.watch(adminBusinessAccountsProvider.future);
  for (final a in all) {
    if (a.id == id) return a;
  }
  return null;
});

final _adminInvoicesProvider = FutureProvider.autoDispose.family<List<BusinessInvoice>, String>(
  (ref, id) => ref.watch(businessRepositoryProvider).adminInvoices(id),
);

final _adminMembersProvider = FutureProvider.autoDispose.family<List<BusinessMember>, String>(
  (ref, id) => ref.watch(businessRepositoryProvider).adminMembers(id),
);

final _adminWalletProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, id) => ref.watch(businessRepositoryProvider).adminWallet(id),
);

class BusinessAccountAdminScreen extends ConsumerStatefulWidget {
  const BusinessAccountAdminScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<BusinessAccountAdminScreen> createState() => _BusinessAccountAdminScreenState();
}

class _BusinessAccountAdminScreenState extends ConsumerState<BusinessAccountAdminScreen> {
  BusinessValues? _overrides;

  void _refresh() {
    ref.invalidate(adminBusinessAccountsProvider);
    ref.invalidate(_adminInvoicesProvider(widget.id));
    ref.invalidate(_adminWalletProvider(widget.id));
    ref.invalidate(_adminMembersProvider(widget.id));
  }

  Future<void> _status(AdminBusinessAccount a, String status, String verb) async {
    final note = await _askNote(context, '$verb ${a.name}?', optional: status == 'active');
    if (note == null || !mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(businessRepositoryProvider).setStatus(a.id, status, note: note.isEmpty ? null : note),
      success: switch (status) {
        'active' => '${a.name} can book on its account now.',
        'suspended' => '${a.name} is suspended.',
        _ => '${a.name} was not approved.',
      },
    );
    if (ok) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(businessAccountsPage)) == AccessLevel.edit;
    final async = ref.watch(_adminAccountProvider(widget.id));
    final rules = ref.watch(businessRegionRulesProvider).value ?? const <BusinessRegionRule>[];
    return AdminPage(
      title: async.value?.name ?? 'Business account',
      page: businessAccountsPage,
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(adminBusinessAccountsProvider),
        data: (a) {
          if (a == null) {
            return const EmptyState(icon: Icons.business_center_outlined, title: 'This account was not found');
          }
          final t = Theme.of(context);
          final stored = a.overrides;
          final draft = _overrides ?? stored;
          final fromRules = resolveBusinessValues(rules, country: a.country, state: a.state, city: a.city);
          final rulesState = a.rules;
          final left = <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: Text(a.name, style: t.textTheme.titleLarge)),
                    BusinessStatusPill(a.status),
                  ]),
                  const SizedBox(height: 8),
                  DetailTable({
                    'SSM number': a.regNo,
                    'Type': a.companyType,
                    'Address': a.address,
                    'Registered in': a.place,
                    'Applied by': [a.applicant, a.applicantPhone].whereType<String>().join(' · '),
                    'Applied': a.createdAt == null ? null : '${a.createdAt!.day} ${shortDate(a.createdAt!).split(' ').last} ${a.createdAt!.year}',
                    'Status note': a.statusNote,
                  }),
                  if ((a.documentUrl ?? '').isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('biz-open-document'),
                        onPressed: () => openStoredFile(context, a.documentUrl!, title: 'SSM document'),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('Open the SSM document'),
                      ),
                    ),
                  if (canEdit) ...[
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      if (a.status != 'active')
                        FilledButton.icon(
                          key: const ValueKey('biz-approve'),
                          onPressed: () => _status(a, 'active', a.status == 'pending' ? 'Approve' : 'Reactivate'),
                          icon: const Icon(Icons.check),
                          label: Text(a.status == 'pending' ? 'Approve' : 'Reactivate'),
                        ),
                      if (a.status == 'active')
                        OutlinedButton.icon(
                          key: const ValueKey('biz-suspend'),
                          onPressed: () => _status(a, 'suspended', 'Suspend'),
                          icon: const Icon(Icons.pause_circle_outline),
                          label: const Text('Suspend'),
                        ),
                      if (a.status == 'pending')
                        OutlinedButton.icon(
                          key: const ValueKey('biz-reject'),
                          onPressed: () => _status(a, 'rejected', 'Reject'),
                          icon: const Icon(Icons.block),
                          label: const Text('Reject'),
                        ),
                    ]),
                  ],
                ]),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('This account\'s values', style: t.textTheme.titleMedium),
                  Text(
                    'Switch a value on to set it for this account only; off, it follows the defaults for ${a.place.isEmpty ? 'its region' : a.place}.',
                    style: t.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  BusinessValuesEditor(
                    values: draft,
                    base: fromRules,
                    followsLabel: 'Default here',
                    onChanged: canEdit ? (v) => setState(() => _overrides = v) : null,
                  ),
                  if (canEdit)
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        key: const ValueKey('biz-overrides-save'),
                        onPressed: draft == stored
                            ? null
                            : () async {
                                final ok = await runAdminAction(
                                  context,
                                  () => ref.read(businessRepositoryProvider).saveAccount(a.id, overrides: draft),
                                  success: 'Saved',
                                );
                                if (ok) {
                                  setState(() => _overrides = null);
                                  _refresh();
                                }
                              },
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save'),
                      ),
                    ),
                ]),
              ),
            ),
          ];
          final right = <Widget>[
            _WalletCard(account: a, canEdit: canEdit, onChanged: _refresh),
            _InvoicesCard(accountId: a.id, canEdit: canEdit, onChanged: _refresh),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('The company\'s rules', style: t.textTheme.titleMedium),
                  Text('Set by the company\'s Admins in the app.', style: t.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  DetailTable({
                    'Booking hours': rulesState.hoursOn
                        ? '${businessHour(rulesState.hoursFrom)} until ${businessHour(rulesState.hoursUntil)}'
                        : 'Any time',
                    'Trip note': rulesState.noteRequired ? 'Required' : 'Optional',
                    'Approval': rulesState.approvalOn ? 'Trips above ${businessMoney(rulesState.approvalOver)}' : 'Off',
                    'Spend cap': rulesState.capOn ? '${businessMoney(rulesState.monthlyCap)} a month' : 'Off',
                    'Bookers book Freight and Courier': rulesState.bookersFreight ? 'Yes' : 'No',
                  }),
                ]),
              ),
            ),
            _MembersCard(accountId: a.id),
          ];
          return LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 900;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: wide
                      ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(child: Column(children: left)),
                          const SizedBox(width: 16),
                          Expanded(child: Column(children: right)),
                        ])
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...left, ...right]),
                ),
              ),
            );
          });
        },
      ),
    );
  }
}

/// A note for a status change; '' when [optional] and left empty; null when cancelled.
Future<String?> _askNote(BuildContext context, String title, {bool optional = false}) async {
  final c = TextEditingController();
  final r = await showAppDialog<String>(
    id: 'business.admin-status-note',
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const ValueKey('biz-status-note'),
        controller: c,
        maxLength: 300,
        decoration: InputDecoration(
          labelText: optional ? 'Note to the company (optional)' : 'Reason, told to the company',
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('biz-status-confirm'),
          onPressed: () => Navigator.pop(d, c.text.trim()),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
  c.dispose();
  return r;
}

class _WalletCard extends ConsumerWidget {
  const _WalletCard({required this.account, required this.canEdit, required this.onChanged});
  final AdminBusinessAccount account;
  final bool canEdit;
  final VoidCallback onChanged;

  Future<void> _adjust(BuildContext context, WidgetRef ref) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    final ok = await showAppDialog<bool>(
      id: 'business.admin-wallet',
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Business wallet'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const ValueKey('biz-wallet-amount'),
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(
              labelText: 'Amount (RM)',
              helperText: 'A top-up received; a minus amount corrects it',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('biz-wallet-note'),
            controller: note,
            decoration: const InputDecoration(labelText: 'What it is (e.g. the bank transfer)', border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('biz-wallet-save'), onPressed: () => Navigator.pop(d, true), child: const Text('Record')),
        ],
      ),
    );
    final v = double.tryParse(amount.text.trim().replaceAll(',', ''));
    final n = note.text.trim();
    amount.dispose();
    note.dispose();
    if (ok != true || !context.mounted) return;
    if (v == null || v == 0) return showInfo(context, 'Enter an amount.');
    final done = await runAdminAction(
      context,
      () => ref.read(businessRepositoryProvider).adjustWallet(account.id, v, n),
      success: 'Recorded',
    );
    if (done) onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final entries = ref.watch(_adminWalletProvider(account.id)).value ?? const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(alignment: WrapAlignment.spaceBetween, spacing: 12, children: [
            Text('Business wallet', style: t.textTheme.titleMedium),
            Text(businessMoneyCents(account.walletBalance), key: const ValueKey('biz-wallet-balance'), style: t.textTheme.titleMedium),
          ]),
          Text('Prepaid accounts pay their trips from here.', style: t.textTheme.bodySmall),
          for (final e in entries.take(8))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${e['note'] ?? e['kind']}'),
              subtitle: Text('${e['created_at']}'.split('T').first),
              trailing: Text(businessMoneyCents((e['amount'] as num?) ?? 0)),
            ),
          if (canEdit)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('biz-wallet-adjust'),
                onPressed: () => _adjust(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Record a top-up'),
              ),
            ),
        ]),
      ),
    );
  }
}

class _InvoicesCard extends ConsumerWidget {
  const _InvoicesCard({required this.accountId, required this.canEdit, required this.onChanged});
  final String accountId;
  final bool canEdit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final async = ref.watch(_adminInvoicesProvider(accountId));
    final now = DateTime.now();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Invoices', style: t.textTheme.titleMedium),
          AsyncView(
            value: async,
            onRetry: () => ref.invalidate(_adminInvoicesProvider(accountId)),
            data: (list) => list.isEmpty
                ? const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No invoices yet.'))
                : Column(children: [
                    for (final i in list)
                      Padding(
                        key: ValueKey('biz-invoice-${i.id}'),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Wrap(alignment: WrapAlignment.spaceBetween, spacing: 12, children: [
                            Text('${i.monthLabel} · ${i.invoiceNo}'),
                            Text(i.amountLabel),
                          ]),
                          Text(
                            '${i.statusLabel(now)} · ${i.trips} ${i.trips == 1 ? 'trip' : 'trips'} · ${i.terms.label}',
                            style: TextStyle(color: i.overdue(now) ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
                          ),
                          Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
                            BusinessInvoiceFileButtons(invoice: i),
                            if (canEdit && i.status == 'issued')
                              FilledButton.tonal(
                                key: ValueKey('biz-invoice-paid-${i.id}'),
                                onPressed: () async {
                                  if (!await confirm(context, 'Mark ${i.invoiceNo} paid?',
                                      '${i.amountLabel} received. Paused bookings go on again.', ok: 'Mark paid')) {
                                    return;
                                  }
                                  if (!context.mounted) return;
                                  final ok = await runAdminAction(
                                    context,
                                    () => ref.read(businessRepositoryProvider).markPaid(i.id),
                                    success: '${i.invoiceNo} is paid.',
                                  );
                                  if (ok) onChanged();
                                },
                                child: const Text('Mark paid'),
                              ),
                          ]),
                        ]),
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}

class _MembersCard extends ConsumerWidget {
  const _MembersCard({required this.accountId});
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final async = ref.watch(_adminMembersProvider(accountId));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Members', style: t.textTheme.titleMedium),
          AsyncView(
            value: async,
            onRetry: () => ref.invalidate(_adminMembersProvider(accountId)),
            data: (list) => ListSearchFilter(
              count: list.length,
              hint: 'Search members',
              builder: (context, q) => Column(children: [
                for (final m in list)
                  if (q.isEmpty || '${m.display} ${m.phone} ${m.team ?? ''}'.toLowerCase().contains(q.toLowerCase()))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(m.display),
                      subtitle: Text([m.phone, m.role.label, if ((m.team ?? '').isNotEmpty) m.team!].join(' · ')),
                      trailing: m.status == 'invited' ? const BusinessStatusPill('invited') : null,
                    ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
