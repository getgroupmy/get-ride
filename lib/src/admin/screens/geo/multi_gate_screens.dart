import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/loading_skeleton.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../../core/airport_queue.dart';
import '../../../core/place_types.dart';
import '../../../data/place_types_repository.dart';
import '../../../widgets/place_type_badge.dart';
import '../../../data/airport_repository.dart' show airportSettingsProvider;
import 'airport_editor.dart';
import 'boundary_editor.dart';
import 'geo_data.dart';
import 'geo_logic.dart';
import 'part_of_fields.dart';
import 'place_search_field.dart';
import '../../../widgets/search_select.dart';

const multiGatePlacesPage = 'admin-settings-multi-gate-places';
const multiGateGatesPage = 'admin-settings-multi-gate-place-gates';

String gatesPath(String placeId, String parentKey) => Uri(
      path: '/admin/m/multi-gate-place-gates',
      queryParameters: {'placeId': placeId, 'parentKey': parentKey},
    ).toString();

Widget _pill(String text, Color c) => Container(
      margin: const EdgeInsets.only(right: 6, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
    );

// ---------------------------------------------------------------------------
// Places
// ---------------------------------------------------------------------------

/// Places with several pickup / drop gates (Expo
/// `admin-settings-multi-gate-places.tsx`, `multi_gate` kind 'place').
class AdminMultiGatePlacesScreen extends ConsumerWidget {
  const AdminMultiGatePlacesScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, {GeoEntry? entry, PlaceForm? initial}) async {
    final form = await showAdminSheet<PlaceForm>(
      context,
      title: entry == null ? 'Add Place' : 'Edit Place',
      builder: (_) => _PlaceFormBody(
        initial: initial ?? (entry == null ? PlaceForm() : PlaceForm.fromValues(entry.values)),
        editing: entry != null,
        id: entry?.id,
      ),
    );
    if (form == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref
          .read(geoAdminRepositoryProvider)
          // Keys the form doesn't edit (the boundary and its tools, 0258) are kept.
          .saveMultiGate('place', id: entry?.id, values: {...?entry?.values, ...form.toValues()}, position: entry?.position ?? 0),
      success: 'Place saved',
    );
    if (ok) ref.invalidate(multiGatePlacesProvider);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, GeoEntry e) async {
    if (!await confirm(context, 'Delete', 'Remove this place?', ok: 'Delete')) return;
    if (!context.mounted) return;
    final ok = await runAdminAction(context, () => ref.read(geoAdminRepositoryProvider).deleteMultiGate('place', e.id),
        success: 'Place deleted');
    if (ok) ref.invalidate(multiGatePlacesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(multiGatePlacesPage)) == AccessLevel.edit;
    final async = ref.watch(multiGatePlacesProvider);
    final settings = ref.watch(airportSettingsProvider).value ?? const <String, AirportSettings>{};
    final types = placeTypesNow(ref);
    return AdminPage(
      title: 'Multi-Gate Places',
      page: multiGatePlacesPage,
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(multiGatePlacesProvider),
        ),
      ],
      addAction: PageAddAction(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add manually'),
      ),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(multiGatePlacesProvider),
        data: (entries) {
          final added = {
            for (final e in entries)
              if ('${e.values['lat'] ?? ''}'.isNotEmpty && '${e.values['lon'] ?? ''}'.isNotEmpty)
                '${e.values['lat']},${e.values['lon']}',
          };
          final t = Theme.of(context);
          Widget card(GeoEntry e) => Card(
                    child: ListTile(
                      // The place's type (0264): Other until it has one.
                      leading: PlaceTypeIcon(
                        key: ValueKey('place-type-icon-${e.id}'),
                        type: placeTypeFor(placeTypeKeyOf(e.values), types),
                        background: placeIconColorOf(e.values),
                      ),
                      title: Text('${e.values['name'] ?? 'Place'}'),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Wrap(children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 6, top: 4),
                            child: PlaceTypePill(
                              key: ValueKey('place-type-pill-${e.id}'),
                              type: placeTypeFor(placeTypeKeyOf(e.values), types),
                              fontSize: 11,
                            ),
                          ),
                          _pill('${e.values['gates'] ?? 0} gates', t.colorScheme.primary),
                          _pill(placeIsActive(e.values) ? 'Active' : 'Inactive',
                              placeIsActive(e.values) ? Colors.green : Colors.grey),
                          _pill(placeGateRequired(e.values) ? 'Gate required' : 'Gate optional', Colors.orange),
                          for (final tool in placeToolLabels(e.values, settings[e.id])) _pill(tool, Colors.teal),
                        ]),
                        if ('${e.values['address'] ?? ''}'.isNotEmpty)
                          Text('${e.values['address']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      ]),
                      isThreeLine: true,
                      trailing: Wrap(children: [
                        IconButton(
                          key: ValueKey('place-tools-${e.id}'),
                          tooltip: 'Boundary, doors, charge, fares, queue',
                          icon: const Icon(Icons.tune),
                          onPressed: () => AirportEditor.openPlace(context, entry: e, canEdit: canEdit),
                        ),
                        IconButton(
                          tooltip: 'Gates',
                          icon: const Icon(Icons.door_front_door_outlined),
                          onPressed: () => context.push(gatesPath(e.id, multiGatePlacesKey)),
                        ),
                        if (canEdit)
                          BusyIconButton(
                            key: ValueKey('place-edit-${e.id}'),
                            tooltip: 'Edit',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _edit(context, ref, entry: e),
                          ),
                        if (canEdit)
                          BusyIconButton(
                            tooltip: 'Delete',
                            icon: Icon(Icons.delete_outline, color: t.colorScheme.error),
                            onPressed: () => _delete(context, ref, e),
                          ),
                      ]),
                    ),
                  );
          return ResponsiveCenter(
            maxWidth: 900,
            child: ListView(padding: EdgeInsets.only(top: 12, bottom: addActionListBottomPadding(context)), children: [
              if (canEdit) ...[
                PlaceSearchField(
                  hint: 'Search airports, malls, stations...',
                  dedupeDigits: 3,
                  maxResults: 12,
                  inline: false,
                  isAdded: (r) => added.contains('${r.lat},${r.lon}'),
                  onPicked: (r) => _edit(context, ref, initial: PlaceForm.fromResult(r)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('Type at least 3 letters to search global places, then tap to add.',
                      style: t.textTheme.bodySmall),
                ),
              ],
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text('ADDED (${entries.length})', style: t.textTheme.labelLarge),
              ),
              if (entries.isEmpty)
                const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'No places yet',
                  message: 'Search above or add one manually to get started.',
                )
              else
                ListSearchFilter(count: entries.length, hint: 'Search places', builder: (context, q) {
                  // Places that are part of one (KLIA Terminal 1 and 2, part of
                  // KLIA) under its name, then the rest on their own.
                  final groups = [
                    for (final g in partOfGroups(entries, (e) => e.values))
                      (
                        name: g.name,
                        count: g.items.length,
                        items: [
                          for (final e in g.items)
                            if (q.isEmpty ||
                                searchSelectMatches(
                                    '${e.values['name'] ?? ''} ${e.values['address'] ?? ''} ${e.values['partOf'] ?? ''}', q))
                              e,
                        ],
                      ),
                  ];
                  final grouped = groups.any((g) => g.name.isNotEmpty);
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    for (final g in groups)
                      if (g.items.isNotEmpty) ...[
                        if (grouped)
                          Padding(
                            key: ValueKey('place-group-${g.name}'),
                            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                            child: Row(children: [
                              Icon(g.name.isEmpty ? Icons.place_outlined : Icons.link,
                                  size: 18, color: t.colorScheme.primary),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  g.name.isEmpty ? 'On their own' : '${g.name} · ${g.count} ${g.count == 1 ? 'place' : 'places'}',
                                  style: t.textTheme.titleSmall,
                                ),
                              ),
                            ]),
                          ),
                        for (final e in g.items) card(e),
                      ],
                  ]);
                }),
            ]),
          );
        },
      ),
    );
  }
}

