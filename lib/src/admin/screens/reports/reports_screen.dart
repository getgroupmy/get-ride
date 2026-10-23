// Admin > Reports (migration 0280). The admin types what report they need
// (or taps an example); the AI service set in API Keys turns it into a
// report plan from the approved datasets (the ai-report function, which
// never shows the AI any data); the page says in plain words what it
// understood, runs it (ai_report_run, checked again by the server and
// limited to the admin's region and People pages), draws a preview chart
// and the table with its total, and downloads it as CSV, Excel or PDF. The
// columns can be changed without the AI; a report can be saved, run again
// for another period, and emailed on a schedule (report_schedule_page.dart).
// Read on the Reports page (admin-reports) or by a full admin; saving and
// schedules need edit.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ai_report.dart';
import '../../../data/ai_report_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/date_boxes.dart';
import '../../../widgets/image_share.dart' show shareOriginOf;
import '../../../widgets/page_style_host.dart';
import '../../../widgets/pdf_actions.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'report_export.dart';
import 'report_schedule_page.dart';
import 'report_widgets.dart';

/// Tapped into the box as they are.
const reportExamples = [
  'Top 20 drivers by trips this month',
  'Cancelled rides by reason, last 7 days',
  'Commission collected per week, 2026',
  'New users per day this month',
  'SOS incidents with response time',
];

class AdminReportsScreen extends ConsumerWidget {
  const AdminReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AdminPage(
    title: 'Reports',
    module: 'reports',
    body: ref.watch(reportCatalogueProvider).when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(icon: Icons.error_outline, title: "Couldn't open Reports", message: reportErrorText(e)),
      data: (cat) => ReportsBody(catalogue: cat),
    ),
  );
}

/// The period choices of the result and of "Run again with".
const _periodChoices = <String, String>{
  'asis': 'As planned',
  'today': 'Today',
  'yesterday': 'Yesterday',
  'last_7_days': 'The last 7 days',
  'last_30_days': 'The last 30 days',
  'this_week': 'This week',
  'last_week': 'Last week',
  'this_month': 'This month',
  'last_month': 'Last month',
  'this_year': 'This year',
  'last_year': 'Last year',
  'all': 'All time',
  'pick': 'Pick dates',
};

class ReportsBody extends ConsumerStatefulWidget {
  const ReportsBody({super.key, required this.catalogue});
  final ReportCatalogue catalogue;

  @override
  ConsumerState<ReportsBody> createState() => _ReportsBodyState();
}

class _ReportsBodyState extends ConsumerState<ReportsBody> {
  final _ask = TextEditingController();
  final _askFocus = FocusNode();
  ReportPlan? _plan;
  ReportResult? _result;
  String? _request;
  String? _name;
  String? _problem;
  bool _asking = false;
  bool _running = false;

  ReportCatalogue get _cat => widget.catalogue;

  @override
  void dispose() {
    _ask.dispose();
    _askFocus.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    final words = _ask.text.trim();
    if (words.length < 3) {
      setState(() => _problem = 'Type what report you need, or tap an example.');
      return;
    }
    setState(() {
      _asking = true;
      _problem = null;
    });
    final answer = await ref.read(aiReportRepositoryProvider).ask(words);
    if (!mounted) return;
    setState(() => _asking = false);
    if (answer.plan == null) {
      setState(() => _problem = answer.reason ?? "The AI couldn't make a report of that.");
      return;
    }
    _request = words;
    _name = null;
    await _run(answer.plan!);
  }

