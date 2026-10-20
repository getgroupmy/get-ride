// Admin → Services & catalogue → Service order (migrations 0249, 0250): the
// vehicle services from lowest to highest, whether that order applies to
// every booking (off by default; the airport queue always uses it), and the
// approved vehicles still without an approved service type, to set first.
// Airport Areas → Waiting queue shows the order and links here.
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
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

  /// Saves [ids] (lowest first), then reads the table back so the screen
  /// shows what is stored. False when the save failed (the edits stay).
  Future<bool> _saveOrder(
    BuildContext context,
    WidgetRef ref,
    List<String> ids,
  ) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(airportRepositoryProvider).saveServiceOrder(ids),
    );
    if (!ok || !context.mounted) return false;
    final stored = await ref.refresh(vehicleServiceOrderProvider.future);
    if (!context.mounted) return true;
    if (listEquals(stored, ids)) {
      showInfo(context, 'Service order saved');
    } else {
      showError(
        context,
        'Saved, but the database reads back a different order. Showing what is stored.',
      );
    }
    return true;
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
    final stored =
        ref.watch(vehicleServiceOrderProvider).value ?? const <String>[];
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
                child: ServiceOrderPanel(
                  services: services,
                  stored: stored,
                  onSave: canEdit
                      ? (ids) => _saveOrder(context, ref, ids)
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

/// The service order being arranged: moves change the shown order only;
/// [onSave] stores it. Until then the shown order follows [stored] (so other
/// admins' saves show live); once moved, the moves are kept until saved, or
/// until [stored] comes to match them.
class ServiceOrderPanel extends StatefulWidget {
  const ServiceOrderPanel({
    super.key,
    required this.services,
    required this.stored,
    this.onSave,
  });
  final List<({String id, String name})> services;

  /// The ranked ids as stored, lowest first (empty: nothing saved yet).
  final List<String> stored;

  /// Saves the ids, lowest first; true once saved (and read back). Null
  /// when the admin may only look.
  final Future<bool> Function(List<String> ids)? onSave;

  @override
  State<ServiceOrderPanel> createState() => _ServiceOrderPanelState();
}

class _ServiceOrderPanelState extends State<ServiceOrderPanel> {
  /// The admin's unsaved arrangement; null while following [stored].
  List<String>? _draft;
  bool _saving = false;

  List<String> get _all => [for (final s in widget.services) s.id];

  ServiceOrder get _shown =>
      ServiceOrder.arrange(_draft ?? widget.stored, _all);

  @override
  void didUpdateWidget(ServiceOrderPanel old) {
    super.didUpdateWidget(old);
    final d = _draft;
    if (d != null &&
        listEquals(ServiceOrder.arrange(d, _all).ids, widget.stored)) {
      _draft = null;
    }
  }

  Future<void> _save() async {
    final save = widget.onSave;
    if (save == null || _saving) return;
    final ids = _shown.ids;
    setState(() => _saving = true);
    final ok = await save(ids);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _draft = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final editable = widget.onSave != null;
    return ServiceOrderEditor(
      services: widget.services,
      order: shown,
      onChanged: editable ? (o) => setState(() => _draft = o.ids) : null,
      onSave: editable ? _save : null,
      changed: !listEquals(shown.ids, widget.stored),
      notSaved: widget.stored.isEmpty,
      saving: _saving,
    );
  }
}

/// The vehicle services from lowest (top) to highest (bottom): dragged, moved
/// with the arrows or given a position number. A driver whose vehicle's
/// service is higher may get orders for a lower one; a lower one never sees a
/// higher one's. Shared by every airport. With [onSave], a Save order button
/// stores the shown order ([changed]: it differs from what is stored;
/// [notSaved]: nothing is stored yet).
class ServiceOrderEditor extends StatelessWidget {
  const ServiceOrderEditor({
    super.key,
    required this.services,
    required this.order,
    this.onChanged,
    this.onSave,
    this.changed = false,
    this.notSaved = false,
    this.saving = false,
  });
  final List<({String id, String name})> services;
  final ServiceOrder order;
  final ValueChanged<ServiceOrder>? onChanged;
  final VoidCallback? onSave;
  final bool changed;
  final bool notSaved;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    String name(String id) =>
        services.where((s) => s.id == id).firstOrNull?.name ?? id;
    final ids = order.ids;
    final on = onChanged;
    final end = t.textTheme.labelMedium?.copyWith(
      color: t.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    Widget endLabel(String key, IconData icon, String text) => Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(text, style: end),
        ],
      ),
    );
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
        if (ids.isNotEmpty)
          endLabel(
            'service-order-lowest',
            Icons.south,
            'Lowest (1)',
          ),
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
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ReorderableDragStartListener(
                              index: i,
                              child: const Icon(Icons.drag_indicator),
                            ),
                            const SizedBox(width: 6),
                            ServiceRankField(
                              key: ValueKey('service-order-rank-${ids[i]}'),
                              rank: i + 1,
                              count: ids.length,
                              label: 'Position of ${name(ids[i])}',
                              onRank: (r) => on(order.moved(i, r - 1)),
                            ),
                          ],
                        ),
                  title: Text(name(ids[i])),
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
        if (ids.isNotEmpty)
          endLabel(
            'service-order-highest',
            Icons.north,
            'Highest (${ids.length})',
          ),
        if (onSave != null && ids.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              if (notSaved)
                Text(
                  'Not saved yet: no order is stored, so none applies until you save.',
                  key: const ValueKey('service-order-not-saved'),
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.error,
                  ),
                )
              else if (changed)
                Text(
                  'Unsaved changes: the order above is not stored yet.',
                  key: const ValueKey('service-order-unsaved'),
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.tertiary,
                  ),
                )
              else
                Text(
                  'Saved: this is the stored order.',
                  key: const ValueKey('service-order-saved'),
                  style: t.textTheme.bodySmall,
                ),
              FilledButton.icon(
                key: const ValueKey('service-order-save'),
                onPressed: (changed || notSaved) && !saving ? onSave : null,
                icon: saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save order'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A row's position (1 = lowest), typed: a new number moves the row there
/// when the field is submitted or loses focus; anything else puts the row's
/// number back.
class ServiceRankField extends StatefulWidget {
  const ServiceRankField({
    super.key,
    required this.rank,
    required this.count,
    required this.label,
    required this.onRank,
  });
  final int rank;
  final int count;
  final String label;
  final ValueChanged<int> onRank;

  @override
  State<ServiceRankField> createState() => _ServiceRankFieldState();
}

class _ServiceRankFieldState extends State<ServiceRankField> {
  late final _text = TextEditingController(text: '${widget.rank}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(ServiceRankField old) {
    super.didUpdateWidget(old);
    if (old.rank != widget.rank) _text.text = '${widget.rank}';
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final n = int.tryParse(_text.text.trim());
    if (n == null) {
      _text.text = '${widget.rank}';
      return;
    }
    final to = n.clamp(1, widget.count);
    _text.text = '$to';
    if (to != widget.rank) widget.onRank(to);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    child: Semantics(
      label: widget.label,
      child: TextField(
      controller: _text,
      focusNode: _focus,
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      maxLength: 3,
      decoration: InputDecoration(
        isDense: true,
        counterText: '',
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        semanticCounterText: '',
        hintText: '${widget.rank}',
      ),
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) => _focus.unfocus(),
      ),
    ),
  );
}
