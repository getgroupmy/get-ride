// A fleet owner's fleet (migration 0251): its drivers (added by phone or
// plate, removed), the drivers asking to join, its vehicles — added through
// the driver app's own vehicle steps and the admin's usual approval — with
// who drives each (an assignment that waits for an admin), and today's stand
// orders. The server lets a fleet owner touch only their own fleet.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dispatch.dart';
import '../../data/dispatch_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../partner/vehicle_screens.dart' show VehicleOnboardingScreen;
import 'dispatch_console.dart' show dispatchErrorText;

final fleetProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, id) => ref.watch(dispatchRepositoryProvider).fleet(id),
);
final fleetVehiclesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, id) => ref.watch(dispatchRepositoryProvider).fleetVehicles(id),
);

/// A vehicle's approval as the fleet owner reads it.
String vehicleApprovalLabel(Map<String, dynamic> v) {
  final s = '${v['status'] ?? ''}';
  if (s == 'approved' || s == 'permit-verified') return 'Approved';
  if (s == 'rejected' || s == 'blocked') return 'Rejected';
  return v['documents_ok'] == true ? 'Pending review' : 'Documents to add';
}

/// An assignment's approval.
String assignmentLabel(Object? approval) => switch (approval) {
  'approved' => 'Approved',
  'rejected' => 'Rejected',
  _ => 'Pending review',
};

class FleetView extends ConsumerStatefulWidget {
  const FleetView({super.key, required this.fleets});
  final List<DispatchGroup> fleets;

  @override
  ConsumerState<FleetView> createState() => _FleetViewState();
}

class _FleetViewState extends ConsumerState<FleetView> {
  late String _id = widget.fleets.first.id;
  final _add = TextEditingController();

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  void _reload() {
    ref.invalidate(fleetProvider(_id));
    ref.invalidate(fleetVehiclesProvider(_id));
  }

  Future<void> _run(Future<void> Function() f, [String? done]) async {
    try {
      await f();
      _reload();
      if (done != null && mounted) showInfo(context, done);
    } catch (e) {
      if (mounted) showError(context, dispatchErrorText(e));
    }
  }

  /// The driver app's own vehicle steps: a new vehicle, or [id]'s.
  Future<void> _openVehicle(String? id) => Navigator.of(context).push(
    AppPageRoute<void>(
      id: 'dispatch.fleet-vehicle',
      builder: (_) => VehicleOnboardingScreen(vehicleId: id),
    ),
  );