  Future<void> _run(ReportPlan plan) async {
    setState(() {
      _plan = plan;
      _running = true;
      _problem = null;
    });
    try {
      final r = await ref.read(aiReportRepositoryProvider).run(plan);
      if (!mounted) return;
      setState(() {
        _result = r;
        _plan = r.plan;
      });
    } catch (e) {
      if (mounted) setState(() => _problem = reportErrorText(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Without the AI: a dataset's usual list, to change from there.
  Future<void> _byHand() async {
    final id = await showSearchPicker<String>(
      context,
      title: 'Which data?',
      choices: [for (final d in _cat.datasets) (value: d.id, label: d.label, subtitle: d.about, leading: null)],
    );
    if (id == null || !mounted) return;
    _request = null;
    _name = null;
    await _run(ReportPlan(dataset: id, period: const ReportPeriod.preset('last_30_days')));
  }

  /// A period for [plan] from a choice; null when cancelled.
  Future<(ReportPeriod?, bool)?> _periodFor(String choice, ReportPlan plan) async {
    switch (choice) {
      case 'asis':
        return (plan.period, false);
      case 'all':
        return (null, true);
      case 'pick':
        final p = await pickReportDates(context, initial: plan.period, now: ref.read(reportClockProvider)());
        return p == null ? null : (p.withField(plan.period?.field), false);
      default:
        return (ReportPeriod.preset(choice, field: plan.period?.field), false);
    }
  }

  Future<void> _changePeriod(String? choice) async {
    final plan = _plan;
    if (choice == null || plan == null) return;
    final p = await _periodFor(choice, plan);
    if (p == null || !mounted) return;
    await _run(plan.copyWith(period: p.$1, clearPeriod: p.$2));
  }

  Future<void> _changeColumns() async {
    final plan = _plan;
    final ds = plan == null ? null : _cat.dataset(plan.dataset);
    if (plan == null || ds == null) return;
    final next = await showAppSheet<ReportPlan>(id: 'admin-reports.change-columns',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ReportColumnsSheet(plan: plan, dataset: ds, catalogue: _cat),
    );
    if (next != null && mounted) await _run(next);
  }

  String get _title {
    final r = _result;
    final p = _plan;
    return _name ?? (p?.title.isNotEmpty == true ? p!.title : '${r?.datasetLabel ?? 'Report'} report');
  }

  String get _periodText {
    final r = _result;
    final p = r?.period;
    final words = periodWords(r?.plan.period);
    return p == null
        ? 'All time'
        : r?.plan.period?.preset == null
        ? '$words (Malaysia time)'
        : '$words: ${shortDay(p.from)} to ${shortDay(p.to)} (Malaysia time)';
  }

  String _madeAt() {
    final m = ref.read(reportClockProvider)().toUtc().add(const Duration(hours: 8));
    return '${isoDay(m)} ${m.hour.toString().padLeft(2, '0')}:${m.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _download(String kind, BuildContext button) async {
    final r = _result;
    if (r == null) return;
    final base = reportFileBase(_title, r.period);
    final understood = describeReportPlan(r.plan, _cat, resolved: r.period, columns: r.columns);
    final origin = shareOriginOf(button);
    if (kind == 'pdf') {
      await sharePdfOrDownload(
        context,
        filename: '$base.pdf',
        title: 'The report as a PDF',
        build: () async =>
            buildReportPdf(r, title: _title, period: _periodText, madeAt: _madeAt(), logo: await reportLogo()),
      );
      return;
    }
    final (bytes, name, mime) = kind == 'csv'
        ? (reportCsvBytes(r), '$base.csv', csvMime)
        : (reportXlsx(r, understood), '$base.xlsx', xlsxMime);
    final out = await ref.read(reportFileSaverProvider)(bytes, name, mime, origin);
    if (!mounted) return;
    switch (out) {
      case ReportFileOutcome.downloaded:
        showInfo(context, 'Downloaded $name');
      case ReportFileOutcome.failed:
        showInfo(context, "Couldn't save $name.");
      case ReportFileOutcome.shared:
        break;
    }
  }

  Future<void> _save() async {
    final plan = _plan;
    if (plan == null) return;
    final name = await askReportName(context, initial: _title);
    if (name == null || !mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(aiReportRepositoryProvider).save(name: name, plan: plan, request: _request),
      success: 'Saved "$name"',
    );
    if (ok && mounted) {
      setState(() => _name = name);
      ref.invalidate(savedReportsProvider);
    }
  }

  Future<void> _openSaved(SavedReport s, String choice) async {
    final p = await _periodFor(choice, s.plan);
    if (p == null || !mounted) return;
    _request = s.request;
    _name = s.name;
    if (s.request != null) _ask.text = s.request!;
    await _run(s.plan.copyWith(period: p.$1, clearPeriod: p.$2));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final services = ref.watch(reportServicesProvider).value;
    final canEdit = ref.watch(moduleAccessProvider('reports')) == AccessLevel.edit;
    final region = _cat.regionLabel;
    final r = _result;
    final plan = _plan;
    final ds = plan == null ? null : _cat.dataset(plan.dataset);
    final bars = r?.chartBars();
    final firstMeasure = r?.columns.where((c) => c.isMeasure && c.isNumber).firstOrNull;
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 40),
      children: [
        ResponsiveCenter(
          maxWidth: 980,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (region != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    region.isEmpty
                        ? 'Your Reports access has no region yet: rides, partners, vehicles, SOS and ratings show '
                              'nothing until a full admin sets one under Sub-admins.'
                        : 'Rides, partners, vehicles, SOS and ratings: only $region.',
                    key: const ValueKey('reports-region'),
                    style: t.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ReportCard(
                children: [
                  Text('What report do you need?', style: t.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('reports-ask'),
                    controller: _ask,
                    focusNode: _askFocus,
                    minLines: 2,
                    maxLines: 5,
                    maxLength: 1000,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      hintText: 'Completed rides and fares per city for the last 30 days, highest first',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (i, e) in reportExamples.indexed)
                        ActionChip(
                          key: ValueKey('reports-example-$i'),
                          label: Text(e),
                          onPressed: () => setState(() => _ask.text = e),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('reports-make'),
                        style: reportButtonStyle,
                        onPressed: _asking || _running ? null : _make,
                        icon: _asking
                            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_awesome_outlined),
                        label: const Text('Make report'),
                      ),
                      OutlinedButton(
                        key: const ValueKey('reports-by-hand'),
                        onPressed: _asking || _running ? null : _byHand,
                        child: const Text('Start without the AI'),
                      ),
                      Text(
                        'Uses the AI service set in API Keys. Only data your admin access allows.',
                        style: t.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                  if (services != null && !services.aiReady)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'No AI service is set up yet: add a key for the AI service in API Keys. '
                        'You can still start without the AI.',
                        key: const ValueKey('reports-no-ai'),
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
                      ),
                    ),
                  if (_problem != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_problem!, key: const ValueKey('reports-problem'), style: TextStyle(color: t.colorScheme.error)),
                    ),
                ],
              ),
              if (plan != null) ...[
                const SizedBox(height: 14),
                ReportCard(
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        Text(_request == null ? 'The report' : 'What the AI understood', style: t.textTheme.titleSmall),
                        const ReportTag('Checked by the server'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ReportPlanLines(
                      lines: describeReportPlan(plan, _cat, resolved: r?.period, columns: r?.columns ?? const []),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_request != null)
                          OutlinedButton(
                            key: const ValueKey('reports-edit-request'),
                            onPressed: () => _askFocus.requestFocus(),
                            child: const Text('Edit the request'),
                          ),
                        OutlinedButton(
                          key: const ValueKey('reports-change-columns'),
                          onPressed: _running || ds == null ? null : _changeColumns,
                          child: const Text('Change columns'),
                        ),
                        SizedBox(
                          width: 220,
                          child: SearchableDropdownFormField<String>(
                            key: ValueKey('reports-period-${plan.period?.toJson()}'),
                            initialValue: 'asis',
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: 'Period', isDense: true, border: OutlineInputBorder()),
                            items: [
                              for (final e in _periodChoices.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                            ],
                            onChanged: _running ? null : _changePeriod,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_running)
                      const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                    else if (r != null) ...[
                      if (bars != null && firstMeasure != null) ...[
                        ReportBars(bars: bars, measureLabel: firstMeasure.label),
                        const SizedBox(height: 12),
                      ],
                      if (r.rows.isEmpty)
                        Text('Nothing matches this report.', key: const ValueKey('reports-empty'), style: TextStyle(color: muted))
                      else
                        ReportTable(result: r),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (kind, label) in const [('csv', 'Download CSV'), ('xlsx', 'Download Excel (.xlsx)'), ('pdf', 'Download PDF')])
                            Builder(
                              builder: (button) => FilledButton.tonal(
                                key: ValueKey('reports-download-$kind'),
                                style: reportButtonStyle,
                                onPressed: r.columns.isEmpty ? null : () => _download(kind, button),
                                child: Text(label),
                              ),
                            ),
                          if (canEdit)
                            OutlinedButton.icon(
                              key: const ValueKey('reports-save'),
                              onPressed: _save,
                              icon: const Icon(Icons.bookmark_add_outlined),
                              label: const Text('Save this report'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 14),
              SavedReportsCard(catalogue: _cat, onOpen: _openSaved, periodChoices: _periodChoices),
            ],
          ),
        ),
      ],
    );
  }
}

/// The name a report is saved under; null when cancelled.
Future<String?> askReportName(BuildContext context, {required String initial}) {
  final c = TextEditingController(text: initial);
  return showAppDialog<String>(id: 'admin-reports.save-name',
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Save this report'),
      content: TextField(
        key: const ValueKey('reports-save-name'),
        controller: c,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (v) => v.trim().isEmpty ? null : Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('reports-save-confirm'),
          onPressed: () => c.text.trim().isEmpty ? null : Navigator.pop(ctx, c.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  ).whenComplete(c.dispose);
}

/// "Pick dates": a from and a to day, typed in boxes or from the calendar.
Future<ReportPeriod?> pickReportDates(BuildContext context, {ReportPeriod? initial, required DateTime now}) {
  final today = malaysiaDay(now);
  final range = initial == null ? null : periodDays(initial, now);
  final from = TextEditingController(text: isoDay(range?.from ?? today.subtract(const Duration(days: 6))));
  final to = TextEditingController(text: isoDay(range?.to ?? today));
  final form = GlobalKey<FormState>();
  return showAppDialog<ReportPeriod>(id: 'admin-reports.pick-dates',
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Pick dates'),
      content: Form(
        key: form,
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DateBoxesField(
                key: const ValueKey('reports-from'),
                label: 'From',
                controller: from,
                isRequired: true,
                firstDate: DateTime(2015),
                lastDate: today,
              ),
              const SizedBox(height: 12),
              DateBoxesField(
                key: const ValueKey('reports-to'),
                label: 'To',
                controller: to,
                isRequired: true,
                firstDate: DateTime(2015),
                lastDate: today,
                validator: (d) {
                  final f = parseIsoDay(from.text);
                  return d != null && f != null && d.isBefore(f) ? 'The end is before the start' : null;
                },
              ),
              const SizedBox(height: 8),
              Text('Malaysia time, both days included.', style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('reports-dates-ok'),
          onPressed: () {
            if (!(form.currentState?.validate() ?? false)) return;
            final f = parseIsoDay(from.text), t = parseIsoDay(to.text);
            if (f != null && t != null) Navigator.pop(ctx, ReportPeriod.dates(f, t));
          },
          child: const Text('Run'),
        ),
      ],
    ),
  ).whenComplete(() {
    from.dispose();
    to.dispose();
  });
}

/// "Change columns": the groups and figures (or a list's columns) ticked
/// on and off from the catalogue, without the AI.
class ReportColumnsSheet extends StatefulWidget {
  const ReportColumnsSheet({super.key, required this.plan, required this.dataset, required this.catalogue});
  final ReportPlan plan;
  final ReportDataset dataset;
  final ReportCatalogue catalogue;

  @override
  State<ReportColumnsSheet> createState() => _ReportColumnsSheetState();
}

class _ReportColumnsSheetState extends State<ReportColumnsSheet> {
  late ReportPlan _plan = widget.plan;

  static const _figureAggs = [('sum', 'Total'), ('avg', 'Average'), ('min', 'Lowest'), ('max', 'Highest')];

  bool _matches(String q, String label) => q.isEmpty || label.toLowerCase().contains(q.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ds = widget.dataset;
    final groupsFull = _plan.groupBy.length >= widget.catalogue.maxGroupBy;
    final measuresFull = _plan.measures.length >= widget.catalogue.maxMeasures;
    Widget heading(String s) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(s, style: t.textTheme.titleSmall),
    );
    final list = _plan.isList;
    final shown = list && _plan.columns.isEmpty ? ds.list : _plan.columns;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: ListSearchFilter(
          count: ds.fields.length,
          hint: 'Search the fields',
          builder: (context, q) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Change columns: ${ds.label}', style: t.textTheme.titleMedium),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      heading('Group by (at most ${widget.catalogue.maxGroupBy})'),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final f in ds.fields.where((f) => _matches(q, f.label)))
                            if (f.isTime)
                              for (final b in widget.catalogue.buckets)
                                FilterChip(
                                  key: ValueKey('reports-group-${f.id}:$b'),
                                  label: Text('${f.label}, by $b'),
                                  selected: _plan.groupBy.contains('${f.id}:$b'),
                                  onSelected: groupsFull && !_plan.groupBy.contains('${f.id}:$b')
                                      ? null
                                      : (_) => setState(() => _plan = _plan.toggleGroup('${f.id}:$b')),
                                )
                            else if (!f.isNumber)
                              FilterChip(
                                key: ValueKey('reports-group-${f.id}'),
                                label: Text(f.label),
                                selected: _plan.groupBy.contains(f.id),
                                onSelected: groupsFull && !_plan.groupBy.contains(f.id)
                                    ? null
                                    : (_) => setState(() => _plan = _plan.toggleGroup(f.id)),
                              ),
                        ],
                      ),
                      heading('Figures (at most ${widget.catalogue.maxMeasures})'),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (_matches(q, 'Count'))
                            FilterChip(
                              key: const ValueKey('reports-measure-count'),
                              label: const Text('Count'),
                              selected: _plan.measures.contains(ReportMeasure.count),
                              onSelected: measuresFull && !_plan.measures.contains(ReportMeasure.count)
                                  ? null
                                  : (_) => setState(() => _plan = _plan.toggleMeasure(ReportMeasure.count)),
                            ),
                          for (final f in ds.fields.where((f) => f.isNumber && _matches(q, f.label)))
                            for (final (agg, word) in _figureAggs)
                              FilterChip(
                                key: ValueKey('reports-measure-${agg}_${f.id}'),
                                label: Text('$word ${f.label.isEmpty ? f.id : f.label[0].toLowerCase() + f.label.substring(1)}'),
                                selected: _plan.measures.contains(ReportMeasure(f.id, agg)),
                                onSelected: measuresFull && !_plan.measures.contains(ReportMeasure(f.id, agg))
                                    ? null
                                    : (_) => setState(() => _plan = _plan.toggleMeasure(ReportMeasure(f.id, agg))),
                              ),
                        ],
                      ),
                      if (_plan.isList) ...[
                        heading('Columns of the list'),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final f in ds.fields.where((f) => _matches(q, f.label)))
                              FilterChip(
                                key: ValueKey('reports-column-${f.id}'),
                                label: Text(f.label),
                                selected: shown.contains(f.id),
                                onSelected: (on) => setState(() {
                                  final next = [...shown.where((c) => c != f.id), if (on) f.id];
                                  _plan = _plan.copyWith(columns: next, sort: const []);
                                }),
                              ),
                          ],
                        ),
                      ],
                      if (!list && _plan.isList)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text('No groups and no figures: the report lists the rows.', style: t.textTheme.bodySmall),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('reports-columns-apply'),
                    style: reportButtonStyle,
                    onPressed: () => Navigator.pop(context, _plan),
                    child: const Text('Run'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Saved reports: run again for another period, email on a schedule.
class SavedReportsCard extends ConsumerWidget {
  const SavedReportsCard({super.key, required this.catalogue, required this.onOpen, required this.periodChoices});
  final ReportCatalogue catalogue;
  final Future<void> Function(SavedReport saved, String choice) onOpen;
  final Map<String, String> periodChoices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final canEdit = ref.watch(moduleAccessProvider('reports')) == AccessLevel.edit;
    final saved = ref.watch(savedReportsProvider);
    final schedules = ref.watch(reportSchedulesProvider).value ?? const <ReportSchedule>[];
    final services = ref.watch(reportServicesProvider).value;
    return ReportCard(
      children: [
        Text('Saved reports', style: t.textTheme.titleSmall),
        if (services != null && schedules.isNotEmpty && !services.emailReady)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              services.emailKeySet
                  ? "The email sender isn't a valid address: set it under Email sender below."
                  : "Email isn't set up yet: add the email key in API Keys (Email > Resend).",
              key: const ValueKey('reports-no-email'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
            ),
          ),
        const SizedBox(height: 6),
        saved.when(
          skipLoadingOnReload: true,
          loading: () => const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text(reportErrorText(e), style: TextStyle(color: t.colorScheme.error)),
          data: (list) => list.isEmpty
              ? Text(
                  canEdit ? 'None yet. Make a report, then Save this report.' : 'None yet.',
                  key: const ValueKey('reports-saved-none'),
                  style: TextStyle(color: muted),
                )
              : ListSearchFilter(
                  count: list.length,
                  hint: 'Search saved reports',
                  fieldKey: const ValueKey('reports-saved-search'),
                  builder: (context, q) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final s in list.where((s) => q.isEmpty || s.name.toLowerCase().contains(q.toLowerCase())))
                        _SavedRow(
                          saved: s,
                          catalogue: catalogue,
                          schedules: [for (final x in schedules) if (x.savedId == s.id) x],
                          canEdit: canEdit,
                          onOpen: onOpen,
                          periodChoices: periodChoices,
                        ),
                    ],
                  ),
                ),
        ),
        if (canEdit) ...[const Divider(height: 24), const EmailSenderRow()],
      ],
    );
  }
}

