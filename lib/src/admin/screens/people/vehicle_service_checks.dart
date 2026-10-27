// Per-service checks of a vehicle (0288, 0301): for each Partner Service
// type, active, paused over its age limit, or waiting for a vehicle permit.
// The server works them out when the vehicle is submitted; vehicles from
// before are checked only when an admin previews and applies them here.
// Rows an admin set are kept. Shown on Edit Vehicle and on the partner
// review.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/vehicle_onboarding.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import 'people_data.dart';
import 'people_widgets.dart' show SectionTitle;

/// The rows, one line each with an icon by status.
class VehicleServiceCheckRows extends StatelessWidget {
  const VehicleServiceCheckRows({super.key, required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in rows)
        ListTile(
          key: ValueKey('service-check-${r['service']}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            switch ('${r['status']}') {
              'active' => Icons.check_circle,
              'paused_age' => Icons.pause_circle,
              _ => Icons.hourglass_top,
            },
            color: '${r['status']}' == 'active' ? c.primary : c.error,
          ),
          title: Text(vehicleServiceCheckText(r)),
        ),
    ]);
  }
}

/// "Per-service checks" on Edit Vehicle: the rows, and (with edit access) a
/// preview of what the server's checks would change, then Apply.
class VehicleServiceChecksSection extends ConsumerStatefulWidget {
  const VehicleServiceChecksSection({super.key, required this.vehicleId, required this.canEdit});
  final String vehicleId;
  final bool canEdit;

  @override
  ConsumerState<VehicleServiceChecksSection> createState() => _VehicleServiceChecksSectionState();
}

class _VehicleServiceChecksSectionState extends ConsumerState<VehicleServiceChecksSection> {
  late Future<List<Map<String, dynamic>>> _rows = _load();
  List<Map<String, dynamic>>? _preview;

  PeopleRepository get _repo => ref.read(peopleRepositoryProvider);

  Future<List<Map<String, dynamic>>> _load() => _repo.vehicleServiceStatus(widget.vehicleId);

  Future<void> _showPreview() async {
    try {
      final p = await _repo.vehicleServiceChecksPreview(widget.vehicleId);
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _apply() async {
    final ok = await runAdminAction(
      context,
      () => _repo.applyVehicleServiceChecks(widget.vehicleId),
      success: 'Per-service checks applied.',
    );
    if (!ok || !mounted) return;
    setState(() {
      _preview = null;
      _rows = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final preview = _preview;
    final changes = preview?.where((r) => r['changes'] == true).length ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(
        'Per-service checks',
        trailing: widget.canEdit
            ? BusyButton.text(
                key: const ValueKey('service-checks-preview'),
                icon: const Icon(Icons.fact_check_outlined),
                onPressed: _showPreview,
                child: const Text('Preview checks'),
              )
            : null,
      ),
      FutureBuilder<List<Map<String, dynamic>>>(
        future: _rows,
        builder: (context, snap) {
          if (snap.hasError) return Text(errorText(snap.error!));
          if (!snap.hasData) return const LinearProgressIndicator();
          final rows = snap.data!;
          if (rows.isEmpty) {
            return Text(
              'No per-service checks yet. They are worked out when the vehicle is submitted, or when you apply them.',
              style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
            );
          }
          return VehicleServiceCheckRows(rows: rows);
        },
      ),
      if (preview != null)
        Card(
          key: const ValueKey('service-checks-preview-card'),
          margin: const EdgeInsets.only(top: 8),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: t.colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 6, children: [
              Text('What the checks would do', style: t.textTheme.titleSmall),
              if (preview.isEmpty) const Text('This vehicle has no Partner Service type that needs a vehicle.'),
              for (final r in preview) Text(vehicleServicePreviewText(r)),
              if (changes > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: BusyButton.tonal(
                    key: const ValueKey('service-checks-apply'),
                    icon: const Icon(Icons.playlist_add_check),
                    onPressed: _apply,
                    child: Text(changes == 1 ? 'Apply 1 change' : 'Apply $changes changes'),
                  ),
                )
              else
                Text('Nothing to change.', style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
            ]),
          ),
        ),
    ]);
  }
}
