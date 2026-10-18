// Admin → Payments & commerce → Partner statements (migration 0201): which
// surcharges count as a driver's earnings, whether weeks run Monday–Sunday
// or Sunday–Saturday, the bank line and the company header on every
// statement; then incentives credited to GET credit, and adjustments, which
// mark the final statements they touch as Revised; and the Layout tab, how the
// PDF looks (statement_layout_tab.dart). Only admins with edit
// rights change anything; the server checks that too.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/partner_statement.dart';
import '../../../data/partner_statement_repository.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../../widgets/page_style_host.dart';
import 'statement_layout_tab.dart';

/// The `admin_access` page these settings sit under.
const statementsPage = 'admin-settings-partner-statements';

final adminStatementSettingsProvider = FutureProvider.autoDispose<StatementSettings>(
  (ref) => ref.watch(statementSettingsProvider.future),
);

final adminSurchargeNamesProvider = FutureProvider.autoDispose<List<({String name, int trips})>>(
  (ref) => ref.watch(partnerStatementRepositoryProvider).surchargeNames(),
);

final adminStatementEntriesProvider = FutureProvider.autoDispose.family<List<StatementEntry>, String>(
  (ref, kind) => ref.watch(partnerStatementRepositoryProvider).entries(kind),
);

class AdminPartnerStatementsScreen extends ConsumerStatefulWidget {
  const AdminPartnerStatementsScreen({super.key});

  @override
  ConsumerState<AdminPartnerStatementsScreen> createState() => _AdminPartnerStatementsScreenState();
}

class _AdminPartnerStatementsScreenState extends ConsumerState<AdminPartnerStatementsScreen> {
  StatementSettings? _stored;
  StatementSettings? _draft;

  /// Bumped when the draft is replaced wholesale, so the text fields re-read it.
  int _generation = 0;
  bool _saving = false;

  bool get _canEdit => ref.watch(pageAccessProvider(statementsPage)) == AccessLevel.edit;

