// The chips on the ride sheet's booking row (Now, Later, Passengers, Luggage,
// and any the admin adds), as Admin → Display Settings → Booking Row arranges
// them: shown or hidden, renamed, re-iconed, recoloured and reordered, plus
// custom chips of the admin's own. Pure: the row widget only draws the result,
// and the admin editor only calls the mutators. Tested in
// test/booking_chips_test.dart.
library;

/// The built-in booking-row chips. Their ids double as their [ResolvedChip.kind]
/// so the row widget knows which behaviour each one drives; a custom chip's
/// kind is [customBookingChipKind].
const bookingChipNowId = 'now';
const bookingChipLaterId = 'later';
const bookingChipPassengersId = 'passengers';
const bookingChipLuggageId = 'luggage';

/// The kind of a chip the admin added, which carries no built-in behaviour.
const customBookingChipKind = 'custom';

/// Each built-in chip in its natural order, with its default label and icon
/// (a [lucideIcons] name). The admin may rename, re-icon, recolour, hide or
/// reorder any of them, but never remove a built-in — only hide it.
const defaultBookingChips = <({String id, String label, String icon})>[
  (id: bookingChipNowId, label: 'Now', icon: 'Clock'),
  (id: bookingChipLaterId, label: 'Later', icon: 'Calendar'),
  (id: bookingChipPassengersId, label: 'Passengers', icon: 'User'),
  (id: bookingChipLuggageId, label: 'Luggage', icon: 'Luggage'),
];

/// A chip as the row should draw it: its id and [kind], the admin's label, the
/// icon name ([lucideIcons] or a Media Gallery ref), and the text/fill colours
/// as `#RRGGBB(AA)` hex, or null to follow the theme.
class ResolvedChip {
  const ResolvedChip({
    required this.id,
    required this.kind,
    required this.label,
    required this.custom,
    this.iconName,
    this.fg,
    this.bg,
  });

  final String id;
  final String kind;
  final String label;
  final bool custom;
  final String? iconName;
  final String? fg;
  final String? bg;

  /// A built-in chip the admin hasn't recoloured sits in its default style
  /// (the row's own); a recoloured or custom chip carries explicit colours.
  bool get themed => fg == null && bg == null;
}

List<String> _strings(Object? v) => v is List ? v.whereType<String>().toList() : const [];

Map<String, String> _hexMap(Object? v) {
  if (v is! Map) return {};
  final out = <String, String>{};
  v.forEach((k, val) {
    final s = '${val ?? ''}'.trim();
    if (k is String && s.isNotEmpty) out[k] = s;
  });
  return out;
}

/// The empty config: the booking row off, no overrides, every built-in chip in
/// its default state. It ships off so the row never appears until an admin
/// turns it on (the behaviour each chip drives lands in a later slice).
Map<String, dynamic> emptyBookingChips() => <String, dynamic>{
      'enabled': false,
      'renames': <String, dynamic>{},
      'icons': <String, dynamic>{},
      'fg': <String, dynamic>{},
      'bg': <String, dynamic>{},
      'hidden': <dynamic>[],
      'order': <dynamic>[],
      'customItems': <dynamic>[],
    };

/// Cleans a stored (or half-typed) config into the shape the rest of the code
/// relies on; anything unreadable falls back to empty.
Map<String, dynamic> normalizeBookingChips(Object? raw) {
  if (raw is! Map) return emptyBookingChips();
  final custom = <Map<String, dynamic>>[];
  if (raw['customItems'] is List) {
    for (final c in raw['customItems'] as List) {
      if (c is! Map || c['id'] is! String) continue;
      final id = c['id'] as String;
      final item = <String, dynamic>{'id': id, 'label': '${c['label'] ?? 'Chip'}'};
      if (c['iconName'] is String && (c['iconName'] as String).trim().isNotEmpty) item['iconName'] = c['iconName'];
      if (c['fg'] is String && (c['fg'] as String).trim().isNotEmpty) item['fg'] = c['fg'];
      if (c['bg'] is String && (c['bg'] as String).trim().isNotEmpty) item['bg'] = c['bg'];
      if (c['route'] is String && (c['route'] as String).trim().isNotEmpty) item['route'] = c['route'];
      custom.add(item);
    }
  }
  return <String, dynamic>{
    'enabled': raw['enabled'] == true,
    'renames': _hexMap(raw['renames']),
    'icons': _hexMap(raw['icons']),
    'fg': _hexMap(raw['fg']),
    'bg': _hexMap(raw['bg']),
    'hidden': _strings(raw['hidden']),
    'order': _strings(raw['order']),
    'customItems': custom,
  };
}

