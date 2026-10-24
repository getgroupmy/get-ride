// Who a sub-admin's God View grant shows (migration 0285): the region (or
// Everywhere) less a hide list, only the people on a list, or nobody. Pure,
// so the editor only gathers and writes.
library;

/// Who they see on God View.
enum GodViewPeopleMode {
  /// The grant's region, or Everywhere, less the hide list.
  region('region', 'Region'),

  /// The people on the only list, wherever they are.
  only('only', 'Only these people'),

  /// No one: they keep the page.
  nobody('nobody', 'Nobody');

  const GodViewPeopleMode(this.wire, this.label);

  /// As stored (`admin_god_view_people_save`'s p_mode).
  final String wire;
  final String label;

  static GodViewPeopleMode parse(Object? v) =>
      values.firstWhere((m) => m.wire == '$v', orElse: () => GodViewPeopleMode.region);
}

/// One person on a list: who, and whether they are a partner.
class GodViewListedPerson {
  const GodViewListedPerson({required this.id, this.name, this.phone, this.displayId, this.partner = false});

  factory GodViewListedPerson.fromRow(Map<String, dynamic> r, {bool? partner}) => GodViewListedPerson(
    id: '${r['id']}',
    name: _text(r['name']),
    phone: _text(r['phone']),
    displayId: _text(r['display_id']),
    partner: partner ?? r['partner'] == true,
  );

  final String id;
  final String? name;
  final String? phone;
  final String? displayId;
  final bool partner;

  String get label => name ?? displayId ?? phone ?? id;

  @override
  bool operator ==(Object other) => other is GodViewListedPerson && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

String? _text(Object? v) {
  final t = '${v ?? ''}'.trim();
  return t.isEmpty ? null : t;
}

/// A grant's mode and both lists, as read from or written to the server.
class GodViewPeople {
  const GodViewPeople({this.mode = GodViewPeopleMode.region, this.only = const [], this.hide = const []});

  /// `admin_god_view_people_get`'s answer.
  factory GodViewPeople.fromJson(Map<String, dynamic> j) {
    final only = <GodViewListedPerson>[];
    final hide = <GodViewListedPerson>[];
    for (final p in (j['people'] as List?) ?? const []) {
      if (p is! Map) continue;
      final row = Map<String, dynamic>.from(p);
      (row['list'] == 'only' ? only : hide).add(GodViewListedPerson.fromRow(row));
    }
    return GodViewPeople(mode: GodViewPeopleMode.parse(j['mode']), only: only, hide: hide);
  }

  static const none = GodViewPeople();

  final GodViewPeopleMode mode;
  final List<GodViewListedPerson> only;
  final List<GodViewListedPerson> hide;

  GodViewPeople copyWith({GodViewPeopleMode? mode, List<GodViewListedPerson>? only, List<GodViewListedPerson>? hide}) =>
      GodViewPeople(mode: mode ?? this.mode, only: only ?? this.only, hide: hide ?? this.hide);

  /// Whether saving this over [saved] changes anything.
  bool differsFrom(GodViewPeople saved) =>
      mode != saved.mode || !_sameIds(only, saved.only) || !_sameIds(hide, saved.hide);

  /// What the editor says under "Who they see".
  String get summary => switch (mode) {
    GodViewPeopleMode.region =>
      hide.isEmpty ? 'Everyone in their region' : 'Everyone in their region but ${_people(hide.length)}',
    GodViewPeopleMode.only =>
      only.isEmpty ? 'Only these people: nobody listed yet, so they see no one' : 'Only ${_people(only.length)}',
    GodViewPeopleMode.nobody => 'Nobody: they keep the God View page but see no one on it',
  };
}

String _people(int n) => n == 1 ? '1 person' : '$n people';

bool _sameIds(List<GodViewListedPerson> a, List<GodViewListedPerson> b) =>
    a.length == b.length && a.map((p) => p.id).toSet().containsAll(b.map((p) => p.id));

/// [list] with [p] added at the end, unless already on it.
List<GodViewListedPerson> addListedPerson(List<GodViewListedPerson> list, GodViewListedPerson p) =>
    list.any((e) => e.id == p.id) ? list : [...list, p];

/// [list] without the person [id].
List<GodViewListedPerson> removeListedPerson(List<GodViewListedPerson> list, String id) =>
    [for (final p in list) if (p.id != id) p];

/// Whether [p] matches a list's search box: name, phone digits, display id.
bool listedPersonMatches(GodViewListedPerson p, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final digits = q.replaceAll(RegExp(r'[^0-9]'), '');
  return [p.name, p.displayId].any((v) => (v ?? '').toLowerCase().contains(q)) ||
      (digits.length >= 3 && (p.phone ?? '').replaceAll(RegExp(r'[^0-9]'), '').contains(digits));
}
