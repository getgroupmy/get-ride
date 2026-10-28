// Admin → Services & catalogue → City to City → Per-seat trips (migration
// 0310; the approved board 15): drivers post a trip and riders book seats.
//
//   Rules        the Default and a rule per region (the trip start's most
//                specific region wins). On a region rule each part is the
//                region's own or left to the rule above ("Own setting").
//   The parts    Per-seat trips on/off; how riders join (instant, driver
//                approves, driver picks per trip; when a request lapses);
//                the seat price (a range, fixed, driver free; % of the
//                whole-car fare or RM); limits (seats, seats a booking, the
//                cut-off, days ahead); door pickup; women only; repeats;
//                co-riders; parcels.
//   By route     a route's own seat price (fixed or an RM range): 0306's
//                route rules of kind 'per_seat'.
//
// Its own permission page (c2cSeatsPage), grantable to sub-admins; City to
// City's page edits it too. The server enforces every part.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/city_to_city.dart';
import '../../../core/city_to_city_seats.dart';
import '../../../core/commission.dart' show Geo;
import '../../../data/city_to_city_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../geo/geo_data.dart' show regionsProvider;
import '../geo/geo_logic.dart' show RegionEntry;
import 'c2c_widgets.dart';

const cityToCitySeatsPath = '/admin/m/city-to-city-seats';

class CityToCitySeatsScreen extends ConsumerWidget {
  const CityToCitySeatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(c2cSeatsPage)) == AccessLevel.edit ||
        ref.watch(pageAccessProvider(c2cPage)) == AccessLevel.edit;
    // Read by Add a region rule: kept loaded while the page is open.
    ref.watch(regionsProvider);
    final t = Theme.of(context);
    return AdminPage(
      title: 'Per-seat trips',
      page: c2cSeatsPage,
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                'Drivers post a trip and riders book seats. A default rule and a rule per region where it should '
                'differ (the most specific region of the trip\'s start wins; a region rule changes only the parts it '
                'sets).',
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              _SeatRulesSection(canEdit: canEdit),
              const SizedBox(height: 16),
              _RouteSeatPrices(canEdit: canEdit),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// The list beside the editor on a wide screen, above it on a phone.
class _Split extends StatelessWidget {
  const _Split({required this.list, required this.editor});
  final Widget list, editor;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
    if (c.maxWidth >= 860) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 300, child: list),
        const SizedBox(width: 16),
        Expanded(child: editor),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [list, const SizedBox(height: 12), editor]);
  });
}

class _SeatRulesSection extends ConsumerStatefulWidget {
  const _SeatRulesSection({required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<_SeatRulesSection> createState() => _SeatRulesSectionState();
}

class _SeatRulesSectionState extends ConsumerState<_SeatRulesSection> {
  /// The rule picked (its id; 'new' for one not saved yet) and its draft.
  String? _pick;
  C2cSeatRule? _draft;
  C2cSeatRule? _loaded;

  bool get _changed => _draft != null && (_loaded == null || _draft!.toRow().toString() != _loaded!.toRow().toString());

  void _select(C2cSeatRule r) => setState(() {
    _pick = r.id ?? 'new';
    _draft = r;
    _loaded = r.id == null ? null : r;
  });

  Future<void> _add(List<C2cSeatRule> rules) async {
    final regions = ref.read(regionsProvider).value ?? const <RegionEntry>[];
    final place = await pickC2cPlace(
      context,
      title: 'Rule for a region',
      choices: c2cPlaceChoices(regions),
      taken: [for (final r in rules) ?r.place],
    );
    if (place == null || !mounted) return;
    // A new region rule sets nothing yet: every part follows the rule above.
    _select(C2cSeatRule(place: place));
  }

  Future<void> _save() async {
    final d = _draft!;
    final ok = await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).saveSeatRule(d),
        success: 'Rule saved');
    if (ok && mounted) {
      setState(() {
        _loaded = d;
        if (d.id == null) _pick = null;
      });
      ref.invalidate(c2cSeatRulesProvider);
    }
  }