Map<String, dynamic> _cfg(Map<String, dynamic> s) => normalizeBookingChips(s['bookingChips']);
Map<String, dynamic> _with(Map<String, dynamic> s, Map<String, dynamic> cfg) => {...s, 'bookingChips': cfg};

/// Whether the booking row shows at all (the admin's master switch).
bool bookingChipsEnabled(Map<String, dynamic> settings) => _cfg(settings)['enabled'] == true;

Map<String, dynamic> setBookingChipsEnabled(Map<String, dynamic> s, bool on) => _with(s, {..._cfg(s), 'enabled': on});

/// Default + custom chips in display order (the admin editor's list).
List<({String id, bool isCustom})> bookingChipOrder(Map<String, dynamic> cfg) {
  final all = <({String id, bool isCustom})>[
    for (final d in defaultBookingChips) (id: d.id, isCustom: false),
    for (final c in (cfg['customItems'] as List)) (id: (c as Map)['id'] as String, isCustom: true),
  ];
  final order = _strings(cfg['order']);
  int rank(String id) {
    final i = order.indexOf(id);
    return i == -1 ? 1 << 30 : i;
  }

  final indexed = [for (var i = 0; i < all.length; i++) (item: all[i], natural: i)];
  indexed.sort((a, b) {
    final r = rank(a.item.id).compareTo(rank(b.item.id));
    return r != 0 ? r : a.natural.compareTo(b.natural);
  });
  return [for (final x in indexed) x.item];
}

/// The visible chips, in order, as the row should draw them.
List<ResolvedChip> resolveBookingChips(Map<String, dynamic> settings) {
  final cfg = _cfg(settings);
  final renames = _hexMap(cfg['renames']);
  final icons = _hexMap(cfg['icons']);
  final fg = _hexMap(cfg['fg']);
  final bg = _hexMap(cfg['bg']);
  final hidden = _strings(cfg['hidden']).toSet();
  final defaults = {for (final d in defaultBookingChips) d.id: d};
  final custom = {for (final c in cfg['customItems'] as List) (c as Map)['id'] as String: c};
  final out = <ResolvedChip>[];
  for (final o in bookingChipOrder(cfg)) {
    if (hidden.contains(o.id)) continue;
    if (o.isCustom) {
      final c = custom[o.id] as Map?;
      out.add(ResolvedChip(
        id: o.id,
        kind: customBookingChipKind,
        label: '${c?['label'] ?? 'Chip'}',
        custom: true,
        iconName: (c?['iconName'] as String?)?.trim().isNotEmpty == true ? c!['iconName'] as String : 'Star',
        fg: c?['fg'] as String?,
        bg: c?['bg'] as String?,
      ));
    } else {
      final d = defaults[o.id]!;
      out.add(ResolvedChip(
        id: o.id,
        kind: o.id,
        label: renames[o.id]?.trim().isNotEmpty == true ? renames[o.id]! : d.label,
        custom: false,
        iconName: icons[o.id]?.trim().isNotEmpty == true ? icons[o.id] : d.icon,
        fg: fg[o.id],
        bg: bg[o.id],
      ));
    }
  }
  return out;
}

// --- mutators (the admin editor) -------------------------------------------

Map<String, dynamic> renameBookingChip(Map<String, dynamic> s, String id, String label) {
  final cfg = _cfg(s);
  final trimmed = label.trim();
  final def = defaultBookingChips.where((d) => d.id == id).firstOrNull;
  final renames = Map<String, dynamic>.from(cfg['renames'] as Map);
  if (trimmed.isEmpty || (def != null && trimmed == def.label)) {
    renames.remove(id);
  } else {
    renames[id] = trimmed;
  }
  final custom = [
    for (final c in cfg['customItems'] as List)
      (c as Map)['id'] == id && trimmed.isNotEmpty ? {...c, 'label': trimmed} : c,
  ];
  return _with(s, {...cfg, 'renames': renames, 'customItems': custom});
}

