import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../../core/airport_queue.dart';
import '../../../data/airport_repository.dart';
import 'airport_editor.dart';
import 'boundary_editor.dart';
import 'geo_data.dart';
import 'geo_logic.dart';
import 'part_of_fields.dart';
import 'place_search_field.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';

const airportAreasPage = 'admin-settings-airport-areas';

/// Airports with an assigned place, a geofence and gates
/// (Expo `admin-settings-airport-areas.tsx`, table `airport_areas`): a list
/// of airports, each opening its editor (airport_editor.dart: Area, Gates &
/// doors, Pickup rules, Waiting queue, Fares and Charges, migration 0249).
/// On a wide screen the editor stands beside the list.
class AdminAirportAreasScreen extends ConsumerStatefulWidget {
  const AdminAirportAreasScreen({super.key});

  @override
  ConsumerState<AdminAirportAreasScreen> createState() => _AdminAirportAreasScreenState();
}

class _AdminAirportAreasScreenState extends ConsumerState<AdminAirportAreasScreen> {
  String _query = '', _country = '', _state = '', _city = '';

  /// The airport open beside the list on a wide screen.
  String? _openId;

  Future<void> _edit([GeoEntry? entry]) async {
    final form = await showAdminSheet<AirportForm>(
      context,
      title: entry == null ? 'Add Airport' : 'Edit Airport',
      builder: (_) => _AirportFormBody(
        initial: entry == null ? AirportForm() : AirportForm.fromValues(entry.values),
        id: entry?.id,
      ),
    );
    if (form == null || !mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(geoAdminRepositoryProvider).saveAirport(
            id: entry?.id,
            values: airportSaveValues(entry?.values, form),
            position: entry?.position ?? 0,
          ),
      success: 'Airport saved',
    );
    if (ok) ref.invalidate(airportsProvider);
  }

  Future<void> _delete(GeoEntry e) async {
    if (!await confirm(context, 'Delete', 'Remove this airport?', ok: 'Delete')) return;
    if (!mounted) return;
    final ok = await runAdminAction(context, () => ref.read(geoAdminRepositoryProvider).deleteAirport(e.id),
        success: 'Airport deleted');
    if (ok) ref.invalidate(airportsProvider);
  }

