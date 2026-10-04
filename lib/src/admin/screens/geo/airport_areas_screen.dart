import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'boundary_editor.dart';
import 'geo_data.dart';
import 'geo_logic.dart';
import 'place_search_field.dart';

const airportAreasPage = 'admin-settings-airport-areas';

/// Airports with an assigned place, a geofence and gates
/// (Expo `admin-settings-airport-areas.tsx`, table `airport_areas`).
class AdminAirportAreasScreen extends ConsumerStatefulWidget {
  const AdminAirportAreasScreen({super.key});

  @override
  ConsumerState<AdminAirportAreasScreen> createState() => _AdminAirportAreasScreenState();
}

class _AdminAirportAreasScreenState extends ConsumerState<AdminAirportAreasScreen> {
  String _query = '', _country = '', _state = '', _city = '';

  Future<void> _edit([GeoEntry? entry]) async {
    final form = await showAdminSheet<AirportForm>(
      context,
      title: entry == null ? 'Add Airport' : 'Edit Airport',
      builder: (_) => _AirportFormBody(initial: entry == null ? AirportForm() : AirportForm.fromValues(entry.values)),
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
      await showDialog<void>(
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
        onSave: (shape) async {
          await repo.saveAirport(
            id: e.id,
            values: {...e.values, ...boundaryValues(shape, DateTime.now())},
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
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Filter by $label'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: Text('All ${label.toLowerCase()}')),
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o),
              child: Row(children: [
                Expanded(child: Text(o)),
                if (o == current) const Icon(Icons.check, size: 18),
              ]),
            ),
        ],
      ),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add airport'),
      ),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(airportsProvider),
        data: (entries) {
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
          return ResponsiveCenter(
            maxWidth: 900,
            padding: EdgeInsets.zero,
            child: Column(children: [
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
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) => _AirportTile(
                          entry: filtered[i],
                          canEdit: canEdit,
                          onGeofence: () => _geofence(filtered[i], canEdit),
                          onGates: () => context.push(Uri(
                            path: '/admin/m/multi-gate-place-gates',
                            queryParameters: {'placeId': filtered[i].id, 'parentKey': airportAreasKey},
                          ).toString()),
                          onEdit: () => _edit(filtered[i]),
                          onDelete: () => _delete(filtered[i]),
                        ),
                      ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _AirportTile extends StatelessWidget {
  const _AirportTile({
    required this.entry,
    required this.canEdit,
    required this.onGeofence,
    required this.onGates,
    required this.onEdit,
    required this.onDelete,
  });
  final GeoEntry entry;
  final bool canEdit;
  final VoidCallback onGeofence, onGates, onEdit, onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = entry.values;
    final code = '${v['code'] ?? ''}';
    final hasBoundary = parseBoundary(v['boundary']) != null;
    final where = [v['city'], v['state'], v['country']].map((x) => '${x ?? ''}').where((s) => s.isNotEmpty).join(' • ');
    Widget badge(String text, Color c) => Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Text(text, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
        );
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(Icons.flight, color: scheme.primary, size: 20),
      ),
      title: Row(children: [
        Flexible(child: Text('${v['name'] ?? 'Airport'}', overflow: TextOverflow.ellipsis)),
        if (code.isNotEmpty) badge(code, scheme.primary),
        if (hasBoundary) badge('Geofence', Colors.teal),
      ]),
      subtitle: where.isEmpty ? null : Text(where),
      trailing: Wrap(children: [
        IconButton(
          tooltip: 'Geofence',
          icon: Icon(Icons.map_outlined, color: hasBoundary ? scheme.primary : null),
          onPressed: onGeofence,
        ),
        IconButton(tooltip: 'Gates', icon: const Icon(Icons.door_front_door_outlined), onPressed: onGates),
        if (canEdit) IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
        if (canEdit)
          IconButton(tooltip: 'Delete', icon: Icon(Icons.delete_outline, color: scheme.error), onPressed: onDelete),
      ]),
    );
  }
}

class _AirportFormBody extends StatefulWidget {
  const _AirportFormBody({required this.initial});
  final AirportForm initial;

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
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _code, _country, _state, _city]) {
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
      ..city = _city.text;
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
      if (_error != null) ...[gap, Text(_error!, style: TextStyle(color: t.colorScheme.error))],
      const SizedBox(height: 20),
      FilledButton.icon(onPressed: _submit, icon: const Icon(Icons.save), label: const Text('Save')),
    ]);
  }
}
