// Admin → Services & catalogue → Service order (migrations 0249, 0250): the
// vehicle services from lowest to highest, whether that order applies to
// every booking (off by default; the airport queue always uses it), and the
// approved vehicles still without an approved service type, to set first.
// Airport Areas → Waiting queue shows the order and links here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/airport_queue.dart' show ServiceOrder;
import '../../../data/airport_repository.dart'
    show airportRepositoryProvider, vehicleServiceOrderProvider;
import '../../../data/service_order_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../geo/geo_data.dart' show regionVehicleTypesProvider;
import '../geo/geo_logic.dart' show ServiceOption;

const serviceOrderPath = '/admin/m/service-order';
const serviceOrderPage = 'admin-settings-vehicle-services';

class ServiceOrderScreen extends ConsumerWidget {
  const ServiceOrderScreen({super.key});

  Future<void> _saveOrder(
    BuildContext context,
    WidgetRef ref,
    ServiceOrder order,
  ) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(airportRepositoryProvider).saveServiceOrder(order.ids),
      success: 'Service order saved',
    );
    if (ok) ref.invalidate(vehicleServiceOrderProvider);
  }

  Future<void> _setEnforced(
    BuildContext context,
    WidgetRef ref,
    bool on,
    int missing,
  ) async {
    if (on && missing > 0) {
      final go = await confirm(
        context,
        'Enforce the service order',
        enforceWarning(missing)!,
        ok: 'Turn on',
      );
      if (!go || !context.mounted) return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(serviceOrderRepositoryProvider).setEnforced(on),
      success: on
          ? 'Service order applies to every booking'
          : 'Service order applies to airports only',
    );
    if (ok) ref.invalidate(serviceOrderEnforcedProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit =
        ref.watch(pageAccessProvider(serviceOrderPage)) == AccessLevel.edit;
    final services = [
      for (final o
          in ref.watch(regionVehicleTypesProvider).value ??
              const <ServiceOption>[])
        (id: o.id, name: o.name),
    ];
    final order = ServiceOrder.arrange(
      ref.watch(vehicleServiceOrderProvider).value ?? const <String>[],
      [for (final s in services) s.id],
    );
    final enforced = ref.watch(serviceOrderEnforcedProvider).value ?? false;
    final missing = ref.watch(vehiclesMissingServiceProvider);
    final t = Theme.of(context);
    return AdminPage(
      title: 'Service order',
      page: serviceOrderPage,
      body: ResponsiveCenter(
        maxWidth: 820,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Card(
              child: SwitchListTile(
                key: const ValueKey('service-order-enforce'),
                title: const Text('Enforce service order for all bookings'),
                subtitle: Text(
                  enforced
                      ? 'On: a driver gets orders of their vehicle\'s service and the lower ones only, everywhere.'
                      : 'Off: only the airport queue uses the order; every other booking goes to any driver, as before.',
                ),
                value: enforced,
                onChanged: canEdit
                    ? (v) => _setEnforced(
                        context,
                        ref,
                        v,
                        missing.value?.length ?? 0,
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ServiceOrderEditor(
                  services: services,
                  order: order,
                  onChanged: canEdit
                      ? (o) => _saveOrder(context, ref, o)
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: AsyncView(
                  value: missing,
                  onRetry: () => ref.invalidate(vehiclesMissingServiceProvider),
                  data: (list) => MissingServiceList(
                    vehicles: list,
                    serviceName: (id) =>
                        services.where((s) => s.id == id).firstOrNull?.name,
                    onOpen: (v) => context.push(
                      Uri(
                        path: '/admin/m/vehicle-edit',
                        queryParameters: {'id': v.id},
                      ).toString(),
                    ),
                  ),
                ),
              ),
            ),
            if (enforced && (missing.value?.isNotEmpty ?? false))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  enforceWarning(missing.value!.length)!,
                  style: TextStyle(color: t.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The approved vehicles without an approved service type: each opens the
/// vehicle's page, where its service type is approved.
class MissingServiceList extends StatelessWidget {
  const MissingServiceList({
    super.key,
    required this.vehicles,
    required this.serviceName,
    this.onOpen,
  });
  final List<VehicleMissingService> vehicles;
  final String? Function(String id) serviceName;
  final ValueChanged<VehicleMissingService>? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      key: const ValueKey('service-order-missing'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Vehicles without an approved service (${vehicles.length})',
          style: t.textTheme.titleSmall,
        ),
        Text(
          vehicles.isEmpty
              ? 'Every approved vehicle has an approved service type.'
              : 'Open each to approve its service type before turning the order on for every booking.',
          style: t.textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        ListSearchFilter(
          count: vehicles.length,
          hint: 'Search plates',
          fieldKey: const ValueKey('service-order-missing-search'),
          builder: (context, q) => Column(
            children: [
              for (final v in vehicles)
                if (q.isEmpty ||
                    searchSelectMatches('${v.plate} ${v.label}', q))
                  ListTile(
                    key: ValueKey('service-order-missing-${v.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.directions_car_outlined),
                    title: Text(v.plate.isEmpty ? '(no plate)' : v.plate),
                    subtitle: Text(
                      [
                        if (v.label.isNotEmpty) v.label,
                        v.requested.isEmpty
                            ? 'No service asked for'
                            : 'Asked for ${serviceName(v.requested) ?? 'an unknown service'}',
                      ].join(' · '),
                    ),
                    trailing: onOpen == null
                        ? null
                        : const Icon(Icons.chevron_right),
                    onTap: onOpen == null ? null : () => onOpen!(v),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The vehicle services from lowest to highest, dragged into order. A driver
/// whose vehicle's service is higher may get orders for a lower one; a lower
/// one never sees a higher one's. Shared by every airport.
class ServiceOrderEditor extends StatelessWidget {
  const ServiceOrderEditor({
    super.key,
    required this.services,
    required this.order,
    this.onChanged,
  });
  final List<({String id, String name})> services;
  final ServiceOrder order;
  final ValueChanged<ServiceOrder>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    String name(String id) =>
        services.where((s) => s.id == id).firstOrNull?.name ?? id;
    final ids = order.ids;
    final on = onChanged;
    return Column(
      key: const ValueKey('airport-service-order'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Service order (lowest to highest)',
          style: t.textTheme.labelLarge,
        ),
        Text(
          'A driver whose vehicle is a higher service can get orders for the lower ones; a lower one never sees a '
          "higher one's. An order goes to its own service's line first, then to each higher line in this order. "
          'The same for every airport.',
          style: t.textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        if (ids.isEmpty)
          Text('No vehicle services yet.', style: t.textTheme.bodySmall),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) => on?.call(order.moved(from, to)),
          children: [
            for (var i = 0; i < ids.length; i++)
              Card(
                key: ValueKey('airport-service-${ids[i]}'),
                margin: const EdgeInsets.only(bottom: 4),
                child: ListTile(
                  leading: on == null
                      ? CircleAvatar(radius: 13, child: Text('${i + 1}'))
                      : ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_indicator),
                        ),
                  title: Text('${i + 1}. ${name(ids[i])}'),
                  trailing: on == null
                      ? null
                      : Wrap(
                          children: [
                            IconButton(
                              tooltip: 'Move ${name(ids[i])} lower',
                              onPressed: i == 0
                                  ? null
                                  : () => on(order.moved(i, i - 1)),
                              icon: const Icon(Icons.arrow_upward, size: 18),
                            ),
                            IconButton(
                              tooltip: 'Move ${name(ids[i])} higher',
                              onPressed: i == ids.length - 1
                                  ? null
                                  : () => on(order.moved(i, i + 1)),
                              icon: const Icon(Icons.arrow_downward, size: 18),
                            ),
                          ],
                        ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
