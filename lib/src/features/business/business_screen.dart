// Account › Business (migration 0313): the member's business accounts and
// invitations, applying for one, and one account's pages: Overview for every
// member; Members, Rules and Invoices for its Admins. Members book as usual
// and pick "Business: <company>" as the payment.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_accounts.dart';
import '../../data/business_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import 'business_invoice_files.dart';
import 'business_widgets.dart';

const businessHomePath = '/account/business';
const businessApplyPath = '/account/business/apply';
String businessAccountPath(String id) => '/account/business/$id';

// ---- The list ------------------------------------------------------------------------------------------
class BusinessHomeScreen extends ConsumerWidget {
  const BusinessHomeScreen({super.key});

  Future<void> _join(BuildContext context, WidgetRef ref, BusinessMembership a, bool join) async {
    try {
      final repo = ref.read(businessRepositoryProvider);
      join ? await repo.join(a.accountId) : await repo.leave(a.accountId);
      ref.invalidate(myBusinessAccountsProvider);
      if (context.mounted) {
        showInfo(context, join ? 'You joined ${a.name}. Pick "Business: ${a.name}" as the payment when you book.' : 'Invitation declined.');
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myBusinessAccountsProvider);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Business')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(myBusinessAccountsProvider),
        data: (list) => ListView(padding: const EdgeInsets.all(16), children: [
          ResponsiveCenter(
            maxWidth: 760,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                'Your company pays for the trips its people book: city rides, scheduled rides, Freight and Courier. '
                'Book as usual and pick "Business: (your company)" as the payment.',
                style: t.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              for (final a in list)
                Card(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ListTile(
                      key: ValueKey('business-account-${a.accountId}'),
                      leading: const Icon(Icons.business_center_outlined),
                      title: Text(a.name),
                      subtitle: Text(a.invited
                          ? 'You were invited as ${a.role.label}'
                          : [a.role.label, if ((a.team ?? '').isNotEmpty) a.team!].join(' · ')),
                      trailing: a.invited
                          ? null
                          : a.status == 'active'
                          ? const Icon(Icons.chevron_right)
                          : BusinessStatusPill(a.status),
                      onTap: a.invited ? null : () => context.push(businessAccountPath(a.accountId)),
                    ),
                    if (a.invited)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
                          TextButton(
                            key: ValueKey('business-decline-${a.accountId}'),
                            onPressed: () => _join(context, ref, a, false),
                            child: const Text('Decline'),
                          ),
                          FilledButton(
                            key: ValueKey('business-join-${a.accountId}'),
                            onPressed: () => _join(context, ref, a, true),
                            child: const Text('Join'),
                          ),
                        ]),
                      ),
                  ]),
                ),
              if (list.isEmpty)
                const EmptyState(
                  icon: Icons.business_center_outlined,
                  title: 'No business account yet',
                  message: 'Apply for your company, or ask its Admin to invite your phone number.',
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('business-apply'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => context.push(businessApplyPath),
                icon: const Icon(Icons.add_business_outlined),
                label: const Text('Apply for a business account'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---- One account ---------------------------------------------------------------------------------------
class BusinessAccountScreen extends ConsumerWidget {
  const BusinessAccountScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(businessAccountDetailProvider(id));
    final d = async.value;
    final tabs = [
      'Overview',
      if (d?.isAdmin ?? false) ...['Members', 'Rules', 'Invoices'],
    ];
    return DefaultTabController(
      key: ValueKey('business-tabs-${tabs.length}'),
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(d?.name ?? 'Business'),
          bottom: tabs.length < 2
              ? null
              : TabBar(isScrollable: true, tabs: [for (final t in tabs) Tab(key: ValueKey('business-tab-$t'), text: t)]),
        ),
        body: AsyncView(
          value: async,
          onRetry: () => ref.invalidate(businessAccountDetailProvider(id)),
          data: (d) {
            Future<void> refresh() async {
              ref.invalidate(businessAccountDetailProvider(id));
              ref.invalidate(myBusinessAccountsProvider);
            }

            final pages = [
              _Overview(d: d, onChanged: refresh),
              if (d.isAdmin) ...[
                _Members(d: d, onChanged: refresh),
                _RulesPage(d: d, onChanged: refresh),
                _Invoices(d: d),
              ],
            ];
            return TabBarView(children: [
              for (final p in pages) ListView(padding: const EdgeInsets.all(16), children: [ResponsiveCenter(maxWidth: 760, child: p)]),
            ]);
          },
        ),
      ),
    );
  }
}

class _Overview extends ConsumerWidget {
  const _Overview({required this.d, required this.onChanged});
  final BusinessAccountDetail d;
  final Future<void> Function() onChanged;