  Future<void> _delete() async {
    final d = _draft!;
    if (d.id == null) {
      setState(() => _pick = _draft = _loaded = null);
      return;
    }
    if (!await confirm(context, 'Delete rule?', 'Trips from ${d.name} follow the rule above again.', ok: 'Delete') ||
        !mounted) {
      return;
    }
    if (await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).deleteSeatRule(d.id!),
        success: 'Rule deleted')) {
      setState(() => _pick = _draft = _loaded = null);
      ref.invalidate(c2cSeatRulesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(c2cSeatRulesProvider);
    return AsyncView(
      value: async,
      onRetry: () => ref.invalidate(c2cSeatRulesProvider),
      data: (stored) {
        final rules = [
          ...stored.where((r) => r.isDefault),
          ...stored.where((r) => !r.isDefault).toList()
            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
        ];
        var draft = _draft;
        if (_pick != 'new') {
          final live = rules.where((r) => r.id == _pick).firstOrNull ?? rules.firstOrNull;
          if (live != null && (draft == null || !_changed || draft.id != live.id)) {
            draft = live;
            _draft = live;
            _loaded = live;
            _pick = live.id;
          }
        }
        final shown = [...rules, if (_pick == 'new' && draft != null) draft];
        final all = [for (final r in rules) if (draft != null && r.id == draft.id) draft else r];
        return _Split(
          list: _RuleList(
            rules: shown,
            all: all,
            selected: draft,
            onPick: _select,
            onAdd: widget.canEdit ? () => _add(rules) : null,
          ),
          editor: draft == null
              ? const SizedBox.shrink()
              : _SeatRuleEditor(
                  rule: draft,
                  above: c2cSeatTermsAbove(all, draft),
                  onChanged: widget.canEdit ? (r) => setState(() => _draft = r) : null,
                  footer: widget.canEdit
                      ? _SaveRow(
                          problem: draft.problem,
                          changed: _changed,
                          onSave: _save,
                          onDelete: draft.isDefault ? null : _delete,
                        )
                      : null,
                ),
        );
      },
    );
  }
}

/// The rules, the Default first, each with what it comes to; Add a region rule.
class _RuleList extends StatelessWidget {
  const _RuleList({required this.rules, required this.all, required this.selected, required this.onPick, this.onAdd});
  final List<C2cSeatRule> rules, all;
  final C2cSeatRule? selected;
  final ValueChanged<C2cSeatRule> onPick;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    String summary(C2cSeatRule r) {
      if (!r.active) return 'Rule off';
      final p = r.place;
      final terms = p == null
          ? C2cSeatTerms(r.values)
          : c2cSeatTermsFor([...all.where((x) => x.id != r.id), r], c2cPlaceGeo(p));
      return c2cSeatRuleSummary(terms);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text('Rules', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          for (final r in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: identical(r, selected) ? cs.primaryContainer : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: identical(r, selected) ? cs.primary : cs.outlineVariant,
                    width: identical(r, selected) ? 2 : 1,
                  ),
                ),
                child: ListTile(
                  key: ValueKey('c2c-seat-rule-${r.id ?? 'new'}'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: Icon(r.isDefault ? Icons.public : Icons.location_on_outlined),
                  title: Text(r.name),
                  subtitle: Text(summary(r)),
                  textColor: identical(r, selected) ? cs.onPrimaryContainer : null,
                  iconColor: identical(r, selected) ? cs.onPrimaryContainer : null,
                  onTap: () => onPick(r),
                ),
              ),
            ),
          if (onAdd != null)
            OutlinedButton.icon(
              key: const ValueKey('c2c-seat-rule-add'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: onAdd,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('Add a region rule'),
            ),
        ]),
      ),
    );
  }
}