class _PlaceFormBody extends ConsumerStatefulWidget {
  const _PlaceFormBody({required this.initial, required this.editing, this.id});
  final PlaceForm initial;
  final bool editing;

  /// The place being edited (null when adding one).
  final String? id;

  @override
  ConsumerState<_PlaceFormBody> createState() => _PlaceFormBodyState();
}

class _PlaceFormBodyState extends ConsumerState<_PlaceFormBody> {
  late final PlaceForm f = widget.initial;
  late final _name = TextEditingController(text: f.name)..addListener(_nameChanged);
  String _guessedFor = '\u0000';

  /// The guess follows the name while the admin hasn't chosen a type.
  void _nameChanged() {
    if (!f.placeTypeSet && _name.text != _guessedFor && mounted) setState(() {});
  }
  late final _gates = TextEditingController(text: f.gates);
  late final _address = TextEditingController(text: f.address);
  late final _lat = TextEditingController(text: f.lat);
  late final _lon = TextEditingController(text: f.lon);
  late final _partOf = TextEditingController(text: f.partOf);
  late final _partOrder = TextEditingController(text: f.partOrder);
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _gates, _address, _lat, _lon, _partOf, _partOrder]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!f.placeTypeSet) f.placeType = _guess(placeTypesNow(ref));
    f
      ..name = _name.text
      ..gates = _gates.text
      ..address = _address.text
      ..lat = _lat.text
      ..lon = _lon.text
      ..partOf = _partOf.text
      ..partOrder = _partOrder.text;
    final err = f.validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, f);
  }

  /// The type the name (and OpenStreetMap's type) suggest.
  String _guess(List<PlaceType> types) {
    _guessedFor = _name.text;
    return pickPlaceType(_name.text, types, osmType: f.osmType, googleType: f.primaryType);
  }

  /// The place type: a chip per type, searchable; the guess until the
  /// admin taps one (0264).
  Widget _typePicker(BuildContext context) {
    final t = Theme.of(context);
    final types = placeTypesNow(ref);
    final chosen = f.placeTypeSet ? (f.placeType ?? otherPlaceTypeKey) : _guess(types);
    final shown = [for (final x in types) if (x.active || x.key == chosen) x];
    final good = t.brightness == Brightness.dark ? Colors.green.shade300 : Colors.green.shade800;
    return Column(
      key: const ValueKey('place-type-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Place type', style: t.textTheme.titleSmall),
        ListSearchFilter(
          count: shown.length,
          hint: 'Search types',
          fieldKey: const ValueKey('place-type-picker-search'),
          builder: (context, q) => Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final x in shown)
                  if (q.isEmpty || searchSelectMatches(x.name, q) || x.key == chosen)
                    ChoiceChip(
                      key: ValueKey('place-type-chip-${x.key}'),
                      avatar: Icon(x.iconData, size: 18, color: x.colorFor(t.brightness)),
                      label: Text(x.name),
                      selected: x.key == chosen,
                      onSelected: (_) => setState(() {
                        f
                          ..placeType = x.key
                          ..placeTypeSet = true;
                      }),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          f.placeTypeSet
              ? 'Set by admin'
              : f.primaryType != null
                  ? "Suggested from Google's place type and the name"
                  : f.osmType == null
                      ? 'Suggested from the name'
                      : 'Suggested from the name and map data',
          key: const ValueKey('place-type-source'),
          style: t.textTheme.bodySmall?.copyWith(color: f.placeTypeSet ? mutedTextColor(t) : good),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 12);
    const coord = TextInputType.numberWithOptions(decimal: true, signed: true);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: _name, decoration: const InputDecoration(labelText: 'Place Name *', hintText: 'e.g. KLIA Terminal 1')),
      gap,
      _typePicker(context),
      gap,
      TextField(
        controller: _gates,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(labelText: 'Number of Gates *', hintText: 'e.g. 4'),
      ),
      gap,
      TextField(
        controller: _address,
        maxLines: 3,
        minLines: 1,
        decoration: const InputDecoration(labelText: 'Address', hintText: 'Full address'),
      ),
      gap,
      Row(children: [
        Expanded(
          child: TextField(controller: _lat, keyboardType: coord, decoration: const InputDecoration(labelText: 'Latitude', hintText: 'e.g. 2.7456')),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(controller: _lon, keyboardType: coord, decoration: const InputDecoration(labelText: 'Longitude', hintText: 'e.g. 101.7099')),
        ),
      ]),
      gap,
      PartOfFields(partOf: _partOf, order: _partOrder, selfId: widget.id),
      gap,
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Gate required'),
        subtitle: const Text('Compulsory for users to pick a gate at this place'),
        value: f.gateRequired,
        onChanged: (v) => setState(() => f.gateRequired = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Active'),
        subtitle: Text(f.active ? 'Active — visible in user search' : 'Deactivated — hidden from users'),
        value: f.active,
        onChanged: (v) => setState(() => f.active = v),
      ),
      if (_error != null) ...[gap, Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))],
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _submit,
        icon: const Icon(Icons.save),
        label: Text(widget.editing ? 'Save changes' : 'Add Place'),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Gates
