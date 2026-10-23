// Admin > Reports > a saved report > Email it on a schedule (migration
// 0280). When (every day, chosen weekdays or a day of the month, 1 to 28 or
// the last day, at a time; Malaysia time, the next run shown), the period
// each run covers, who gets it (addresses and admins), the files (CSV,
// Excel, PDF, attached or as links valid 7 days), the subject and message
// ({report}, {period}, {rows}), skip when empty, pause and "Send now". The
// database sends it on time (ai_report_schedules_due, every 5 minutes) with
// the ai-report-email function.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ai_report.dart';
import '../../../data/ai_report_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../widgets/admin_widgets.dart';
import 'report_widgets.dart';

/// "Mon 26 Oct 2026, 08:00" in Malaysia time.
String mytWords(DateTime at) {
  final m = at.toUtc().add(const Duration(hours: 8));
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${days[m.weekday - 1]} ${shortDay(DateTime(m.year, m.month, m.day))}, '
      '${m.hour.toString().padLeft(2, '0')}:${m.minute.toString().padLeft(2, '0')}';
}

/// Opens the schedule editor for [saved] ([existing] to change one).
Future<void> openReportSchedule(BuildContext context, {required SavedReport saved, ReportSchedule? existing}) async {
  final changed = await Navigator.of(context).push<bool>(AppPageRoute(id: 'admin-reports.schedule',
    builder: (_) => ReportSchedulePage(saved: saved, existing: existing),
  ));
  if (changed == true && context.mounted) {
    ProviderScope.containerOf(context).invalidate(reportSchedulesProvider);
  }
}

/// A schedule under its saved report: when, what it covers, who, how it went.
class ReportScheduleTile extends ConsumerWidget {
  const ReportScheduleTile({super.key, required this.schedule, required this.saved, required this.canEdit});
  final ReportSchedule schedule;
  final SavedReport saved;
  final bool canEdit;