/// A place as the trip end it names.
Geo c2cPlaceGeo(C2cPlace p) => Geo(
  country: p.country,
  state: p.rank >= 2 ? p.state : null,
  city: p.rank >= 3 ? p.city : null,
  suburb: p.rank >= 4 ? p.suburb : null,
);

/// Why it can't be saved, or whether it is; Delete and Save.
class _SaveRow extends StatelessWidget {
  const _SaveRow({required this.problem, required this.changed, required this.onSave, this.onDelete});
  final String? problem;
  final bool changed;
  final VoidCallback onSave;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(problem ?? (changed ? 'Not saved yet.' : 'Saved.'),
              style: TextStyle(color: problem != null ? cs.error : cs.onSurfaceVariant)),
          if (onDelete != null)
            TextButton.icon(
              key: const ValueKey('c2c-seat-delete'),
              style: TextButton.styleFrom(foregroundColor: cs.error, minimumSize: const Size(0, 44)),
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete rule'),
            ),
          FilledButton.icon(
            key: const ValueKey('c2c-seat-save'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: changed && problem == null ? onSave : null,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

final _seg = SegmentedButton.styleFrom(visualDensity: VisualDensity.compact);

/// One rule: each part, the region's own or the rule above's.
class _SeatRuleEditor extends StatelessWidget {
  const _SeatRuleEditor({required this.rule, required this.above, this.onChanged, this.footer});
  final C2cSeatRule rule;

  /// What the rule above gives (the parts a region rule leaves).
  final C2cSeatTerms above;
  final ValueChanged<C2cSeatRule>? onChanged;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final r = rule;
    // What the editor shows: the rule's own parts, else the rule above's.
    final shown = C2cSeatTerms({
      for (final p in C2cSeatPart.values)
        for (final c in p.columns) c: r.sets(p) ? r.values[c] : above.values[c],
    });
    ValueChanged<Map<String, Object?>>? edit(C2cSeatPart p) =>
        onChanged == null || !r.sets(p) ? null : (v) => onChanged!(r.withValues(v));
    Widget part(C2cSeatPart p, Widget body) => _PartBox(
      part: p,
      region: !r.isDefault,
      own: r.sets(p),
      onOwn: onChanged == null || r.isDefault ? null : (v) => onChanged!(r.withPart(p, v ? above : null)),
      child: body,
    );
    VoidCallback? step(ValueChanged<Map<String, Object?>>? on, bool ok, Map<String, Object?> v) =>
        on == null || !ok ? null : () => on(v);
    final s = shown;
    String money(double v) => c2cMoney(v);

    final join = edit(C2cSeatPart.join);
    final price = edit(C2cSeatPart.price);
    final limits = edit(C2cSeatPart.limits);
    final door = edit(C2cSeatPart.door);
    final repeat = edit(C2cSeatPart.repeat);
    final parcels = edit(C2cSeatPart.parcels);
    final on = edit(C2cSeatPart.on);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: t.textTheme.titleLarge),
                Text(r.scope, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
            if (!r.isDefault) ...[
              Text('Rule on', style: t.textTheme.bodyMedium),
              Switch(
                key: const ValueKey('c2c-seat-active'),
                value: r.active,
                onChanged: onChanged == null ? null : (v) => onChanged!(r.copyWith(active: v)),
              ),
            ],
          ]),
          part(
            C2cSeatPart.on,
            SwitchListTile(
              key: const ValueKey('c2c-seat-on'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Per-seat trips'),
              subtitle: const Text('Off: drivers can\'t post trips that start here'),
              value: s.seatsOn,
              onChanged: on == null ? null : (v) => on({'seats_on': v}),
            ),
          ),
          part(
            C2cSeatPart.join,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<C2cJoinMode>(
                key: const ValueKey('c2c-seat-join'),
                style: _seg,
                segments: [for (final m in C2cJoinMode.values) ButtonSegment(value: m, label: Text(m.label))],
                selected: {s.joinMode},
                onSelectionChanged: join == null ? null : (v) => join({'join_mode': v.first.key}),
              ),
              const SizedBox(height: 4),
              Text(s.joinMode.note(hours: s.approveHours, beforeMin: s.approveBeforeMin),
                  key: const ValueKey('c2c-seat-join-note'),
                  style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              if (s.joinMode != C2cJoinMode.instant) ...[
                C2cStepper(
                  label: 'A request lapses after',
                  value: '${s.approveHours} h',
                  onDown: step(join, s.approveHours > 1, {'approve_hours': s.approveHours - 1}),
                  onUp: step(join, s.approveHours < 72, {'approve_hours': s.approveHours + 1}),
                ),
                C2cStepper(
                  label: 'Or before leaving',
                  value: c2cMinutesText(s.approveBeforeMin),
                  onDown: step(join, s.approveBeforeMin >= 15, {'approve_before_min': s.approveBeforeMin - 15}),
                  onUp: step(join, s.approveBeforeMin <= 1425, {'approve_before_min': s.approveBeforeMin + 15}),
                ),
              ],
            ]),
          ),
          part(
            C2cSeatPart.price,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<C2cSeatPriceMode>(
                key: const ValueKey('c2c-seat-price'),
                style: _seg,
                segments: [for (final m in C2cSeatPriceMode.values) ButtonSegment(value: m, label: Text(m.label))],
                selected: {s.priceMode},
                onSelectionChanged: price == null ? null : (v) => price({'price_mode': v.first.key}),
              ),
              if (s.priceMode != C2cSeatPriceMode.free) ...[
                const SizedBox(height: 8),
                SegmentedButton<C2cSeatRangeMode>(
                  key: const ValueKey('c2c-seat-range'),
                  style: _seg,
                  segments: [for (final m in C2cSeatRangeMode.values) ButtonSegment(value: m, label: Text(m.label))],
                  selected: {s.rangeMode},
                  onSelectionChanged: price == null ? null : (v) => price({'range_mode': v.first.key}),
                ),
                if (s.rangeMode == C2cSeatRangeMode.percent) ...[
                  C2cStepper(
                    label: 'Lowest',
                    hint: 'Of the whole-car fare',
                    value: '${s.pctLow.round()}%',
                    valueKey: const ValueKey('c2c-seat-pct-low'),
                    onDown: step(price, s.pctLow > 5, {'pct_low': s.pctLow - 5}),
                    onUp: step(price, s.pctLow + 5 <= s.pctHigh, {'pct_low': s.pctLow + 5}),
                  ),
                  C2cStepper(
                    label: 'Highest',
                    value: '${s.pctHigh.round()}%',
                    valueKey: const ValueKey('c2c-seat-pct-high'),
                    onDown: step(price, s.pctHigh - 5 >= s.pctLow, {'pct_high': s.pctHigh - 5}),
                    onUp: step(price, s.pctHigh <= 95, {'pct_high': s.pctHigh + 5}),
                  ),
                ] else ...[
                  C2cStepper(
                    label: 'Lowest',
                    value: money(s.amountLow),
                    onDown: step(price, s.amountLow > 5, {'amount_low': s.amountLow - 5}),
                    onUp: step(price, s.amountLow + 5 <= s.amountHigh, {'amount_low': s.amountLow + 5}),
                  ),
                  C2cStepper(
                    label: 'Highest',
                    value: money(s.amountHigh),
                    onDown: step(price, s.amountHigh - 5 >= s.amountLow, {'amount_high': s.amountHigh - 5}),
                    onUp: step(price, s.amountHigh < 100000, {'amount_high': s.amountHigh + 5}),
                  ),
                ],
              ],
              const SizedBox(height: 4),
              Text(c2cSeatRangeExample(s),
                  key: const ValueKey('c2c-seat-price-example'), style: t.textTheme.bodyMedium),
              Text(s.priceMode.note, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
          part(
            C2cSeatPart.limits,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              C2cStepper(
                label: 'Seats a trip',
                value: '${s.maxSeats}',
                onDown: step(limits, s.maxSeats > 1, {'max_seats': s.maxSeats - 1}),
                onUp: step(limits, s.maxSeats < 8, {'max_seats': s.maxSeats + 1}),
              ),
              C2cStepper(
                label: 'Seats a booking',
                hint: 'More than 1 needs co-riders on',
                value: '${s.maxPerBooking}',
                onDown: step(limits, s.maxPerBooking > 1, {'max_per_booking': s.maxPerBooking - 1}),
                onUp: step(limits, s.maxPerBooking < 6, {'max_per_booking': s.maxPerBooking + 1}),
              ),
              C2cStepper(
                label: 'Booking closes',
                hint: 'Before leaving',
                value: c2cMinutesText(s.cutoffMin),
                valueKey: const ValueKey('c2c-seat-cutoff'),
                onDown: step(limits, s.cutoffMin >= 15, {'cutoff_min': s.cutoffMin - 15}),
                onUp: step(limits, s.cutoffMin <= 1425, {'cutoff_min': s.cutoffMin + 15}),
              ),
              C2cStepper(
                label: 'Post up to',
                hint: 'Days ahead',
                value: '${s.postAheadDays} d',
                onDown: step(limits, s.postAheadDays > 1, {'post_ahead_days': s.postAheadDays - 1}),
                onUp: step(limits, s.postAheadDays < 90, {'post_ahead_days': s.postAheadDays + 1}),
              ),
            ]),
          ),
          part(
            C2cSeatPart.door,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Meeting points set by the driver (always on).', style: t.textTheme.bodyMedium),
              CheckboxListTile(
                key: const ValueKey('c2c-seat-door'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('Drivers may offer door pickup: up to ${s.doorMaxKm.toStringAsFixed(s.doorMaxKm % 1 == 0 ? 0 : 1)} km '
                    'off the route, ${money(s.doorPerKm)} a km extra'),
                value: s.doorOn,
                onChanged: door == null ? null : (v) => door({'door_on': v ?? false}),
              ),
              if (s.doorOn) ...[
                C2cStepper(
                  label: 'Up to',
                  hint: 'Km off the route',
                  value: '${s.doorMaxKm.toStringAsFixed(1)} km',
                  onDown: step(door, s.doorMaxKm > 0.5, {'door_max_km': s.doorMaxKm - 0.5}),
                  onUp: step(door, s.doorMaxKm < 50, {'door_max_km': s.doorMaxKm + 0.5}),
                ),
                C2cStepper(
                  label: 'Extra a km',
                  value: money(s.doorPerKm),
                  onDown: step(door, s.doorPerKm >= 0.5, {'door_per_km': s.doorPerKm - 0.5}),
                  onUp: step(door, s.doorPerKm < 1000, {'door_per_km': s.doorPerKm + 0.5}),
                ),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text('Drivers may', style: t.textTheme.titleSmall),
          ),
          part(
            C2cSeatPart.women,
            _Tick(
              keyName: 'women',
              label: 'Mark a trip women only',
              note: 'Woman drivers with a verified ID; only riders whose verified profile says female can book',
              value: s.womenOn,
              onChanged: edit(C2cSeatPart.women) == null ? null : (v) => edit(C2cSeatPart.women)!({'women_on': v}),
            ),
          ),
          part(
            C2cSeatPart.repeat,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Tick(
                keyName: 'repeat',
                label: 'Repeat a trip',
                note: 'Every day, weekdays or weekly, for up to ${s.repeatMaxWeeks} ${s.repeatMaxWeeks == 1 ? 'week' : 'weeks'}',
                value: s.repeatOn,
                onChanged: repeat == null ? null : (v) => repeat({'repeat_on': v}),
              ),
              if (s.repeatOn)
                C2cStepper(
                  label: 'Up to',
                  value: '${s.repeatMaxWeeks} wk',
                  onDown: step(repeat, s.repeatMaxWeeks > 1, {'repeat_max_weeks': s.repeatMaxWeeks - 1}),
                  onUp: step(repeat, s.repeatMaxWeeks < 12, {'repeat_max_weeks': s.repeatMaxWeeks + 1}),
                ),
            ]),
          ),
          part(
            C2cSeatPart.coriders,
            _Tick(
              keyName: 'coriders',
              label: 'Book seats for co-riders',
              note: 'Several seats in one booking, each passenger named; riders see the first name, rating and pickup '
                  'point of the others, after booking',
              value: s.coridersOn,
              onChanged: edit(C2cSeatPart.coriders) == null
                  ? null
                  : (v) => edit(C2cSeatPart.coriders)!({'coriders_on': v}),
            ),
          ),
          part(
            C2cSeatPart.parcels,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Tick(
                keyName: 'parcels',
                label: 'Carry parcels',
                note: 'Spare boot space: a parcel takes a parcel slot, priced by the driver within these limits',
                value: s.parcelsOn,
                onChanged: parcels == null ? null : (v) => parcels({'parcels_on': v}),
              ),
              if (s.parcelsOn) ...[
                C2cStepper(
                  label: 'Parcel slots a trip',
                  value: '${s.parcelMaxSlots}',
                  onDown: step(parcels, s.parcelMaxSlots > 1, {'parcel_max_slots': s.parcelMaxSlots - 1}),
                  onUp: step(parcels, s.parcelMaxSlots < 6, {'parcel_max_slots': s.parcelMaxSlots + 1}),
                ),
                const SizedBox(height: 4),
                Text('Biggest parcel', style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 4),
                SegmentedButton<C2cParcelSize>(
                  key: const ValueKey('c2c-seat-parcel-size'),
                  style: _seg,
                  segments: [for (final z in C2cParcelSize.values) ButtonSegment(value: z, label: Text(z.label))],
                  selected: {s.parcelMaxSize},
                  onSelectionChanged: parcels == null ? null : (v) => parcels({'parcel_max_size': v.first.key}),
                ),
                C2cStepper(
                  label: 'Parcel price from',
                  value: money(s.parcelMinPrice),
                  onDown: step(parcels, s.parcelMinPrice >= 1, {'parcel_min_price': s.parcelMinPrice - 1}),
                  onUp: step(parcels, s.parcelMinPrice + 1 <= s.parcelMaxPrice, {'parcel_min_price': s.parcelMinPrice + 1}),
                ),
                C2cStepper(
                  label: 'Parcel price to',
                  value: money(s.parcelMaxPrice),
                  onDown: step(parcels, s.parcelMaxPrice - 1 >= s.parcelMinPrice, {'parcel_max_price': s.parcelMaxPrice - 1}),
                  onUp: step(parcels, s.parcelMaxPrice < 10000, {'parcel_max_price': s.parcelMaxPrice + 1}),
                ),
              ],
            ]),
          ),
          ?footer,
        ]),
      ),
    );
  }
}