  Future<void> _geofence(GeoEntry e, bool canEdit) async {
    final placeName = '${e.values['placeName'] ?? ''}'.trim();
    if (placeName.isEmpty) {
      await showAppDialog<void>(id: 'airport-areas.geofence',
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Place required'),
          content: const Text(
              'Please assign at least one place (via the OSM search) to this airport before setting up geofence.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      if (canEdit && mounted) await _edit(e);
      return;
    }
    final repo = ref.read(geoAdminRepositoryProvider);
    final stored = parseBoundary(e.values['boundary']);
    await BoundaryEditorPage.open(
      context,
      BoundaryEditorPage(
        title: 'Geofence · ${e.values['name'] ?? 'Airport'}',
        query: placeName,
        canEdit: canEdit,
        initial: stored,
        near: latLngOf(e.values),
        reverseFirst: true,
        onPickSaved: () => pickSavedRegionShape(context, ref),
        onSave: (shape) async {
          await repo.saveAirport(
            id: e.id,
            values: {...e.values, ...boundaryValues(simplifyShape(shape), DateTime.now())},
            position: e.position,
          );
          ref.invalidate(airportsProvider);
        },
        onClear: stored == null
            ? null
            : () async {
                await repo.saveAirport(id: e.id, values: withoutBoundary(e.values), position: e.position);
                ref.invalidate(airportsProvider);
              },
      ),
    );
  }

  Future<void> _pickFilter(String label, List<String> options, String current, ValueChanged<String> onPick) async {
    final picked = await showSearchPicker<String>(
      context,
      title: 'Filter by $label',
      selected: current,
      choices: [
        (value: '', label: 'All ${label.toLowerCase()}', subtitle: null, leading: null),
        for (final o in options) (value: o, label: o, subtitle: null, leading: null),
      ],
    );
    if (picked != null) onPick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(airportAreasPage)) == AccessLevel.edit;
    final async = ref.watch(airportsProvider);
    return AdminPage(
      title: 'Airport Areas',
      page: airportAreasPage,
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(airportsProvider)),
      ],
      addAction: PageAddAction(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add airport'),
      ),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(airportsProvider),
        data: (entries) {
          final wide = MediaQuery.sizeOf(context).width >= 1000;
          final doors = ref.watch(airportDoorsProvider).value ?? const <AirportDoor>[];
          final settings = ref.watch(airportSettingsProvider).value ?? const <String, AirportSettings>{};
          final open = entries.where((e) => e.id == _openId).firstOrNull ?? entries.firstOrNull;
          final values = [for (final e in entries) e.values];
          final opts = airportFilterOptions(values, country: _country, state: _state);
          final filtered = entries
              .where((e) => airportMatches(e.values, query: _query, country: _country, state: _state, city: _city))
              .toList();
          Widget chip(String label, String value, List<String> options, bool enabled, ValueChanged<String> onPick) =>
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(value.isEmpty ? label : value),
                  selected: value.isNotEmpty,
                  onSelected: enabled ? (_) => _pickFilter(label, options, value, onPick) : null,
                ),
              );
          final list = Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search airport, code, city...',
                    isDense: true,
                    helperText: '${filtered.length} of ${entries.length} airports',
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  chip('Country', _country, opts.countries, true, (v) => setState(() {
                        _country = v;
                        _state = '';
                        _city = '';
                      })),
                  chip('State', _state, opts.states, _country.isNotEmpty, (v) => setState(() {
                        _state = v;
                        _city = '';
                      })),
                  chip('City', _city, opts.cities, _country.isNotEmpty, (v) => setState(() => _city = v)),
                  if (_country.isNotEmpty || _state.isNotEmpty || _city.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() => _country = _state = _city = ''),
                      child: const Text('Clear'),
                    ),
                ]),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const EmptyState(
                        icon: Icons.flight_outlined,
                        title: 'No airports',
                        message: 'Adjust filters or add a new airport.',
                      )
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(12, 4, 12, addActionListBottomPadding(context)),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) => _AirportTile(
                          entry: filtered[i],
                          selected: wide && filtered[i].id == open?.id,
                          summary: airportCardSummary(
                            filtered[i].values,
                            doors: doors,
                            airportId: filtered[i].id,
                            settings: settings[filtered[i].id],
                          ),
                          canEdit: canEdit,
                          onOpen: () => wide
                              ? setState(() => _openId = filtered[i].id)
                              : AirportEditor.open(
                                  context,
                                  entry: filtered[i],
                                  canEdit: canEdit,
                                  onEditDetails: () => _edit(filtered[i]),
                                  onEditBoundary: () => _geofence(filtered[i], canEdit),
                                ),
                          onEdit: () => _edit(filtered[i]),
                          onDelete: () => _delete(filtered[i]),
                        ),
                      ),
              ),
            ]);
          if (!wide || open == null) return ResponsiveCenter(maxWidth: 900, padding: EdgeInsets.zero, child: list);
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(width: 360, child: list),
            const VerticalDivider(width: 1),
            Expanded(
              child: AirportEditor(
                key: ValueKey('airport-editor-${open.id}'),
                entry: open,
                canEdit: canEdit,
                onEditDetails: () => _edit(open),
                onEditBoundary: () => _geofence(open, canEdit),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

/// "KUL · 2 drop-off · 2 pickup · queue pickups" for an airport's card.
String airportCardSummary(
  Map<String, dynamic> values, {
  required List<AirportDoor> doors,
  required String airportId,
  AirportSettings? settings,
}) {
  final code = '${values['code'] ?? ''}'.trim();
  final drop = doorsFor(doors, airportId, AirportSide.drop).length;
  final pick = doorsFor(doors, airportId, AirportSide.pick).length;
  final mode = settings == null || !settings.restrictPickups
      ? 'normal pickups'
      : settings.pickupFrom.length == 2
      ? 'queue and zone pickups'
      : settings.pickupFrom.contains(PickupSource.queue)
      ? 'queue pickups'
      : 'zone pickups';
  return [if (code.isNotEmpty) code, '$drop drop-off', '$pick pickup', mode].join(' · ');
}

class _AirportTile extends StatelessWidget {
  const _AirportTile({
    required this.entry,
    required this.summary,
    required this.selected,
    required this.canEdit,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });
  final GeoEntry entry;
  final String summary;
  final bool selected, canEdit;
  final VoidCallback onOpen;
  final Future<void> Function() onEdit, onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = entry.values;
    final hasBoundary = parseBoundary(v['boundary']) != null;
    return Card(
      key: ValueKey('airport-card-${entry.id}'),
      color: selected ? scheme.primaryContainer : null,
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.flight, color: scheme.primary, size: 20),
        ),
        title: Text('${v['name'] ?? 'Airport'}', overflow: TextOverflow.ellipsis),
        subtitle: Text([
          hasBoundary ? summary : '$summary · no boundary yet',
          if ('${v['partOf'] ?? ''}'.trim() case final part when part.isNotEmpty) 'Part of: $part',
        ].join('\n')),
        trailing: canEdit
            ? Wrap(children: [
                BusyIconButton(tooltip: 'Edit details', icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
                BusyIconButton(tooltip: 'Delete', icon: Icon(Icons.delete_outline, color: scheme.error), onPressed: onDelete),
              ])
            : const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _AirportFormBody extends StatefulWidget {
  const _AirportFormBody({required this.initial, this.id});
  final AirportForm initial;

  /// The airport being edited (null when adding one).
  final String? id;

  @override
  State<_AirportFormBody> createState() => _AirportFormBodyState();
}

class _AirportFormBodyState extends State<_AirportFormBody> {
  late final AirportForm f = widget.initial;
  late final _name = TextEditingController(text: f.name);
  late final _code = TextEditingController(text: f.code);
  late final _country = TextEditingController(text: f.country);
  late final _state = TextEditingController(text: f.state);
  late final _city = TextEditingController(text: f.city);
  late final _partOf = TextEditingController(text: f.partOf);
  late final _partOrder = TextEditingController(text: f.partOrder);
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _code, _country, _state, _city, _partOf, _partOrder]) {
      c.dispose();
    }
    super.dispose();
  }

  void _read() {
    f
      ..name = _name.text
      ..code = _code.text
      ..country = _country.text
      ..state = _state.text
      ..city = _city.text
      ..partOf = _partOf.text
      ..partOrder = _partOrder.text;
  }

  void _picked(PlaceResult r) {
    _read();
    setState(() => f.applyPlace(r));
    _country.text = f.country;
    _state.text = f.state;
    _city.text = f.city;
  }

  void _submit() {
    _read();
    final err = f.validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, f);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const gap = SizedBox(height: 12);
    final pos = latLngOf({'lat': f.lat, 'lon': f.lon});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Assigned place *', style: t.textTheme.titleSmall),
      const SizedBox(height: 6),
      PlaceSearchField(hint: 'Search airport on OpenStreetMap', nameKeys: airportNameKeys, onPicked: _picked),
      if (f.lat.isNotEmpty && f.lon.isNotEmpty)
        Card(
          child: ListTile(
            leading: Icon(Icons.check_circle, color: t.colorScheme.primary),
            title: Text(f.placeName.isEmpty ? 'Assigned place' : f.placeName),
            subtitle: Text([
              if (pos != null) '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}',
              if (f.address.isNotEmpty) f.address,
            ].join('\n')),
            trailing: IconButton(
              tooltip: 'Remove place',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => f
                ..lat = ''
                ..lon = ''
                ..address = ''
                ..placeName = ''),
            ),
          ),
        ),
      const SizedBox(height: 16),
      TextField(controller: _name, decoration: const InputDecoration(labelText: 'Airport Name *', hintText: 'e.g. Kuala Lumpur International')),
      gap,
      TextField(
        controller: _code,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(labelText: 'IATA Code', hintText: 'e.g. KUL'),
      ),
      gap,
      TextField(controller: _country, decoration: const InputDecoration(labelText: 'Country *', hintText: 'e.g. Malaysia')),
      gap,
      TextField(controller: _state, decoration: const InputDecoration(labelText: 'State / Region', hintText: 'e.g. Selangor')),
      gap,
      TextField(controller: _city, decoration: const InputDecoration(labelText: 'City', hintText: 'e.g. Sepang')),
      gap,
      PartOfFields(partOf: _partOf, order: _partOrder, selfId: widget.id),
      if (_error != null) ...[gap, Text(_error!, style: TextStyle(color: t.colorScheme.error))],
      const SizedBox(height: 20),
      FilledButton.icon(onPressed: _submit, icon: const Icon(Icons.save), label: const Text('Save')),
    ]);
  }
}
