// Admin → Commission → Promotions and Reports (migration 0224).
//
// Promotions: lower rates for a time, optionally only in a place, for some
// services, on some days and hours, or for new drivers; each can be turned
// off. Reports: the commission charged by day, week, month, region or
// driver between two dates, as a CSV too, and the drivers whose GET.credit
// is under the floor.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/commission_promotions.dart';
import '../../core/format.dart' show formatDateTime, formatMoney, formatTime;
import '../../data/live_tables.dart';
import '../../features/partner/earnings_screen.dart' show CsvShareOutcome, earningsCsvSharerProvider;
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/image_share.dart' show shareOriginOf;
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import 'geo/geo_data.dart' show regionsProvider;
import 'geo/geo_logic.dart' show RegionEntry, RegionLevel, regionNamesAt;

final commissionPromotionsProvider = FutureProvider.autoDispose<List<CommissionPromotion>>((ref) {
  ref.watchAdminLive('commission_promotions');
  return ref.watch(adminRepositoryProvider).commissionPromotions();
});

/// Service names seen on trips; empty when unreadable.
final commissionServiceNamesProvider = FutureProvider.autoDispose<List<({String name, int trips})>>((ref) async {
  try {
    return await ref.watch(adminRepositoryProvider).commissionServiceNames();
  } catch (_) {
    return const [];
  }
});

typedef CommissionReportQuery = ({DateTime from, DateTime to, CommissionReportGroup group});

final commissionReportProvider =
    FutureProvider.autoDispose.family<List<CommissionReportRow>, CommissionReportQuery>((ref, q) {
  return ref.watch(adminRepositoryProvider).commissionReport(q.from, q.to, q.group);
});

final driversBelowCreditProvider = FutureProvider.autoDispose<List<BelowCreditDriver>>((ref) {
  return ref.watch(adminRepositoryProvider).driversBelowCredit();
});

String _day(DateTime d) => formatDateTime(d).split(',').first;

/// A promotion's start or end day, on its own line: "1 Mar 2026".
String promoMomentDate(DateTime d) => _day(d);

/// Hands a CSV to the share sheet, or downloads it on the web (as the Earnings page does).
Future<void> _exportCsv(BuildContext button, WidgetRef ref, String csv, String fileName) async {
  final messenger = ScaffoldMessenger.of(button);
  final outcome = await ref.read(earningsCsvSharerProvider)(csv, fileName, shareOriginOf(button));
  final note = switch (outcome) {
    CsvShareOutcome.shared => null,
    CsvShareOutcome.downloaded => 'Downloaded $fileName.',
    CsvShareOutcome.copied => 'Couldn\'t open sharing; the CSV is on your clipboard.',
    CsvShareOutcome.failed => 'Couldn\'t export the CSV.',
  };
  if (note != null) messenger.showSnackBar(SnackBar(content: Text(note)));
}

