// Saving a place and editing a saved one (inDrive's "Save place" and
// "Editing Home"): the name (other places only), the address, which can be
// chosen again, and the entrance to wait at. A new place shows its spot on
// the map above the form; a saved one can be deleted.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/saved_places.dart';
import '../../data/geo_service.dart';
import '../../data/saved_places_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/map_tiles.dart';
import 'place_search.dart';

/// Opens the form for [place] (a new one when it has no id). True when it
/// was saved or deleted.
Future<bool> showSavedPlaceForm(BuildContext context, SavedPlace place, {LatLng? near}) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SavedPlaceForm(place: place, near: near),
      ),
    ) ??
    false;

/// Adds Home, Work or another place: the address first ("Enter address"),
/// then the form. True when one was saved.
Future<bool> addSavedPlace(BuildContext context, SavedPlaceKind kind, {LatLng? near}) async {
  final pick = await showPlaceSearch(context, title: 'Enter address', near: near, mode: PlaceSearchMode.address);
  final p = pick?.place;
  if (p == null || !context.mounted) return false;
  return showSavedPlaceForm(
    context,
    SavedPlace(
      kind: kind,
      name: kind == SavedPlaceKind.other ? p.name : '',
      address: p.address.isEmpty ? p.name : p.address,
      point: p.point,
    ),
    near: near,
  );
}

class SavedPlaceForm extends ConsumerStatefulWidget {
  const SavedPlaceForm({super.key, required this.place, this.near});

  final SavedPlace place;
  final LatLng? near;

  @override
  ConsumerState<SavedPlaceForm> createState() => _SavedPlaceFormState();
}

class _SavedPlaceFormState extends ConsumerState<SavedPlaceForm> {
  late SavedPlace _place = widget.place;
  late final _name = TextEditingController(text: widget.place.name);
  late final _entrance = TextEditingController(text: widget.place.entrance);
  bool _busy = false;

  bool get _editing => widget.place.id != null;
  bool get _other => _place.kind == SavedPlaceKind.other;

  @override
  void dispose() {
    _name.dispose();
    _entrance.dispose();
    super.dispose();
  }

  String get _title {
    final what = _other ? (_editing ? _place.name : 'place') : _place.title;
    return _editing ? 'Editing $what' : (_other ? 'Save place' : 'Add $what');
  }

  Future<void> _changeAddress() async {
    final pick = await showPlaceSearch(
      context,
      title: 'Enter address',
      near: widget.near,
      mode: PlaceSearchMode.address,
    );
    final p = pick?.place;
    if (p == null || !mounted) return;
    setState(() {
      _place = _place.copyWith(address: p.address.isEmpty ? p.name : p.address, point: p.point);
      if (_other && _name.text.trim().isEmpty) _name.text = p.name;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(savedPlacesRepositoryProvider)
          .save(_place.copyWith(name: _other ? _name.text.trim() : _place.title, entrance: _entrance.text.trim()));
      ref.invalidate(savedPlacesProvider);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showInfo(context, 'Could not save the place. ${errorText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${_place.title}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('saved-place-delete-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: Text('Delete', style: TextStyle(color: Theme.of(c).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(savedPlacesRepositoryProvider).delete(_place.id!);
      ref.invalidate(savedPlacesProvider);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showInfo(context, 'Could not delete the place. ${errorText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final problem = savedPlaceProblem(kind: _place.kind, name: _name.text, address: _place.address);
    final field = t.colorScheme.surfaceContainerHighest;
    InputDecoration deco(String label) => InputDecoration(
      labelText: label,
      filled: true,
      fillColor: field,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    );
    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_other) ...[
          TextField(
            key: const ValueKey('saved-place-name'),
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 80,
            buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
            onChanged: (_) => setState(() {}),
            decoration: deco('Name'),
          ),
          const SizedBox(height: 12),
        ],
        InkWell(
          key: const ValueKey('saved-place-address'),
          borderRadius: BorderRadius.circular(14),
          onTap: _busy ? null : _changeAddress,
          child: InputDecorator(
            decoration: deco('Address'),
            child: Text(
              _place.address,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.bodyLarge?.copyWith(
                color: _editing ? t.colorScheme.onSurfaceVariant : t.colorScheme.onSurface,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('saved-place-entrance'),
          controller: _entrance,
          maxLength: 80,
          buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
          decoration: deco('Entrance'),
        ),
        if (_editing) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 56,
            child: TextButton(
              key: const ValueKey('saved-place-delete'),
              style: TextButton.styleFrom(
                backgroundColor: field,
                foregroundColor: t.colorScheme.error,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
              ),
              onPressed: _busy ? null : _delete,
              child: const Text('Delete place'),
            ),
          ),
        ],
      ],
    );
    final save = FilledButton(
      key: const ValueKey('saved-place-save'),
      onPressed: problem == null && !_busy ? _save : null,
      child: _busy
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Text('Save', style: TextStyle(fontSize: 18)),
    );
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(56, 16, 12, 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            key: const ValueKey('saved-place-close'),
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
    // A saved place is edited on a plain page; a new one shows its spot.
    if (_editing) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              header,
              Expanded(
                child: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 16), child: form),
              ),
              Padding(padding: const EdgeInsets.all(16), child: save),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _SpotPreview(point: _place.point)),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Material(
                      color: t.colorScheme.surface,
                      shape: const CircleBorder(),
                      elevation: 3,
                      child: IconButton(
                        tooltip: 'Back',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: t.colorScheme.surface,
            elevation: 8,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 20, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(_title, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 16),
                    form,
                    const SizedBox(height: 16),
                    save,
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

/// The place's spot: the map on it, still, with the flag on the point.
class _SpotPreview extends StatelessWidget {
  const _SpotPreview({required this.point});
  final LatLng point;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark ? Colors.white : const Color(0xFF111111);
    final ink = dark ? Colors.black : Colors.white;
    return FlutterMap(
      key: ValueKey('saved-place-map-${point.latitude},${point.longitude}'),
      options: MapOptions(
        initialCenter: point,
        initialZoom: 17,
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
      ),
      children: [
        baseTileLayer(context),
        MarkerLayer(
          markers: [
            Marker(
              point: point,
              width: 48,
              height: 64,
              alignment: Alignment.topCenter,
              child: Column(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.circular(13),
                      boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                    ),
                    child: Icon(Icons.flag, color: ink, size: 28),
                  ),
                  Container(width: 3, height: 16, color: fill),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A saved place as the route sheet hands it back.
Place savedPlaceAsPlace(SavedPlace p) =>
    Place(name: p.title, address: p.address.isEmpty ? p.title : p.address, point: p.point);