  Future<void> _sendNow(BuildContext context, WidgetRef ref) async {
    try {
      final posted = await ref.read(aiReportRepositoryProvider).sendNow(schedule.id);
      if (!context.mounted) return;
      showInfo(context, posted ? 'Sending now. The result shows here in a minute.' : 'Sent in the last minute: try again shortly.');
    } catch (e) {
      if (context.mounted) showInfo(context, reportErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final s = schedule;
    final who = s.emails.length + s.adminIds.length;
    final status = switch (s.lastStatus) {
      'sent' => 'Last sent ${s.lastRunAt == null ? '' : mytWords(s.lastRunAt!)}',
      'skipped' => 'Last run skipped: nothing to send',
      'failed' => 'Last run failed: ${s.lastError ?? 'unknown reason'}',
      _ => 'Not sent yet',
    };
    return Container(
      key: ValueKey('reports-schedule-${s.id}'),
      margin: const EdgeInsets.only(top: 6, left: 12),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: t.colorScheme.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${scheduleWords(s.timing)} (Malaysia time)', style: t.textTheme.bodyMedium),
                Text(
                  [
                    s.paused ? 'Paused' : 'Next: ${s.nextRunAt == null ? '—' : mytWords(s.nextRunAt!)}',
                    periodWords(s.period),
                    '$who recipient${who == 1 ? '' : 's'}',
                    s.formats.map((f) => scheduleFormats[f] ?? f).join(', ') + (s.linkOnly ? ' as links' : ''),
                  ].join(' · '),
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                Text(
                  status,
                  style: t.textTheme.bodySmall?.copyWith(color: s.lastStatus == 'failed' ? t.colorScheme.error : muted),
                ),
              ],
            ),
          ),
          if (canEdit) ...[
            Switch(
              key: ValueKey('reports-schedule-on-${s.id}'),
              value: !s.paused,
              onChanged: (on) async {
                final ok = await runAdminAction(
                  context,
                  () => ref.read(aiReportRepositoryProvider).setPaused(s.id, !on),
                  success: on ? 'Resumed' : 'Paused',
                );
                if (ok) ref.invalidate(reportSchedulesProvider);
              },
            ),
            PopupMenuButton<String>(
              key: ValueKey('reports-schedule-menu-${s.id}'),
              tooltip: 'More',
              onSelected: (v) async {
                switch (v) {
                  case 'now':
                    await _sendNow(context, ref);
                  case 'edit':
                    await openReportSchedule(context, saved: saved, existing: s);
                  case 'delete':
                    final yes = await confirm(context, 'Stop this email?', 'The schedule is deleted. The saved report stays.', ok: 'Delete');
                    if (!yes || !context.mounted) return;
                    final ok = await runAdminAction(
                      context,
                      () => ref.read(aiReportRepositoryProvider).deleteSchedule(s.id),
                      success: 'Schedule deleted',
                    );
                    if (ok) ref.invalidate(reportSchedulesProvider);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'now', child: Text('Send now')),
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class ReportSchedulePage extends ConsumerStatefulWidget {
  const ReportSchedulePage({super.key, required this.saved, this.existing});
  final SavedReport saved;
  final ReportSchedule? existing;

  @override
  ConsumerState<ReportSchedulePage> createState() => _ReportSchedulePageState();
}

class _ReportSchedulePageState extends ConsumerState<ReportSchedulePage> {
  late final ReportSchedule? _e = widget.existing;
  late ScheduleFrequency _frequency = _e?.timing.frequency ?? ScheduleFrequency.weekly;
  late TimeOfDay _at = TimeOfDay(hour: _e?.timing.hour ?? 8, minute: _e?.timing.minute ?? 0);
  late Set<int> _weekdays = {...?_e?.timing.weekdays, if (_e == null) 1};
  late int _monthDay = _e?.timing.monthDay ?? 1;
  late String _period = _e?.period.preset ?? 'previous_week';
  late final _days = TextEditingController(text: '${_e?.period.days ?? 7}');
  late final _emails = TextEditingController(text: (_e?.emails ?? const []).join(', '));
  late Set<String> _admins = {...?_e?.adminIds};
  late Set<String> _formats = {...?_e?.formats, if (_e == null) ...['csv', 'xlsx']};
  late bool _linkOnly = _e?.linkOnly ?? false;
  late final _subject = TextEditingController(text: _e?.subject ?? '{report} for {period}');
  late final _message = TextEditingController(text: _e?.message ?? '');
  late bool _skipEmpty = _e?.skipEmpty ?? false;
  late bool _paused = _e?.paused ?? false;
  List<ReportAdmin>? _adminList;
  String? _problem;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    ref.read(aiReportRepositoryProvider).admins().then((a) {
      if (mounted) setState(() => _adminList = a);
    }).catchError((Object _) {
      if (mounted) setState(() => _adminList = const []);
    });
  }

  @override
  void dispose() {
    _days.dispose();
    _emails.dispose();
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  ScheduleTiming get _timing =>
      ScheduleTiming(frequency: _frequency, hour: _at.hour, minute: _at.minute, weekdays: _weekdays, monthDay: _monthDay);

  ReportPeriod get _periodValue => _period == 'last_n_days'
      ? ReportPeriod.preset('last_n_days', days: int.tryParse(_days.text.trim()))
      : ReportPeriod.preset(_period);

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _at,
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t != null && mounted) setState(() => _at = t);
  }

  Future<void> _pickAdmins() async {
    final list = _adminList ?? const <ReportAdmin>[];
    final picked = await showAppSheet<Set<String>>(id: 'admin-reports.pick-admins',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _AdminPicker(admins: list, selected: _admins),
    );
    if (picked != null && mounted) setState(() => _admins = picked);
  }

  Future<void> _save() async {
    final mails = parseEmails(_emails.text);
    final days = int.tryParse(_days.text.trim());
    final problem = mails.bad.isNotEmpty
        ? 'Not an email address: ${mails.bad.join(', ')}'
        : mails.ok.length > 20
        ? 'At most 20 addresses.'
        : mails.ok.isEmpty && _admins.isEmpty
        ? 'Add at least one email address or admin.'
        : _formats.isEmpty
        ? 'Pick at least one file: CSV, Excel or PDF.'
        : _frequency == ScheduleFrequency.weekly && _weekdays.isEmpty
        ? 'Pick at least one day of the week.'
        : _period == 'last_n_days' && (days == null || days < 1 || days > 366)
        ? 'The number of days is from 1 to 366.'
        : _subject.text.trim().isEmpty
        ? 'Give the email a subject.'
        : null;
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    setState(() {
      _problem = null;
      _saving = true;
    });
    final s = ReportSchedule(
      id: _e?.id ?? '',
      savedId: widget.saved.id,
      timing: _timing,
      period: _periodValue,
      emails: mails.ok,
      adminIds: _admins.toList(),
      formats: [for (final f in scheduleFormats.keys) if (_formats.contains(f)) f],
      linkOnly: _linkOnly,
      subject: _subject.text.trim(),
      message: _message.text.trim(),
      skipEmpty: _skipEmpty,
      paused: _paused,
    );
    try {
      await ref.read(aiReportRepositoryProvider).saveSchedule(s, isNew: _e == null);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _problem = reportErrorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final services = ref.watch(reportServicesProvider).value;
    final now = ref.watch(reportClockProvider)();
    final next = nextScheduleRun(_timing, now);
    final covers = periodDays(_periodValue, next ?? now);
    Widget heading(String s) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(s, style: t.textTheme.titleSmall),
    );
    final adminNames = {for (final a in _adminList ?? const <ReportAdmin>[]) a.id: a.name.isEmpty ? a.email : a.name};
    return Scaffold(
      appBar: AppBar(title: Text(_e == null ? 'Email on a schedule' : 'Change the schedule')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 40),
        children: [
          ResponsiveCenter(
            maxWidth: 720,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.saved.name, style: t.textTheme.titleMedium),
                if (services != null && !services.emailReady)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ReportCard(
                      children: [
                        Text(
                          services.emailKeySet
                              ? "The email sender isn't a valid address: set it on Reports under Email sender."
                              : "Email isn't set up yet: add the email key in API Keys (Email > Resend). "
                                    'The schedule can be saved now and sends once it is set up.',
                          key: const ValueKey('schedule-no-email'),
                          style: TextStyle(color: t.colorScheme.error),
                        ),
                      ],
                    ),
                  ),
                heading('When (Malaysia time)'),
                SegmentedButton<ScheduleFrequency>(
                  key: const ValueKey('schedule-frequency'),
                  segments: const [
                    ButtonSegment(value: ScheduleFrequency.daily, label: Text('Every day')),
                    ButtonSegment(value: ScheduleFrequency.weekly, label: Text('Every week')),
                    ButtonSegment(value: ScheduleFrequency.monthly, label: Text('Every month')),
                  ],
                  selected: {_frequency},
                  onSelectionChanged: (s) => setState(() => _frequency = s.first),
                ),
                const SizedBox(height: 10),
                if (_frequency == ScheduleFrequency.weekly)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var d = 1; d <= 7; d++)
                        FilterChip(
                          key: ValueKey('schedule-day-$d'),
                          label: Text(weekdayNames[d - 1].substring(0, 3)),
                          selected: _weekdays.contains(d),
                          onSelected: (on) => setState(() => _weekdays = on ? {..._weekdays, d} : ({..._weekdays}..remove(d))),
                        ),
                    ],
                  ),
                if (_frequency == ScheduleFrequency.monthly)
                  SizedBox(
                    width: 240,
                    child: SearchableDropdownFormField<int>(
                      key: const ValueKey('schedule-month-day'),
                      initialValue: _monthDay,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'On', border: OutlineInputBorder(), isDense: true),
                      items: [
                        for (var d = 1; d <= 28; d++) DropdownMenuItem(value: d, child: Text('Day $d')),
                        const DropdownMenuItem(value: ScheduleTiming.lastDay, child: Text('The last day')),
                      ],
                      onChanged: (v) => setState(() => _monthDay = v ?? 1),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('schedule-time'),
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule),
                      label: Text('At ${_at.hour.toString().padLeft(2, '0')}:${_at.minute.toString().padLeft(2, '0')}'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        next == null ? 'Pick when it sends.' : 'Next: ${mytWords(next)}',
                        key: const ValueKey('schedule-next'),
                        style: t.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
                heading('Each email covers'),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SearchableDropdownFormField<String>(
                        key: const ValueKey('schedule-period'),
                        initialValue: _period,
                        isExpanded: true,
                        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                        items: [
                          for (final e in schedulePeriods.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                        ],
                        onChanged: (v) => setState(() => _period = v ?? 'previous_day'),
                      ),
                    ),
                    if (_period == 'last_n_days') ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 90,
                        child: TextField(
                          key: const ValueKey('schedule-days'),
                          controller: _days,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Days', border: OutlineInputBorder(), isDense: true),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ],
                ),
                if (covers != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'The next one: ${shortDay(covers.from)} to ${shortDay(covers.to)}',
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                heading('Send to'),
                TextField(
                  key: const ValueKey('schedule-emails'),
                  controller: _emails,
                  minLines: 1,
                  maxLines: 4,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email addresses',
                    helperText: 'Commas or new lines between them, at most 20',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final id in _admins)
                      InputChip(
                        key: ValueKey('schedule-admin-$id'),
                        label: Text(adminNames[id] ?? 'Admin'),
                        onDeleted: () => setState(() => _admins = {..._admins}..remove(id)),
                      ),
                    TextButton.icon(
                      key: const ValueKey('schedule-add-admins'),
                      onPressed: _adminList == null ? null : _pickAdmins,
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Add admins'),
                    ),
                  ],
                ),
                heading('Files'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in scheduleFormats.entries)
                      FilterChip(
                        key: ValueKey('schedule-format-${e.key}'),
                        label: Text(e.value),
                        selected: _formats.contains(e.key),
                        onSelected: (on) => setState(() => _formats = on ? {..._formats, e.key} : ({..._formats}..remove(e.key))),
                      ),
                  ],
                ),
                SwitchListTile(
                  key: const ValueKey('schedule-link-only'),
                  contentPadding: EdgeInsets.zero,
                  value: _linkOnly,
                  onChanged: (v) => setState(() => _linkOnly = v),
                  title: const Text('Link only'),
                  subtitle: const Text('A link to download the files, valid 7 days, instead of attaching them'),
                ),
                heading('The email'),
                TextField(
                  key: const ValueKey('schedule-subject'),
                  controller: _subject,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: 'Subject', border: OutlineInputBorder()),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('schedule-message'),
                  controller: _message,
                  minLines: 2,
                  maxLines: 6,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                    labelText: 'Short message (optional)',
                    helperText: '{report}, {period} and {rows} are filled in',
                    border: OutlineInputBorder(),
                  ),
                ),
                Text(
                  'For example: ${fillReportPlaceholders(_subject.text, report: widget.saved.name, period: covers == null ? 'All time' : '${shortDay(covers.from)} to ${shortDay(covers.to)}', rows: 128)}',
                  key: const ValueKey('schedule-subject-preview'),
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                SwitchListTile(
                  key: const ValueKey('schedule-skip-empty'),
                  contentPadding: EdgeInsets.zero,
                  value: _skipEmpty,
                  onChanged: (v) => setState(() => _skipEmpty = v),
                  title: const Text('Skip when empty'),
                  subtitle: const Text('No email when the report has no rows'),
                ),
                SwitchListTile(
                  key: const ValueKey('schedule-paused'),
                  contentPadding: EdgeInsets.zero,
                  value: _paused,
                  onChanged: (v) => setState(() => _paused = v),
                  title: const Text('Paused'),
                ),
                if (_problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_problem!, key: const ValueKey('schedule-problem'), style: TextStyle(color: t.colorScheme.error)),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey('schedule-save'),
                  onPressed: _saving ? null : _save,
                  child: Text(_e == null ? 'Save the schedule' : 'Save changes'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminPicker extends StatefulWidget {
  const _AdminPicker({required this.admins, required this.selected});
  final List<ReportAdmin> admins;
  final Set<String> selected;

  @override
  State<_AdminPicker> createState() => _AdminPickerState();
}

class _AdminPickerState extends State<_AdminPicker> {
  late Set<String> _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Admins to send to', style: Theme.of(context).textTheme.titleMedium),
          if (widget.admins.isEmpty)
            const Padding(padding: EdgeInsets.all(12), child: Text('No admin has an email address.')),
          Flexible(
            child: ListSearchFilter(
              count: widget.admins.length,
              hint: 'Search admins',
              builder: (context, q) => ListView(
                shrinkWrap: true,
                children: [
                  for (final a in widget.admins.where((a) =>
                      q.isEmpty || '${a.name} ${a.email}'.toLowerCase().contains(q.toLowerCase())))
                    CheckboxListTile(
                      key: ValueKey('pick-admin-${a.id}'),
                      value: _picked.contains(a.id),
                      title: Text(a.name.isEmpty ? a.email : a.name),
                      subtitle: Text(a.email),
                      onChanged: (on) => setState(() => _picked = on == true ? {..._picked, a.id} : ({..._picked}..remove(a.id))),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('pick-admins-done'),
            onPressed: () => Navigator.pop(context, _picked),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
}
