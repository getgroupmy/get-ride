import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/vehicle_assignment.dart';
import '../../data/vehicle_assignment_repository.dart';
import '../../widgets/common.dart';

/// The vehicle this driver is driving right now (Drive tab), with the
/// picker to take one and the button to hand it back for a co-driver
/// (Expo `VehicleSelectModal` + `claimVehicle`).
class CurrentVehicleCard extends ConsumerStatefulWidget {
  const CurrentVehicleCard({super.key});

  @override
  ConsumerState<CurrentVehicleCard> createState() => _CurrentVehicleCardState();
}

class _CurrentVehicleCardState extends ConsumerState<CurrentVehicleCard> {
  bool _busy = false;

  Future<void> _pick(List<AssignableVehicle> list) async {
    final picked = await showModalBottomSheet<AssignableVehicle>(
      context: context,
      isScrollControlled: true,
      builder: (_) => VehiclePickerSheet(vehicles: list),
    );
    if (picked == null || picked.inUseByMe || !mounted) return;
    await _run(() => ref.read(vehicleAssignmentRepositoryProvider).claim(picked.id), claim: true);
  }

  Future<void> _handBack(AssignableVehicle v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Hand back ${v.plate}?'),
        content: const Text('You stop driving this vehicle, so another assigned driver can take it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Hand back')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() => ref.read(vehicleAssignmentRepositoryProvider).release());
  }

  Future<void> _run(Future<void> Function() action, {bool claim = false}) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        showInfo(context, claim ? claimVehicleErrorMessage(e) : "Couldn't hand the vehicle back. Try again.");
      }
    } finally {
      ref.invalidate(assignableVehiclesProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(assignableVehiclesProvider);
    final list = async.value;
    final current = list?.where((v) => v.inUseByMe).firstOrNull;
    final Widget subtitle;
    final List<Widget> actions;
    if (list == null) {
      subtitle = Text(async.hasError ? "Couldn't load your vehicles" : 'Loading…');
      actions = [
        if (async.hasError)
          TextButton(onPressed: () => ref.invalidate(assignableVehiclesProvider), child: const Text('Retry')),
      ];
    } else if (list.isEmpty) {
      subtitle = const Text('No vehicles yet. Add yours, or ask an admin to assign you to one.');
      actions = [TextButton(onPressed: () => context.push('/drive/vehicles'), child: const Text('My vehicles'))];
    } else if (current != null) {
      subtitle = Text('${current.plate} · ${current.title} · ${vehicleRoleLabel(current.role)}');
      actions = [
        TextButton(onPressed: _busy ? null : () => _pick(list), child: const Text('Change')),
        TextButton(onPressed: _busy ? null : () => _handBack(current), child: const Text('Hand back')),
      ];
    } else {
      subtitle = const Text('No vehicle selected');
      actions = [FilledButton.tonal(onPressed: _busy ? null : () => _pick(list), child: const Text('Select'))];
    }
    return Card(
      key: const ValueKey('current-vehicle'),
      child: ListTile(
        leading: _busy
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(current != null ? Icons.directions_car : Icons.directions_car_outlined),
        title: Text(current != null ? 'Driving' : 'Vehicle'),
        subtitle: subtitle,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
      ),
    );
  }
}

/// Every vehicle the driver may drive, with its role and whether it can be
/// taken now. Pops with the chosen one.
class VehiclePickerSheet extends StatelessWidget {
  const VehiclePickerSheet({super.key, required this.vehicles});

  final List<AssignableVehicle> vehicles;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('Choose a vehicle', style: t.textTheme.titleMedium),
              subtitle: const Text('Only one driver can use a vehicle at a time.'),
            ),
            for (final v in vehicles)
              ListTile(
                key: ValueKey('pick-${v.id}'),
                enabled: v.selectable,
                leading: Icon(
                  v.inUseByMe ? Icons.check_circle : Icons.directions_car_outlined,
                  color: v.inUseByMe ? Colors.green : null,
                ),
                title: Text(v.plate.isEmpty ? v.title : '${v.plate} · ${v.title}'),
                subtitle: Text(
                  [
                    vehicleRoleLabel(v.role),
                    assignableStatusLabel(v.status),
                    if (v.blockedReason != null) v.blockedReason!,
                  ].join(' · '),
                ),
                onTap: v.selectable ? () => Navigator.pop(context, v) : null,
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('My vehicles'),
              subtitle: const Text('Add a vehicle or finish setting one up'),
              onTap: () {
                Navigator.pop(context);
                context.push('/drive/vehicles');
              },
            ),
          ],
        ),
      ),
    );
  }
}
