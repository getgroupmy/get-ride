import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/commission.dart' show Geo;
import '../../core/fare_tariff.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import 'geo/geo_data.dart';
import 'geo/geo_logic.dart';
import '../../data/live_tables.dart';

final fareTariffRowsProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('fare_tariffs');
  return ref.watch(adminRepositoryProvider).fareTariffs();
});

/// What the page's pickers are set to: a place (from Country / States /
/// Cities) and a Service Settings type.
class TariffFilter {
  const TariffFilter({this.country = '', this.state = '', this.city = '', this.serviceType});

  final String country, state, city;

  /// A Service Settings id; null for every type.
  final String? serviceType;

  /// The level a card set from here applies at.
  String get level => city.isNotEmpty
      ? 'city'
      : state.isNotEmpty
      ? 'state'
      : country.isNotEmpty
      ? 'country'
      : 'master';

  Geo get geo => Geo(country: country, state: state, city: city);

  String get place => level == 'master' ? 'Everywhere' : [city, state, country].where((s) => s.isNotEmpty).join(', ');
}

/// Admin → Fare tariffs (migrations 0109, 0123): what bookings are quoted
/// at, by place and service. Pick a place and a service type; the page
/// lists the type's vehicle services with the fare each is quoted at there,
/// and a fare can be set for the type or for one vehicle.
class AdminFareTariffsScreen extends ConsumerStatefulWidget {
  const AdminFareTariffsScreen({super.key});

  @override
  ConsumerState<AdminFareTariffsScreen> createState() => _AdminFareTariffsScreenState();
}

class _AdminFareTariffsScreenState extends ConsumerState<AdminFareTariffsScreen> {
  TariffFilter _filter = const TariffFilter();

  Future<void> _edit(FareTariff? card, {FareTariff? draft}) async {
    final result = await showDialog<FareTariff>(
      context: context,
      builder: (_) => TariffDialog(card: card, draft: draft),
    );
    if (result == null || !mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveFareTariff(fareTariffRow(result)),
      success: 'Tariff saved',
    );
    if (ok) ref.invalidate(fareTariffRowsProvider);
  }

