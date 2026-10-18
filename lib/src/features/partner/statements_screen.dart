// Earnings → Statements: weekly, monthly and annual earnings statements as
// PDFs, in English or Bahasa Melayu (migration 0201). Each period says
// whether it is Provisional (still open), Final, or Revised (an adjustment
// changed a final one). The copy last downloaded opens offline. From January
// to April the year before's annual statement is pinned, for Borang B/BE.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/partner_statement.dart';
import '../../data/partner_statement_repository.dart';
import '../../providers.dart' show partnerProvider;
import '../../widgets/common.dart';
import '../../widgets/pdf_actions.dart';
import '../../widgets/back_or_go_button.dart';
import '../../widgets/page_style_host.dart';

/// Hands a statement's PDF to share or download. Overridden in tests.
final statementPdfOpenerProvider =
    Provider<Future<void> Function(BuildContext context, Uint8List bytes, String fileName, String title)>(
      (ref) =>
          (context, bytes, fileName, title) =>
              sharePdfOrDownload(context, filename: fileName, title: title, build: () async => bytes),
    );

/// The statement language, remembered on this device.
final statementLangProvider = NotifierProvider<StatementLangNotifier, StatementLang>(StatementLangNotifier.new);

class StatementLangNotifier extends Notifier<StatementLang> {
  @override
  StatementLang build() {
    ref.read(partnerStatementRepositoryProvider).savedLang().then((l) {
      if (ref.mounted && l != state) state = l;
    });
    return StatementLang.en;
  }

  void set(StatementLang lang) {
    state = lang;
    ref.read(partnerStatementRepositoryProvider).saveLang(lang);
  }
}

final payoutAccountProvider = FutureProvider.autoDispose<PayoutAccount?>(
  (ref) => ref.watch(partnerStatementRepositoryProvider).payoutAccount(),
);