// ---- Promotions ----------------------------------------------------------------------------------
class CommissionPromotionsTab extends ConsumerWidget {
  const CommissionPromotionsTab({super.key, required this.canEdit});
  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, [CommissionPromotion? p]) async {
    final result = await showAppDialog<CommissionPromotion>(
      id: 'commission.promotion',
      context: context,
      builder: (_) => _PromotionDialog(promotion: p),
    );
    if (result == null || !context.mounted) return;
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).saveCommissionPromotion(result),
        success: 'Promotion saved')) {
      ref.invalidate(commissionPromotionsProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final now = DateTime.now().toUtc();
    return AsyncView(
      value: ref.watch(commissionPromotionsProvider),
      onRetry: () => ref.invalidate(commissionPromotionsProvider),
      data: (promotions) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          ResponsiveCenter(
            maxWidth: 760,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'A promotion lowers the rate for a time: everywhere or in one place, for some services, on some '
                  'days and hours (the trip\'s local time), or for new drivers in their first days. When a driver '
                  'accepts a trip, the lowest of their rate (after tiers) and the promotions that fit wins, and is '
                  'kept for that trip. A promotion never raises a rate, and a personal rate set for one driver is '
                  'not lowered. Meter / TEKSI hires count from when they began.',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                const SizedBox(height: 8),
                if (canEdit)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('commission-promo-add'),
                      onPressed: () => _edit(context, ref),
                      icon: const Icon(Icons.add),
                      label: const Text('Add promotion'),
                    ),
                  ),
                const SizedBox(height: 8),
                if (promotions.isEmpty)
                  const EmptyState(icon: Icons.local_offer_outlined, title: 'No promotions yet'),
                ListSearchFilter(
                  count: promotions.length,
                  hint: 'Search promotions',
                  fieldKey: const ValueKey('commission-promo-search'),
                  builder: (context, q) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final p in promotions)
                        if (q.isEmpty || searchSelectMatches('${p.name} ${p.summary} ${p.note}', q))
                          _PromotionCard(
                            promotion: p,
                            status: p.statusAt(now),
                            canEdit: canEdit,
                            onEdit: () => _edit(context, ref, p),
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

class _PromotionCard extends ConsumerWidget {
  const _PromotionCard({required this.promotion, required this.status, required this.canEdit, required this.onEdit});
  final CommissionPromotion promotion;
  final String status;
  final bool canEdit;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final p = promotion;
    final (bg, fg) = switch (status) {
      'Running' => (cs.primaryContainer, cs.onPrimaryContainer),
      'Scheduled' => (cs.tertiaryContainer, cs.onTertiaryContainer),
      _ => (cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };
    return Card(
      child: ListTile(
        key: ValueKey('commission-promo-${p.id}'),
        leading: Icon(Icons.local_offer_outlined, color: status == 'Running' ? cs.primary : cs.outline),
        // The name gets the width (two lines), with its status under it.
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
              child: Text(status, style: t.textTheme.labelSmall?.copyWith(color: fg)),
            ),
          ],
        ),
        subtitle: Text(
          [
            p.summary,
            '${formatDateTime(p.startsAt)} – ${formatDateTime(p.endsAt)}',
            if (p.note.isNotEmpty) p.note,
          ].join('\n'),
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        isThreeLine: true,
        onTap: canEdit ? onEdit : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: '${p.name} on',
              child: Switch(
              key: ValueKey('commission-promo-active-${p.id}'),
              value: p.active,
              onChanged: canEdit
                  ? (v) async {
                      if (await runAdminAction(
                          context, () => ref.read(adminRepositoryProvider).saveCommissionPromotion(p.copyWith(active: v)),
                          success: v ? 'Promotion turned on' : 'Promotion turned off')) {
                        ref.invalidate(commissionPromotionsProvider);
                      }
                    }
                  : null,
              ),
            ),
            if (canEdit)
              BusyIconButton(
                key: ValueKey('commission-promo-delete-${p.id}'),
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await confirm(context, 'Delete promotion?', p.name, ok: 'Delete')) return;
                  if (!context.mounted) return;
                  if (await runAdminAction(
                      context, () => ref.read(adminRepositoryProvider).deleteCommissionPromotion(p.id!))) {
                    ref.invalidate(commissionPromotionsProvider);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _PromotionDialog extends ConsumerStatefulWidget {
  const _PromotionDialog({this.promotion});
  final CommissionPromotion? promotion;

  @override
  ConsumerState<_PromotionDialog> createState() => _PromotionDialogState();
}

class _PromotionDialogState extends ConsumerState<_PromotionDialog> {
  final _form = GlobalKey<FormState>();
  late final CommissionPromotion? _p = widget.promotion;
  late final _name = TextEditingController(text: _p?.name ?? '');
  late final _rate = TextEditingController(text: _p == null ? '' : _num(_p.rate * 100));
  late final _days = TextEditingController(text: _p?.newDriverDays?.toString() ?? '30');
  late final _note = TextEditingController(text: _p?.note ?? '');
  late DateTime _from = (_p?.startsAt ?? _today()).toLocal();
  late DateTime _to = (_p?.endsAt ?? _today().add(const Duration(days: 7))).toLocal();
  late final _place = {'country': _p?.country ?? '', 'state': _p?.state ?? '', 'city': _p?.city ?? ''};
  late final Set<String> _services = {...?_p?.services};
  late final Set<int> _weekdays = {...?_p?.weekdays};
  late bool _hours = _p?.hasHours ?? false;
  late int _timeFrom = _p?.timeFrom ?? 7 * 60;
  late int _timeTo = _p?.timeTo ?? 10 * 60;
  late bool _newDrivers = _p?.newDriverDays != null;
  late bool _active = _p?.active ?? true;
  String? _error;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  void dispose() {
    _name.dispose();
    _rate.dispose();
    _days.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickMoment(bool start) async {
    final current = start ? _from : _to;
    final d = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (!mounted) return;
    final picked = DateTime(d.year, d.month, d.day, t?.hour ?? current.hour, t?.minute ?? current.minute);
    setState(() => start ? _from = picked : _to = picked);
  }

  Future<void> _pickTime(bool from) async {
    final m = from ? _timeFrom : _timeTo;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
    if (t == null || !mounted) return;
    setState(() => from ? _timeFrom = t.hour * 60 + t.minute : _timeTo = t.hour * 60 + t.minute);
  }

  /// A place: picked from Admin → Country / States / Cities where that level
  /// has names, typed where it has none. Blank: anywhere.
  Widget _placeField(String k, List<RegionEntry> regions) {
    const levels = {'country': RegionLevel.country, 'state': RegionLevel.state, 'city': RegionLevel.city};
    const order = ['country', 'state', 'city'];
    final title = k[0].toUpperCase() + k.substring(1);
    final options = regionNamesAt(regions, levels[k]!, country: _place['country']!, state: _place['state']!);
    final value = _place[k]!.trim();
    void set(String v) => setState(() {
          _place[k] = v;
          // A new parent clears the places under it.
          for (final below in order.skip(order.indexOf(k) + 1)) {
            _place[below] = '';
          }
        });
    if (options.isEmpty) {
      return TextFormField(
        key: ValueKey('promo-$k-${_place['country']}/${_place['state']}'),
        initialValue: value,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(labelText: '$title (optional)', helperText: 'Blank: any $k'),
        onChanged: (v) => _place[k] = v.trim(),
      );
    }
    const any = '';
    final all = [...options, if (value.isNotEmpty && !options.any((o) => o.toLowerCase() == value.toLowerCase())) value];
    final selected = all.where((o) => o.toLowerCase() == value.toLowerCase()).firstOrNull ?? any;
    return SearchableDropdownFormField<String>(
      key: ValueKey('promo-$k-${_place['country']}/${_place['state']}'),
      isExpanded: true,
      initialValue: selected,
      decoration: InputDecoration(labelText: title),
      items: [
        DropdownMenuItem(value: any, child: Text('Any $k')),
        for (final o in all) DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) => set(v ?? ''),
    );
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    if (!_to.isAfter(_from)) {
      setState(() => _error = 'The promotion must end after it starts.');
      return;
    }
    if (_hours && _timeFrom == _timeTo) {
      setState(() => _error = 'The hours must start and end at different times.');
      return;
    }
    String? place(String k) => _place[k]!.trim().isEmpty ? null : _place[k]!.trim();
    Navigator.pop(
      context,
      CommissionPromotion(
        id: _p?.id,
        name: _name.text.trim(),
        active: _active,
        rate: double.parse((double.parse(_rate.text.trim()) / 100).toStringAsFixed(4)),
        startsAt: _from.toUtc(),
        endsAt: _to.toUtc(),
        country: place('country'),
        state: place('country') == null ? null : place('state'),
        city: place('country') == null || place('state') == null ? null : place('city'),
        services: [..._services]..sort(),
        weekdays: _weekdays.length == 7 ? const [] : ([..._weekdays]..sort()),
        timeFrom: _hours ? _timeFrom : null,
        timeTo: _hours ? _timeTo : null,
        newDriverDays: _newDrivers ? int.parse(_days.text.trim()) : null,
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final seen = ref.watch(commissionServiceNamesProvider).value ?? const [];
    final services = <String, int>{
      meterServiceName: 0,
      for (final s in _services) s: 0,
      for (final s in seen) s.name: s.trips,
    };
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(text, style: t.textTheme.titleSmall),
    );
    // The date on one line and the time on the next, each kept whole.
    Widget moment(String label, DateTime at, bool start) => Expanded(
      child: OutlinedButton(
        key: ValueKey(start ? 'promo-from' : 'promo-to'),
        onPressed: () => _pickMoment(start),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, maxLines: 1),
            FittedBox(fit: BoxFit.scaleDown, child: Text(promoMomentDate(at), maxLines: 1)),
            Text(formatTime(at), maxLines: 1),
          ],
        ),
      ),
    );
    return AlertDialog(
      title: Text(_p == null ? 'Add promotion' : 'Edit promotion'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('promo-name'),
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Hari Raya week'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Give the promotion a name' : null,
                ),
                TextFormField(
                  key: const ValueKey('promo-rate'),
                  controller: _rate,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Rate (%)',
                    suffixText: '%',
                    helperText: '0 for no commission',
                    helperStyle: t.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                  validator: (v) {
                    final n = double.tryParse((v ?? '').trim());
                    return n == null || n < 0 || n >= 100 ? 'Between 0 and 99.99' : null;
                  },
                ),
                heading('When'),
                Row(children: [moment('From', _from, true), const SizedBox(width: 8), moment('To', _to, false)]),
                heading('Where'),
                _placeField('country', regions),
                if (_place['country']!.isNotEmpty) _placeField('state', regions),
                if (_place['country']!.isNotEmpty && _place['state']!.isNotEmpty) _placeField('city', regions),
                heading('Services'),
                Text('None ticked: every service.', style: t.textTheme.bodySmall?.copyWith(color: muted)),
                ListSearchFilter(
                  count: services.length,
                  hint: 'Search services',
                  fieldKey: const ValueKey('promo-service-search'),
                  builder: (context, q) => Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final e in services.entries)
                        if (q.isEmpty || searchSelectMatches(e.key, q) || _services.contains(e.key))
                          FilterChip(
                            key: ValueKey('promo-service-${e.key}'),
                            label: Text(e.key == meterServiceName ? 'Meter / TEKSI' : e.key),
                            selected: _services.contains(e.key),
                            onSelected: (v) => setState(() => v ? _services.add(e.key) : _services.remove(e.key)),
                          ),
                    ],
                  ),
                ),
                heading('Days and hours'),
                Text('None ticked: every day. Hours are the trip\'s local time.',
                    style: t.textTheme.bodySmall?.copyWith(color: muted)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        key: ValueKey('promo-day-$d'),
                        label: Text(weekdayNames[d - 1]),
                        selected: _weekdays.contains(d),
                        onSelected: (v) => setState(() => v ? _weekdays.add(d) : _weekdays.remove(d)),
                      ),
                  ],
                ),
                SwitchListTile(
                  key: const ValueKey('promo-hours'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Only at certain hours'),
                  subtitle: _hours && _timeFrom > _timeTo ? const Text('Runs past midnight') : null,
                  value: _hours,
                  onChanged: (v) => setState(() => _hours = v),
                ),
                if (_hours)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          key: const ValueKey('promo-time-from'),
                          onPressed: () => _pickTime(true),
                          child: Text('From ${timeOfDayLabel(_timeFrom)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          key: const ValueKey('promo-time-to'),
                          onPressed: () => _pickTime(false),
                          child: Text('To ${timeOfDayLabel(_timeTo)}'),
                        ),
                      ),
                    ],
                  ),
                heading('Drivers'),
                SwitchListTile(
                  key: const ValueKey('promo-new-drivers'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('New drivers only'),
                  subtitle: const Text('Counted from the day they joined'),
                  value: _newDrivers,
                  onChanged: (v) => setState(() => _newDrivers = v),
                ),
                if (_newDrivers)
                  TextFormField(
                    key: const ValueKey('promo-days'),
                    controller: _days,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Their first', suffixText: 'days'),
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      return n == null || n < 1 || n > 3650 ? 'Between 1 and 3650 days' : null;
                    },
                  ),
                TextFormField(
                  key: const ValueKey('promo-note'),
                  controller: _note,
                  textInputAction: TextInputAction.done,
                  maxLength: 300,
                  decoration: const InputDecoration(labelText: 'Note (optional)'),
                ),
                SwitchListTile(
                  key: const ValueKey('promo-active'),
                  contentPadding: EdgeInsets.zero,
                  value: _active,
                  title: const Text('On'),
                  onChanged: (v) => setState(() => _active = v),
                ),
                if (_error != null) Text(_error!, style: TextStyle(color: t.colorScheme.error)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('promo-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---- Reports -------------------------------------------------------------------------------------
class CommissionReportsTab extends ConsumerStatefulWidget {
  const CommissionReportsTab({super.key});

  @override
  ConsumerState<CommissionReportsTab> createState() => _CommissionReportsTabState();
}

class _CommissionReportsTabState extends ConsumerState<CommissionReportsTab> {
  /// The first and last day shown (local dates); the query runs to the day after [_last].
  late DateTime _first = _today().subtract(const Duration(days: 29));
  late DateTime _last = _today();
  CommissionReportGroup _group = CommissionReportGroup.day;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  CommissionReportQuery get _query =>
      (from: _first, to: DateTime(_last.year, _last.month, _last.day + 1), group: _group);

  Future<void> _pickDay(bool first) async {
    final d = await showDatePicker(
      context: context,
      initialDate: first ? _first : _last,
      firstDate: DateTime(2020),
      lastDate: _today(),
    );
    if (d == null || !mounted) return;
    setState(() {
      if (first) {
        _first = d;
        if (_last.isBefore(d)) _last = d;
      } else {
        _last = d;
        if (_first.isAfter(d)) _first = d;
      }
    });
  }

  String _stamp(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final q = _query;
    final report = ref.watch(commissionReportProvider(q));
    final below = ref.watch(driversBelowCreditProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        ResponsiveCenter(
          maxWidth: 760,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Commission charged on trips and meter / TEKSI hires, by when it was charged (Malaysia time). '
                'A region is the trip\'s, or where a meter hire began.',
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('report-from'),
                    onPressed: () => _pickDay(true),
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text('From ${_day(_first)}'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('report-to'),
                    onPressed: () => _pickDay(false),
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text('To ${_day(_last)}'),
                  ),
                  SizedBox(
                    width: 180,
                    child: SearchableDropdownFormField<CommissionReportGroup>(
                      key: const ValueKey('report-group'),
                      isExpanded: true,
                      initialValue: _group,
                      decoration: const InputDecoration(labelText: 'By', isDense: true),
                      items: [
                        for (final g in CommissionReportGroup.values) DropdownMenuItem(value: g, child: Text(g.label)),
                      ],
                      onChanged: (g) => setState(() => _group = g ?? _group),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              AsyncView(
                value: report,
                errorTitle: "Couldn't load the report",
                onRetry: () => ref.invalidate(commissionReportProvider(q)),
                data: (rows) => _ReportView(
                  rows: rows,
                  group: q.group,
                  fileName: 'commission-${q.group.name}-${_stamp(_first)}-${_stamp(_last)}.csv',
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(child: Text('Below the GET.credit limit', style: t.textTheme.titleMedium)),
                  IconButton(
                    key: const ValueKey('below-credit-refresh'),
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => ref.invalidate(driversBelowCreditProvider),
                  ),
                  if (below.value case final list? when list.isNotEmpty)
                    Builder(
                      builder: (button) => IconButton(
                        key: const ValueKey('below-credit-export'),
                        tooltip: 'Export as CSV',
                        icon: const Icon(Icons.file_download_outlined),
                        onPressed: () => _exportCsv(button, ref, belowCreditCsv(list), 'below-credit-${_stamp(_today())}.csv'),
                      ),
                    ),
                ],
              ),
              Text(
                'Drivers who can\'t take work until they top up (Settings → GET.credit below zero).',
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 8),
              AsyncView(
                value: below,
                onRetry: () => ref.invalidate(driversBelowCreditProvider),
                data: (list) => list.isEmpty
                    ? const EmptyState(icon: Icons.verified_outlined, title: 'No driver is below the limit')
                    : ListSearchFilter(
                        count: list.length,
                        hint: 'Search drivers',
                        fieldKey: const ValueKey('below-credit-search'),
                        builder: (context, s) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final d in list)
                              if (s.isEmpty ||
                                  searchSelectMatches('${d.name ?? ''} ${d.displayId ?? ''} ${d.phone ?? ''} ${d.uid}', s))
                                Card(
                                  child: ListTile(
                                    key: ValueKey('below-credit-${d.uid}'),
                                    leading: Icon(Icons.account_balance_wallet_outlined, color: t.colorScheme.error),
                                    title: Text(d.name ?? 'Unknown driver'),
                                    subtitle: Text(
                                      [d.displayId ?? d.uid, if (d.phone != null) d.phone!,
                                        'limit ${formatMoney(d.floor)}'].join(' · '),
                                      style: TextStyle(color: muted),
                                    ),
                                    trailing: Text(
                                      formatMoney(d.balance),
                                      style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.error),
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReportView extends ConsumerWidget {
  const _ReportView({required this.rows, required this.group, required this.fileName});
  final List<CommissionReportRow> rows;
  final CommissionReportGroup group;
  final String fileName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final total = rows.fold<double>(0, (s, r) => s + r.commission);
    final trips = rows.fold<int>(0, (s, r) => s + r.trips);
    final meter = rows.fold<int>(0, (s, r) => s + r.meterTrips);
    String counts(int trips, int meter) =>
        [if (trips > 0 || meter == 0) '$trips trip${trips == 1 ? '' : 's'}', if (meter > 0) '$meter meter'].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: t.colorScheme.secondaryContainer,
          child: ListTile(
            title: Text('Commission charged', style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
            subtitle: Text(counts(trips, meter), style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatMoney(total),
                  key: const ValueKey('report-total'),
                  style: t.textTheme.titleLarge?.copyWith(color: t.colorScheme.onSecondaryContainer),
                ),
                Builder(
                  builder: (button) => IconButton(
                    key: const ValueKey('report-export'),
                    tooltip: 'Export as CSV',
                    color: t.colorScheme.onSecondaryContainer,
                    icon: const Icon(Icons.file_download_outlined),
                    onPressed: rows.isEmpty ? null : () => _exportCsv(button, ref, commissionReportCsv(rows, group), fileName),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (rows.isEmpty)
          const EmptyState(icon: Icons.query_stats, title: 'No commission charged in this range')
        else
          ListSearchFilter(
            count: rows.length,
            hint: 'Search',
            fieldKey: const ValueKey('report-search'),
            builder: (context, s) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final r in rows)
                  if (s.isEmpty || searchSelectMatches('${commissionReportLabel(r, group)} ${r.detail ?? ''}', s))
                    ListTile(
                      key: ValueKey('report-row-${r.key}'),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      title: Text(commissionReportLabel(r, group)),
                      subtitle: Text(
                        [if (r.detail != null) r.detail!, counts(r.trips, r.meterTrips), 'on ${formatMoney(r.base)}']
                            .join(' · '),
                        style: TextStyle(color: muted),
                      ),
                      trailing: Text(formatMoney(r.commission), style: t.textTheme.titleSmall),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}
