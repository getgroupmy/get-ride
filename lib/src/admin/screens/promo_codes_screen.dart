// Admin → Settings → Promocode (migration 0242): rider promo codes.
//
// The list keeps its place (/admin/settings/promocode-list) and opens the
// full editor: the discount (fixed or a percentage with a cap), the limits
// (uses in total and per rider, a budget, a minimum fare), when it runs, the
// regions and whether the pickup, the drop-off or both must be inside, the
// date range, daily hours and weekdays (Malaysia time), genders, chosen
// riders, services, first ride only, auto apply and on / off. Each code shows
// what it has given: trips, the total discount and the latest trips.
//
// Gated by the Promocode page grant (admin-settings-promocode), as before.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/commission_promotions.dart' show timeOfDayLabel, weekdayNames;
import '../../core/format.dart' show formatDateTime, formatMoney;
import '../../core/promo_codes.dart';
import '../../data/live_tables.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../profile_search.dart';
import '../widgets/admin_widgets.dart';
import 'commission_promotions_tabs.dart' show commissionServiceNamesProvider;
import 'geo/geo_data.dart' show regionsProvider;
import 'geo/geo_logic.dart' show RegionEntry, RegionLevel, regionNamesAt;

/// The Promocode page's grant.
const promoCodePage = 'admin-settings-promocode';

final promoCodesProvider = FutureProvider.autoDispose<List<PromoCode>>((ref) {
  ref.watchAdminLive('promo_codes');
  return ref.watch(adminRepositoryProvider).promoCodes();
});

typedef PromoStats = ({int uses, double discount, DateTime? lastAt});

/// What each code has given; empty when unreadable.
final promoStatsProvider = FutureProvider.autoDispose<Map<String, PromoStats>>((ref) async {
  ref.watchAdminLive('promo_redemptions');
  try {
    return await ref.watch(adminRepositoryProvider).promoRedemptionStats();
  } catch (_) {
    return const {};
  }
});

String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
String _day(DateTime d) => formatDateTime(d).split(',').first;

