// Side menu > Telematics (migration 0255): how far the driver drove while
// online, to pickups and with passengers (estimated against actual), and
// their trips by type, for today, this week, this month or a range; all
// their vehicles or one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/telematics.dart';
import '../../data/telematics_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/search_select.dart';
import '../../widgets/side_menu_host.dart';
import '../telematics/telematics_widgets.dart';

class TelematicsScreen extends ConsumerStatefulWidget {
  const TelematicsScreen({super.key});

  @override
  ConsumerState<TelematicsScreen> createState() => _TelematicsScreenState();
}

class _TelematicsScreenState extends ConsumerState<TelematicsScreen> {
  TelematicsPeriod _period = TelematicsPeriod.week;
  late DateTime _last = _today();
  late DateTime _first = _last.subtract(const Duration(days: 6));

  /// One vehicle, or all ('').
  String _vehicle = '';

  DateTime _today() {
    final n = ref.read(telematicsClockProvider)();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  Widget build(BuildContext context) {
    final range = telematicsRange(_period, ref.read(telematicsClockProvider)(), first: _first, last: _last);
    final me = ref.watch(currentUserIdProvider);
    final vehicles = ref.watch(
      telematicsListProvider((scope: TelematicsScope.self, range: range, group: TelematicsGroup.vehicle)),
    );
    final cars = [
      for (final v in vehicles.value ?? const <TelematicsListRow>[])
        if (v.vehicleId != null) v,
    ];
    final query = (
      scope: TelematicsScope.self,
      range: range,
      driverId: me,
      vehicleId: _vehicle.isEmpty ? null : _vehicle,
    );
    final summary = ref.watch(telematicsSummaryProvider(query));
    return Scaffold(
      appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Telematics')),
      body: RefreshIndicator(
        onRefresh: () {
          ref.invalidate(telematicsListProvider);
          return ref.refresh(telematicsSummaryProvider(query).future);
        },
        child: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            ResponsiveCenter(
              maxWidth: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                  SearchableDropdownFormField<String>(
                    key: ValueKey('telematics-vehicle-${cars.length}'),
                    isExpanded: true,
                    initialValue: cars.any((c) => c.vehicleId == _vehicle) ? _vehicle : '',
                    decoration: const InputDecoration(labelText: 'Vehicle', isDense: true),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('All my vehicles')),
                      for (final c in cars)
                        DropdownMenuItem(value: c.vehicleId!, child: Text(c.vehicleLabel, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => _vehicle = v ?? ''),
                  ),
                  const SizedBox(height: 12),
                  AsyncView(
                    value: summary,
                    errorTitle: "Couldn't load your telematics",
                    onRetry: () => ref.invalidate(telematicsSummaryProvider(query)),
                    data: (s) => TelematicsReport(summary: s, range: range),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Kilometres are counted while you are online in the app, from your phone\'s location '
                    '(or the car\'s odometer when an OBD-II reader is connected).',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