  Future<void> _decide(BuildContext context, WidgetRef ref, BusinessApproval a, bool approve) async {
    try {
      await ref.read(businessRepositoryProvider).decideApproval(a.id, approve);
      await onChanged();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final pending = [for (final a in d.approvals) if (a.status == 'pending') a];
    final next = d.nextInvoice;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (d.status != 'active')
        Card(
          color: t.colorScheme.tertiaryContainer,
          child: ListTile(
            leading: const Icon(Icons.hourglass_top),
            title: BusinessStatusPill(d.status),
            subtitle: Text(d.statusNote ??
                (d.status == 'pending' ? 'get.ride checks the company documents. You can book once it is approved.' : 'Bookings on this account are paused.')),
          ),
        ),
      if (d.pausedBy != null)
        Card(
          key: const ValueKey('business-paused'),
          color: t.colorScheme.errorContainer,
          child: ListTile(
            leading: const Icon(Icons.pause_circle_outline),
            title: const Text('Bookings are paused'),
            subtitle: Text('Invoice ${d.pausedBy} is overdue. Bookings go on once it is paid.'),
          ),
        ),
      BusinessFigure(
        label: 'This month',
        value: businessMoneyCents(d.monthSpend),
        sub: d.monthCounts,
        valueKey: const ValueKey('business-month'),
      ),
      if (d.terms == BusinessTerms.invoice)
        BusinessFigure(
          label: 'Credit limit',
          value: businessMoney(d.settings.creditLimit ?? 0),
          sub: 'Set by get.ride',
        )
      else
        BusinessFigure(label: 'Business wallet', value: businessMoneyCents(d.walletBalance), sub: 'Prepaid; top-ups through get.ride'),
      if (next != null)
        BusinessFigure(label: 'Next invoice', value: '1 ${shortDate(next).split(' ').last}', sub: d.termsLine),
      BusinessFigure(
        label: 'Your spend this month',
        value: businessMoneyCents(d.mySpend),
        sub: d.myLimit > 0 ? 'Of your ${businessMoney(d.myLimit)} monthly limit' : 'No monthly limit',
      ),
      if (pending.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Trips waiting for approval', style: t.textTheme.titleMedium),
        for (final a in pending)
          Card(
            child: ListTile(
              key: ValueKey('business-approval-${a.id}'),
              title: Text('${a.member}: ${businessMoney(a.amount)}'),
              subtitle: Text([
                if ((a.service ?? '').isNotEmpty) a.service!,
                if ((a.pickup ?? '').isNotEmpty) '${a.pickup} to ${a.dropoff ?? ''}',
                if ((a.note ?? '').isNotEmpty) a.note!,
              ].join(' · ')),
              trailing: Wrap(spacing: 4, children: [
                IconButton(
                  key: ValueKey('business-decline-approval-${a.id}'),
                  tooltip: 'Decline',
                  icon: const Icon(Icons.close),
                  onPressed: () => _decide(context, ref, a, false),
                ),
                IconButton.filled(
                  key: ValueKey('business-approve-${a.id}'),
                  tooltip: 'Approve',
                  icon: const Icon(Icons.check),
                  onPressed: () => _decide(context, ref, a, true),
                ),
              ]),
            ),
          ),
      ],
      const SizedBox(height: 8),
      Text(
        'Members book as usual and pick "${businessPaymentLabel(d.name)}" as the payment.',
        key: const ValueKey('business-how'),
        style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
    ]);
  }
}

// ---- Members ---------------------------------------------------------------------------------------------
class _Members extends ConsumerWidget {
  const _Members({required this.d, required this.onChanged});
  final BusinessAccountDetail d;
  final Future<void> Function() onChanged;