  /// Set the fare for [vehicle] (or the whole type, or every service) at
  /// the picked place: edits the card already there, else starts one.
  void _setFare(List<FareTariff> cards, {String? serviceType, String? vehicle, String? currency}) {
    final f = _filter;
    final draft = FareTariff(
      level: f.level,
      country: f.country,
      state: f.state,
      city: f.city,
      serviceType: serviceType,
      vehicleService: vehicle,
      currency: currency ?? 'MYR',
    );
    _edit(cards.where((c) => c.sameSlot(draft)).firstOrNull, draft: draft);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(moduleAccessProvider('fare-tariffs')) == AccessLevel.edit;
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final types = ref.watch(regionServicesProvider).value ?? const <ServiceOption>[];
    final vehicles = ref.watch(serviceVehiclesProvider).value ?? const <ServiceVehicle>[];
    return AdminPage(
      title: 'Fare tariffs',
      module: 'fare-tariffs',
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => _edit(null),
              icon: const Icon(Icons.add),
              label: const Text('Add tariff'),
            )
          : null,
      body: AsyncView(
        value: ref.watch(fareTariffRowsProvider),
        onRetry: () => ref.invalidate(fareTariffRowsProvider),
        data: (rows) {
          final cards = [for (final r in rows) FareTariff.fromRow(r)]
            ..sort((a, b) => fareTariffLevels.indexOf(a.level).compareTo(fareTariffLevels.indexOf(b.level)));
          final names = {for (final t in types) t.id: t.name, for (final v in vehicles) v.id: v.name};
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              const Card(
                child: ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('How a booking is priced'),
                  subtitle: Text(
                    'The most specific place with a card for the service wins: suburb → city → state → country → '
                    "everywhere. There, a vehicle's own card beats its service type's, which beats a card for every "
                    'service. Fare = the larger of the minimum fare and (base + per km + per minute), plus the booking '
                    "fee, in the card's currency; cards for a type or every service are multiplied by the vehicle's "
                    'multiplier. With no card, the built-in TEKSI tariff applies in ringgit. Meter Digital keeps its '
                    'own rate cards.',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _FilterCard(
                filter: _filter,
                regions: regions,
                types: types,
                onChanged: (f) => setState(() => _filter = f),
              ),
              const SizedBox(height: 8),
              _ServiceFares(
                filter: _filter,
                cards: cards,
                types: types,
                vehicles: vehicles,
                names: names,
                currency: _filter.country.isEmpty ? null : regionCurrency(regions, _filter.country),
                onSet: canEdit
                    ? (serviceType, vehicle, currency) =>
                          _setFare(cards, serviceType: serviceType, vehicle: vehicle, currency: currency)
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
                child: Text('All tariff cards (${cards.length})', style: Theme.of(context).textTheme.titleMedium),
              ),
              if (cards.isEmpty)
                const EmptyState(
                  icon: Icons.price_change_outlined,
                  title: 'No tariffs yet',
                  message: 'Every booking is quoted on the built-in TEKSI tariff in ringgit. Pick a place and a '
                      'service above and set a fare, or add a card.',
                ),
              for (final c in cards)
                Card(
                  key: ValueKey('tariff-${c.id}'),
                  child: BusyListTile(
                    leading: CircleAvatar(child: Text(c.level.substring(0, 1).toUpperCase())),
                    title: Text([c.scope, tariffServiceLabel(c, names), if (c.label != null) c.label!].join(' · ')),
                    subtitle: Text(describeFareTariff(c)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!c.active) const StatusChip('inactive'),
                        if (canEdit)
                          BusyIconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              if (!await confirm(context, 'Delete tariff?', c.scope, ok: 'Delete')) return;
                              if (!context.mounted) return;
                              if (await runAdminAction(
                                context,
                                () => ref.read(adminRepositoryProvider).deleteFareTariff(c.id!),
                              )) {
                                ref.invalidate(fareTariffRowsProvider);
                              }
                            },
                          ),
                      ],
                    ),
                    onTap: canEdit ? () => _edit(c) : null,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// "Car", "Car · Premium", or "All services": what a card prices.
String tariffServiceLabel(FareTariff c, Map<String, String> names) {
  String name(String id) => names[id] ?? 'Removed service';
  if (c.allServices) return 'All services';
  return [if (c.serviceType != null) name(c.serviceType!), if (c.vehicleService != null) name(c.vehicleService!)]
      .join(' · ');
}

const _anyValue = '';

/// A dropdown of names with an "any" first entry ('' is any). A stored
/// value missing from [options] (renamed or removed since) stays listed.
Widget _namePicker({
  required Key key,
  required String label,
  required String anyLabel,
  required String value,
  required List<String> options,
  required ValueChanged<String> onChanged,
}) {
  final all = [...options, if (value.isNotEmpty && !options.any((o) => o.toLowerCase() == value.toLowerCase())) value];
  final selected = all.firstWhere((o) => o.toLowerCase() == value.toLowerCase(), orElse: () => _anyValue);
  return DropdownButtonFormField<String>(
    key: key,
    isExpanded: true,
    initialValue: selected,
    decoration: InputDecoration(labelText: label),
    items: [
      DropdownMenuItem(value: _anyValue, child: Text(anyLabel)),
      for (final o in all) DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis)),
    ],
    onChanged: (v) => onChanged(v ?? _anyValue),
  );
}

class _FilterCard extends StatelessWidget {
  const _FilterCard({required this.filter, required this.regions, required this.types, required this.onChanged});

  final TariffFilter filter;
  final List<RegionEntry> regions;
  final List<ServiceOption> types;
  final ValueChanged<TariffFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final f = filter;
    Widget cell(Widget child) => SizedBox(width: 220, child: child);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            cell(
              _namePicker(
                key: ValueKey('tariff-filter-country-${f.country}'),
                label: 'Country',
                anyLabel: 'Everywhere',
                value: f.country,
                options: regionNamesAt(regions, RegionLevel.country),
                onChanged: (v) => onChanged(TariffFilter(country: v, serviceType: f.serviceType)),
              ),
            ),
            if (f.country.isNotEmpty)
              cell(
                _namePicker(
                  key: ValueKey('tariff-filter-state-${f.country}-${f.state}'),
                  label: 'State',
                  anyLabel: 'All of ${f.country}',
                  value: f.state,
                  options: regionNamesAt(regions, RegionLevel.state, country: f.country),
                  onChanged: (v) => onChanged(TariffFilter(country: f.country, state: v, serviceType: f.serviceType)),
                ),
              ),
            if (f.state.isNotEmpty)
              cell(
                _namePicker(
                  key: ValueKey('tariff-filter-city-${f.state}-${f.city}'),
                  label: 'City',
                  anyLabel: 'All of ${f.state}',
                  value: f.city,
                  options: regionNamesAt(regions, RegionLevel.city, country: f.country, state: f.state),
                  onChanged: (v) => onChanged(
                    TariffFilter(country: f.country, state: f.state, city: v, serviceType: f.serviceType),
                  ),
                ),
              ),
            cell(
              DropdownButtonFormField<String>(
                key: const ValueKey('tariff-filter-type'),
                isExpanded: true,
                initialValue: types.any((t) => t.id == f.serviceType) ? f.serviceType : _anyValue,
                decoration: const InputDecoration(labelText: 'Service type'),
                items: [
                  const DropdownMenuItem(value: _anyValue, child: Text('All services')),
                  for (final t in types) DropdownMenuItem(value: t.id, child: Text(t.name)),
                ],
                onChanged: (v) => onChanged(
                  TariffFilter(
                    country: f.country,
                    state: f.state,
                    city: f.city,
                    serviceType: v == null || v == _anyValue ? null : v,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The picked type's vehicle services, each with the fare it is quoted at
/// at the picked place and where that fare comes from.
class _ServiceFares extends StatelessWidget {
  const _ServiceFares({
    required this.filter,
    required this.cards,
    required this.types,
    required this.vehicles,
    required this.names,
    required this.currency,
    required this.onSet,
  });

  final TariffFilter filter;
  final List<FareTariff> cards;
  final List<ServiceOption> types;
  final List<ServiceVehicle> vehicles;
  final Map<String, String> names;
  final String? currency;
  final void Function(String? serviceType, String? vehicle, String? currency)? onSet;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final type = types.where((x) => x.id == filter.serviceType).firstOrNull;
    final shown = vehiclesInType(vehicles, type?.name);
    final typeIds = {for (final x in types) x.name.trim().toLowerCase(): x.id};

    Widget row({
      required String id,
      required String title,
      required FareTariff? card,
      String? serviceType,
      String? vehicle,
    }) {
      // Whether the fare shown is a card set at this place for this
      // service, rather than one it falls back to.
      final here = card != null &&
          card.sameSlot(
            FareTariff(
              level: filter.level,
              country: filter.country,
              state: filter.state,
              city: filter.city,
              serviceType: serviceType,
              vehicleService: vehicle,
            ),
          );
      final from = card == null
          ? 'Built-in TEKSI tariff (MYR)'
          : here
          ? 'Set here'
          : 'From ${card.scope} · ${tariffServiceLabel(card, names)}';
      return ListTile(
        key: ValueKey('tariff-row-$id'),
        title: Text(title),
        subtitle: Text(card == null ? from : '${describeFareTariff(card)}\n$from'),
        isThreeLine: card != null,
        trailing: onSet == null
            ? null
            : OutlinedButton(
                key: ValueKey('tariff-row-$id-set'),
                onPressed: () => onSet!(serviceType, vehicle, card?.currency ?? currency),
                child: Text(here ? 'Edit fare' : 'Set fare'),
              ),
      );
    }

    final scopeTypes = type == null ? const <String>{} : {type.id};
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '${type?.name ?? 'All services'} · ${filter.place}',
              key: const ValueKey('tariff-fares-title'),
              style: t.textTheme.titleMedium,
            ),
          ),
          row(
            id: type?.id ?? 'all',
            title: type == null ? 'Every service' : 'Every ${type.name} vehicle',
            card: resolveFareTariff(cards, filter.geo, serviceTypes: scopeTypes),
            serviceType: type?.id,
          ),
          const Divider(height: 1),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                type == null
                    ? 'No vehicle services yet (Admin → Vehicle Services).'
                    : 'No vehicle service has ${type.name} as its Service type (Admin → Vehicle Services).',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
          for (final v in shown)
            row(
              id: v.id,
              title: v.name,
              card: resolveFareTariff(
                cards,
                filter.geo,
                vehicleService: v.id,
                serviceTypes: {for (final n in v.types) ?typeIds[n.trim().toLowerCase()]},
              ),
              serviceType: type?.id,
              vehicle: v.id,
            ),
        ],
      ),
    );
  }
}

/// Add / edit one card. [draft] starts a new card already pointed at a
/// place and service.
class TariffDialog extends ConsumerStatefulWidget {
  const TariffDialog({super.key, this.card, this.draft});
  final FareTariff? card;
  final FareTariff? draft;