  Future<void> _addVehicle() async {
    final repo = ref.read(dispatchRepositoryProvider);
    await _openVehicle(null);
    // The vehicles the owner made and not yet in a fleet join this one.
    await _run(() async {
      for (final v in await repo.fleetVehicles(_id)) {
        if (v['fleet_id'] == null) await repo.linkVehicle(_id, '${v['id']}');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final repo = ref.read(dispatchRepositoryProvider);
    final fleet = ref.watch(fleetProvider(_id));
    final vehicles = ref.watch(fleetVehiclesProvider(_id));
    final drivers = [
      for (final d in (fleet.value?['drivers'] as List?) ?? const [])
        if (d is Map) Map<String, dynamic>.from(d),
    ];
    final members = drivers.where((d) => d['status'] == 'approved').toList();
    final asking = drivers.where((d) => d['status'] == 'pending').toList();
    final today = fleet.value?['today'] as Map?;

    Widget card(String title, List<Widget> children) => Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );

    final driversCard = card('${widget.fleets.firstWhere((f) => f.id == _id).name} · drivers', [
      if (fleet.isLoading && fleet.value == null) const LinearProgressIndicator(),
      if (fleet.hasError && fleet.value == null)
        Text(dispatchErrorText(fleet.error!), style: TextStyle(color: t.colorScheme.error)),
      if (fleet.hasValue && members.isEmpty) Text('No drivers yet.', style: muted),
      ListSearchFilter(
        count: members.length,
        hint: 'Search drivers',
        fieldKey: const ValueKey('fleet-driver-search'),
        builder: (_, q) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final d in members)
              if (q.isEmpty || '${d['name']} ${d['vehicle']} ${d['plate']}'.toLowerCase().contains(q.toLowerCase()))
                ListTile(
                  key: ValueKey('fleet-driver-${d['driver_id']}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text([d['name'], d['plate']].whereType<String>().join(' · ')),
                  subtitle: Text([d['service'], DriverState.parse(d['state']).label].whereType<String>().join(' · ')),
                  trailing: TextButton(
                    onPressed: () => _run(() => repo.removeMember(_id, '${d['driver_id']}'), 'Removed'),
                    child: const Text('Remove'),
                  ),
                ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('fleet-add'),
              controller: _add,
              decoration: const InputDecoration(
                labelText: 'Add a driver by phone or plate',
                hintText: 'e.g. WRR 1180',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const ValueKey('fleet-add-go'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () {
              final q = _add.text.trim();
              if (q.isEmpty) return;
              _run(() async {
                await repo.fleetAdd(_id, q);
                _add.clear();
              }, 'Driver added');
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ]);

    final vehicleRows = vehicles.value ?? const <Map<String, dynamic>>[];
    final vehiclesCard = card('Vehicles', [
      if (vehicles.isLoading && vehicles.value == null) const LinearProgressIndicator(),
      if (vehicles.hasValue && vehicleRows.isEmpty) Text('No vehicles yet.', style: muted),
      for (final v in vehicleRows)
        _VehicleRow(
          vehicle: v,
          members: members,
          onOpen: () async {
            await _openVehicle('${v['id']}');
            _reload();
          },
          onDriver: (driverId) => _run(() => repo.assignVehicle(_id, '${v['id']}', driverId)),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('fleet-add-vehicle'),
        onPressed: _addVehicle,
        icon: const Icon(Icons.add),
        label: const Text('Add vehicle'),
      ),
      const SizedBox(height: 6),
      Text(
        "Add the plate, make and model, then upload the vehicle's documents — the same steps as a driver adding a "
        "vehicle. New vehicles and every driver–vehicle assignment go to the admin's usual approval. Until approved, "
        "the vehicle can't be driven.",
        style: muted,
      ),
    ]);

    final askingCard = card('Asking to join', [
      if (asking.isEmpty) Text('Nobody waiting.', style: muted),
      for (final d in asking)
        ListTile(
          key: ValueKey('fleet-ask-${d['driver_id']}'),
          contentPadding: EdgeInsets.zero,
          title: Text('${d['name'] ?? 'Driver'}'),
          subtitle: Text(
            [?dispatchCarLine(d['vehicle'] as String?, d['plate'] as String?), 'Asked from the driver app'].join('\n'),
          ),
          trailing: Wrap(
            spacing: 4,
            children: [
              FilledButton(
                key: ValueKey('fleet-approve-${d['driver_id']}'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: () => _run(() => repo.decide(_id, '${d['driver_id']}', 'approved'), 'Approved'),
                child: const Text('Approve'),
              ),
              OutlinedButton(
                onPressed: () => _run(() => repo.decide(_id, '${d['driver_id']}', 'rejected'), 'Rejected'),
                child: const Text('Reject'),
              ),
            ],
          ),
        ),
      if (today != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Fleet stand orders today: ${today['orders']} · done ${today['done']} · cancelled ${today['cancelled']} · '
            'fares RM ${((today['fares'] as num?) ?? 0).toStringAsFixed(2)}',
            key: const ValueKey('fleet-today'),
            style: muted,
          ),
        ),
    ]);

    return LayoutBuilder(
      builder: (_, c) => RefreshIndicator(
        onRefresh: () async => _reload(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.fleets.length > 1) ...[
              SearchableDropdownFormField<String>(
                initialValue: _id,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Fleet', border: OutlineInputBorder(), isDense: true),
                items: [for (final f in widget.fleets) DropdownMenuItem(value: f.id, child: Text(f.name))],
                onChanged: (v) => setState(() => _id = v ?? _id),
              ),
              const SizedBox(height: 12),
            ],
            if (c.maxWidth >= 860)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Column(children: [driversCard, const SizedBox(height: 16), askingCard])),
                  const SizedBox(width: 16),
                  Expanded(child: vehiclesCard),
                ],
              )
            else ...[
              driversCard,
              const SizedBox(height: 16),
              vehiclesCard,
              const SizedBox(height: 16),
              askingCard,
            ],
          ],
        ),
      ),
    );
  }
}

class _VehicleRow extends StatelessWidget {
  const _VehicleRow({required this.vehicle, required this.members, required this.onOpen, required this.onDriver});

  final Map<String, dynamic> vehicle;
  final List<Map<String, dynamic>> members;
  final VoidCallback onOpen;
  final ValueChanged<String?> onDriver;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final status = vehicleApprovalLabel(vehicle);
    final assigned = [
      for (final d in (vehicle['drivers'] as List?) ?? const [])
        if (d is Map) Map<String, dynamic>.from(d),
    ];
    final current = assigned.firstOrNull;
    final ok = status == 'Approved';
    final bad = status == 'Rejected';
    Color ink(Color c) => t.brightness == Brightness.dark ? Color.lerp(c, Colors.white, 0.45)! : c;
    return Container(
      key: ValueKey('fleet-vehicle-${vehicle['id']}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onOpen,
                  child: Text(
                    [
                      vehicle['plate'],
                      [vehicle['make'], vehicle['model']].whereType<String>().join(' '),
                    ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                    style: t.textTheme.bodyLarge,
                  ),
                ),
              ),
              Text(
                status,
                style: t.textTheme.labelMedium?.copyWith(
                  color: ink(ok ? Colors.green.shade700 : (bad ? t.colorScheme.error : t.colorScheme.tertiary)),
                ),
              ),
            ],
          ),
          if (vehicle['service'] != null) Text('${vehicle['service']}', style: muted),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SearchableDropdownFormField<String>(
                  key: ValueKey('fleet-vehicle-driver-${vehicle['id']}'),
                  initialValue: current?['driver_id'] as String?,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Driver', border: OutlineInputBorder(), isDense: true),
                  items: [
                    const DropdownMenuItem<String>(value: '', child: Text('None')),
                    for (final m in members)
                      DropdownMenuItem(value: '${m['driver_id']}', child: Text('${m['name'] ?? 'Driver'}')),
                  ],
                  onChanged: (v) => onDriver(v == null || v.isEmpty ? null : v),
                ),
              ),
              if (current != null) ...[
                const SizedBox(width: 8),
                Text(assignmentLabel(current['approval']), style: muted),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