class AdminPromoCodesScreen extends ConsumerWidget {
  const AdminPromoCodesScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [PromoCode? p]) async {
    final result = await showAppDialog<PromoCode>(
      id: 'admin.promo-code',
      context: context,
      builder: (_) => PromoCodeEditor(code: p),
    );
    if (result == null || !context.mounted) return;
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).savePromoCode(result),
        success: 'Promo code saved')) {
      ref.invalidate(promoCodesProvider);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, PromoCode p, PromoStats? stats) async {
    if ((stats?.uses ?? 0) > 0 || p.usesCount > 0) {
      await showNotice(context,
          title: 'Turn it off instead',
          message: '${p.code} has been used on trips, so it is kept for their records. Turn it off to stop it.');
      return;
    }
    if (!await confirm(context, 'Delete promo code?', p.code, ok: 'Delete')) return;
    if (!context.mounted) return;
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deletePromoCode(p.id!))) {
      ref.invalidate(promoCodesProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(adminAccessProvider).value ?? AdminAccess.none;
    final level = access.levelFor([promoCodePage, 'admin-settings']);
    final canEdit = level == AccessLevel.edit;
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final stats = ref.watch(promoStatsProvider).value ?? const <String, PromoStats>{};
    final now = DateTime.now().toUtc();
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/admin/settings')),
        title: const Text('Promocode'),
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              key: const ValueKey('pc-add'),
              onPressed: () => _edit(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add code'),
            )
          : null,
      body: level == AccessLevel.none
          ? const EmptyState(icon: Icons.lock_outline, title: 'No access', message: 'Ask an admin for the Promocode page.')
          : AsyncView(
              value: ref.watch(promoCodesProvider),
              onRetry: () => ref.invalidate(promoCodesProvider),
              data: (codes) => ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  ResponsiveCenter(
                    maxWidth: 760,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'A promo code takes money off the rider\'s fare. Riders see the codes that fit their trip on '
                          'the confirm step, or type one; the server checks it again when they book and settles it '
                          'when the trip completes in full. The discount is paid to the driver\'s GET.wallet. A trip '
                          'the driver ends early gets no promo.',
                          style: t.textTheme.bodySmall?.copyWith(color: muted),
                        ),
                        const SizedBox(height: 8),
                        if (codes.isEmpty)
                          const EmptyState(icon: Icons.sell_outlined, title: 'No promo codes yet'),
                        ListSearchFilter(
                          count: codes.length,
                          hint: 'Search promo codes',
                          fieldKey: const ValueKey('pc-search'),
                          builder: (context, q) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final p in codes)
                                if (q.isEmpty || searchSelectMatches('${p.code} ${p.description}', q))
                                  _PromoCodeCard(
                                    code: p,
                                    status: p.statusAt(now),
                                    stats: stats[p.id],
                                    canEdit: canEdit,
                                    onEdit: () => _edit(context, ref, p),
                                    onDelete: () => _delete(context, ref, p, stats[p.id]),
                                    onRedemptions: () => showAppDialog<void>(
                                      id: 'admin.promo-code-redemptions',
                                      context: context,
                                      builder: (_) => PromoRedemptionsDialog(code: p, stats: stats[p.id]),
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
            ),
    );
  }
}

/// One line per rule a code has, for its card.
List<String> promoRuleLines(PromoCode p) => [
      [
        p.discountLabel,
        if (p.minFare != null) 'min fare ${formatMoney(p.minFare)}',
        if (p.autoApply) 'auto apply',
        if (p.firstRideOnly) 'first ride only',
      ].join(' · '),
      if (p.regions.isNotEmpty)
        '${p.appliesTo.label}: ${p.regions.map((r) => r.label).join('; ')}',
      if (p.startsAt != null || p.endsAt != null)
        '${p.startsAt == null ? 'Now' : formatDateTime(p.startsAt)} – ${p.endsAt == null ? 'no end' : formatDateTime(p.endsAt)}',
      if (p.dateFrom != null || p.dateTo != null || p.weekdays.isNotEmpty || p.hasHours)
        [
          if (p.dateFrom != null || p.dateTo != null)
            '${p.dateFrom == null ? '…' : _day(p.dateFrom!)} to ${p.dateTo == null ? '…' : _day(p.dateTo!)}',
          if (p.weekdays.isNotEmpty) p.weekdays.map((d) => weekdayNames[d - 1]).join(', '),
          if (p.hasHours) '${timeOfDayLabel(p.timeFrom!)}–${timeOfDayLabel(p.timeTo!)}',
        ].join(' · '),
      if (p.genders.isNotEmpty || p.riderIds.isNotEmpty || p.services.isNotEmpty)
        [
          if (p.genders.isNotEmpty) p.genders.map(promoGenderLabel).join(', '),
          if (p.riderIds.isNotEmpty) '${p.riderIds.length} chosen rider${p.riderIds.length == 1 ? '' : 's'}',
          if (p.services.isNotEmpty) p.services.join(', '),
        ].join(' · '),
    ];

class _PromoCodeCard extends ConsumerWidget {
  const _PromoCodeCard({
    required this.code,
    required this.status,
    required this.stats,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
    required this.onRedemptions,
  });
  final PromoCode code;
  final String status;
  final PromoStats? stats;
  final bool canEdit;
  final VoidCallback onEdit;
  final Future<void> Function() onDelete;
  final VoidCallback onRedemptions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final p = code;
    final (bg, fg) = switch (status) {
      'Running' => (cs.primaryContainer, cs.onPrimaryContainer),
      'Scheduled' => (cs.tertiaryContainer, cs.onTertiaryContainer),
      _ => (cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };
    final uses = stats?.uses ?? p.usesCount;
    final given = stats?.discount ?? p.discountTotal;
    return Card(
      child: ListTile(
        key: ValueKey('pc-${p.id}'),
        leading: Icon(Icons.sell_outlined, color: status == 'Running' ? cs.primary : cs.outline),
        title: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(p.code, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
              child: Text(status, style: t.textTheme.labelSmall?.copyWith(color: fg)),
            ),
          ],
        ),
        subtitle: Text(
          [
            if (p.description.trim().isNotEmpty) p.description.trim(),
            ...promoRuleLines(p),
            'Used $uses${p.maxUses == null ? '' : ' of ${p.maxUses}'} · ${formatMoney(given)} given'
                '${p.budget == null ? '' : ' of ${formatMoney(p.budget)}'}',
          ].join('\n'),
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        isThreeLine: true,
        onTap: canEdit ? onEdit : onRedemptions,
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              label: '${p.code} on',
              child: Switch(
                key: ValueKey('pc-active-${p.id}'),
                value: p.active,
                onChanged: canEdit
                    ? (v) async {
                        if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).savePromoCode(
                            PromoCode.fromRow({...p.toRow(), 'id': p.id, 'active': v})),
                            success: v ? 'Promo code turned on' : 'Promo code turned off')) {
                          ref.invalidate(promoCodesProvider);
                        }
                      }
                    : null,
              ),
            ),
            IconButton(
              key: ValueKey('pc-redemptions-${p.id}'),
              tooltip: 'Trips it was used on',
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: onRedemptions,
            ),
            if (canEdit)
              BusyIconButton(
                key: ValueKey('pc-delete-${p.id}'),
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}