  @override
  ConsumerState<TariffDialog> createState() => _TariffDialogState();
}

class _TariffDialogState extends ConsumerState<TariffDialog> {
  late final FareTariff? _start = widget.card ?? widget.draft;
  late String _level = _start?.level ?? 'country';
  late bool _active = widget.card?.active ?? true;
  late final _place = {
    'country': _start?.country ?? '',
    'state': _start?.state ?? '',
    'city': _start?.city ?? '',
    'suburb': _start?.suburb ?? '',
  };
  late String? _serviceType = _start?.serviceType;
  late String? _vehicle = _start?.vehicleService;
  late final _label = TextEditingController(text: widget.card?.label);
  late final _currency = TextEditingController(text: _start?.currency ?? 'MYR');
  late final _money = {
    'base': TextEditingController(text: _show(widget.card?.baseFare)),
    'km': TextEditingController(text: _show(widget.card?.perKm)),
    'min': TextEditingController(text: _show(widget.card?.perMinute)),
    'minimum': TextEditingController(text: _show(widget.card?.minimumFare)),
    'fee': TextEditingController(text: _show(widget.card?.bookingFee)),
  };
  String? _error;

  static String _show(double? v) => v == null || v == 0 ? '' : v.toString();

  @override
  void dispose() {
    for (final c in [_label, _currency, ..._money.values]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _n(String k) {
    final t = _money[k]!.text.trim();
    if (t.isEmpty) return 0;
    final v = double.tryParse(t);
    return v == null || v < 0 ? null : v;
  }

  void _save() {
    final values = {for (final k in _money.keys) k: _n(k)};
    if (values.values.any((v) => v == null)) {
      setState(() => _error = 'Charges are numbers of 0 or more.');
      return;
    }
    final card = FareTariff(
      id: widget.card?.id,
      level: _level,
      country: _place['country'],
      state: _place['state'],
      city: _place['city'],
      suburb: _place['suburb'],
      label: _label.text,
      currency: _currency.text.trim().toUpperCase(),
      baseFare: values['base']!,
      perKm: values['km']!,
      perMinute: values['min']!,
      minimumFare: values['minimum']!,
      bookingFee: values['fee']!,
      active: _active,
      serviceType: _serviceType,
      vehicleService: _vehicle,
    );
    final problem = fareTariffProblem(card);
    if (problem != null) return setState(() => _error = problem);
    Navigator.pop(context, card);
  }

  /// Picks [k]'s name, clearing the levels below it; a country brings its
  /// currency (Country information) onto a card that has no charges yet.
  void _pick(String k, String v, List<RegionEntry> regions) => setState(() {
    _place[k] = v;
    const order = ['country', 'state', 'city', 'suburb'];
    for (final below in order.skip(order.indexOf(k) + 1)) {
      _place[below] = '';
    }
    if (k == 'country' && widget.card == null) {
      final c = regionCurrency(regions, v);
      if (c != null) _currency.text = c;
    }
  });

  @override
  Widget build(BuildContext context) {
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final types = ref.watch(regionServicesProvider).value ?? const <ServiceOption>[];
    final vehicles = ref.watch(serviceVehiclesProvider).value ?? const <ServiceVehicle>[];
    final depth = fareTariffLevels.indexOf(_level);
    final type = types.where((t) => t.id == _serviceType).firstOrNull;
    final inType = vehiclesInType(vehicles, type?.name);
    Widget gap(Widget child) => Padding(padding: const EdgeInsets.only(top: 12), child: child);
    Widget money(String k, String label) => gap(
      TextField(
        key: ValueKey('tariff-$k'),
        controller: _money[k],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, hintText: '0'),
      ),
    );
    Widget place(int i, String k, RegionLevel level) {
      final options = regionNamesAt(
        regions,
        level,
        country: _place['country']!,
        state: _place['state']!,
        city: _place['city']!,
      );
      final title = k[0].toUpperCase() + k.substring(1);
      // A place not on Country / States / Cities yet can still be typed.
      if (options.isEmpty) {
        return gap(
          TextFormField(
            key: ValueKey('tariff-$k'),
            initialValue: _place[k],
            decoration: InputDecoration(labelText: title, helperText: 'Not on Country / States / Cities yet'),
            onChanged: (v) => _place[k] = v,
          ),
        );
      }
      return gap(
        _namePicker(
          key: ValueKey('tariff-$k-${_place.values.take(i).join('/')}'),
          label: title,
          anyLabel: 'Choose a ${k == 'country' ? 'country' : k}',
          value: _place[k]!,
          options: options,
          onChanged: (v) => _pick(k, v, regions),
        ),
      );
    }

    return AlertDialog(
      title: Text(widget.card == null ? 'Add fare tariff' : 'Edit fare tariff'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('tariff-level'),
                initialValue: _level,
                decoration: const InputDecoration(labelText: 'Applies to'),
                items: [
                  for (final l in fareTariffLevels)
                    DropdownMenuItem(value: l, child: Text(l == 'master' ? 'Everywhere (master)' : l)),
                ],
                onChanged: (v) => setState(() => _level = v ?? _level),
              ),
              if (depth >= 1) place(0, 'country', RegionLevel.country),
              if (depth >= 2) place(1, 'state', RegionLevel.state),
              if (depth >= 3) place(2, 'city', RegionLevel.city),
              if (depth >= 4) place(3, 'suburb', RegionLevel.suburb),
              gap(
                DropdownButtonFormField<String>(
                  key: const ValueKey('tariff-service-type'),
                  isExpanded: true,
                  initialValue: type?.id ?? _anyValue,
                  decoration: const InputDecoration(labelText: 'Service type'),
                  items: [
                    const DropdownMenuItem(value: _anyValue, child: Text('All services')),
                    for (final t in types) DropdownMenuItem(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: (v) => setState(() {
                    _serviceType = v == null || v == _anyValue ? null : v;
                    final name = types.where((t) => t.id == _serviceType).firstOrNull?.name;
                    // A vehicle outside the new type no longer applies.
                    if (!vehiclesInType(vehicles, name).any((x) => x.id == _vehicle)) _vehicle = null;
                  }),
                ),
              ),
              gap(
                DropdownButtonFormField<String>(
                  key: ValueKey('tariff-vehicle-${_serviceType ?? ''}'),
                  isExpanded: true,
                  initialValue: inType.any((v) => v.id == _vehicle) ? _vehicle : _anyValue,
                  decoration: InputDecoration(
                    labelText: 'Vehicle service',
                    helperText: _vehicle == null
                        ? "Priced × each vehicle's multiplier"
                        : "This vehicle's own fare (no multiplier)",
                  ),
                  items: [
                    DropdownMenuItem(
                      value: _anyValue,
                      child: Text(type == null ? 'All vehicles' : 'All ${type.name} vehicles'),
                    ),
                    for (final v in inType) DropdownMenuItem(value: v.id, child: Text(v.name)),
                  ],
                  onChanged: (v) => setState(() => _vehicle = v == null || v == _anyValue ? null : v),
                ),
              ),
              gap(
                TextField(
                  key: const ValueKey('tariff-currency'),
                  controller: _currency,
                  maxLength: 3,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Currency (ISO code)', counterText: ''),
                ),
              ),
              money('base', 'Base fare'),
              money('km', 'Per km'),
              money('min', 'Per minute'),
              money('minimum', 'Minimum fare'),
              money('fee', 'Booking fee'),
              gap(
                TextField(
                  controller: _label,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Label (optional)', counterText: ''),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
              if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey('tariff-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('tariff-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