// ---------------------------------------------------------------------------

/// Gates of one multi-gate place or airport (Expo
/// `admin-settings-multi-gate-place-gates.tsx`, `multi_gate` kind 'gate').
class AdminMultiGateGatesScreen extends ConsumerWidget {
  const AdminMultiGateGatesScreen({super.key, required this.placeId, this.parentKey = multiGatePlacesKey});
  final String placeId;
  final String parentKey;

  Future<void> _edit(BuildContext context, WidgetRef ref, List<GeoEntry> gates, Map<String, dynamic>? place,
      {GeoEntry? entry}) async {
    final form = await showAdminSheet<GateForm>(
      context,
      title: entry == null ? 'Add Gate' : 'Edit Gate',
      builder: (_) => _GateFormBody(
        initial: entry == null ? GateForm.next(gates.length, placeCenter(place)) : GateForm.fromValues(entry.values),
        editing: entry != null,
        priorityCount: gates.length + 1 < 10 ? 10 : gates.length + 1,
        fallback: placeCenter(place),
      ),
    );
    if (form == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(geoAdminRepositoryProvider).saveMultiGate(
            'gate',
            id: entry?.id,
            // Keys the form doesn't edit (an airport door's guide, 0249) are kept.
            values: {...?entry?.values, 'group': null, ...form.toValues(placeId: placeId, parentKey: parentKey)}
              ..removeWhere((k, v) => k == 'group' && v == null),
            position: entry?.position ?? 0,
          ),
      success: 'Gate saved',
    );
    if (ok) ref.invalidate(multiGateGatesProvider);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, GeoEntry e) async {
    if (!await confirm(context, 'Delete gate', 'Remove this gate?', ok: 'Delete')) return;
    if (!context.mounted) return;
    final ok = await runAdminAction(context, () => ref.read(geoAdminRepositoryProvider).deleteMultiGate('gate', e.id),
        success: 'Gate deleted');
    if (ok) ref.invalidate(multiGateGatesProvider);
  }