class StatementsScreen extends ConsumerWidget {
  const StatementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang = ref.watch(statementLangProvider);
    final showBank = ref.watch(statementSettingsProvider).value?.showBank ?? false;
    final taxYear = taxSeasonYear(DateTime.now());
    return DefaultTabController(
      length: StatementType.values.length,
      child: Scaffold(
        appBar: AppBar(
          leading: const BackOrGoButton(fallback: '/drive'),
          title: const Text('Statements'),
          bottom: TabBar(
            key: const ValueKey('statements-tabs'),
            tabs: [for (final t in StatementType.values) Tab(text: t.label)],
          ),
        ),
        body: Column(
          children: [
            ResponsiveCenter(
              maxWidth: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  SegmentedButton<StatementLang>(
                    key: const ValueKey('statements-lang'),
                    segments: const [
                      ButtonSegment(value: StatementLang.en, label: Text('English')),
                      ButtonSegment(value: StatementLang.ms, label: Text('Bahasa Melayu')),
                    ],
                    selected: {lang},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => ref.read(statementLangProvider.notifier).set(v.first),
                  ),
                  if (taxYear != null) ...[const SizedBox(height: 8), _TaxPin(year: taxYear, lang: lang)],
                  if (showBank) const _PayoutAccountTile(),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [for (final t in StatementType.values) _PeriodList(type: t, lang: lang)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Makes or fetches the statement, falling back to the copy on the device
/// when offline, then offers to share or download it.
Future<void> openStatement(BuildContext context, WidgetRef ref, StatementPeriod p, StatementLang lang) async {
  final repo = ref.read(partnerStatementRepositoryProvider);
  final opener = ref.read(statementPdfOpenerProvider);
  final title = '${p.type.label} statement · ${p.label}';
  Uint8List bytes;
  var fileName = 'getride-statement-${p.type.name}-${isoDate(p.start)}-${lang.name}.pdf';
  try {
    final d = await repo.download(p, lang);
    bytes = d.bytes;
    fileName = d.info.fileName;
  } catch (e) {
    final cached = await repo.cached(p, lang);
    if (cached == null) {
      if (context.mounted) showError(context, e);
      return;
    }
    bytes = cached;
    if (context.mounted) showInfo(context, 'Couldn\'t reach GET.ride: this is the copy saved on this device.');
  }
  if (context.mounted) await opener(context, bytes, fileName, title);
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status);
  final StatementStatus status;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      StatementStatus.finalised => (c.primaryContainer, c.onPrimaryContainer),
      StatementStatus.revised => (c.tertiaryContainer, c.onTertiaryContainer),
      StatementStatus.provisional => (c.surfaceContainerHighest, c.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(status.label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
    );
  }
}

class _PeriodList extends ConsumerStatefulWidget {
  const _PeriodList({required this.type, required this.lang});
  final StatementType type;
  final StatementLang lang;

  @override
  ConsumerState<_PeriodList> createState() => _PeriodListState();
}

class _PeriodListState extends ConsumerState<_PeriodList> with AutomaticKeepAliveClientMixin {
  final _periods = <StatementPeriod>[];
  Object? _error;
  bool _loading = true;
  bool _more = true;
  String? _opening;

  static const _page = 12;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _periods.clear();
        _more = true;
      }
    });
    try {
      final next = await ref
          .read(partnerStatementRepositoryProvider)
          .periods(widget.type, limit: _page, before: _periods.isEmpty ? null : _periods.last.start);
      if (!mounted) return;
      setState(() {
        _periods.addAll(next);
        _more = next.length == _page;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _open(StatementPeriod p) async {
    final key = '${p.type.name}-${isoDate(p.start)}';
    setState(() => _opening = key);
    try {
      await openStatement(context, ref, p, widget.lang);
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = Theme.of(context);
    if (_periods.isEmpty && _loading) return const Center(child: CircularProgressIndicator());
    if (_periods.isEmpty && _error != null) {
      // Not approved yet: there is nothing to load, so no error and no retry.
      final partner = ref.watch(partnerProvider).value;
      if (partner != null && !partner.approved) {
        return const EmptyState(
          key: ValueKey('statements-not-approved'),
          icon: Icons.description_outlined,
          title: 'No statements yet',
          message: 'Statements start from your first week as an approved driver.',
        );
      }
      // In the same column as the tabs and the language switch above.
      return ResponsiveCenter(
        maxWidth: 760,
        child: EmptyState(
          key: const ValueKey('statements-error'),
          icon: Icons.cloud_off_outlined,
          title: 'Couldn\'t load your statements',
          message: errorText(_error!),
          action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => _load(reset: true),
            child: const Text('Try again'),
          ),
        ),
      );
    }
    if (_periods.isEmpty) {
      return const EmptyState(
        icon: Icons.description_outlined,
        title: 'No statements yet',
        message: 'Statements start from the week you joined as a driver.',
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        key: ValueKey('statements-${widget.type.name}'),
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        itemCount: _periods.length + (_more ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == _periods.length) {
            return Center(
              child: _loading
                  ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())
                  : TextButton(
                      key: const ValueKey('statements-more'),
                      onPressed: _load,
                      child: const Text('Show earlier'),
                    ),
            );
          }
          final p = _periods[i];
          final busy = _opening == '${p.type.name}-${isoDate(p.start)}';
          return ResponsiveCenter(
            maxWidth: 760,
            child: Card(
              child: ListTile(
                key: ValueKey('statement-${p.type.name}-${isoDate(p.start)}'),
                // The period on up to two lines, its status beside it or,
                // with no room, under it.
                title: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(p.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                    _StatusChip(p.status),
                  ],
                ),
                subtitle: Text(
                  '${p.trips == 1 ? '1 trip' : '${p.trips} trips'} · net ${formatMoney(p.net)}',
                  style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                ),
                trailing: busy
                    ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Icon(Icons.picture_as_pdf_outlined),
                onTap: busy || _opening != null ? null : () => _open(p),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TaxPin extends ConsumerStatefulWidget {
  const _TaxPin({required this.year, required this.lang});
  final int year;
  final StatementLang lang;

  @override
  ConsumerState<_TaxPin> createState() => _TaxPinState();
}

class _TaxPinState extends ConsumerState<_TaxPin> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final period = StatementPeriod(
      type: StatementType.annual,
      start: DateTime.utc(widget.year),
      end: DateTime.utc(widget.year, 12, 31),
      status: StatementStatus.finalised,
      net: 0,
      trips: 0,
    );
    return Card(
      key: const ValueKey('statements-tax-pin'),
      color: c.secondaryContainer,
      child: ListTile(
        leading: Icon(Icons.push_pin_outlined, color: c.onSecondaryContainer),
        title: Text('${widget.year} annual statement', style: TextStyle(color: c.onSecondaryContainer)),
        subtitle: Text(
          'For your income tax return (Borang B/BE)',
          style: TextStyle(color: c.onSecondaryContainer.withValues(alpha: 0.8)),
        ),
        trailing: _busy
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
            : Icon(Icons.picture_as_pdf_outlined, color: c.onSecondaryContainer),
        onTap: _busy
            ? null
            : () async {
                setState(() => _busy = true);
                try {
                  await openStatement(context, ref, period, widget.lang);
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
      ),
    );
  }
}

class _PayoutAccountTile extends ConsumerWidget {
  const _PayoutAccountTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(payoutAccountProvider).value;
    final last4 = a == null || a.account.length < 4 ? '' : a.account.substring(a.account.length - 4);
    return Card(
      key: const ValueKey('statements-payout'),
      child: ListTile(
        leading: const Icon(Icons.account_balance_outlined),
        title: Text(a == null ? 'Add your payout account' : '${a.bank} ****$last4'),
        subtitle: const Text('Shown on your statements'),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => _edit(context, ref, a),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, PayoutAccount? a) async {
    final saved = await showAppDialog<bool>(id: 'statements.edit',
      context: context,
      builder: (_) => _PayoutAccountDialog(current: a),
    );
    if (saved == true) ref.invalidate(payoutAccountProvider);
  }
}

class _PayoutAccountDialog extends ConsumerStatefulWidget {
  const _PayoutAccountDialog({this.current});
  final PayoutAccount? current;

  @override
  ConsumerState<_PayoutAccountDialog> createState() => _PayoutAccountDialogState();
}

class _PayoutAccountDialogState extends ConsumerState<_PayoutAccountDialog> {
  late final _bank = TextEditingController(text: widget.current?.bank);
  late final _account = TextEditingController(text: widget.current?.account);
  late final _holder = TextEditingController(text: widget.current?.holder);
  final _form = GlobalKey<FormState>();
  bool _saving = false;

  @override
  void dispose() {
    _bank.dispose();
    _account.dispose();
    _holder.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(partnerStatementRepositoryProvider).savePayoutAccount(_bank.text, _account.text, _holder.text);
      if (mounted) Navigator.pop(context, true);
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
      title: const Text('Payout account'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const ValueKey('payout-bank'),
              controller: _bank,
              decoration: const InputDecoration(labelText: 'Bank'),
              validator: required,
            ),
            TextFormField(
              key: const ValueKey('payout-account'),
              controller: _account,
              decoration: const InputDecoration(labelText: 'Account number'),
              keyboardType: TextInputType.number,
              validator: (v) => payoutAccountError(v ?? ''),
            ),
            TextFormField(
              key: const ValueKey('payout-holder'),
              controller: _holder,
              decoration: const InputDecoration(labelText: 'Account holder'),
              validator: required,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('payout-save'), onPressed: _saving ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
