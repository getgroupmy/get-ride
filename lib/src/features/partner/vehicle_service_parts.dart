// The vehicle's service and its per-service checks, shared by partner
// registration's Register vehicle step (registration_steps.dart) and Add
// vehicle for later vehicles (vehicle_screens.dart):
//
// * VehicleServiceField: "Vehicle service *" (0249). Filled in, read-only,
//   when GET.ride set a service for the make & model (Vehicle Make & Model);
//   otherwise the driver chooses one. GET.ride checks it at review.
// * VehicleServiceStatusBlocks: how each Partner Service type stands with
//   the vehicle (vehicleServiceStatuses): its age limit, paused when over
//   it, and the vehicle permits GET.ride uploads. The server works out the
//   same when the vehicle is submitted (0301).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/screens/people/people_data.dart';
import '../../core/partner_registration.dart';
import '../../core/partner_type_rules.dart' show vehicleAgeYears;
import '../../core/vehicle_onboarding.dart';
import '../../widgets/search_select.dart';
import 'registration_parts.dart';

/// The services a vehicle can be registered for; empty when they can't be
/// read (the field then asks for nothing and the server's make & model match
/// decides, as before).
final vehicleServiceOptionsProvider = FutureProvider.autoDispose<List<VehicleServiceOption>>((ref) async {
  try {
    return vehicleServiceOptions(await ref.watch(peopleRepositoryProvider).vehicleServices());
  } catch (_) {
    return const [];
  }
});

/// "Vehicle service *": [mapped] (the make & model's, '' when it sets none)
/// shown read-only, else a pick of the services that sets [value].
class VehicleServiceField extends ConsumerWidget {
  const VehicleServiceField({
    super.key,
    required this.mapped,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.errorText,
  });

  final String mapped;
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final String? errorText;

  static const label = 'Vehicle service *';
  static const helper = 'The jobs this vehicle takes. GET.ride checks it at review. When the make & model has a '
      'service set by GET.ride, it is filled in for you.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(vehicleServiceOptionsProvider).value ?? const <VehicleServiceOption>[];
    if (mapped.trim().isNotEmpty) {
      final name = vehicleServiceName(options, mapped) ?? 'Set by GET.ride';
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InputDecorator(
          key: const ValueKey('vehicle-service-mapped'),
          decoration: const InputDecoration(
            labelText: label,
            helperText: helper,
            helperMaxLines: 4,
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.lock_outline),
          ),
          child: Text('$name · from make & model'),
        ),
      );
    }
    final known = options.any((o) => o.id == value);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SearchableDropdownFormField<String>(
        key: ValueKey('vehicle-service-pick-$known-${options.length}'),
        isExpanded: true,
        initialValue: known ? value : null,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 4,
          errorText: errorText,
          errorMaxLines: 2,
          border: const OutlineInputBorder(),
        ),
        items: [for (final o in options) DropdownMenuItem(value: o.id, child: Text(o.name))],
        onChanged: enabled ? (v) => onChanged(v ?? '') : null,
      ),
    );
  }
}

/// The age and vehicle permit blocks for [statuses]: the vehicle's age
/// ([regLabel]: "Registered 2009", from [registered]) and each service's
/// limit, then what each service needs as a vehicle permit.
class VehicleServiceStatusBlocks extends StatelessWidget {
  const VehicleServiceStatusBlocks({
    super.key,
    required this.statuses,
    required this.regLabel,
    this.registered,
    this.now,
  });

  final List<VehicleServiceStatus> statuses;
  final String regLabel;
  final DateTime? registered;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final st = statuses;
    if (st.isEmpty) return const SizedBox.shrink();
    final anyPaused = st.any((s) => s.state == VehicleServiceState.pausedAge);
    final withLimit = st.where((s) => s.limit != null).toList();
    final reg = registered;
    final age = reg == null ? null : vehicleAgeYears(reg, now: now);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (withLimit.isNotEmpty)
        RegNotice(
          key: const ValueKey('vehicle-age'),
          icon: Icons.event,
          tone: anyPaused ? NoticeTone.warn : NoticeTone.info,
          children: [
            Text(age == null ? 'Vehicle age' : '$regLabel: $age years old', style: const TextStyle(fontWeight: FontWeight.w600)),
            for (final s in st)
              CheckLine(
                ok: s.state != VehicleServiceState.pausedAge,
                paused: s.state == VehicleServiceState.pausedAge,
                text: vehicleAgeLine(s),
              ),
            Text(
              anyPaused
                  ? 'You can carry on. The other services work with this vehicle; the paused one turns on when you add a newer vehicle later.'
                  : 'We remind you a year before a limit is reached.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      RegNotice(
        key: const ValueKey('vehicle-permits'),
        icon: Icons.verified_outlined,
        children: [
          const Text('Vehicle permits', style: TextStyle(fontWeight: FontWeight.w600)),
          for (final s in st) CheckLine(ok: s.permit == null, paused: s.permit != null, text: vehiclePermitLine(s)),
          Text("You don't upload these; we tell you when each one is ready.", style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ]);
  }
}