  Future<void> _move(BuildContext context, WidgetRef ref, List<GeoEntry> sorted, String id, int dir) async {
    final changes = reorderGates(
      [for (final g in sorted) g.id],
      {for (final g in sorted) g.id: g.values['displayPriority'] is num ? g.values['displayPriority'] as num : num.tryParse('${g.values['displayPriority']}')},
      id,
      dir,
    );
    if (changes.isEmpty) return;
    HapticFeedback.selectionClick();
    final repo = ref.read(geoAdminRepositoryProvider);
    await runAdminAction(context, () async {
      for (final g in sorted) {
        final p = changes[g.id];
        if (p == null) continue;
        await repo.saveMultiGate('gate', id: g.id, values: {...g.values, 'displayPriority': p}, position: g.position);
      }
    });
    ref.invalidate(multiGateGatesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(multiGateGatesPage)) == AccessLevel.edit;
    final placesAsync = parentKey == airportAreasKey ? ref.watch(airportsProvider) : ref.watch(multiGatePlacesProvider);
    final gatesAsync = ref.watch(multiGateGatesProvider);
    final place = placesAsync.value?.where((e) => e.id == placeId).firstOrNull;
    final all = gatesAsync.value ?? const <GeoEntry>[];
    final gates = gatesForPlace(all, (g) => g.values, placeId, parentKey);
    final t = Theme.of(context);
    return AdminPage(
      title: place == null ? 'Place Gates' : '${place.values['name'] ?? 'Place Gates'}',
      page: multiGateGatesPage,
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref
            ..invalidate(multiGateGatesProvider)
            ..invalidate(parentKey == airportAreasKey ? airportsProvider : multiGatePlacesProvider),
        ),
      ],
      addAction: place == null
          ? null
          : PageAddAction(
              onPressed: () => _edit(context, ref, gates, place.values),
              icon: const Icon(Icons.add),
              label: const Text('Add gate'),
            ),
      body: AsyncView(
        value: gatesAsync,
        onRetry: () => ref.invalidate(multiGateGatesProvider),
        data: (_) {
          if (placesAsync.isLoading && !placesAsync.hasValue) return const LoadingSkeletonPage();
          if (place == null) {
            return const EmptyState(
              icon: Icons.error_outline,
              title: 'Place not found',
              message: 'The place you are trying to manage does not exist.',
            );
          }
          return ResponsiveCenter(
            maxWidth: 900,
            child: ListView(padding: EdgeInsets.only(top: 12, bottom: addActionListBottomPadding(context)), children: [
              Text('${gates.length} ${gates.length == 1 ? 'gate' : 'gates'} assigned', style: t.textTheme.bodySmall),
              const SizedBox(height: 8),
              if (gates.isEmpty)
                const EmptyState(
                  icon: Icons.door_front_door_outlined,
                  title: 'No gates yet',
                  message: 'Add a gate location and name to help drivers reach the right pickup point.',
                )
              else
                for (var i = 0; i < gates.length; i++) _gateTile(context, ref, gates, i, canEdit, place.values),
            ]),
          );
        },
      ),
    );
  }

  Widget _gateTile(
    BuildContext context,
    WidgetRef ref,
    List<GeoEntry> gates,
    int i,
    bool canEdit,
    Map<String, dynamic> place,
  ) {
    final t = Theme.of(context);
    final g = gates[i];
    final v = g.values;
    final active = placeIsActive(v);
    final mode = parseGateMode(v['mode']);
    final pick = gateSurcharge(v, pickup: true);
    final drop = gateSurcharge(v, pickup: false);
    String fmt(double n) => n == n.truncateToDouble() ? n.toInt().toString() : '$n';
    return Opacity(
      opacity: active ? 1 : 0.6,
      child: Card(
        child: ListTile(
          leading: canEdit
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  InkWell(
                    onTap: i == 0 ? null : () => _move(context, ref, gates, g.id, -1),
                    child: Icon(Icons.keyboard_arrow_up, color: i == 0 ? t.disabledColor : null),
                  ),
                  InkWell(
                    onTap: i == gates.length - 1 ? null : () => _move(context, ref, gates, g.id, 1),
                    child: Icon(Icons.keyboard_arrow_down, color: i == gates.length - 1 ? t.disabledColor : null),
                  ),
                ])
              : CircleAvatar(child: Text('${v['displayPriority'] ?? '-'}')),
          title: Text('${v['name'] ?? 'Gate'}'),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(children: [
              _pill('#${v['displayPriority'] ?? '-'}', t.colorScheme.primary),
              _pill(active ? 'Active' : 'Hidden', active ? Colors.green : Colors.grey),
              _pill(gateModeLabel(mode), Colors.indigo),
              if (pick != null) _pill('Pick up +${fmt(pick)}', Colors.orange),
              if (drop != null) _pill('Drop +${fmt(drop)}', Colors.orange),
            ]),
            Text('${v['lat'] ?? ''}, ${v['lon'] ?? ''}'),
          ]),
          isThreeLine: true,
          trailing: canEdit
              ? Wrap(children: [
                  BusyIconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _edit(context, ref, gates, place, entry: g),
                  ),
                  BusyIconButton(
                    tooltip: 'Delete',
                    icon: Icon(Icons.delete_outline, color: t.colorScheme.error),
                    onPressed: () => _delete(context, ref, g),
                  ),
                ])
              : null,
        ),
      ),
    );
  }
}

