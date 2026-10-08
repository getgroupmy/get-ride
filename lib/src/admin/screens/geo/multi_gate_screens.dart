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
import 'boundary_editor.dart';
import 'geo_data.dart';
import 'geo_logic.dart';
import 'place_search_field.dart';

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
      ),
    );
    if (form == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref
          .read(geoAdminRepositoryProvider)
          .saveMultiGate('place', id: entry?.id, values: form.toValues(), position: entry?.position ?? 0),
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
      floatingActionButton: FloatingActionButton.extended(
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
          return ResponsiveCenter(
            maxWidth: 900,
            child: ListView(padding: const EdgeInsets.only(top: 12, bottom: 96), children: [
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
                for (final e in entries)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.apartment),
                      title: Text('${e.values['name'] ?? 'Place'}'),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Wrap(children: [
                          _pill('${e.values['gates'] ?? 0} gates', t.colorScheme.primary),
                          _pill(placeIsActive(e.values) ? 'Active' : 'Inactive',
                              placeIsActive(e.values) ? Colors.green : Colors.grey),
                          _pill(placeGateRequired(e.values) ? 'Gate required' : 'Gate optional', Colors.orange),
                        ]),
                        if ('${e.values['address'] ?? ''}'.isNotEmpty)
                          Text('${e.values['address']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      ]),
                      isThreeLine: true,
                      trailing: Wrap(children: [
                        IconButton(
                          tooltip: 'Gates',
                          icon: const Icon(Icons.door_front_door_outlined),
                          onPressed: () => context.push(gatesPath(e.id, multiGatePlacesKey)),
                        ),
                        if (canEdit)
                          BusyIconButton(
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
                  ),
            ]),
          );
        },
      ),
    );
  }
}

class _PlaceFormBody extends StatefulWidget {
  const _PlaceFormBody({required this.initial, required this.editing});
  final PlaceForm initial;
  final bool editing;

  @override
  State<_PlaceFormBody> createState() => _PlaceFormBodyState();
}

class _PlaceFormBodyState extends State<_PlaceFormBody> {
  late final PlaceForm f = widget.initial;
  late final _name = TextEditingController(text: f.name);
  late final _gates = TextEditingController(text: f.gates);
  late final _address = TextEditingController(text: f.address);
  late final _lat = TextEditingController(text: f.lat);
  late final _lon = TextEditingController(text: f.lon);
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _gates, _address, _lat, _lon]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    f
      ..name = _name.text
      ..gates = _gates.text
      ..address = _address.text
      ..lat = _lat.text
      ..lon = _lon.text;
    final err = f.validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, f);
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 12);
    const coord = TextInputType.numberWithOptions(decimal: true, signed: true);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: _name, decoration: const InputDecoration(labelText: 'Place Name *', hintText: 'e.g. KLIA Terminal 1')),
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
            values: form.toValues(placeId: placeId, parentKey: parentKey),
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
      floatingActionButton: place == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(context, ref, gates, place.values),
              icon: const Icon(Icons.add),
              label: const Text('Add gate'),
            ),
      body: AsyncView(
        value: gatesAsync,
        onRetry: () => ref.invalidate(multiGateGatesProvider),
        data: (_) {
          if (placesAsync.isLoading) return const LoadingSkeletonPage();
          if (place == null) {
            return const EmptyState(
              icon: Icons.error_outline,
              title: 'Place not found',
              message: 'The place you are trying to manage does not exist.',
            );
          }
          return ResponsiveCenter(
            maxWidth: 900,
            child: ListView(padding: const EdgeInsets.only(top: 12, bottom: 96), children: [
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
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _lat, _lon, _pick, _drop]) {
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
      ..dropSurcharge = _drop.text;
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
      Row(children: [
        Expanded(child: TextField(controller: _lat, keyboardType: coord, decoration: const InputDecoration(labelText: 'Latitude *', hintText: '2.7456'))),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _lon, keyboardType: coord, decoration: const InputDecoration(labelText: 'Longitude *', hintText: '101.7099'))),
      ]),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _pickOnMap, icon: const Icon(Icons.my_location), label: const Text('Pick on map')),
      gap,
      DropdownButtonFormField<int>(
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
