/// The pets a rider brings along ("Pet with me" on the Options sheet): what
/// the admin offers (types, sizes, how many of each, whether a photo is a
/// must), each pet the rider adds, the line the driver reads, and what the
/// Your pets sheet still needs before Done. Pure.
library;

import 'dart:typed_data';

/// What the Your pets sheet offers. Read from the display settings blob
/// ([fromSettings]); [toSettings] writes the same keys back, for Admin →
/// Display Settings.
class PetConfig {
  const PetConfig({
    this.types = defaultTypes,
    this.sizes = defaultSizes,
    this.maxPerType = defaultMaxPerType,
    this.photoRequired = true,
  });

  static const defaultTypes = ['Dog', 'Cat', 'Rabbit', 'Guinea pig', 'Hamster'];
  static const defaultSizes = ['XS', 'S', 'M', 'L', 'XL'];
  static const defaultMaxPerType = 5;

  /// The most of one type an admin may allow.
  static const maxPerTypeLimit = 20;

  /// The display settings keys.
  static const typesKey = 'petTypes';
  static const sizesKey = 'petSizes';
  static const maxPerTypeKey = 'petMaxPerType';
  static const photoRequiredKey = 'petPhotoRequired';

  /// The pet types to pick from, in order.
  final List<String> types;

  /// The sizes, smallest first.
  final List<String> sizes;

  /// How many of one type a ride takes (1 up to this).
  final int maxPerType;

  /// Whether Done waits for a photo of every pet.
  final bool photoRequired;

  static List<String> _list(Object? v, List<String> fallback) {
    final raw = switch (v) {
      final List<dynamic> l => l,
      final String s => s.split(','),
      _ => const <Object?>[],
    };
    final out = <String>[];
    for (final e in raw) {
      final t = e is String ? e.trim() : '';
      if (t.isNotEmpty && t.length <= 40 && !out.any((o) => o.toLowerCase() == t.toLowerCase())) out.add(t);
    }
    return out.isEmpty ? fallback : List.unmodifiable(out);
  }

  static PetConfig fromSettings(Map<String, dynamic> s) {
    final m = s[maxPerTypeKey];
    final max = m is num ? m.toInt() : (m is String ? int.tryParse(m.trim()) : null);
    final p = s[photoRequiredKey];
    final photo = switch (p) {
      final bool b => b,
      final num n => n != 0,
      final String t when ['false', '0', 'off'].contains(t.trim().toLowerCase()) => false,
      _ => true,
    };
    return PetConfig(
      types: _list(s[typesKey], defaultTypes),
      sizes: _list(s[sizesKey], defaultSizes),
      maxPerType: (max ?? defaultMaxPerType).clamp(1, maxPerTypeLimit),
      photoRequired: photo,
    );
  }

  Map<String, Object> toSettings() => {
    typesKey: types,
    sizesKey: sizes,
    maxPerTypeKey: maxPerType,
    photoRequiredKey: photoRequired,
  };
}

/// One pet: its type, the size the rider chose and, once uploaded, where
/// its photo is in the `ride-pets` bucket. [preview] is the picked photo,
/// kept on this phone only to show it on the sheet.
class RidePet {
  const RidePet({required this.type, this.size, this.photoPath, this.preview});

  final String type;
  final String? size;
  final String? photoPath;
  final Uint8List? preview;

  /// "Dog · M", under its photo.
  String get label => size == null ? type : '$type · $size';

  RidePet copyWith({String? size, String? photoPath, Uint8List? preview}) => RidePet(
    type: type,
    size: size ?? this.size,
    photoPath: photoPath ?? this.photoPath,
    preview: preview ?? this.preview,
  );

  /// As `ride_requests.pets` keeps it.
  Map<String, Object> toJson() => {
    'type': type,
    'size': ?size,
    'photo_path': ?photoPath,
  };

  static RidePet? fromJson(Object? v) {
    if (v is! Map) return null;
    String? text(Object? x) => x is String && x.trim().isNotEmpty ? x.trim() : null;
    final type = text(v['type']);
    if (type == null) return null;
    return RidePet(type: type, size: text(v['size']), photoPath: text(v['photo_path']));
  }

  @override
  bool operator ==(Object other) =>
      other is RidePet && other.type == type && other.size == size && other.photoPath == photoPath;

  @override
  int get hashCode => Object.hash(type, size, photoPath);
}

/// The pets on a ride row (`ride_requests.pets`); none for anything else.
List<RidePet> parseRidePets(Object? raw) => [
  if (raw is List)
    for (final e in raw) ?RidePet.fromJson(e),
];

bool samePets(List<RidePet> a, List<RidePet> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The pets by type, in the order each type first appears.
Map<String, List<RidePet>> petsByType(List<RidePet> pets) {
  final out = <String, List<RidePet>>{};
  for (final p in pets) {
    (out[p.type] ??= []).add(p);
  }
  return out;
}

String _plural(String noun, int n) {
  if (n == 1) return noun;
  final l = noun.toLowerCase();
  if (l.endsWith('s') || l.endsWith('x') || l.endsWith('sh') || l.endsWith('ch')) return '${noun}es';
  return '${noun}s';
}

/// A type card's title: "Dogs", "Guinea pigs".
String petTypeTitle(String type) => _plural(type, 2);

/// "2 dogs (M, L), 1 cat (S)": for the Options row and the driver. Empty
/// for no pets.
String petSummary(List<RidePet> pets) => [
  for (final e in petsByType(pets).entries)
    [
      '${e.value.length} ${_plural(e.key.toLowerCase(), e.value.length)}',
      if (e.value.any((p) => p.size != null)) '(${[for (final p in e.value) ?p.size].join(', ')})',
    ].join(' '),
].join(', ');

/// What the pets still lack before Done: sizes and photos (photos only when
/// the admin asks for them).
({int sizes, int photos}) petsMissing(List<RidePet> pets, PetConfig config) => (
  sizes: pets.where((p) => p.size == null).length,
  photos: config.photoRequired ? pets.where((p) => p.photoPath == null).length : 0,
);

/// Whether Done can be pressed: at least one pet, each with a size and (when
/// asked for) a photo.
bool petsComplete(List<RidePet> pets, PetConfig config) {
  final m = petsMissing(pets, config);
  return pets.isNotEmpty && m.sizes == 0 && m.photos == 0;
}

/// The hint beside Done: "Still needed: 1 size and 2 photos." Null once
/// nothing is missing.
String? petsMissingText(List<RidePet> pets, PetConfig config) {
  if (pets.isEmpty) return 'Pick at least one pet type.';
  final m = petsMissing(pets, config);
  final parts = [
    if (m.sizes > 0) '${m.sizes} ${m.sizes == 1 ? 'size' : 'sizes'}',
    if (m.photos > 0) '${m.photos} ${m.photos == 1 ? 'photo' : 'photos'}',
  ];
  return parts.isEmpty ? null : 'Still needed: ${parts.join(' and ')}.';
}

/// Where a pet's photo goes in the `ride-pets` bucket: the rider's own
/// folder, which is what its storage policies look at.
String ridePetPhotoPath(String uid, String tag, String ext) => '$uid/pet-$tag.${ext.isEmpty ? 'jpg' : ext.toLowerCase()}';

/// The private bucket for pet photos (migration 0247).
const ridePetsBucket = 'ride-pets';

/// How long a signed link to a pet photo lasts.
const ridePetLinkTtl = Duration(hours: 1);