class _GateFormBody extends StatefulWidget {
  const _GateFormBody({required this.initial, required this.editing, required this.priorityCount, required this.fallback});
  final GateForm initial;
  final bool editing;
  final int priorityCount;
  final LatLng fallback;

  @override
  State<_GateFormBody> createState() => _GateFormBodyState();
}

class _GateFormBodyState extends State<_GateFormBody> {
  late final GateForm f = widget.initial;
  late final _name = TextEditingController(text: f.name);
  late final _lat = TextEditingController(text: f.lat);
  late final _lon = TextEditingController(text: f.lon);
  late final _pick = TextEditingController(text: f.pickupSurcharge);
  late final _drop = TextEditingController(text: f.dropSurcharge);
  late final _group = TextEditingController(text: f.group);
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _lat, _lon, _pick, _drop, _group]) {
      c.dispose();
    }
    super.dispose();
  }

  void _read() {
    f
      ..name = _name.text
      ..lat = _lat.text
      ..lon = _lon.text
      ..pickupSurcharge = _pick.text
      ..dropSurcharge = _drop.text
      ..group = _group.text;
  }

  Future<void> _pickOnMap() async {
    _read();
    final start = latLngOf({'lat': f.lat, 'lon': f.lon}) ?? widget.fallback;
    final p = await PointPickerPage.open(context, start, title: 'Gate location');
    if (p == null || !mounted) return;
    setState(() {
      _lat.text = p.latitude.toStringAsFixed(6);
      _lon.text = p.longitude.toStringAsFixed(6);
    });
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
    const coord = TextInputType.numberWithOptions(decimal: true, signed: true);
    const money = TextInputType.numberWithOptions(decimal: true);
    final maxP = widget.priorityCount < f.displayPriority ? f.displayPriority : widget.priorityCount;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: _name, decoration: const InputDecoration(labelText: 'Gate name *', hintText: 'e.g. Gate A / Departure Hall')),
      gap,
      TextField(
        key: const ValueKey('gate-group'),
        controller: _group,
        decoration: const InputDecoration(
          labelText: 'Group',
          hintText: 'e.g. KLIA Terminal 1 / klia2',
          helperText: 'Optional. Riders pick the group first, then its gate.',
        ),
      ),
      gap,
      Row(children: [
        Expanded(child: TextField(controller: _lat, keyboardType: coord, decoration: const InputDecoration(labelText: 'Latitude *', hintText: '2.7456'))),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _lon, keyboardType: coord, decoration: const InputDecoration(labelText: 'Longitude *', hintText: '101.7099'))),
      ]),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _pickOnMap, icon: const Icon(Icons.my_location), label: const Text('Pick on map')),
      gap,
      SearchableDropdownFormField<int>(
        isExpanded: true,
        initialValue: f.displayPriority,
        decoration: const InputDecoration(labelText: 'Display priority', helperText: 'Lower number shows first to users.'),
        items: [for (var n = 1; n <= maxP; n++) DropdownMenuItem(value: n, child: Text('$n'))],
        onChanged: (v) => setState(() => f.displayPriority = v ?? 1),
      ),
      gap,
      Text('Gate type', style: t.textTheme.titleSmall),
      const SizedBox(height: 6),
      SegmentedButton<GateMode>(
        segments: const [
          ButtonSegment(value: GateMode.both, label: Text('Both'), icon: Icon(Icons.swap_horiz)),
          ButtonSegment(value: GateMode.pickup, label: Text('Pick up'), icon: Icon(Icons.upload)),
          ButtonSegment(value: GateMode.drop, label: Text('Drop'), icon: Icon(Icons.download)),
        ],
        selected: {f.mode},
        onSelectionChanged: (s) => setState(() => f.mode = s.first),
      ),
      const SizedBox(height: 4),
      Text('Controls when this gate appears in place search.', style: t.textTheme.bodySmall),
      if (f.mode != GateMode.drop) ...[
        gap,
        TextField(
          controller: _pick,
          keyboardType: money,
          decoration: const InputDecoration(
            labelText: 'Pick up surcharge',
            hintText: '0.00',
            helperText: 'Extra fee added when this gate is used for pickup.',
          ),
        ),
      ],
      if (f.mode != GateMode.pickup) ...[
        gap,
        TextField(
          controller: _drop,
          keyboardType: money,
          decoration: const InputDecoration(
            labelText: 'Drop surcharge',
            hintText: '0.00',
            helperText: 'Extra fee added when this gate is used for drop-off.',
          ),
        ),
      ],
      gap,
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Active'),
        subtitle: Text(f.active ? 'Visible to users' : 'Hidden from users'),
        value: f.active,
        onChanged: (v) => setState(() => f.active = v),
      ),
      if (_error != null) ...[gap, Text(_error!, style: TextStyle(color: t.colorScheme.error))],
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _submit,
        icon: const Icon(Icons.save),
        label: Text(widget.editing ? 'Save changes' : 'Add Gate'),
      ),
    ]);
  }
}


/// The tools a place has on, for its card (0258): "Boundary", "Doors
/// required", "Guide", "Charge", "Own fares", "Queue". Empty without a
/// boundary.
List<String> placeToolLabels(Map<String, dynamic> values, AirportSettings? s) {
  if (!placeAreaOn(values)) return const [];
  return [
    'Boundary',
    if (s != null) ...[
      if (s.doorsRequired) 'Doors required',
      if (s.guideOn) 'Guide',
      if (s.placeChargeOn) 'Charge',
      if (s.faresOn) 'Own fares',
      if (s.restrictPickups) 'Queue',
    ],
  ];
}
