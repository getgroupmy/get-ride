// Admin → Airport Areas: one airport's editor (migration 0249) with six tabs
// — Area, Gates & doors, Pickup rules, Waiting queue, Fares and Charges.
// Doors are the airport's gates in multi_gate (the Multi-Gate page's rows),
// so a change here shows there at once and the reverse; settings, waiting
// zones and fare zones are airport_settings / airport_waiting_zones /
// airport_fare_zones, followed live.
//
// The same editor serves Admin → Multi-Gate Places (migration 0258) with
// [AirportEditor.place]: six tabs, one per tool, each with its own switch —
// Boundary, Doors, Pickup guide, Extra charge, Own fares and Waiting queue.
// A place's tools work once its boundary is on (the server keeps its area
// row and settings, see 0258); a place with no boundary keeps its gates only.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/airport_queue.dart';
import '../../../data/airport_repository.dart';
import '../../../features/ride/airport_door_sheet.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../widgets/admin_widgets.dart';
import '../catalogue/catalogue_data.dart' show pickImageFile;
import '../catalogue/service_order_screen.dart' show serviceOrderPath;
import 'airport_tabs.dart';
import 'boundary_editor.dart';
import 'geo_data.dart';
import 'geo_logic.dart';
import 'place_area_tabs.dart';

/// The editor's tabs, in order.
/// A place's tabs (Admin → Multi-Gate Places), in order.
const placeEditorTabs = [
  'Boundary',
  'Doors',
  'Pickup guide',
  'Extra charge',
  'Own fares',
  'Waiting queue',
];

const airportEditorTabs = [
  'Area',
  'Gates & doors',
  'Pickup rules',
  'Waiting queue',
  'Fares',
  'Charges',
];

class AirportEditor extends ConsumerStatefulWidget {
  const AirportEditor({
    super.key,
    required this.entry,
    required this.canEdit,
    this.onEditDetails,
    this.onEditBoundary,
    this.showHeader = true,
    this.place = false,
  });

  final GeoEntry entry;
  final bool canEdit;
  final VoidCallback? onEditDetails, onEditBoundary;
  final bool showHeader;

  /// A multi-gate place (Places page) rather than an airport.
  final bool place;

  static Future<void> open(
    BuildContext context, {
    required GeoEntry entry,
    required bool canEdit,
    VoidCallback? onEditDetails,
    VoidCallback? onEditBoundary,
  }) => Navigator.of(context).push(
    AppPageRoute(
      id: 'airport-areas.editor',
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text('${entry.values['name'] ?? 'Airport'}')),
        body: SafeArea(
          child: AirportEditor(
            entry: entry,
            canEdit: canEdit,
            onEditDetails: onEditDetails,
            onEditBoundary: onEditBoundary,
            showHeader: false,
          ),
        ),
      ),
    ),
  );

  /// A multi-gate place's tools (Admin → Multi-Gate Places).
  static Future<void> openPlace(
    BuildContext context, {
    required GeoEntry entry,
    required bool canEdit,
  }) => Navigator.of(context).push(
    AppPageRoute(
      id: 'multi-gate-places.editor',
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text('${entry.values['name'] ?? 'Place'}')),
        body: SafeArea(
          child: AirportEditor(
            entry: entry,
            canEdit: canEdit,
            showHeader: false,
            place: true,
          ),
        ),
      ),
    ),
  );

  @override
  ConsumerState<AirportEditor> createState() => _AirportEditorState();
}

class _AirportEditorState extends ConsumerState<AirportEditor> {
  AirportSettings? _draft;
  bool _saving = false;

  /// The pickup door whose guide is open, and its steps as edited.
  String? _guideDoor;
  List<GuideStep>? _guideSteps;
  bool _guideDirty = false;
  int? _uploading;

  String get _id => widget.entry.id;

  /// The airport as stored now (a boundary or details saved since this
  /// editor opened show at once).
  GeoEntry get _entry =>
      (ref.read(widget.place ? multiGatePlacesProvider : airportsProvider).value ?? const <GeoEntry>[])
          .where((e) => e.id == _id)
          .firstOrNull ??
      widget.entry;

  bool get _place => widget.place;
  String get _parentKey => _place ? multiGatePlacesKey : airportAreasKey;
  String get _noun => _place ? 'place' : 'airport';
  bool get _edit => widget.canEdit;

