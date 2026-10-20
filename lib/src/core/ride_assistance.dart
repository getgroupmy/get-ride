/// "Assistance required" on the rider's Options sheet: the catalogue of
/// help the admin offers (Admin → Display Settings → Ride Options), what
/// the rider picks from it, the line the driver reads, and what the sheet
/// still needs before Done. Pure.
library;

import 'option_charge.dart';

/// The groups the catalogue starts with, in order. An admin may type more.
const assistanceDefaultGroups = ['Mobility', 'Senses and communication', 'Help on the way'];

/// The guide or service dog: always free, and not a pet (no pet photos).
const guideDogAssistanceId = 'guide-dog';

/// The longest name, description, choice and note the app keeps.
const assistanceNameMax = 60;
const assistanceDescriptionMax = 120;
const assistanceChoiceMax = 80;
const assistanceNoteMax = 300;

/// One kind of help the rider can ask for.
class AssistanceItem {
  const AssistanceItem({
    required this.id,
    required this.name,
    this.emoji = '',
    this.description = '',
    this.group = 'Mobility',
    this.choices = const [],
    this.hidden = false,
    this.charge = OptionCharge.none,
  });

  final String id;
  final String name;
  final String emoji;
  final String description;
  final String group;

  /// The rider must pick one of these when there are any.
  final List<String> choices;

  /// Hidden by the admin: not offered, but kept with its settings.
  final bool hidden;

  /// What it adds to the fare (none for the guide dog, always).
  final OptionCharge charge;

  bool get isGuideDog => id == guideDogAssistanceId;

  /// The charge as it applies: the guide dog's is always none.
  OptionCharge get effectiveCharge => isGuideDog ? OptionCharge.none : charge;

  AssistanceItem copyWith({
    String? name,
    String? emoji,
    String? description,
    String? group,
    List<String>? choices,
    bool? hidden,
    OptionCharge? charge,
  }) => AssistanceItem(
    id: id,
    name: name ?? this.name,
    emoji: emoji ?? this.emoji,
    description: description ?? this.description,
    group: group ?? this.group,
    choices: choices ?? this.choices,
    hidden: hidden ?? this.hidden,
    charge: charge ?? this.charge,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'emoji': emoji,
    'description': description,
    'group': group,
    'choices': choices,
    if (hidden) 'hidden': true,
    if (!effectiveCharge.isZero) 'charge': effectiveCharge.toJson(),
  };

  static String _text(Object? v, int max) {
    final t = v is String ? v.trim() : '';
    return t.length > max ? t.substring(0, max).trim() : t;
  }