// ---- What a code has given --------------------------------------------------------------------

final _redemptionsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, id) {
  ref.watchAdminLive('promo_redemptions');
  return ref.watch(adminRepositoryProvider).promoRedemptions(id);
});

class PromoRedemptionsDialog extends ConsumerWidget {
  const PromoRedemptionsDialog({super.key, required this.code, this.stats});
  final PromoCode code;
  final PromoStats? stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final rows = code.id == null ? const AsyncValue<List<Map<String, dynamic>>>.data([]) : ref.watch(_redemptionsProvider(code.id!));
    final uses = stats?.uses ?? code.usesCount;
    final given = stats?.discount ?? code.discountTotal;
    return AlertDialog(
      title: Text('${code.code} · trips'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: _Figure(key: const ValueKey('pc-red-count'), label: 'Trips', value: '$uses'),
              ),
              Expanded(
                child: _Figure(key: const ValueKey('pc-red-total'), label: 'Total discount', value: formatMoney(given)),
              ),
            ]),
            const SizedBox(height: 12),
            Text('Latest trips', style: t.textTheme.titleSmall),
            Flexible(
              child: AsyncView(
                value: rows,
                onRetry: () => ref.invalidate(_redemptionsProvider(code.id ?? '')),
                data: (list) => list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text('Not used on a trip yet.', style: TextStyle(color: muted)),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final r in list)
                            ListTile(
                              key: ValueKey('pc-red-${r['ride_id']}'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.local_taxi_outlined),
                              title: Text('${formatMoney(r['discount'] as num?)} off ${formatMoney(r['fare'] as num?)}'),
                              subtitle: Text(
                                '${formatDateTime(DateTime.tryParse('${r['created_at']}'))} · '
                                'rider paid ${formatMoney(r['payable'] as num?)} · '
                                'trip ${'${r['ride_id']}'.split('-').first}',
                                style: TextStyle(color: muted),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      Text(value, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
    ]);
  }
}

// ---- The editor ------------------------------------------------------------------------------

class PromoCodeEditor extends ConsumerStatefulWidget {
  const PromoCodeEditor({super.key, this.code});
  final PromoCode? code;

  @override
  ConsumerState<PromoCodeEditor> createState() => _PromoCodeEditorState();
}

