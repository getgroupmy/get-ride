// Telematics for many drivers and vehicles (migration 0255): Admin >
// Telematics (everyone), and the Dispatch page's Telematics tab for a fleet
// owner (their fleet's vehicles) or a stand admin (their stand's orders).
// Driver / Vehicle / Driver + vehicle, one picked from a searchable list
// (or all of them), the period, the report, the period's list and its CSV.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/telematics.dart';
import '../../data/telematics_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/image_share.dart' show shareOriginOf;
import '../../widgets/search_select.dart';
import '../partner/earnings_screen.dart' show CsvShareOutcome, earningsCsvSharerProvider;
import 'telematics_widgets.dart';

class TelematicsScopeView extends ConsumerStatefulWidget {
  const TelematicsScopeView({super.key, required this.scope});

  final TelematicsScope scope;

  @override
  ConsumerState<TelematicsScopeView> createState() => _TelematicsScopeViewState();
}

class _TelematicsScopeViewState extends ConsumerState<TelematicsScopeView> {
  TelematicsPeriod _period = TelematicsPeriod.week;
  TelematicsGroup _group = TelematicsGroup.driver;
  late DateTime _last = _today();
  late DateTime _first = _last.subtract(const Duration(days: 6));

  /// The picked row (null: all of the scope).
  TelematicsListRow? _picked;

  DateTime _today() {
    final n = ref.read(telematicsClockProvider)();
    return DateTime(n.year, n.month, n.day);
  }

  TelematicsRange get _range =>
      telematicsRange(_period, ref.read(telematicsClockProvider)(), first: _first, last: _last);

  String _allLabel() => switch (widget.scope.kind) {
    'fleet' => 'All ${_group.plural} of ${widget.scope.name ?? 'the fleet'}',
    'stand' => 'All ${_group.plural} of ${widget.scope.name ?? 'the stand'}',
    _ => 'All ${_group.plural}',
  };

  String _rowLabel(TelematicsListRow r) => switch (_group) {
    TelematicsGroup.driver => r.driverLabel,
    TelematicsGroup.vehicle => r.vehicleLabel,
    TelematicsGroup.pair => '${r.driverLabel} in ${r.plate ?? 'a vehicle not recorded'}',
  };

  bool _pickable(TelematicsListRow r) => switch (_group) {
    TelematicsGroup.driver => r.driverId != null,
    TelematicsGroup.vehicle => r.vehicleId != null,
    TelematicsGroup.pair => r.driverId != null && r.vehicleId != null,
  };

  Future<void> _pick(List<TelematicsListRow> rows) async {
    final choices = <SearchChoice<String>>[
      (value: '', label: _allLabel(), subtitle: null, leading: null),
      for (final r in rows)
        if (_pickable(r))
          (
            value: r.key(_group),
            label: _rowLabel(r),
            subtitle: '${formatTelematicsKm(r.onlineKm)} km online · ${r.trips} trips',
            leading: null,
          ),
    ];
    final key = await showSearchPicker<String>(
      context,
      title: 'Pick a ${_group.label.toLowerCase()}',
      choices: choices,
      selected: _picked?.key(_group) ?? '',
    );
    if (key == null || !mounted) return;
    setState(() => _picked = key.isEmpty ? null : rows.firstWhere((r) => r.key(_group) == key));
  }

  Future<void> _export(BuildContext button, List<TelematicsListRow> rows) async {
    final messenger = ScaffoldMessenger.of(button);
    final name = telematicsCsvFileName(_group, _range);
    final outcome = await ref.read(earningsCsvSharerProvider)(
      telematicsListCsv(rows, _group),
      name,
      shareOriginOf(button),
    );
    final note = switch (outcome) {
      CsvShareOutcome.shared => null,
      CsvShareOutcome.downloaded => 'Downloaded $name.',
      CsvShareOutcome.copied => 'Couldn\'t open sharing; the CSV is on your clipboard.',
      CsvShareOutcome.failed => 'Couldn\'t export the CSV.',
    };
    if (note != null) messenger.showSnackBar(SnackBar(content: Text(note)));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final range = _range;
    final listQuery = (scope: widget.scope, range: range, group: _group);
    final list = ref.watch(telematicsListProvider(listQuery));
    final rows = list.value ?? const <TelematicsListRow>[];
    final picked = _picked;
    final query = (
      scope: widget.scope,
      range: range,
      driverId: _group == TelematicsGroup.vehicle ? null : picked?.driverId,
      vehicleId: _group == TelematicsGroup.driver ? null : picked?.vehicleId,
    );
    final summary = ref.watch(telematicsSummaryProvider(query));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<TelematicsGroup>(
              key: const ValueKey('telematics-group'),
              showSelectedIcon: false,
              segments: [
                for (final g in TelematicsGroup.values) ButtonSegment(value: g, label: Text(g.label)),
              ],
              selected: {_group},
              onSelectionChanged: (v) => setState(() {
                _group = v.first;
                _picked = null;
              }),
            ),
            OutlinedButton.icon(
              key: const ValueKey('telematics-pick'),
              onPressed: list.hasValue ? () => _pick(rows) : null,
              icon: const Icon(Icons.search, size: 18),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(picked == null ? _allLabel() : _rowLabel(picked), overflow: TextOverflow.ellipsis),
              ),
            ),
            Builder(
              builder: (button) => TextButton.icon(
                key: const ValueKey('telematics-export'),
                onPressed: rows.isEmpty ? null : () => _export(button, rows),
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('Export CSV'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TelematicsPeriodPicker(
          period: _period,
          onPeriod: (p) => setState(() => _period = p),
          first: _first,
          last: _last,
          today: _today(),
          onRange: (a, b) => setState(() {
            _first = a;
            _last = b;
          }),
        ),
        const SizedBox(height: 12),
        AsyncView(
          value: summary,
          errorTitle: "Couldn't load telematics",
          onRetry: () => ref.invalidate(telematicsSummaryProvider(query)),
          data: (s) => TelematicsReport(summary: s, range: range),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 4),
          child: Text('All ${_group.plural} in this period', style: t.textTheme.titleSmall),
        ),
        AsyncView(
          value: list,
          errorTitle: "Couldn't load the list",
          onRetry: () => ref.invalidate(telematicsListProvider(listQuery)),
          data: (rows) => TelematicsListTable(
            rows: rows,
            group: _group,
            selected: picked?.key(_group),
            onPick: (r) {
              if (_pickable(r)) setState(() => _picked = picked?.key(_group) == r.key(_group) ? null : r);
            },
          ),
        ),
      ],
    );
  }
}