  static AssistanceItem? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = _text(v['id'], 60);
    final name = _text(v['name'], assistanceNameMax);
    if (id.isEmpty || name.isEmpty) return null;
    final group = _text(v['group'], assistanceNameMax);
    final choices = <String>[];
    if (v['choices'] is List) {
      for (final c in v['choices'] as List) {
        final t = _text(c, assistanceChoiceMax);
        if (t.isNotEmpty && !choices.contains(t)) choices.add(t);
      }
    }
    return AssistanceItem(
      id: id,
      name: name,
      emoji: _text(v['emoji'], 16),
      description: _text(v['description'], assistanceDescriptionMax),
      group: group.isEmpty ? assistanceDefaultGroups.first : group,
      choices: List.unmodifiable(choices),
      hidden: v['hidden'] == true,
      charge: id == guideDogAssistanceId ? OptionCharge.none : OptionCharge.fromJson(v['charge']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AssistanceItem &&
      other.id == id &&
      other.name == name &&
      other.emoji == emoji &&
      other.description == description &&
      other.group == group &&
      _sameStrings(other.choices, choices) &&
      other.hidden == hidden &&
      other.charge == charge;

  @override
  int get hashCode => Object.hash(id, name, emoji, description, group, Object.hashAll(choices), hidden, charge);
}

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The catalogue the owner approved, which the admin starts from.
const defaultAssistanceItems = <AssistanceItem>[
  AssistanceItem(
    id: 'wheelchair',
    emoji: '♿',
    name: 'Wheelchair user',
    description: 'Help getting in and room for the chair',
    choices: [
      'Foldable, I can transfer to a seat',
      'Stays in the wheelchair (accessible car with ramp)',
      'Electric / heavy',
    ],
  ),
  AssistanceItem(
    id: 'walking-aid',
    emoji: '🦯',
    name: 'Walker, cane or crutches',
    description: 'Extra time and room for the walking aid',
  ),
  AssistanceItem(id: 'elderly', emoji: '👵', name: 'Elderly rider', description: 'A gentle pace and help in and out'),
  AssistanceItem(
    id: 'injury',
    emoji: '🩹',
    name: 'Recent injury or surgery',
    description: 'Careful driving and help in and out',
  ),
  AssistanceItem(id: 'pregnant', emoji: '🤰', name: 'Pregnant', description: 'A smooth ride, please'),
  AssistanceItem(
    id: 'low-vision',
    emoji: '👁️',
    name: 'Blind or low vision',
    description: 'Say who you are and guide me to the car',
    group: 'Senses and communication',
  ),
  AssistanceItem(
    id: guideDogAssistanceId,
    emoji: '🦮',
    name: 'Guide or service dog',
    description: 'My dog rides with me. Always free, no pet photos needed',
    group: 'Senses and communication',
  ),
  AssistanceItem(
    id: 'hearing',
    emoji: '🧏',
    name: 'Deaf or hard of hearing',
    description: 'Message me instead of calling',
    group: 'Senses and communication',
  ),
  AssistanceItem(
    id: 'speech',
    emoji: '💬',
    name: 'Speech difficulty',
    description: 'I may type or show what I want to say',
    group: 'Senses and communication',
  ),
  AssistanceItem(
    id: 'quiet',
    emoji: '🤫',
    name: 'Quiet ride',
    description: 'Autism, anxiety or sensory needs',
    group: 'Senses and communication',
  ),
  AssistanceItem(
    id: 'door-to-door',
    emoji: '🚪',
    name: 'Door-to-door help',
    description: 'Meet me at the door and walk with me',
    group: 'Help on the way',
  ),
  AssistanceItem(
    id: 'luggage',
    emoji: '🧳',
    name: 'Help with luggage or shopping',
    description: 'Help loading and unloading',
    group: 'Help on the way',
  ),
  AssistanceItem(
    id: 'pram',
    emoji: '👶',
    name: 'Pram or stroller',
    description: 'Room in the boot for a pram',
    group: 'Help on the way',
  ),
  AssistanceItem(
    id: 'medical',
    emoji: '🫁',
    name: 'Medical equipment',
    description: 'Room for the equipment I carry',
    group: 'Help on the way',
    choices: ['Portable oxygen', 'Mobility scooter', 'Other'],
  ),
  AssistanceItem(
    id: 'supervision',
    emoji: '🧑‍🍼',
    name: 'Rider needs supervision',
    description: 'A child or someone who should not travel alone',
    group: 'Help on the way',
  ),
];

/// What the admin offers, in order. Read from the display settings blob
/// ([fromSettings]); [toSettings] writes the same key back.
class AssistanceCatalogue {
  const AssistanceCatalogue({this.items = defaultAssistanceItems});

  static const key = 'assistanceCatalogue';

  /// The most items a catalogue keeps.
  static const maxItems = 40;

  final List<AssistanceItem> items;

  /// No stored list is the starting catalogue; a stored one, even empty, is
  /// the admin's.
  static AssistanceCatalogue fromSettings(Map<String, dynamic> s) {
    final raw = s[key];
    if (raw is! List) return const AssistanceCatalogue();
    final out = <AssistanceItem>[];
    for (final e in raw) {
      final item = AssistanceItem.fromJson(e);
      if (item != null && !out.any((o) => o.id == item.id) && out.length < maxItems) out.add(item);
    }
    return AssistanceCatalogue(items: List.unmodifiable(out));
  }

  Map<String, Object> toSettings() => {key: [for (final i in items) i.toJson()]};

  /// What the rider is offered.
  List<AssistanceItem> get visible => [for (final i in items) if (!i.hidden) i];

  AssistanceItem? byId(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// The groups in use, the starting ones first, then the admin's own as
  /// they first appear.
  List<String> get groups => groupsOf(items);

  /// [list] by group, in [groupsOf] order; empty groups left out.
  static Map<String, List<AssistanceItem>> byGroup(List<AssistanceItem> list) => {
    for (final g in groupsOf(list)) g: [for (final i in list) if (i.group == g) i],
  };

  static List<String> groupsOf(List<AssistanceItem> list) => [
    for (final g in assistanceDefaultGroups)
      if (list.any((i) => i.group == g)) g,
    for (final g in {for (final i in list) i.group})
      if (!assistanceDefaultGroups.contains(g)) g,
  ];
}

/// One kind of help on a booking: copied from the catalogue (name and
/// emoji too), so the ride keeps what was picked even after the admin
/// renames or removes the item.
class AssistancePick {
  const AssistancePick({required this.id, required this.name, this.emoji = '', this.choice});

  final String id;
  final String name;
  final String emoji;
  final String? choice;

  factory AssistancePick.of(AssistanceItem item, {String? choice}) =>
      AssistancePick(id: item.id, name: item.name, emoji: item.emoji, choice: choice);

  AssistancePick withChoice(String? choice) => AssistancePick(id: id, name: name, emoji: emoji, choice: choice);

  /// "Wheelchair user (Foldable, I can transfer to a seat)".
  String get label => choice == null ? name : '$name ($choice)';

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    if (emoji.isNotEmpty) 'emoji': emoji,
    'choice': ?choice,
  };

  static AssistancePick? fromJson(Object? v) {
    if (v is! Map) return null;
    String? text(Object? x, int max) {
      final t = x is String ? x.trim() : '';
      if (t.isEmpty) return null;
      return t.length > max ? t.substring(0, max).trim() : t;
    }

    final name = text(v['name'], assistanceNameMax);
    if (name == null) return null;
    return AssistancePick(
      id: text(v['id'], 60) ?? name,
      name: name,
      emoji: text(v['emoji'], 16) ?? '',
      choice: text(v['choice'], assistanceChoiceMax),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AssistancePick && other.id == id && other.name == name && other.emoji == emoji && other.choice == choice;

  @override
  int get hashCode => Object.hash(id, name, emoji, choice);
}

/// The help on a booking (`ride_requests.assistance`): what was picked and
/// the rider's note. While a request is open the note waits aside for the
/// rider (migration 0248), and comes back once a driver takes the ride.
class RideAssistance {
  const RideAssistance({this.items = const [], this.note});

  final List<AssistancePick> items;
  final String? note;

  bool get isEmpty => items.isEmpty;

  Map<String, Object> toJson() => {
    'items': [for (final i in items) i.toJson()],
    if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
  };

  /// The help on a ride row; null for none.
  static RideAssistance? fromJson(Object? v) {
    if (v is! Map) return null;
    final items = [
      if (v['items'] is List)
        for (final e in v['items'] as List) ?AssistancePick.fromJson(e),
    ];
    if (items.isEmpty) return null;
    final n = v['note'];
    final note = n is String && n.trim().isNotEmpty ? n.trim() : null;
    return RideAssistance(items: items, note: note);
  }

  @override
  bool operator ==(Object other) {
    if (other is! RideAssistance || other.note != note || other.items.length != items.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (other.items[i] != items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(note, Object.hashAll(items));
}

/// The Options row's subtitle: up to two names, then "+N more".
String assistanceSummary(List<AssistancePick> items) {
  if (items.isEmpty) return '';
  final names = [for (final i in items.take(2)) i.name].join(', ');
  return items.length > 2 ? '$names +${items.length - 2} more' : names;
}

/// For the driver's note: "Assistance: Wheelchair user (Foldable, ...),
/// Pregnant". The rider's own note never goes in it: the note on an open
/// request is for every nearby driver.
/// [prefix] is the admin's name for the option, when renamed.
String assistanceNoteLabel(List<AssistancePick> items, {String prefix = 'Assistance'}) =>
    '$prefix: ${[for (final i in items) i.label].join(', ')}';

/// Whether [pick] still needs one of its item's choices.
bool assistanceNeedsChoice(AssistancePick pick, AssistanceCatalogue catalogue) {
  final item = catalogue.byId(pick.id);
  return item != null && item.choices.isNotEmpty && (pick.choice == null || !item.choices.contains(pick.choice));
}

/// Whether Done can be pressed: at least one item, and every picked item
/// with choices has one.
bool assistanceComplete(List<AssistancePick> items, AssistanceCatalogue catalogue) =>
    items.isNotEmpty && !items.any((p) => assistanceNeedsChoice(p, catalogue));

/// The hint beside Done; null once nothing is missing.
String? assistanceMissingText(List<AssistancePick> items, AssistanceCatalogue catalogue) {
  if (items.isEmpty) return 'Pick at least one.';
  final open = [for (final p in items) if (assistanceNeedsChoice(p, catalogue)) p.name];
  if (open.isEmpty) return null;
  return 'Choose an option for ${open.join(', ')}.';
}