class _PromoCodeEditorState extends ConsumerState<PromoCodeEditor> {
  final _form = GlobalKey<FormState>();
  late final PromoCode? _p = widget.code;
  late final _code = TextEditingController(text: _p?.code ?? '');
  late final _description = TextEditingController(text: _p?.description ?? '');
  late final _value = TextEditingController(text: _p == null ? '' : _num(_p.discountValue));
  late final _maxDiscount = TextEditingController(text: _p?.maxDiscount == null ? '' : _num(_p!.maxDiscount!));
  late final _maxUses = TextEditingController(text: _p?.maxUses?.toString() ?? '');
  late final _perRider = TextEditingController(text: _p?.maxUsesPerRider?.toString() ?? '');
  late final _budget = TextEditingController(text: _p?.budget == null ? '' : _num(_p!.budget!));
  late final _minFare = TextEditingController(text: _p?.minFare == null ? '' : _num(_p!.minFare!));
  final _riderSearch = TextEditingController();
  late PromoDiscountType _type = _p?.discountType ?? PromoDiscountType.fixed;
  late DateTime? _startsAt = _p?.startsAt?.toLocal();
  late DateTime? _endsAt = _p?.endsAt?.toLocal();
  late PromoAppliesTo _appliesTo = _p?.appliesTo ?? PromoAppliesTo.pickup;
  late final List<PromoRegion> _regions = [...?_p?.regions];
  final _place = {'country': '', 'state': '', 'city': '', 'suburb': ''};
  late DateTime? _dateFrom = _p?.dateFrom;
  late DateTime? _dateTo = _p?.dateTo;
  late final Set<int> _weekdays = {...?_p?.weekdays};
  late bool _hours = _p?.hasHours ?? false;
  late int _timeFrom = _p?.timeFrom ?? 22 * 60;
  late int _timeTo = _p?.timeTo ?? 6 * 60;
  late final Set<String> _genders = {...?_p?.genders};
  late bool _someRiders = (_p?.riderIds ?? const []).isNotEmpty;
  late final List<String> _riderIds = [...?_p?.riderIds];
  final Map<String, Map<String, dynamic>> _people = {};
  List<Map<String, dynamic>>? _found;
  bool _finding = false;
  String? _findError;
  late final Set<String> _services = {...?_p?.services};
  late bool _firstRide = _p?.firstRideOnly ?? false;
  late bool _autoApply = _p?.autoApply ?? false;
  late bool _active = _p?.active ?? true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_riderIds.isNotEmpty) _loadNames();
  }

  Future<void> _loadNames() async {
    try {
      final found = await ref.read(adminRepositoryProvider).peopleByIds(_riderIds);
      if (mounted) setState(() => _people.addAll(found));
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final c in [_code, _description, _value, _maxDiscount, _maxUses, _perRider, _budget, _minFare, _riderSearch]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<DateTime?> _pickMoment(DateTime? current) async {
    final base = current ?? DateTime.now();
    final d = await showDatePicker(context: context, initialDate: base, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (d == null || !mounted) return null;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(base));
    if (!mounted) return null;
    return DateTime(d.year, d.month, d.day, t?.hour ?? 0, t?.minute ?? 0);
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: _dateFrom != null && _dateTo != null
          ? DateTimeRange(start: _dateFrom!, end: _dateTo!)
          : DateTimeRange(start: DateTime(now.year, now.month, now.day), end: DateTime(now.year, now.month, now.day + 7)),
    );
    if (range == null || !mounted) return;
    setState(() {
      _dateFrom = range.start;
      _dateTo = range.end;
    });
  }

  Future<void> _pickTime(bool from) async {
    final m = from ? _timeFrom : _timeTo;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
    if (t == null || !mounted) return;
    setState(() => from ? _timeFrom = t.hour * 60 + t.minute : _timeTo = t.hour * 60 + t.minute);
  }

  Future<void> _findRiders() async {
    final q = _riderSearch.text.trim();
    if (!isProfileUuid(q) && peopleSearchTerm(q) == null) {
      setState(() => _findError = 'Type at least two characters.');
      return;
    }
    setState(() {
      _finding = true;
      _findError = null;
    });
    try {
      final rows = await ref.read(adminRepositoryProvider).searchPeople(q);
      if (mounted) setState(() => _found = rows);
    } catch (e) {
      if (mounted) setState(() => _findError = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  void _addRider(Map<String, dynamic> person) {
    final id = '${person['id']}';
    setState(() {
      _people[id] = person;
      if (!_riderIds.contains(id)) _riderIds.add(id);
    });
  }

  /// A level of the region being added: picked from Admin → Country /
  /// States / Cities / Suburbs where it has names, typed where it has none.
  Widget _placeField(String k, List<RegionEntry> regions) {
    const levels = {
      'country': RegionLevel.country,
      'state': RegionLevel.state,
      'city': RegionLevel.city,
      'suburb': RegionLevel.suburb,
    };
    const order = ['country', 'state', 'city', 'suburb'];
    final title = k[0].toUpperCase() + k.substring(1);
    final options =
        regionNamesAt(regions, levels[k]!, country: _place['country']!, state: _place['state']!, city: _place['city']!);
    final value = _place[k]!;
    final scope = order.take(order.indexOf(k)).map((o) => _place[o]).join('/');
    void set(String v) => setState(() {
          _place[k] = v;
          for (final below in order.skip(order.indexOf(k) + 1)) {
            _place[below] = '';
          }
        });
    if (options.isEmpty) {
      return TextFormField(
        key: ValueKey('pc-region-$k-$scope'),
        initialValue: value,
        decoration: InputDecoration(labelText: k == 'country' ? title : '$title (optional)'),
        onChanged: (v) => _place[k] = v.trim(),
      );
    }
    const any = '';
    return SearchableDropdownFormField<String>(
      key: ValueKey('pc-region-$k-$scope'),
      isExpanded: true,
      initialValue: options.contains(value) ? value : any,
      decoration: InputDecoration(labelText: title),
      items: [
        DropdownMenuItem(value: any, child: Text(k == 'country' ? 'Choose a country' : 'Any $k')),
        for (final o in options) DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) => set(v ?? ''),
    );
  }

  void _addRegion() {
    final r = PromoRegion(
      country: _place['country']!.trim(),
      state: _place['state']!.trim(),
      city: _place['city']!.trim(),
      suburb: _place['suburb']!.trim(),
    );
    if (r.country.isEmpty) {
      setState(() => _error = 'Choose a country for the region.');
      return;
    }
    setState(() {
      _error = null;
      if (!_regions.contains(r)) _regions.add(r);
      _place.updateAll((_, _) => '');
    });
  }

  double? _money(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    return v == null || v <= 0 ? null : double.parse(v.toStringAsFixed(2));
  }

  int? _count(TextEditingController c) {
    final v = int.tryParse(c.text.trim());
    return v == null || v <= 0 ? null : v;
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    if (_someRiders && _riderIds.isEmpty) {
      setState(() => _error = 'Pick at least one rider, or let every rider use it.');
      return;
    }
    final p = PromoCode(
      id: _p?.id,
      code: normalizePromoCode(_code.text),
      description: _description.text.trim(),
      active: _active,
      discountType: _type,
      discountValue: double.parse(double.parse(_value.text.trim()).toStringAsFixed(2)),
      maxDiscount: _type == PromoDiscountType.percent ? _money(_maxDiscount) : null,
      maxUses: _count(_maxUses),
      maxUsesPerRider: _count(_perRider),
      budget: _money(_budget),
      minFare: _money(_minFare),
      startsAt: _startsAt?.toUtc(),
      endsAt: _endsAt?.toUtc(),
      appliesTo: _appliesTo,
      regions: List.of(_regions),
      dateFrom: _dateFrom,
      dateTo: _dateTo,
      weekdays: [..._weekdays]..sort(),
      timeFrom: _hours ? _timeFrom : null,
      timeTo: _hours ? _timeTo : null,
      genders: [for (final g in promoGenders) if (_genders.contains(g)) g],
      riderIds: _someRiders ? List.of(_riderIds) : const [],
      services: [..._services]..sort(),
      firstRideOnly: _firstRide,
      autoApply: _autoApply,
      usesCount: _p?.usesCount ?? 0,
      discountTotal: _p?.discountTotal ?? 0,
    );
    final problem = p.problem;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final seen = ref.watch(commissionServiceNamesProvider).value ?? const [];
    final services = <String, int>{
      for (final s in _services) s: 0,
      for (final s in seen) s.name: s.trips,
    }..remove('meter');
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 4),
          child: Text(text, style: t.textTheme.titleSmall),
        );
    Widget hint(String text) => Text(text, style: t.textTheme.bodySmall?.copyWith(color: muted));
    Widget number(Key key, TextEditingController c, String label, {String? suffix, String? prefix, bool decimal = true}) =>
        TextFormField(
          key: key,
          controller: c,
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(decimal ? r'[0-9.]' : r'[0-9]'))],
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: label, suffixText: suffix, prefixText: prefix),
          validator: (v) => (v ?? '').trim().isEmpty || double.tryParse(v!.trim()) != null ? null : 'Enter a number',
        );
    Widget moment(String label, DateTime? at, Key key, ValueChanged<DateTime?> set) => Expanded(
          child: Row(children: [
            Expanded(
              child: OutlinedButton(
                key: key,
                onPressed: () async {
                  final d = await _pickMoment(at);
                  if (d != null) setState(() => set(d));
                },
                child: Text(at == null ? '$label: any' : '$label ${formatDateTime(at)}',
                    textAlign: TextAlign.center, maxLines: 2),
              ),
            ),
            if (at != null)
              IconButton(tooltip: 'Clear $label', icon: const Icon(Icons.close), onPressed: () => setState(() => set(null))),
          ]),
        );
    return AlertDialog(
      title: Text(_p == null ? 'Add promo code' : 'Edit ${_p.code}'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('pc-code'),
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_-]'))],
                  maxLength: 32,
                  decoration: const InputDecoration(labelText: 'Code', hintText: 'e.g. RIDE5'),
                  validator: (v) => isPromoCodeShape(v ?? '') ? null : '2 to 32 letters, digits, - or _',
                ),
                TextFormField(
                  key: const ValueKey('pc-description'),
                  controller: _description,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: 'Description (optional)'),
                ),
                heading('Discount'),
                SegmentedButton<PromoDiscountType>(
                  key: const ValueKey('pc-type'),
                  segments: const [
                    ButtonSegment(value: PromoDiscountType.fixed, label: Text('Amount (RM)')),
                    ButtonSegment(value: PromoDiscountType.percent, label: Text('Percentage')),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                ),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('pc-value'),
                      controller: _value,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: InputDecoration(
                        labelText: _type == PromoDiscountType.percent ? 'Percent off' : 'Amount off',
                        prefixText: _type == PromoDiscountType.fixed ? 'RM ' : null,
                        suffixText: _type == PromoDiscountType.percent ? '%' : null,
                      ),
                      validator: (v) {
                        final n = double.tryParse((v ?? '').trim());
                        if (n == null || n <= 0) return 'Above zero';
                        if (_type == PromoDiscountType.percent && n > 100) return 'At most 100';
                        return null;
                      },
                    ),
                  ),
                  if (_type == PromoDiscountType.percent) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: number(const ValueKey('pc-max-discount'), _maxDiscount, 'Up to (optional)', prefix: 'RM '),
                    ),
                  ],
                ]),
                heading('Limits'),
                hint('Blank: no limit.'),
                Row(children: [
                  Expanded(child: number(const ValueKey('pc-max-uses'), _maxUses, 'Uses in total', decimal: false)),
                  const SizedBox(width: 12),
                  Expanded(child: number(const ValueKey('pc-per-rider'), _perRider, 'Uses per rider', decimal: false)),
                ]),
                Row(children: [
                  Expanded(child: number(const ValueKey('pc-budget'), _budget, 'Total budget', prefix: 'RM ')),
                  const SizedBox(width: 12),
                  Expanded(child: number(const ValueKey('pc-min-fare'), _minFare, 'Minimum fare', prefix: 'RM ')),
                ]),
                heading('Valid'),
                Row(children: [
                  moment('From', _startsAt, const ValueKey('pc-starts'), (d) => _startsAt = d),
                  const SizedBox(width: 8),
                  moment('Until', _endsAt, const ValueKey('pc-ends'), (d) => _endsAt = d),
                ]),
                heading('Where'),
                hint('No region: everywhere. A point is inside when the region holds it.'),
                const SizedBox(height: 4),
                SegmentedButton<PromoAppliesTo>(
                  key: const ValueKey('pc-applies'),
                  segments: [
                    for (final a in PromoAppliesTo.values)
                      ButtonSegment(value: a, label: Text(a == PromoAppliesTo.both ? 'Both' : a.label)),
                  ],
                  selected: {_appliesTo},
                  onSelectionChanged: (s) => setState(() => _appliesTo = s.first),
                ),
                if (_appliesTo == PromoAppliesTo.both) hint('Both the pickup and the drop-off must be inside.'),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (var i = 0; i < _regions.length; i++)
                    InputChip(
                      key: ValueKey('pc-region-$i'),
                      label: Text(_regions[i].label),
                      onDeleted: () => setState(() => _regions.removeAt(i)),
                      deleteButtonTooltipMessage: 'Remove ${_regions[i].label}',
                    ),
                ]),
                _placeField('country', regions),
                if (_place['country']!.isNotEmpty) _placeField('state', regions),
                if (_place['state']!.isNotEmpty) _placeField('city', regions),
                if (_place['city']!.isNotEmpty) _placeField('suburb', regions),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('pc-region-add'),
                    onPressed: _addRegion,
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Add region'),
                  ),
                ),
                heading('When'),
                hint('Malaysia time. Nothing set: any day, any time.'),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('pc-dates'),
                      onPressed: _pickDates,
                      icon: const Icon(Icons.date_range_outlined),
                      label: Text(_dateFrom == null || _dateTo == null
                          ? 'Any date'
                          : '${_day(_dateFrom!)} – ${_day(_dateTo!)}'),
                    ),
                  ),
                  if (_dateFrom != null)
                    IconButton(
                      tooltip: 'Clear dates',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _dateFrom = _dateTo = null),
                    ),
                ]),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      key: ValueKey('pc-day-$d'),
                      label: Text(weekdayNames[d - 1]),
                      selected: _weekdays.contains(d),
                      onSelected: (v) => setState(() => v ? _weekdays.add(d) : _weekdays.remove(d)),
                    ),
                ]),
                SwitchListTile(
                  key: const ValueKey('pc-hours'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Only at certain hours'),
                  subtitle: _hours && _timeFrom > _timeTo ? const Text('Runs past midnight') : null,
                  value: _hours,
                  onChanged: (v) => setState(() => _hours = v),
                ),
                if (_hours)
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('pc-time-from'),
                        onPressed: () => _pickTime(true),
                        child: Text('From ${timeOfDayLabel(_timeFrom)}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('pc-time-to'),
                        onPressed: () => _pickTime(false),
                        child: Text('To ${timeOfDayLabel(_timeTo)}'),
                      ),
                    ),
                  ]),
                heading('Who'),
                hint('No gender ticked: everyone.'),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final g in promoGenders)
                    FilterChip(
                      key: ValueKey('pc-gender-$g'),
                      label: Text(promoGenderLabel(g)),
                      selected: _genders.contains(g),
                      onSelected: (v) => setState(() => v ? _genders.add(g) : _genders.remove(g)),
                    ),
                ]),
                SwitchListTile(
                  key: const ValueKey('pc-riders-some'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Only some riders'),
                  subtitle: Text(_someRiders ? '${_riderIds.length} chosen' : 'Every rider'),
                  value: _someRiders,
                  onChanged: (v) => setState(() => _someRiders = v),
                ),
                if (_someRiders) ...[
                  TextField(
                    key: const ValueKey('pc-rider-search'),
                    controller: _riderSearch,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _findRiders(),
                    decoration: InputDecoration(
                      labelText: 'Find a rider: name, phone, email or account id',
                      errorText: _findError,
                      suffixIcon: _finding
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : IconButton(
                              key: const ValueKey('pc-rider-find'),
                              tooltip: 'Search',
                              icon: const Icon(Icons.search),
                              onPressed: _findRiders,
                            ),
                    ),
                  ),
                  if (_found != null && _found!.isEmpty)
                    Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: hint('Nobody matches.')),
                  for (final r in _found ?? const <Map<String, dynamic>>[])
                    ListTile(
                      key: ValueKey('pc-rider-pick-${r['id']}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_add_alt_outlined),
                      title: Text(personLabel(r)),
                      subtitle: Text(personDetails(r)),
                      trailing: _riderIds.contains('${r['id']}')
                          ? Icon(Icons.check_circle, color: t.colorScheme.primary, semanticLabel: 'Chosen')
                          : null,
                      onTap: () => _addRider(r),
                    ),
                  if (_riderIds.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('Chosen riders', style: t.textTheme.labelLarge),
                    ListSearchFilter(
                      count: _riderIds.length,
                      hint: 'Search chosen riders',
                      fieldKey: const ValueKey('pc-chosen-search'),
                      builder: (context, q) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final id in _riderIds)
                            if (q.isEmpty ||
                                searchSelectMatches(
                                    '${_people[id] == null ? id : '${personLabel(_people[id]!)} ${personDetails(_people[id]!)}'} $id', q))
                              ListTile(
                                key: ValueKey('pc-rider-$id'),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.person_outline),
                                title: Text(_people[id] == null ? id : personLabel(_people[id]!)),
                                subtitle: _people[id] == null ? null : Text(personDetails(_people[id]!)),
                                trailing: IconButton(
                                  key: ValueKey('pc-rider-remove-$id'),
                                  tooltip: 'Remove',
                                  icon: const Icon(Icons.remove_circle_outline),
                                  onPressed: () => setState(() => _riderIds.remove(id)),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ],
                ],
                SwitchListTile(
                  key: const ValueKey('pc-first-ride'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('First ride only'),
                  subtitle: const Text('Riders with no completed trip yet'),
                  value: _firstRide,
                  onChanged: (v) => setState(() => _firstRide = v),
                ),
                heading('Services'),
                hint('None ticked: every service.'),
                ListSearchFilter(
                  count: services.length,
                  hint: 'Search services',
                  fieldKey: const ValueKey('pc-service-search'),
                  builder: (context, q) => Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final s in services.keys)
                        if (q.isEmpty || searchSelectMatches(s, q) || _services.contains(s))
                          FilterChip(
                            key: ValueKey('pc-service-$s'),
                            label: Text(s),
                            selected: _services.contains(s),
                            onSelected: (v) => setState(() => v ? _services.add(s) : _services.remove(s)),
                          ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const ValueKey('pc-auto-apply'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Apply by itself'),
                  subtitle: const Text('Riders who qualify get it without typing it'),
                  value: _autoApply,
                  onChanged: (v) => setState(() => _autoApply = v),
                ),
                SwitchListTile(
                  key: const ValueKey('pc-active'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('On'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
                if (_error != null)
                  Text(_error!, key: const ValueKey('pc-error'), style: TextStyle(color: t.colorScheme.error)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('pc-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