/// A part of a rule; on a region rule with "Own setting" (off: the rule
/// above's, shown greyed).
class _PartBox extends StatelessWidget {
  const _PartBox({required this.part, required this.region, required this.own, this.onOwn, required this.child});
  final C2cSeatPart part;
  final bool region, own;
  final ValueChanged<bool>? onOwn;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(part.label, style: t.textTheme.titleSmall)),
          if (region) ...[
            Text(own ? 'Own setting' : 'As the rule above',
                style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            Switch(
              key: ValueKey('c2c-seat-own-${part.name}'),
              value: own,
              onChanged: onOwn,
            ),
          ],
        ]),
        Opacity(opacity: region && !own ? 0.6 : 1, child: child),
      ]),
    );
  }
}

/// A tick box with a note under it.
class _Tick extends StatelessWidget {
  const _Tick({required this.keyName, required this.label, required this.note, required this.value, this.onChanged});
  final String keyName, label, note;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    key: ValueKey('c2c-seat-$keyName'),
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    title: Text(label),
    subtitle: Text(note),
    value: value,
    onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
  );
}

// ---- Seat price by route ---------------------------------------------------------------------------------

class _RouteSeatPrices extends ConsumerWidget {
  const _RouteSeatPrices({required this.canEdit});
  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, C2cRule? rule) async {
    final regions = ref.read(regionsProvider).value ?? const <RegionEntry>[];
    final out = await showAppDialog<C2cRule>(
      id: 'admin.city-to-city-seat-route',
      context: context,
      builder: (_) => _RouteSeatDialog(rule: rule, choices: c2cPlaceChoices(regions)),
    );
    if (out == null || !context.mounted) return;
    if (await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).saveRule(out),
        success: 'Seat price saved')) {
      ref.invalidate(c2cRulesProvider);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, C2cRule r) async {
    if (!await confirm(context, 'Delete seat price?', 'Trips on this route follow the region\'s seat price again.',
        ok: 'Delete')) {
      return;
    }
    if (!context.mounted) return;
    if (await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).deleteRule(r.id!),
        success: 'Seat price deleted')) {
      ref.invalidate(c2cRulesProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final async = ref.watch(c2cRulesProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.route_outlined, 'Seat price by route'),
          Text(
            'A route\'s own seat price: fixed, or an RM range drivers price inside. It wins over the region\'s range '
            '(not over Driver free). The most specific route wins, as with whole-car rules.',
            style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: async,
            onRetry: () => ref.invalidate(c2cRulesProvider),
            data: (all) {
              final rules = [for (final r in all) if (r.tripKind == 'per_seat') r];
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (rules.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('No route has its own seat price.', key: const ValueKey('c2c-seat-routes-none'),
                        style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                for (final r in rules)
                  ListTile(
                    key: ValueKey('c2c-seat-route-${r.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(r.active ? Icons.event_seat_outlined : Icons.event_seat, color: r.active ? null : cs.outline),
                    title: Text('${r.from.map((p) => p.name).join(', ')} to ${r.to.map((p) => p.name).join(', ')}'),
                    subtitle: Text(c2cSeatRouteLine(r)),
                    onTap: canEdit ? () => _edit(context, ref, r) : null,
                    trailing: canEdit
                        ? IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, ref, r),
                          )
                        : null,
                  ),
                if (canEdit)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('c2c-seat-route-add'),
                      onPressed: () => _edit(context, ref, null),
                      icon: const Icon(Icons.add),
                      label: const Text('Add a route'),
                    ),
                  ),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

/// "Fixed RM 45 a seat" / "RM 35 to RM 60 a seat"; "Off. …" when off.
String c2cSeatRouteLine(C2cRule r) {
  final line = r.fareMode == C2cFareMode.fixed
      ? 'Fixed ${c2cMoney(r.fixedFare ?? 0)} a seat'
      : '${c2cMoney(r.rangeLow ?? 0)} to ${c2cMoney(r.rangeHigh ?? 0)} a seat';
  return r.active ? line : 'Off. $line';
}

class _RouteSeatDialog extends StatefulWidget {
  const _RouteSeatDialog({required this.rule, required this.choices});
  final C2cRule? rule;
  final List<C2cPlace> choices;

  @override
  State<_RouteSeatDialog> createState() => _RouteSeatDialogState();
}

class _RouteSeatDialogState extends State<_RouteSeatDialog> {
  late C2cRule _r = widget.rule ??
      const C2cRule(tripKind: 'per_seat', fareMode: C2cFareMode.fixed, fixedFare: 45, rangeMode: C2cRangeMode.set,
          rangeLow: 35, rangeHigh: 60);

  bool get _fixed => _r.fareMode == C2cFareMode.fixed;

  String? get _problem {
    if (_r.from.isEmpty || _r.to.isEmpty) return 'Pick where the route starts and ends.';
    if (_fixed && (_r.fixedFare ?? 0) <= 0) return 'Set the seat price.';
    if (!_fixed && (_r.rangeLow ?? 0) > (_r.rangeHigh ?? 0)) return 'The lowest price must not be above the highest.';
    return null;
  }

  Future<void> _addPlace(bool from) async {
    final p = await pickC2cPlace(context,
        title: from ? 'From' : 'To', choices: widget.choices, taken: from ? _r.from : _r.to);
    if (p == null || !mounted) return;
    setState(() => _r = from ? _r.copyWith(from: [..._r.from, p]) : _r.copyWith(to: [..._r.to, p]));
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return AlertDialog(
      title: Text(widget.rule == null ? 'Seat price for a route' : 'Change seat price'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('From'),
            const SizedBox(height: 4),
            C2cPlaceChips(
              places: r.from,
              keyPrefix: 'seat-from-',
              onRemove: (p) => setState(() => _r = r.copyWith(from: [...r.from]..remove(p))),
              onAdd: () => _addPlace(true),
            ),
            const SizedBox(height: 10),
            const Text('To'),
            const SizedBox(height: 4),
            C2cPlaceChips(
              places: r.to,
              from: false,
              keyPrefix: 'seat-to-',
              onRemove: (p) => setState(() => _r = r.copyWith(to: [...r.to]..remove(p))),
              onAdd: () => _addPlace(false),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              key: const ValueKey('c2c-seat-route-mode'),
              style: _seg,
              segments: const [
                ButtonSegment(value: true, label: Text('Fixed seat price')),
                ButtonSegment(value: false, label: Text('RM range')),
              ],
              selected: {_fixed},
              onSelectionChanged: (v) => setState(() => _r = r.copyWith(
                fareMode: v.first ? C2cFareMode.fixed : C2cFareMode.card,
                fixedFare: r.fixedFare ?? 45,
                rangeMode: C2cRangeMode.set,
                rangeLow: r.rangeLow ?? 35,
                rangeHigh: r.rangeHigh ?? 60,
              )),
            ),
            if (_fixed)
              C2cStepper(
                label: 'A seat',
                value: c2cMoney(r.fixedFare ?? 0),
                valueKey: const ValueKey('c2c-seat-route-fixed'),
                onDown: (r.fixedFare ?? 0) > 5 ? () => setState(() => _r = r.copyWith(fixedFare: r.fixedFare! - 5)) : null,
                onUp: () => setState(() => _r = r.copyWith(fixedFare: (r.fixedFare ?? 0) + 5)),
              )
            else ...[
              C2cStepper(
                label: 'Lowest',
                value: c2cMoney(r.rangeLow ?? 0),
                onDown: (r.rangeLow ?? 0) > 5 ? () => setState(() => _r = r.copyWith(rangeLow: r.rangeLow! - 5)) : null,
                onUp: (r.rangeLow ?? 0) + 5 <= (r.rangeHigh ?? 0)
                    ? () => setState(() => _r = r.copyWith(rangeLow: r.rangeLow! + 5))
                    : null,
              ),
              C2cStepper(
                label: 'Highest',
                value: c2cMoney(r.rangeHigh ?? 0),
                onDown: (r.rangeHigh ?? 0) - 5 >= (r.rangeLow ?? 0)
                    ? () => setState(() => _r = r.copyWith(rangeHigh: r.rangeHigh! - 5))
                    : null,
                onUp: () => setState(() => _r = r.copyWith(rangeHigh: (r.rangeHigh ?? 0) + 5)),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('On'),
              value: r.active,
              onChanged: (v) => setState(() => _r = r.copyWith(active: v)),
            ),
            if (_problem != null)
              Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('c2c-seat-route-save'),
          onPressed: _problem == null ? () => Navigator.pop(context, _r) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