  Future<void> _run(BuildContext context, Future<void> Function() f) async {
    try {
      await f();
      await onChanged();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final repo = ref.read(businessRepositoryProvider);
    final def = d.settings.memberLimit ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FilledButton.icon(
        key: const ValueKey('business-invite'),
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
        onPressed: () async {
          final ok = await showInviteSheet(context, ref, d.id);
          if (ok == true) await onChanged();
        },
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('Invite by phone'),
      ),
      const SizedBox(height: 8),
      ListSearchFilter(
        count: d.members.length,
        hint: 'Search members',
        builder: (context, q) {
          final shown = [
            for (final m in d.members)
              if (q.isEmpty || '${m.display} ${m.phone} ${m.team ?? ''} ${m.role.label}'.toLowerCase().contains(q.toLowerCase())) m,
          ];
          return Column(children: [
            for (final m in shown)
              Card(
                key: ValueKey('business-member-${m.id}'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(m.display, style: t.textTheme.titleMedium),
                          Text([m.role.label, if ((m.team ?? '').isNotEmpty) m.team!, if (m.status == 'invited') 'Invited']
                              .join(' · ')),
                        ]),
                      ),
                      IconButton(
                        key: ValueKey('business-member-edit-${m.id}'),
                        tooltip: 'Change ${m.display}',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final ok = await showMemberSheet(context, ref, m);
                          if (ok == true) await onChanged();
                        },
                      ),
                    ]),
                    BusinessStepper(
                      label: 'Monthly limit',
                      hint: m.monthlyLimit == null ? 'The account\'s default' : 'Spent ${businessMoney(m.spend)} this month',
                      value: m.monthlyLimit == null
                          ? (def <= 0 ? 'No limit' : businessMoney(def))
                          : (m.monthlyLimit! <= 0 ? 'No limit' : businessMoney(m.monthlyLimit!)),
                      valueKey: ValueKey('business-member-limit-${m.id}'),
                      onDown: (m.monthlyLimit ?? def) <= 0
                          ? null
                          : () => _run(context, () => repo.updateMember(m.id, limit: ((m.monthlyLimit ?? def) - 100).clamp(0, 1e8))),
                      onUp: () => _run(context, () => repo.updateMember(m.id, limit: (m.monthlyLimit ?? def) + 100)),
                    ),
                  ]),
                ),
              ),
          ]);
        },
      ),
    ]);
  }
}

/// Invite a member by phone; true when invited.
Future<bool?> showInviteSheet(BuildContext context, WidgetRef ref, String accountId) => showAppSheet<bool>(
  id: 'business.invite',
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (c) => _InviteSheet(accountId: accountId),
);

class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet({required this.accountId});
  final String accountId;

  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _team = TextEditingController();
  BusinessRole _role = BusinessRole.rider;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    _team.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_phone.text.replaceAll(RegExp(r'\D'), '').length < 6) {
      showInfo(context, "Enter the person's phone number with its country code.");
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(businessRepositoryProvider).invite(
        widget.accountId,
        phone: _phone.text.trim(),
        name: _name.text.trim().isEmpty ? null : _name.text.trim(),
        role: _role,
        team: _team.text.trim().isEmpty ? null : _team.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Invite by phone', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('business-invite-phone'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone number', hintText: '+60 12 345 6789', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('business-invite-name'),
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name (optional)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('business-invite-team'),
          controller: _team,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Team (optional)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        _RolePicker(value: _role, onChanged: (r) => setState(() => _role = r)),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('business-invite-send'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: _busy ? null : _send,
          child: const Text('Send invitation'),
        ),
      ]),
    ),
  );
}

class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.value, required this.onChanged});
  final BusinessRole value;
  final ValueChanged<BusinessRole> onChanged;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    SegmentedButton<BusinessRole>(
      key: const ValueKey('business-role'),
      segments: [for (final r in BusinessRole.values) ButtonSegment(value: r, label: Text(r.label))],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    ),
    Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(value.help, style: Theme.of(context).textTheme.bodySmall),
    ),
  ]);
}

/// Change a member's role, team or limit, or remove them; true when changed.
Future<bool?> showMemberSheet(BuildContext context, WidgetRef ref, BusinessMember m) => showAppSheet<bool>(
  id: 'business.member',
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (c) => _MemberSheet(m: m),
);

class _MemberSheet extends ConsumerStatefulWidget {
  const _MemberSheet({required this.m});
  final BusinessMember m;

  @override
  ConsumerState<_MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends ConsumerState<_MemberSheet> {
  late final _team = TextEditingController(text: widget.m.team ?? '');
  late BusinessRole _role = widget.m.role;
  bool _busy = false;

  @override
  void dispose() {
    _team.dispose();
    super.dispose();
  }

  Future<void> _go(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(businessRepositoryProvider);
    final m = widget.m;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(m.display, style: Theme.of(context).textTheme.titleLarge),
          Text(m.phone),
          const SizedBox(height: 12),
          _RolePicker(value: _role, onChanged: (r) => setState(() => _role = r)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('business-member-team'),
            controller: _team,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Team', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('business-member-save'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _busy ? null : () => _go(() => repo.updateMember(m.id, role: _role, team: _team.text)),
            child: const Text('Save'),
          ),
          if (m.monthlyLimit != null)
            TextButton(
              key: const ValueKey('business-member-default-limit'),
              onPressed: _busy ? null : () => _go(() => repo.updateMember(m.id, defaultLimit: true)),
              child: const Text("Use the account's default limit"),
            ),
          TextButton(
            key: const ValueKey('business-member-remove'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: _busy ? null : () => _go(() => repo.removeMember(m.id)),
            child: const Text('Remove from the account'),
          ),
        ]),
      ),
    );
  }
}

// ---- Rules --------------------------------------------------------------------------------------------------
class _RulesPage extends ConsumerStatefulWidget {
  const _RulesPage({required this.d, required this.onChanged});
  final BusinessAccountDetail d;
  final Future<void> Function() onChanged;

