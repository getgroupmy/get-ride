// "Pet with me": the Your pets sheet the Options switch opens (which pets,
// how many of each, a photo and a size for every one), and the pets as the
// driver and admins see them (the summary line, a thumbnail per pet, a
// larger look at one). In the app's light or dark theme.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ride_chat.dart' show ridePhotoProblem;
import '../../core/ride_pets.dart';
import '../../data/photo_picker.dart';
import '../../data/ride_pet_repository.dart';
import '../../widgets/chat_photo.dart' show choosePhotoSource;
import '../../widgets/common.dart' show showError, showInfo;
import '../../widgets/net_image.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart' show ListSearchFilter;

/// The Your pets sheet: the pets when Done is pressed, null when it was
/// cancelled (Cancel, a tap on the scrim or a swipe down), which keeps
/// whatever was saved before.
Future<List<RidePet>?> showRidePetsSheet(
  BuildContext context, {
  List<RidePet> initial = const [],
  PetConfig config = const PetConfig(),
}) => showAppSheet<List<RidePet>>(id: 'ride.pets',
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => RidePetsSheet(initial: initial, config: config),
);

class RidePetsSheet extends ConsumerStatefulWidget {
  const RidePetsSheet({super.key, this.initial = const [], this.config = const PetConfig()});
  final List<RidePet> initial;
  final PetConfig config;

  @override
  ConsumerState<RidePetsSheet> createState() => _RidePetsSheetState();
}

class _RidePetsSheetState extends ConsumerState<RidePetsSheet> {
  /// The pets of each picked type, in the order the types were picked.
  late final Map<String, List<RidePet>> _byType = {
    for (final e in petsByType(widget.initial).entries) e.key: List.of(e.value),
  };

  /// The pets whose photo is on its way up ("Dog#0").
  final Set<String> _uploading = {};

  PetConfig get _c => widget.config;

  /// The picked types as cards: the admin's order, then any saved type the
  /// admin no longer offers.
  List<String> get _cards => [
    for (final t in _c.types)
      if (_byType.containsKey(t)) t,
    for (final t in _byType.keys)
      if (!_c.types.contains(t)) t,
  ];

  List<RidePet> get _pets => [for (final t in _cards) ..._byType[t]!];

  void _toggle(String type, bool on) => setState(() {
    if (on) {
      _byType[type] = [RidePet(type: type)];
    } else {
      _byType.remove(type);
      _uploading.removeWhere((k) => k.startsWith('$type#'));
    }
  });

  void _count(String type, int delta) => setState(() {
    final list = _byType[type]!;
    final n = (list.length + delta).clamp(1, _c.maxPerType);
    while (list.length < n) {
      list.add(RidePet(type: type));
    }
    while (list.length > n) {
      list.removeLast();
      _uploading.remove('$type#${list.length}');
    }
  });

  void _size(String type, int i, String size) => setState(() {
    _byType[type]![i] = _byType[type]![i].copyWith(size: size);
  });

  Future<void> _photo(String type, int i) async {
    final key = '$type#$i';
    if (_uploading.contains(key)) return;
    final source = await choosePhotoSource(context, camera: ref.read(photoCameraAvailableProvider));
    if (source == null || !mounted) return;
    final PickedPhoto? photo;
    try {
      photo = await ref.read(photoPickerProvider)(source);
    } catch (_) {
      if (mounted) {
        showInfo(
          context,
          source == PhotoSource.camera
              ? "Couldn't open the camera. Check that GET.ride may use it in Settings."
              : "Couldn't open your photos. Check that GET.ride may use them in Settings.",
        );
      }
      return;
    }
    if (photo == null || !mounted) return;
    final problem = ridePhotoProblem(photo.bytes.length);
    if (problem != null) return showInfo(context, problem);
    setState(() => _uploading.add(key));
    try {
      final path = await ref.read(ridePetPhotoUploadProvider)(photo.bytes, photo.name);
      if (!mounted) return;
      final list = _byType[type];
      // The pet may have gone while its photo went up.
      if (list != null && i < list.length && _uploading.contains(key)) {
        setState(() => list[i] = list[i].copyWith(photoPath: path, preview: photo!.bytes));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pets = _pets;
    final missing = petsMissingText(pets, _c);
    final done = petsComplete(pets, _c) && _uploading.isEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          key: const ValueKey('ride-pets'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Your pets', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  _c.photoRequired
                      ? 'Pick every type riding along, then a size and a photo for each pet.'
                      : 'Pick every type riding along, then a size for each pet.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Pet types', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    ListSearchFilter(
                      count: _c.types.length,
                      hint: 'Search pets',
                      fieldKey: const ValueKey('pets-type-search'),
                      builder: (context, q) => Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final type in _c.types)
                            if (q.isEmpty || type.toLowerCase().contains(q.toLowerCase()))
                              FilterChip(
                                key: ValueKey('pets-type-$type'),
                                label: Text(type),
                                selected: _byType.containsKey(type),
                                onSelected: (on) => _toggle(type, on),
                              ),
                        ]),
                      ),
                    ),
                    for (final type in _cards) ...[
                      const SizedBox(height: 12),
                      _typeCard(context, type),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(children: [
                Expanded(
                  child: Text(
                    missing ?? (_uploading.isEmpty ? '' : 'Uploading photos…'),
                    key: const ValueKey('pets-missing'),
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const ValueKey('pets-cancel'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('pets-done'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: done ? () => Navigator.pop(context, List<RidePet>.of(pets)) : null,
                  child: const Text('Done'),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeCard(BuildContext context, String type) {
    final t = Theme.of(context);
    final list = _byType[type]!;
    return Card(
      key: ValueKey('pets-card-$type'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: t.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(petTypeTitle(type), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              key: ValueKey('pets-minus-$type'),
              tooltip: 'One less',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: list.length > 1 ? () => _count(type, -1) : null,
            ),
            SizedBox(
              width: 28,
              child: Text(
                '${list.length}',
                key: ValueKey('pets-count-$type'),
                textAlign: TextAlign.center,
                style: t.textTheme.titleMedium,
              ),
            ),
            IconButton(
              key: ValueKey('pets-plus-$type'),
              tooltip: 'One more',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: list.length < _c.maxPerType ? () => _count(type, 1) : null,
            ),
          ]),
          for (var i = 0; i < list.length; i++) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _photoSlot(context, type, i, list[i]),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    '$type ${i + 1} size',
                    style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final s in _c.sizes)
                      ChoiceChip(
                        key: ValueKey('pet-size-$type-$i-$s'),
                        label: Text(s),
                        selected: list[i].size == s,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => _size(type, i, s),
                      ),
                  ]),
                ]),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _photoSlot(BuildContext context, String type, int i, RidePet pet) {
    final t = Theme.of(context);
    const side = 64.0;
    final busy = _uploading.contains('$type#$i');
    final Widget inside;
    if (busy) {
      inside = const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)));
    } else if (pet.preview != null) {
      inside = Image.memory(pet.preview!, width: side, height: side, fit: BoxFit.cover);
    } else if (pet.photoPath != null) {
      inside = RidePetPhoto(path: pet.photoPath!, side: side);
    } else {
      inside = Center(
        child: Text(
          '+ Photo',
          textAlign: TextAlign.center,
          style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      );
    }
    final missing = _c.photoRequired && pet.photoPath == null && !busy;
    return Semantics(
      button: true,
      label: pet.photoPath == null ? 'Add a photo of $type ${i + 1}' : 'Change the photo of $type ${i + 1}',
      child: Material(
        color: t.colorScheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: missing ? t.colorScheme.outline : Colors.transparent),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('pet-photo-$type-$i'),
          onTap: busy ? null : () => _photo(type, i),
          child: SizedBox.square(dimension: side, child: inside),
        ),
      ),
    );
  }
}