  Future<void> _save() async {
    final d = _draft;
    if (d == null) return;
    setState(() => _saving = true);
    final ok = await runAdminAction(context, () async {
      final saved = await ref.read(partnerStatementRepositoryProvider).saveSettings(d);
      if (mounted) {
        setState(() {
          _stored = _draft = saved;
          _generation++;
        });
      }
    }, success: 'Statement settings saved');
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) ref.invalidate(statementSettingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(adminStatementSettingsProvider);
    final fresh = loaded.value;
    if (fresh != null && fresh != _stored) {
      if (_draft == null || _draft == _stored) {
        _draft = fresh;
        _generation++;
      }
      _stored = fresh;
    }
    final dirty = _draft != null && _draft != _stored;
    return DefaultTabController(
      length: 4,
      child: AdminPage(
        title: 'Partner statements',
        page: statementsPage,
        bottom: const TabBar(
          tabs: [
            Tab(key: ValueKey('statements-tab-settings'), text: 'Settings'),
            Tab(key: ValueKey('statements-tab-layout'), text: 'Layout'),
            Tab(key: ValueKey('statements-tab-incentives'), text: 'Incentives'),
            Tab(key: ValueKey('statements-tab-adjustments'), text: 'Adjustments'),
          ],
        ),
        actions: [
          if (dirty)
            TextButton(
              key: const ValueKey('statements-discard'),
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      _draft = _stored;
                      _generation++;
                    }),
              child: const Text('Discard'),
            ),
        ],
        floatingActionButton: dirty
            ? FloatingActionButton.extended(
                key: const ValueKey('statements-save'),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(_saving ? 'Saving…' : 'Save'),
              )
            : null,
        body: AsyncView(
          value: loaded,
          onRetry: () => ref.invalidate(statementSettingsProvider),
          data: (_) => TabBarView(
            // No swiping between tabs: dragging the logo on the Layout preview moves it.
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _SettingsTab(
                key: ValueKey('statements-settings-$_generation'),
                settings: _draft!,
                canEdit: _canEdit,
                onChanged: (s) => setState(() => _draft = s),
              ),
              StatementLayoutTab(canEdit: _canEdit, companyName: _draft!.companyName),
              _EntriesTab(kind: 'incentive', canEdit: _canEdit),
              _EntriesTab(kind: 'adjustment', canEdit: _canEdit),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Settings -----------------------------------------------------------------------------------
class _SettingsTab extends ConsumerStatefulWidget {
  const _SettingsTab({super.key, required this.settings, required this.canEdit, required this.onChanged});
  final StatementSettings settings;
  final bool canEdit;
  final ValueChanged<StatementSettings> onChanged;

  @override
  ConsumerState<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<_SettingsTab> {
  final _extra = TextEditingController();

  @override
  void dispose() {
    _extra.dispose();
    super.dispose();
  }

  void _toggle(String name, bool on) {
    final names = [...widget.settings.earningSurcharges];
    on ? names.add(name) : names.remove(name);
    widget.onChanged(widget.settings.copyWith(earningSurcharges: names));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final seen = ref.watch(adminSurchargeNamesProvider).value ?? const [];
    // Names marked before but not on a trip this year stay listed, so they can be unticked.
    final names = <String, int>{for (final n in s.earningSurcharges) n: 0, for (final n in seen) n.name: n.trips};
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
    Widget field(String key, String label, String value, ValueChanged<String> onChanged, {String? hint}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: ValueKey(key),
        initialValue: value,
        enabled: widget.canEdit,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
        onChanged: onChanged,
      ),
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        ResponsiveCenter(
          maxWidth: 760,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              heading('Week', 'Weekly statements and the Earnings page\'s "This week".'),
              SegmentedButton<bool>(
                key: const ValueKey('statements-week'),
                segments: const [
                  ButtonSegment(value: false, label: Text('Monday – Sunday')),
                  ButtonSegment(value: true, label: Text('Sunday – Saturday')),
                ],
                selected: {s.weekStartsSunday},
                showSelectedIcon: false,
                onSelectionChanged: widget.canEdit
                    ? (v) => widget.onChanged(s.copyWith(weekStartsSunday: v.first))
                    : null,
              ),
              heading(
                'Surcharges counted as earnings',
                'Ticked surcharges are the driver\'s income. The rest, with taxes and tolls, are shown as collected '
                    'for others. Scheduling and late-cancel fees are GET.ride\'s and listed apart.',
              ),
              if (names.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('No surcharges on trips in the last year.', style: TextStyle(color: muted)),
                ),
              for (final e in names.entries)
                CheckboxListTile(
                  key: ValueKey('statements-surcharge-${e.key}'),
                  value: s.earningSurcharges.contains(e.key),
                  title: Text(e.key),
                  subtitle: e.value > 0 ? Text('${e.value} trips in the last year') : null,
                  onChanged: widget.canEdit ? (v) => _toggle(e.key, v ?? false) : null,
                ),
              if (widget.canEdit)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('statements-surcharge-add'),
                        controller: _extra,
                        decoration: const InputDecoration(labelText: 'Another surcharge name'),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        final n = _extra.text.trim();
                        if (n.isEmpty || s.earningSurcharges.contains(n)) return;
                        _extra.clear();
                        _toggle(n, true);
                      },
                      child: const Text('Add'),
                    ),
                  ],
                ),
              heading('On every statement'),
              SwitchListTile(
                key: const ValueKey('statements-bank'),
                contentPadding: EdgeInsets.zero,
                value: s.showBank,
                title: const Text('Show the payout bank account'),
                subtitle: const Text('Drivers add their bank on the Statements page; the number is masked.'),
                onChanged: widget.canEdit ? (v) => widget.onChanged(s.copyWith(showBank: v)) : null,
              ),
              const SizedBox(height: 8),
              field(
                'statements-company',
                'Company name',
                s.companyName,
                (v) => widget.onChanged(s.copyWith(companyName: v)),
              ),
              field('statements-ssm', 'SSM number', s.companySsm, (v) => widget.onChanged(s.copyWith(companySsm: v))),
              field(
                'statements-support',
                'Support contact',
                s.supportContact,
                (v) => widget.onChanged(s.copyWith(supportContact: v)),
              ),
              field(
                'statements-verify',
                'Verification page',
                s.verifyUrl,
                (v) => widget.onChanged(s.copyWith(verifyUrl: v)),
                hint: 'Blank: https://getride.my/verify',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Incentives and adjustments -----------------------------------------------------------------
class _EntriesTab extends ConsumerWidget {
  const _EntriesTab({required this.kind, required this.canEdit});

  /// incentive | adjustment
  final String kind;
  final bool canEdit;

  bool get _incentive => kind == 'incentive';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final entries = ref.watch(adminStatementEntriesProvider(kind));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(adminStatementEntriesProvider(kind).future),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ResponsiveCenter(
            maxWidth: 760,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Text(
                  _incentive
                      ? 'Credited to the driver\'s GET credit under its own name, and shown as an incentive on their '
                            'statement. Weekly rules (Driver incentive) are credited every Monday on their own.'
                      : 'A correction to GET credit: plus to pay a driver, minus to take back. A final statement '
                            'covering the date is marked Revised.',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                if (canEdit) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      key: ValueKey('statements-new-$kind'),
                      icon: const Icon(Icons.add),
                      label: Text(_incentive ? 'Credit an incentive' : 'Post an adjustment'),
                      onPressed: () async {
                        final done = await showAppDialog<bool>(id: 'partner-statements.entries-tab',
                          context: context,
                          builder: (_) => _EntryDialog(incentive: _incentive),
                        );
                        if (done == true) ref.invalidate(adminStatementEntriesProvider(kind));
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                AsyncView(
                  value: entries,
                  onRetry: () => ref.invalidate(adminStatementEntriesProvider(kind)),
                  data: (list) => list.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _incentive ? 'No incentives credited yet.' : 'No adjustments posted yet.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: muted),
                          ),
                        )
                      : Column(
                          children: [
                            for (final e in list)
                              Card(
                                child: ListTile(
                                  key: ValueKey('statements-entry-${e.id}'),
                                  title: Text(e.label),
                                  subtitle: Text(
                                    [
                                      '${e.partnerName}${e.partnerId.isEmpty ? '' : ' (${e.partnerId})'}',
                                      if (e.at != null) '${e.at!.day}/${e.at!.month}/${e.at!.year}',
                                      if (e.byName.isNotEmpty) 'by ${e.byName}',
                                    ].join(' · '),
                                    style: TextStyle(color: muted),
                                  ),
                                  trailing: Text(
                                    '${e.amount > 0 && !_incentive ? '+' : ''}${formatMoney(e.amount)}',
                                    style: t.textTheme.titleMedium,
                                  ),
                                ),
                              ),
                          ],
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

class _EntryDialog extends ConsumerStatefulWidget {
  const _EntryDialog({required this.incentive});
  final bool incentive;

  @override
  ConsumerState<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends ConsumerState<_EntryDialog> {
  final _form = GlobalKey<FormState>();
  final _partner = TextEditingController();
  final _amount = TextEditingController();
  final _label = TextEditingController();
  DateTime? _date;
  bool _saving = false;

  @override
  void dispose() {
    _partner.dispose();
    _amount.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final amount = double.parse(_amount.text.trim());
    final ok = await confirm(
      context,
      widget.incentive ? 'Credit this incentive?' : 'Post this adjustment?',
      '${formatMoney(amount)} to ${_partner.text.trim()}: ${_label.text.trim()}. GET credit changes at once and '
      'the driver is told.',
      ok: widget.incentive ? 'Credit' : 'Post',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(partnerStatementRepositoryProvider);
      widget.incentive
          ? await repo.creditIncentive(_partner.text, amount, _label.text)
          : await repo.postAdjustment(_partner.text, amount, _label.text, _date);
      if (mounted) {
        Navigator.pop(context, true);
        showInfo(context, widget.incentive ? 'Incentive credited' : 'Adjustment posted');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? v) => (v ?? '').trim().isEmpty ? 'Required' : null;
    return AlertDialog(
      title: Text(widget.incentive ? 'Credit an incentive' : 'Post an adjustment'),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('entry-partner'),
                controller: _partner,
                decoration: const InputDecoration(labelText: 'Partner ID or phone'),
                validator: required,
              ),
              TextFormField(
                key: const ValueKey('entry-amount'),
                controller: _amount,
                decoration: InputDecoration(
                  labelText: 'Amount (RM)',
                  helperText: widget.incentive ? null : 'Minus to take back, e.g. -5.00',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                validator: (v) {
                  final n = double.tryParse((v ?? '').trim());
                  if (n == null || n == 0) return 'Enter an amount';
                  if (widget.incentive && n < 0) return 'An incentive is more than 0';
                  return null;
                },
              ),
              TextFormField(
                key: const ValueKey('entry-label'),
                controller: _label,
                decoration: InputDecoration(labelText: widget.incentive ? 'Incentive name' : 'Reason'),
                validator: required,
              ),
              if (!widget.incentive) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(_date == null ? 'Dated today' : 'Dated ${_date!.day}/${_date!.month}/${_date!.year}'),
                    ),
                    TextButton(
                      key: const ValueKey('entry-date'),
                      onPressed: () async {
                        final now = DateTime.now();
                        final d = await showDatePicker(
                          context: context,
                          initialDate: _date ?? now,
                          firstDate: DateTime(now.year - 7),
                          lastDate: now,
                        );
                        if (d != null) setState(() => _date = d);
                      },
                      child: const Text('Change'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('entry-submit'),
          onPressed: _saving ? null : _submit,
          child: Text(widget.incentive ? 'Credit' : 'Post'),
        ),
      ],
    );
  }
}