  @override
  ConsumerState<_RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends ConsumerState<_RulesPage> {
  late BusinessRules _r = widget.d.rules;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant _RulesPage old) {
    super.didUpdateWidget(old);
    if (old.d.rules != widget.d.rules) _r = widget.d.rules;
  }

  Future<void> _save() async {
    final why = _r.problem;
    if (why != null) return showInfo(context, why);
    setState(() => _busy = true);
    try {
      await ref.read(businessRepositoryProvider).setRules(widget.d.id, _r);
      await widget.onChanged();
      if (mounted) showInfo(context, 'Rules saved.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _rule(String key, String label, bool on, ValueChanged<bool> set, {List<Widget> values = const []}) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CheckboxListTile(
          key: ValueKey('business-rule-$key'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: on,
          title: Text(label),
          onChanged: (v) => set(v ?? false),
        ),
        if (on) ...values,
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final r = _r;
    void set(BusinessRules v) => setState(() => _r = v);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _rule('hours', 'Business trips only at set hours', r.hoursOn, (v) => set(r.copyWith(hoursOn: v)), values: [
        BusinessStepper(
          label: 'From',
          value: businessHour(r.hoursFrom),
          valueKey: const ValueKey('business-hours-from'),
          onDown: r.hoursFrom > 0 ? () => set(r.copyWith(hoursFrom: r.hoursFrom - 1)) : null,
          onUp: r.hoursFrom < 23 ? () => set(r.copyWith(hoursFrom: r.hoursFrom + 1)) : null,
        ),
        BusinessStepper(
          label: 'Until',
          value: businessHour(r.hoursUntil),
          valueKey: const ValueKey('business-hours-until'),
          onDown: r.hoursUntil > 1 ? () => set(r.copyWith(hoursUntil: r.hoursUntil - 1)) : null,
          onUp: r.hoursUntil < 24 ? () => set(r.copyWith(hoursUntil: r.hoursUntil + 1)) : null,
        ),
      ]),
      _rule('note', 'A trip note (project or reason) is required', r.noteRequired, (v) => set(r.copyWith(noteRequired: v))),
      _rule('approval', "Trips above an amount need an Admin's approval", r.approvalOn, (v) => set(r.copyWith(approvalOn: v)),
          values: [
            BusinessStepper(
              label: 'Above',
              value: businessMoney(r.approvalOver),
              valueKey: const ValueKey('business-approval-over'),
              onDown: r.approvalOver >= 10 ? () => set(r.copyWith(approvalOver: r.approvalOver - 10)) : null,
              onUp: r.approvalOver < 1000000 ? () => set(r.copyWith(approvalOver: r.approvalOver + 10)) : null,
            ),
          ]),
      _rule('cap', 'Company spend cap per month', r.capOn, (v) => set(r.copyWith(capOn: v)), values: [
        BusinessStepper(
          label: 'Cap',
          value: businessMoney(r.monthlyCap),
          valueKey: const ValueKey('business-cap'),
          onDown: r.monthlyCap >= 500 ? () => set(r.copyWith(monthlyCap: r.monthlyCap - 500)) : null,
          onUp: () => set(r.copyWith(monthlyCap: r.monthlyCap + 500)),
        ),
      ]),
      _rule('freight', 'Bookers may book Freight and Courier', r.bookersFreight, (v) => set(r.copyWith(bookersFreight: v))),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const ValueKey('business-rules-save'),
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
        onPressed: _busy || r == widget.d.rules ? null : _save,
        icon: const Icon(Icons.save_outlined),
        label: const Text('Save rules'),
      ),
    ]);
  }
}

// ---- Invoices ----------------------------------------------------------------------------------------------
class _Invoices extends StatelessWidget {
  const _Invoices({required this.d});
  final BusinessAccountDetail d;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final now = DateTime.now();
    if (d.invoices.isEmpty) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'No invoices yet',
        message: 'The first one starts with the first trip.',
      );
    }
    return Column(children: [
      for (final i in d.invoices)
        Card(
          key: ValueKey('business-invoice-${i.id}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(alignment: WrapAlignment.spaceBetween, spacing: 12, children: [
                Text(i.monthLabel, style: t.textTheme.titleMedium),
                Text(i.amountLabel, style: t.textTheme.titleMedium),
              ]),
              Text(
                '${i.invoiceNo} · ${i.statusLabel(now)} · ${i.trips} ${i.trips == 1 ? 'trip' : 'trips'}',
                style: TextStyle(color: i.overdue(now) ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
              ),
              Align(alignment: Alignment.centerRight, child: BusinessInvoiceFileButtons(invoice: i)),
            ]),
          ),
        ),
    ]);
  }
}