class _SavedRow extends ConsumerWidget {
  const _SavedRow({
    required this.saved,
    required this.catalogue,
    required this.schedules,
    required this.canEdit,
    required this.onOpen,
    required this.periodChoices,
  });
  final SavedReport saved;
  final ReportCatalogue catalogue;
  final List<ReportSchedule> schedules;
  final bool canEdit;
  final Future<void> Function(SavedReport saved, String choice) onOpen;
  final Map<String, String> periodChoices;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      'Delete "${saved.name}"?',
      schedules.isEmpty ? 'The saved report goes.' : 'The saved report and its ${schedules.length} email schedule(s) go.',
      ok: 'Delete',
    );
    if (!ok || !context.mounted) return;
    final done = await runAdminAction(context, () => ref.read(aiReportRepositoryProvider).deleteSaved(saved.id), success: 'Deleted');
    if (done) {
      ref.invalidate(savedReportsProvider);
      ref.invalidate(reportSchedulesProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final last = saved.lastRunAt;
    return Padding(
      key: ValueKey('reports-saved-${saved.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(saved.name, style: t.textTheme.bodyLarge),
                  Text(
                    [
                      catalogue.dataset(saved.plan.dataset)?.label ?? saved.plan.dataset,
                      periodWords(saved.plan.period),
                      if (last != null) 'last emailed ${formatDateForUser(last.toLocal())}',
                    ].join(' · '),
                    style: t.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 200,
                    child: SearchableDropdownFormField<String>(
                      key: ValueKey('reports-run-again-${saved.id}'),
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Run again with', isDense: true, border: OutlineInputBorder()),
                      items: [
                        for (final e in periodChoices.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.key == 'asis' ? 'As saved' : e.value)),
                      ],
                      onChanged: (v) => v == null ? null : onOpen(saved, v),
                    ),
                  ),
                  if (canEdit) ...[
                    IconButton(
                      key: ValueKey('reports-schedule-add-${saved.id}'),
                      tooltip: 'Email it on a schedule',
                      icon: const Icon(Icons.schedule_send_outlined),
                      onPressed: () => openReportSchedule(context, saved: saved),
                    ),
                    IconButton(
                      key: ValueKey('reports-saved-delete-${saved.id}'),
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(context, ref),
                    ),
                  ],
                ],
              ),
            ],
          ),
          for (final s in schedules) ReportScheduleTile(schedule: s, saved: saved, canEdit: canEdit),
          const Divider(height: 12),
        ],
      ),
    );
  }
}

/// The address the emails come from (ai_report_settings).
class EmailSenderRow extends ConsumerStatefulWidget {
  const EmailSenderRow({super.key});

  @override
  ConsumerState<EmailSenderRow> createState() => _EmailSenderRowState();
}

class _EmailSenderRowState extends ConsumerState<EmailSenderRow> {
  final _from = TextEditingController();
  bool _loaded = false;

  @override
  void dispose() {
    _from.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(reportServicesProvider).value;
    if (!_loaded && services != null) {
      _loaded = true;
      _from.text = services.emailFrom ?? '';
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('reports-email-from'),
            controller: _from,
            decoration: const InputDecoration(
              labelText: 'Email sender',
              helperText: 'Its domain must be verified with the email service, e.g. GET.ride Reports <reports@getride.my>',
              helperMaxLines: 2,
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: const ValueKey('reports-email-from-save'),
          onPressed: () async {
            final ok = await runAdminAction(
              context,
              () => ref.read(aiReportRepositoryProvider).setEmailFrom(_from.text),
              success: 'Sender saved',
            );
            if (ok) ref.invalidate(reportServicesProvider);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