/// A pet's photo from the private bucket, through a signed link; a paw while
/// there is none or it can't be shown.
class RidePetPhoto extends ConsumerWidget {
  const RidePetPhoto({super.key, required this.path, required this.side, this.fit = BoxFit.cover});
  final String path;
  final double side;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paw = Icon(Icons.pets, color: Theme.of(context).colorScheme.onSurfaceVariant, size: side * 0.4);
    final url = ref.watch(ridePetPhotoUrlProvider(path)).value;
    if (url == null) return SizedBox.square(dimension: side, child: Center(child: paw));
    return NetImage(url, width: side, height: side, fit: fit, radius: 0, fallback: SizedBox.square(dimension: side, child: Center(child: paw)));
  }
}

/// The rider's pets for the driver (request sheet, trip screen) and admins:
/// the summary, then a thumbnail per pet labelled "Dog · M" that opens a
/// larger look. [locked]: the request is still open, when only the rider
/// sees the photos (migration 0247); the thumbnails are paws until the
/// driver takes the ride.
class RidePetsView extends StatelessWidget {
  const RidePetsView({super.key, required this.pets, this.locked = false, this.title});
  final List<RidePet> pets;
  final bool locked;

  /// A heading over it ("Pets riding along"); none on the compact request
  /// sheet.
  final String? title;

  @override
  Widget build(BuildContext context) {
    if (pets.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Column(
      key: const ValueKey('ride-pets-view'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          Text(title!, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
        ],
        Row(children: [
          Icon(Icons.pets, size: 18, color: t.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              petSummary(pets),
              key: const ValueKey('pets-summary'),
              style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 8, children: [
          for (var i = 0; i < pets.length; i++) _thumb(context, i),
        ]),
        if (locked)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Photos show once you accept.',
              key: const ValueKey('pets-photos-after-accept'),
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
      ],
    );
  }

  Widget _thumb(BuildContext context, int i) {
    final t = Theme.of(context);
    final pet = pets[i];
    const side = 64.0;
    final path = locked ? null : pet.photoPath;
    return SizedBox(
      width: 76,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Material(
          color: t.colorScheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('pet-thumb-$i'),
            onTap: path == null ? null : () => showRidePetPhoto(context, pet),
            child: SizedBox.square(
              dimension: side,
              child: path == null
                  ? Icon(Icons.pets, color: t.colorScheme.onSurfaceVariant)
                  : RidePetPhoto(path: path, side: side),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          pet.label,
          key: ValueKey('pet-thumb-label-$i'),
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: t.textTheme.labelSmall,
        ),
      ]),
    );
  }
}

/// A larger look at one pet's photo, with its label.
Future<void> showRidePetPhoto(BuildContext context, RidePet pet) => showAppDialog<void>(id: 'ride.pet-photo',
  context: context,
  builder: (c) {
    final t = Theme.of(c);
    final side = (MediaQuery.sizeOf(c).shortestSide - 96).clamp(160.0, 420.0);
    return Dialog(
      key: const ValueKey('pet-photo-dialog'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: t.colorScheme.surfaceContainerHighest,
              child: InteractiveViewer(
                maxScale: 4,
                child: RidePetPhoto(path: pet.photoPath!, side: side, fit: BoxFit.contain),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(pet.label, key: const ValueKey('pet-photo-label'), style: t.textTheme.titleMedium),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('pet-photo-close'),
              onPressed: () => Navigator.pop(c),
              child: const Text('Close'),
            ),
          ),
        ]),
      ),
    );
  },
);