Map<String, dynamic> setBookingChipIcon(Map<String, dynamic> s, String id, String? iconName) {
  final cfg = _cfg(s);
  final name = (iconName ?? '').trim();
  final icons = Map<String, dynamic>.from(cfg['icons'] as Map)..remove(id);
  final list = cfg['customItems'] as List;
  if (list.any((c) => (c as Map)['id'] == id)) {
    final custom = [
      for (final c in list) (c as Map)['id'] == id ? {...c, 'iconName': name.isEmpty ? 'Star' : name} : c,
    ];
    return _with(s, {...cfg, 'icons': icons, 'customItems': custom});
  }
  if (name.isNotEmpty) icons[id] = name;
  return _with(s, {...cfg, 'icons': icons});
}

/// [which] is `'fg'` (text) or `'bg'` (fill). A null/empty [hex] clears the
/// override, so the chip goes back to the theme's colour.
Map<String, dynamic> setBookingChipColor(Map<String, dynamic> s, String id, String which, String? hex) {
  assert(which == 'fg' || which == 'bg');
  final cfg = _cfg(s);
  final value = (hex ?? '').trim();
  final list = cfg['customItems'] as List;
  if (list.any((c) => (c as Map)['id'] == id)) {
    final custom = [
      for (final c in list)
        if ((c as Map)['id'] != id)
          c
        else if (value.isEmpty)
          ({...c}..remove(which))
        else
          {...c, which: value},
    ];
    return _with(s, {...cfg, 'customItems': custom});
  }
  final map = Map<String, dynamic>.from(cfg[which] as Map);
  if (value.isEmpty) {
    map.remove(id);
  } else {
    map[id] = value;
  }
  return _with(s, {...cfg, which: map});
}

Map<String, dynamic> setBookingChipVisibility(Map<String, dynamic> s, String id, bool visible) {
  final cfg = _cfg(s);
  final set = {..._strings(cfg['hidden'])};
  if (visible) {
    set.remove(id);
  } else {
    set.add(id);
  }
  return _with(s, {...cfg, 'hidden': set.toList()});
}

List<String>? _moved(List<String> ids, String id, int dir) {
  final order = [...ids];
  final from = order.indexOf(id);
  if (from == -1) return null;
  final to = from + dir;
  if (to < 0 || to >= order.length) return null;
  order
    ..removeAt(from)
    ..insert(to, id);
  return order;
}

Map<String, dynamic> moveBookingChip(Map<String, dynamic> s, String id, int dir) {
  final cfg = _cfg(s);
  final order = _moved([for (final o in bookingChipOrder(cfg)) o.id], id, dir);
  return order == null ? s : _with(s, {...cfg, 'order': order});
}

Map<String, dynamic> addCustomBookingChip(Map<String, dynamic> s, String label, {required String id, String icon = 'Star'}) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return s;
  final cfg = _cfg(s);
  return _with(s, {
    ...cfg,
    'customItems': [...cfg['customItems'] as List, <String, dynamic>{'id': id, 'label': trimmed, 'iconName': icon}],
  });
}

Map<String, dynamic> removeCustomBookingChip(Map<String, dynamic> s, String id) {
  final cfg = _cfg(s);
  return _with(s, {
    ...cfg,
    'customItems': [for (final c in cfg['customItems'] as List) if ((c as Map)['id'] != id) c],
    'hidden': _strings(cfg['hidden']).where((x) => x != id).toList(),
    'order': _strings(cfg['order']).where((x) => x != id).toList(),
    'fg': {for (final e in _hexMap(cfg['fg']).entries) if (e.key != id) e.key: e.value},
    'bg': {for (final e in _hexMap(cfg['bg']).entries) if (e.key != id) e.key: e.value},
    'icons': {for (final e in _hexMap(cfg['icons']).entries) if (e.key != id) e.key: e.value},
    'renames': {for (final e in _hexMap(cfg['renames']).entries) if (e.key != id) e.key: e.value},
  });
}
