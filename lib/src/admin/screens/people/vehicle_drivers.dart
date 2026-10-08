import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/vehicle_assignment.dart';
import '../../../data/vehicle_assignment_repository.dart';
import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/loading_skeleton.dart';
import '../../widgets/admin_widgets.dart';
import 'people_widgets.dart';

final _vehicleDriversProvider = FutureProvider.autoDispose.family<List<VehicleDriver>, String>(
  (ref, id) => ref.watch(vehicleAssignmentRepositoryProvider).driversFor(id),
);

/// Who may drive this vehicle besides its owner (Admin → Vehicles → edit).
/// Expo has the table and the claim/release flow but no screen for it, so
/// links could only be made in the database; this is that screen.
class VehicleDriversSection extends ConsumerWidget {
  const VehicleDriversSection({super.key, required this.vehicleId, required this.canEdit});

  final String vehicleId;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_vehicleDriversProvider(vehicleId));
    final repo = ref.read(vehicleAssignmentRepositoryProvider);
    void refresh() => ref.invalidate(_vehicleDriversProvider(vehicleId));

    Future<void> act(Future<void> Function() action, String done) async {
      await runAdminAction(context, action, success: done);
      refresh();
    }

    final drivers = async.value ?? const <VehicleDriver>[];
    final driving = drivers.where((d) => d.drivingNow).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Drivers',
          trailing: canEdit
              ? TextButton.icon(
                  key: const ValueKey('add-driver'),
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Add driver'),
                  onPressed: () async {
                    final added = await showDialog<bool>(
                      context: context,
                      builder: (_) => _AddDriverDialog(vehicleId: vehicleId),
                    );
                    if (added == true) refresh();
                  },
                )
              : null,
        ),
        if (async.isLoading && async.value == null) const LoadingSkeleton(rows: 2),
        if (async.hasError) Text('Could not load drivers: ${async.error}'),
        if (async.value != null && drivers.isEmpty)
          const Text('Only the owner can drive this vehicle. Add a driver or co-driver to share it.'),
        for (final d in drivers)
          ListTile(
            key: ValueKey('driver-${d.userId}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              d.drivingNow ? Icons.directions_car : Icons.person_outline,
              color: d.drivingNow ? Colors.green : null,
            ),
            title: Text(d.name?.isNotEmpty == true ? d.name! : (d.phone ?? d.userId)),
            subtitle: Text(
              [
                vehicleRoleLabel(d.role),
                if (d.phone != null) d.phone!,
                if (d.drivingNow) 'Driving now',
                if (!d.active) 'Paused',
              ].join(' · '),
            ),
            trailing: canEdit && d.role != VehicleRole.owner
                ? PopupMenuButton<String>(
                    tooltip: 'Driver actions',
                    onSelected: (v) => switch (v) {
                      'pause' => act(() => repo.setActive(d.assignmentId, false), 'Paused'),
                      'resume' => act(() => repo.setActive(d.assignmentId, true), 'Resumed'),
                      _ => act(() => repo.remove(d.assignmentId), 'Removed'),
                    },
                    itemBuilder: (_) => [
                      d.active
                          ? const PopupMenuItem(value: 'pause', child: Text('Pause (keep on file)'))
                          : const PopupMenuItem(value: 'resume', child: Text('Resume')),
                      const PopupMenuItem(value: 'remove', child: Text('Remove')),
                    ],
                  )
                : null,
          ),
        if (canEdit && driving != null)
          Align(
            alignment: Alignment.centerLeft,
            child: BusyButton.text(
              icon: const Icon(Icons.logout),
              child: Text('End ${driving.name ?? 'the current'} session'),
              onPressed: () => act(() => repo.endSession(vehicleId), 'Session ended'),
            ),
          ),
      ],
    );
  }
}

class _AddDriverDialog extends ConsumerStatefulWidget {
  const _AddDriverDialog({required this.vehicleId});
  final String vehicleId;

  @override
  ConsumerState<_AddDriverDialog> createState() => _AddDriverDialogState();
}

class _AddDriverDialogState extends ConsumerState<_AddDriverDialog> {
  final _phone = TextEditingController();
  var _role = VehicleRole.coDriver;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(vehicleAssignmentRepositoryProvider);
    try {
      final who = await repo.findByPhone(_phone.text);
      if (who == null) {
        setState(() => _error = 'No account has that phone number. They need to sign up first.');
        return;
      }
      await repo.assign(
        assignmentRow(
          vehicleId: widget.vehicleId,
          userId: who.userId,
          partnerId: who.partnerId,
          role: _role,
          adminId: ref.read(currentUserIdProvider),
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not add the driver: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add driver'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('driver-phone'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone number', hintText: '+60 12-345 6789'),
        ),
        const SizedBox(height: 12),
        SegmentedButton<VehicleRole>(
          segments: const [
            ButtonSegment(value: VehicleRole.coDriver, label: Text('Co-driver')),
            ButtonSegment(value: VehicleRole.driver, label: Text('Driver')),
          ],
          selected: {_role},
          onSelectionChanged: (s) => setState(() => _role = s.first),
        ),
        const SizedBox(height: 8),
        const Text('They can then pick this vehicle on their Drive tab. One driver uses it at a time.'),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      BusyButton.filled(onPressed: _busy ? null : _save, child: const Text('Add')),
    ],
  );
}