  AirportRepository get _repo => ref.read(airportRepositoryProvider);
  GeoAdminRepository get _geo => ref.read(geoAdminRepositoryProvider);

  void _change(AirportSettings s) => setState(() => _draft = s);

  Future<void> _save() async {
    final d = _draft;
    if (d == null) return;
    final problem = d.fares.band.on
        ? bandTiersProblem(d.fares.band.tiers)
        : null;
    if (problem != null) return showInfo(context, problem);
    setState(() => _saving = true);
    final ok = await runAdminAction(
      context,
      () => _repo.saveSettings(d),
      success: _place ? 'Place settings saved' : 'Airport settings saved',
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _draft = null;
    });
    if (ok) ref.invalidate(airportSettingsProvider);
  }

  // ---- Doors ----

  List<GeoEntry> _gates() => gatesForPlace(
    ref.read(multiGateGatesProvider).value ?? const <GeoEntry>[],
    (g) => g.values,
    _id,
    _parentKey,
  );

  GeoEntry? _gate(String id) => _gates().where((g) => g.id == id).firstOrNull;

  Future<void> _saveGate(
    GeoEntry g,
    Map<String, dynamic> values, {
    String? success,
  }) async {
    final ok = await runAdminAction(
      context,
      () => _geo.saveMultiGate(
        'gate',
        id: g.id,
        values: values,
        position: g.position,
      ),
      success: success,
    );
    if (ok) ref.invalidate(multiGateGatesProvider);
  }

  Future<void> _kind(AirportDoor d, DoorKind k) async {
    final g = _gate(d.id);
    if (g == null) return;
    await _saveGate(g, {...g.values, 'mode': doorMode(k)});
    if (k == DoorKind.drop && _guideDoor == d.id) {
      setState(() => _guideDoor = null);
    }
  }

  Future<String?> _askName(String title, String initial) async {
    final c = TextEditingController(text: initial);
    final name = await showAppDialog<String>(
      id: 'airport-areas.name',
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    c.dispose();
    final n = name?.trim();
    return n == null || n.isEmpty ? null : n;
  }

  Future<void> _addDoor() async {
    final gates = _gates();
    final name = await _askName('Add door', 'Door ${gates.length + 1}');
    if (name == null || !mounted) return;
    final f = GateForm.next(gates.length, placeCenter(_entry.values))
      ..name = name;
    final ok = await runAdminAction(
      context,
      () => _geo.saveMultiGate(
        'gate',
        values: f.toValues(placeId: _id, parentKey: _parentKey),
      ),
      success: 'Door added',
    );
    if (ok) ref.invalidate(multiGateGatesProvider);
  }

  Future<void> _rename(AirportDoor d) async {
    final g = _gate(d.id);
    if (g == null) return;
    final name = await _askName('Rename door', d.name);
    if (name == null || !mounted) return;
    await _saveGate(g, {...g.values, 'name': name});
  }

  Future<void> _removeDoor(AirportDoor d) async {
    if (!await confirm(
      context,
      'Remove door',
      'Remove ${d.name}? It goes from the Multi-Gate page too.',
      ok: 'Remove',
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runAdminAction(
      context,
      () => _geo.deleteMultiGate('gate', d.id),
      success: 'Door removed',
    );
    if (!ok) return;
    ref.invalidate(multiGateGatesProvider);
    if (_guideDoor == d.id) setState(() => _guideDoor = null);
  }

  Future<void> _move(AirportDoor d, int dir) async {
    final sorted = _gates();
    final changes = reorderGates(
      [for (final g in sorted) g.id],
      {
        for (final g in sorted)
          g.id: g.values['displayPriority'] is num
              ? g.values['displayPriority'] as num
              : num.tryParse('${g.values['displayPriority']}'),
      },
      d.id,
      dir,
    );
    if (changes.isEmpty) return;
    await runAdminAction(context, () async {
      for (final g in sorted) {
        final p = changes[g.id];
        if (p != null) {
          await _geo.saveMultiGate(
            'gate',
            id: g.id,
            values: {...g.values, 'displayPriority': p},
            position: g.position,
          );
        }
      }
    });
    ref.invalidate(multiGateGatesProvider);
  }

  void _openGuide(AirportDoor d) => setState(() {
    _guideDoor = d.id;
    _guideSteps = [...d.guide];
    _guideDirty = false;
  });

  Future<void> _saveGuide() async {
    final g = _gate(_guideDoor ?? '');
    final steps = _guideSteps;
    if (g == null || steps == null) return;
    await _saveGate(g, {
      ...g.values,
      'guide': [for (final s in steps) s.toJson()],
    }, success: 'Guide saved');
    if (mounted) setState(() => _guideDirty = false);
  }

  Future<void> _photo(int i) async {
    final steps = _guideSteps;
    if (steps == null) return;
    try {
      final f = await pickImageFile();
      if (f == null || !mounted) return;
      setState(() => _uploading = i);
      final url = await _repo.uploadGuidePhoto(_id, f.bytes, f.name);
      if (!mounted) return;
      setState(() {
        _guideSteps = [
          for (var k = 0; k < steps.length; k++)
            k == i ? steps[k].copyWith(photo: url) : steps[k],
        ];
        _guideDirty = true;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  // ---- A place's boundary (0258) ----

  Future<void> _savePlace(Map<String, dynamic> values, {String? success}) async {
    final e = _entry;
    final ok = await runAdminAction(
      context,
      () => _geo.saveMultiGate('place', id: e.id, values: values, position: e.position),
      success: success,
    );
    if (ok) ref.invalidate(multiGatePlacesProvider);
  }

  Future<void> _drawPlaceBoundary() async {
    final e = _entry;
    final stored = parseBoundary(e.values['boundary']);
    final name = '${e.values['name'] ?? 'Place'}';
    await BoundaryEditorPage.open(
      context,
      BoundaryEditorPage(
        title: 'Boundary · $name',
        query: name,
        canEdit: _edit,
        initial: stored,
        near: latLngOf(e.values) ?? placeCenter(e.values),
        askQuery: true,
        onPickSaved: () => pickSavedRegionShape(context, ref),
        onSave: (shape) async {
          final now = _entry;
          await _geo.saveMultiGate(
            'place',
            id: now.id,
            values: {...now.values, ...boundaryValues(simplifyShape(shape), DateTime.now()), 'areaOn': true},
            position: now.position,
          );
          ref.invalidate(multiGatePlacesProvider);
        },
        onClear: stored == null
            ? null
            : () async {
                final now = _entry;
                await _geo.saveMultiGate(
                  'place',
                  id: now.id,
                  values: {...withoutBoundary(now.values), 'areaOn': false},
                  position: now.position,
                );
                ref.invalidate(multiGatePlacesProvider);
              },
      ),
    );
  }

  /// The boundary switch: on with no boundary yet opens the drawing.
  Future<void> _setPlaceArea(bool on) async {
    if (on && parseBoundary(_entry.values['boundary']) == null) return _drawPlaceBoundary();
    await _savePlace({..._entry.values, 'areaOn': on}, success: on ? 'Boundary on' : 'Boundary off');
  }

  // ---- Zones ----

  Future<void> _editZone(
    String table, {
    AirportZone? zone,
    required String title,
    required String defaultName,
  }) async {
    String? name = zone?.name;
    if (zone == null) {
      name = await _askName(title, defaultName);
      if (name == null || !mounted) return;
    }
    final initial = zone == null ? null : parseBoundary(jsonEncode(zone.shape));
    await BoundaryEditorPage.open(
      context,
      BoundaryEditorPage(
        title: '$title · ${name ?? ''}',
        query: '${_entry.values['name'] ?? (_place ? 'Place' : 'Airport')}',
        canEdit: _edit,
        initial: initial,
        near: latLngOf(_entry.values) ?? placeCenter(_entry.values),
        askQuery: true,
        onPickSaved: () => pickSavedRegionShape(context, ref),
        onSave: (shape) async {
          await _repo.saveZone(
            table,
            id: zone?.id,
            airportId: _id,
            name: name!,
            shape: simplifyShape(shape).toJson(),
            position: zone?.position ?? 0,
            toAmount: table == 'airport_fare_zones'
                ? (zone?.toAmount ?? 50)
                : null,
            fromAmount: table == 'airport_fare_zones'
                ? (zone?.fromAmount ?? 55)
                : null,
          );
          ref.invalidate(
            table == 'airport_fare_zones'
                ? airportFareZonesProvider
                : airportWaitingZonesProvider,
          );
        },
      ),
    );
  }

  Future<void> _removeZone(String table, AirportZone z) async {
    if (!await confirm(
      context,
      'Remove zone',
      'Remove ${z.name}?',
      ok: 'Remove',
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runAdminAction(
      context,
      () => _repo.deleteZone(table, z.id),
      success: 'Zone removed',
    );
    if (ok) {
      ref.invalidate(
        table == 'airport_fare_zones'
            ? airportFareZonesProvider
            : airportWaitingZonesProvider,
      );
    }
  }

  Future<void> _zoneAmounts(AirportZone z, double to, double from) async {
    try {
      await _repo.saveZone(
        'airport_fare_zones',
        id: z.id,
        airportId: _id,
        name: z.name,
        shape: z.shape,
        position: z.position,
        toAmount: to,
        fromAmount: from,
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(_place ? multiGatePlacesProvider : airportsProvider);
    final entry = _entry;
    final t = Theme.of(context);
    final settingsById = ref.watch(airportSettingsProvider).value ?? const <String, AirportSettings>{};
    // A place has settings once its boundary has been on (0258).
    final ready = !_place || settingsById.containsKey(_id);
    final saved = settingsById[_id] ?? (_place ? AirportSettings.place(_id) : AirportSettings(airportId: _id));
    final s = _draft ?? saved;
    final on = _edit && ready ? _change : null;
    final gates = gatesForPlace(
      ref.watch(multiGateGatesProvider).value ?? const <GeoEntry>[],
      (g) => g.values,
      _id,
      _parentKey,
    );
    final doors = [for (final g in gates) AirportDoor.fromGate(g.id, g.values)];
    final waits = [
      for (final z
          in ref.watch(airportWaitingZonesProvider).value ??
              const <AirportZone>[])
        if (z.airportId == _id) z,
    ];
    final fareZones = [
      for (final z
          in ref.watch(airportFareZonesProvider).value ?? const <AirportZone>[])
        if (z.airportId == _id) z,
    ];
    final serviceList = [
      for (final o
          in ref.watch(regionVehicleTypesProvider).value ??
              const <ServiceOption>[])
        (id: o.id, name: o.name),
    ];
    final services = [for (final o in serviceList) o.name];
    final guideDoor = doors
        .where((d) => d.id == _guideDoor && d.kind != DoorKind.drop)
        .firstOrNull;
    final guideSteps = _guideSteps ?? guideDoor?.guide ?? const <GuideStep>[];
    final shownGuide = guideDoor == null
        ? null
        : AirportDoor(
            id: guideDoor.id,
            airportId: _id,
            name: guideDoor.name,
            kind: guideDoor.kind,
            guide: guideSteps,
          );
    final boundary = parseBoundary(entry.values['boundary']);
    final map = AirportMapPreview(
      boundary: boundary,
      waitZones: waits,
      doors: doors,
      areaLabel: _place ? 'Place area' : 'Airport area',
    );
    final code = '${entry.values['code'] ?? ''}';

    final guideEditor = shownGuide == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AirportGuideEditor(
                door: shownGuide,
                busyStep: _uploading,
                onChanged: _edit
                    ? (steps) => setState(() {
                        _guideSteps = steps;
                        _guideDirty = true;
                      })
                    : null,
                onPhoto: _edit ? _photo : null,
                onPreview: () => showAirportGuidePreview(context, shownGuide),
                onClose: () => setState(() {
                  _guideDoor = null;
                  _guideSteps = null;
                }),
              ),
              if (_edit && _guideDirty)
                Align(
                  alignment: Alignment.centerRight,
                  child: BusyButton.filled(
                    key: const ValueKey('airport-guide-save'),
                    onPressed: _saveGuide,
                    icon: const Icon(Icons.save),
                    child: const Text('Save guide'),
                  ),
                ),
            ],
          );
    final serviceOrder = ServiceOrder.arrange(
      ref.watch(vehicleServiceOrderProvider).value ?? const <String>[],
      [for (final s in serviceList) s.id],
    );
    Widget waitTab({List<Widget> leading = const []}) => AirportQueueTab(
      settings: s,
      zones: waits,
      onChanged: on,
      map: map,
      noun: _noun,
      leading: leading,
      onAddZone: on != null
          ? () => _editZone(
              'airport_waiting_zones',
              title: 'Waiting zone',
              defaultName: 'Waiting zone ${waits.length + 1}',
            )
          : null,
      onEditZone: (z) => _editZone(
        'airport_waiting_zones',
        zone: z,
        title: 'Waiting zone',
        defaultName: z.name,
      ),
      onRemoveZone: on != null ? (z) => _removeZone('airport_waiting_zones', z) : null,
      services: serviceList,
      serviceOrder: serviceOrder,
      onOpenServiceOrder: () => context.push(serviceOrderPath),
    );
    Widget faresTab() => AirportFaresTab(
      settings: s,
      services: services.isEmpty ? const ['Ride'] : services,
      zones: fareZones,
      onChanged: on,
      noun: _noun,
      onAddZone: on != null
          ? () => _editZone(
              'airport_fare_zones',
              title: 'Fare zone',
              defaultName: 'Zone ${String.fromCharCode(65 + fareZones.length % 26)}',
            )
          : null,
      onEditZone: (z) => _editZone(
        'airport_fare_zones',
        zone: z,
        title: 'Fare zone',
        defaultName: z.name,
      ),
      onRemoveZone: on != null ? (z) => _removeZone('airport_fare_zones', z) : null,
      onZoneAmounts: on != null ? _zoneAmounts : null,
    );
    final areaOn = placeAreaOn(entry.values);
    final List<String> tabNames = _place ? placeEditorTabs : airportEditorTabs;
    final List<Widget> views = _place
        ? [
            PlaceFeatureTab(
              switchKey: const ValueKey('place-switch-boundary'),
              title: 'Boundary (geofence)',
              subtitle: "Pickups and drop-offs inside it use this place's tools. Off: gates only, as before.",
              value: areaOn,
              dimWhenOff: false,
              onChanged: _edit ? _setPlaceArea : null,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  map,
                  const SizedBox(height: 12),
                  AirportRow(
                    title: 'Boundary',
                    subtitle: boundary == null
                        ? 'Not drawn yet'
                        : '${boundary.pointCount} corners · ${zoneSourceLabel(boundary.source)}',
                  ),
                  const SizedBox(height: 8),
                  const AirportNote(
                    'Draw the boundary corner by corner, start from its OpenStreetMap outline or copy a saved '
                    "region. Where it overlaps an airport, the airport's rules win; where two places overlap, the "
                    "smaller one's do.",
                  ),
                  const SizedBox(height: 12),
                  if (_edit)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        key: const ValueKey('place-edit-boundary'),
                        onPressed: _drawPlaceBoundary,
                        icon: const Icon(Icons.map_outlined),
                        label: Text(boundary == null ? 'Draw boundary' : 'Edit boundary'),
                      ),
                    ),
                ],
              ),
            ),
            PlaceFeatureTab(
              switchKey: const ValueKey('place-switch-doors'),
              title: 'Riders must pick a door',
              subtitle: 'Also for scheduled rides. Off: choosing a door is optional.',
              value: s.doorsRequired,
              enabled: ready,
              dimWhenOff: false,
              onChanged: on == null ? null : (v) => on(s.copyWith(pickDoorRequired: v, dropDoorRequired: v)),
              child: AirportDoorsTab(
                doors: doors,
                settings: s,
                onSettings: on,
                showDoorSwitches: false,
                note: "These are the place's gates, the same as on its Gates page. A change here shows there too.",
                onKind: _edit ? _kind : null,
                onRemove: _edit ? _removeDoor : null,
                onRename: _edit ? _rename : null,
                onMove: _edit ? _move : null,
                onAdd: _edit ? _addDoor : null,
              ),
            ),
            PlaceFeatureTab(
              switchKey: const ValueKey('place-switch-guide'),
              title: 'Pickup guide',
              subtitle: 'Step-by-step photos and text per pickup door',
              value: s.guideOn,
              enabled: ready,
              onChanged: on == null ? null : (v) => on(s.copyWith(guideOn: v)),
              child: PlaceGuideTab(
                doors: doors,
                onGuide: _openGuide,
                openGuideId: _guideDoor,
                guideEditor: guideEditor,
              ),
            ),
            PlaceFeatureTab(
              switchKey: const ValueKey('place-switch-charge'),
              title: 'Extra charge',
              subtitle: 'Added to the fare for a pickup or drop-off here',
              value: s.placeChargeOn,
              enabled: ready,
              onChanged: on == null ? null : (v) => on(withPlaceCharge(s, on: v)),
              child: PlaceChargeTab(settings: s, onChanged: on),
            ),
            PlaceFeatureTab(
              switchKey: const ValueKey('place-switch-fares'),
              title: 'Own fares',
              subtitle: 'Base per service, minimums, distance bands, zone fares, round-up. Off: the normal tariff.',
              value: s.faresOn,
              enabled: ready,
              onChanged: on == null ? null : (v) => on(s.copyWith(faresOn: v)),
              child: faresTab(),
            ),
            PlaceFeatureTab(
              switchKey: const ValueKey('place-switch-queue'),
              title: 'Driver waiting queue',
              subtitle: 'Pickups here go to drivers waiting in its zones first, e.g. a taxi rank',
              value: s.restrictPickups,
              enabled: ready,
              onChanged: on == null ? null : (v) => on(s.copyWith(restrictPickups: v)),
              child: waitTab(
                leading: [
                  AirportRulesTab(settings: s, onChanged: on, noun: _noun, showSwitch: false, embedded: true),
                  const Divider(height: 32),
                ],
              ),
            ),
          ]
        : [
            _AreaTab(
              entry: entry,
              map: map,
              boundary: boundary,
              onEditDetails: _edit ? widget.onEditDetails : null,
              onEditBoundary: widget.onEditBoundary,
            ),
            AirportDoorsTab(
              doors: doors,
              settings: s,
              onSettings: on,
              onKind: _edit ? _kind : null,
              onRemove: _edit ? _removeDoor : null,
              onRename: _edit ? _rename : null,
              onMove: _edit ? _move : null,
              onAdd: _edit ? _addDoor : null,
              onGuide: _openGuide,
              openGuideId: _guideDoor,
              guideEditor: guideEditor,
            ),
            AirportRulesTab(settings: s, onChanged: on),
            waitTab(),
            faresTab(),
            AirportChargesTab(settings: s, onChanged: on),
          ];

    return DefaultTabController(
      length: tabNames.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showHeader)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${entry.values['name'] ?? 'Airport'}',
                      style: t.textTheme.titleLarge,
                    ),
                  ),
                  if (code.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: t.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        code,
                        style: t.textTheme.labelLarge?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [for (final name in tabNames) Tab(text: name)],
          ),
          Expanded(child: TabBarView(children: views)),
          if (_draft != null && _edit)
            Material(
              elevation: 3,
              color: t.colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Unsaved changes')),
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() => _draft = null),
                        child: const Text('Discard'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        key: const ValueKey('airport-settings-save'),
                        onPressed: _saving ? null : _save,
                        icon: const Icon(Icons.save),
                        label: const Text('Save'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A saved region (Country / States / Cities / Suburbs) chosen by search,
/// its outline copied and simplified; null when none was chosen.
Future<BoundaryShape?> pickSavedRegionShape(
  BuildContext context,
  WidgetRef ref,
) async {
  List<RegionEntry> regions;
  try {
    regions = await ref.read(regionsProvider.future);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
  if (!context.mounted) return null;
  final withShape = [
    for (final r in regions)
      if ('${r.values['boundarySource'] ?? ''}'.isNotEmpty) r,
  ];
  if (withShape.isEmpty) {
    showInfo(context, 'No saved region has a boundary yet.');
    return null;
  }
  String label(RegionEntry r) => [
    r.suburb,
    r.city,
    r.state,
    r.country,
  ].where((x) => x.isNotEmpty).join(', ');
  final picked = await showSearchPicker<RegionEntry>(
    context,
    title: 'Copy a saved region',
    choices: [
      for (final r in withShape)
        (
          value: r,
          label: label(r),
          subtitle: regionLevelLabel(r.level),
          leading: null,
        ),
    ],
  );
  if (picked == null) return null;
  final raw = await ref.read(geoAdminRepositoryProvider).boundaryOf(picked);
  final shape = parseBoundary(raw);
  if (shape == null) {
    if (context.mounted) {
      showInfo(context, "That region's boundary couldn't be read.");
    }
    return null;
  }
  return shapeFromRegion(simplifyShape(shape), picked.level);
}

class _AreaTab extends StatelessWidget {
  const _AreaTab({
    required this.entry,
    required this.map,
    required this.boundary,
    this.onEditDetails,
    this.onEditBoundary,
  });
  final GeoEntry entry;
  final Widget map;
  final BoundaryShape? boundary;
  final VoidCallback? onEditDetails, onEditBoundary;

  @override
  Widget build(BuildContext context) {
    final v = entry.values;
    final b = boundary;
    String s(String k) => '${v[k] ?? ''}'.trim();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        map,
        const SizedBox(height: 12),
        AirportRow(
          title: 'Airport name',
          subtitle: s('name').isEmpty ? '—' : s('name'),
        ),
        AirportRow(
          title: 'Code',
          subtitle: s('code').isEmpty ? '—' : s('code'),
        ),
        AirportRow(
          title: 'Place',
          subtitle: [
            s('placeName'),
            s('city'),
            s('state'),
            s('country'),
          ].where((x) => x.isNotEmpty).join(' · '),
        ),
        AirportRow(
          title: 'Boundary',
          subtitle: b == null
              ? 'Not drawn yet'
              : '${b.pointCount} corners · ${zoneSourceLabel(b.source)}',
        ),
        const SizedBox(height: 8),
        const AirportNote(
          'Draw the boundary on the map: draw it corner by corner, start from its OpenStreetMap outline or copy a '
          'saved region, then move its corners. Riders searching inside it see one entry for the airport; places '
          'within 300 m of it count as the airport.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (onEditBoundary != null)
              FilledButton.tonalIcon(
                key: const ValueKey('airport-edit-boundary'),
                onPressed: onEditBoundary,
                icon: const Icon(Icons.map_outlined),
                label: Text(b == null ? 'Draw boundary' : 'Edit boundary'),
              ),
            if (onEditDetails != null)
              OutlinedButton.icon(
                onPressed: onEditDetails,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit details'),
              ),
          ],
        ),
      ],
    );
  }
}

/// The airport's area, waiting zones and doors on a small map.
class AirportMapPreview extends StatelessWidget {
  const AirportMapPreview({
    super.key,
    required this.boundary,
    this.waitZones = const [],
    this.doors = const [],
    this.areaLabel = 'Airport area',
  });
  final String areaLabel;
  final BoundaryShape? boundary;
  final List<AirportZone> waitZones;
  final List<AirportDoor> doors;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = boundary;
    final zones = [
      for (final z in waitZones) ?parseBoundary(jsonEncode(z.shape)),
    ];
    final pts = [
      if (b != null) ...b.coords,
      for (final z in zones) ...z.coords,
      for (final d in doors)
        if (d.lat != null && d.lng != null) LatLng(d.lat!, d.lng!),
    ];
    Widget legend(Color c, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 220,
            child: pts.isEmpty
                ? ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: const Center(child: Text('No boundary drawn yet')),
                  )
                : FlutterMap(
                    options: MapOptions(
                      initialCameraFit: pts.length == 1
                          ? null
                          : CameraFit.bounds(
                              bounds: LatLngBounds.fromPoints(pts),
                              padding: const EdgeInsets.all(20),
                            ),
                      initialCenter: pts.first,
                      initialZoom: 14,
                    ),
                    children: [
                      ...osmBaseLayers(context),
                      PolygonLayer(
                        polygons: [
                          if (b != null)
                            for (final ring in b.rings)
                              if (ring.length >= 3)
                                Polygon(
                                  points: ring,
                                  color: scheme.primary.withValues(alpha: 0.14),
                                  borderColor: scheme.primary,
                                  borderStrokeWidth: 2,
                                ),
                          for (final z in zones)
                            for (final ring in z.rings)
                              if (ring.length >= 3)
                                Polygon(
                                  points: ring,
                                  color: scheme.tertiary.withValues(
                                    alpha: 0.18,
                                  ),
                                  borderColor: scheme.tertiary,
                                  borderStrokeWidth: 2,
                                ),
                        ],
                      ),
                      MarkerLayer(
                        markers: [
                          for (var i = 0; i < doors.length; i++)
                            if (doors[i].lat != null && doors[i].lng != null)
                              Marker(
                                point: LatLng(doors[i].lat!, doors[i].lng!),
                                width: 22,
                                height: 22,
                                child: Container(
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: doors[i].kind == DoorKind.drop
                                        ? scheme.secondary
                                        : scheme.tertiary,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: scheme.surface,
                                      width: 2,
                                    ),
                                  ),
                                  child: Text(
                                    '${i + 1}',
                                    style: TextStyle(
                                      color: scheme.onTertiary,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            legend(scheme.primary, areaLabel),
            legend(scheme.secondary, 'Drop-off door'),
            legend(scheme.tertiary, 'Pickup door / waiting zone'),
          ],
        ),
      ],
    );
  }
}
