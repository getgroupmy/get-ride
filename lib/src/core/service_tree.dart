// The services as a tree, for a super app with many on-demand services:
// Service Settings entries are the master services (Car, Bike, Food, …);
// anything else is a sub-service under one or more of them, or under
// another sub-service, to any depth.
//
// A sub-service names its parents in `parentServices` (a list of settings
// entry ids, from any category). Vehicle Services' older `serviceTypes`
// (Service Settings names) count as parents too. A category added later
// joins the tree just by setting `parentServices` on its entries.
//
// A region switches each one on or off (`subServices`, `{id: bool}`); one it
// doesn't list follows the regions around it, and is on by default. A
// service is off where it, or anything above it, is switched off.
import 'dart:convert';

/// One settings entry that may sit in the tree.
class ServiceEntry {
  const ServiceEntry({
    required this.id,
    required this.name,
    required this.category,
    this.description = '',
    this.parentIds = const [],
    this.typeNames = const [],
  });

  /// From a `settings_entries` row's id, category and values.
  factory ServiceEntry.fromValues(String id, String category, Map<String, dynamic> v) => ServiceEntry(
    id: id,
    name: '${v['name'] ?? ''}'.trim().isEmpty ? 'Unnamed service' : '${v['name']}'.trim(),
    category: category,
    description: '${v['description'] ?? ''}'.trim(),
    parentIds: serviceParentIds(v),
    typeNames: [
      for (final t in v['serviceTypes'] is List ? v['serviceTypes'] as List : const [])
        if ('$t'.trim().isNotEmpty) '$t'.trim(),
    ],
  );

  final String id;
  final String name;

  /// Its settings category: `service-settings` for a master service.
  final String category;
  final String description;

  /// The entries it sits under, by id (`parentServices`).
  final List<String> parentIds;

  /// The master services it sits under by name (Vehicle Services'
  /// `serviceTypes`).
  final List<String> typeNames;
}

/// The settings category of the master services.
const masterServiceCategory = 'service-settings';

/// The categories whose entries are sub-services even without
/// `parentServices` (the ones there before it).
const subServiceCategories = ['vehicle-services'];

/// An entry's `parentServices`: a list of ids, or one id.
List<String> serviceParentIds(Map<String, dynamic> v) {
  final raw = v['parentServices'];
  final list = raw is List ? raw : (raw is String && raw.trim().isNotEmpty ? [raw] : const []);
  return [
    for (final p in list)
      if ('$p'.trim().isNotEmpty) '$p'.trim(),
  ];
}

/// One place in the tree: an entry and what sits under it here.
class ServiceNode {
  const ServiceNode(this.entry, this.depth, this.children);
  final ServiceEntry entry;

  /// 0 for a master service.
  final int depth;
  final List<ServiceNode> children;

  String get id => entry.id;
}

/// The tree: [roots] (master services, in their order) with their
/// sub-services under them, and the sub-services linked to nothing that
/// exists ([unlinked]). A sub-service with several parents shows under each;
/// a loop is cut where it would repeat.
class ServiceTree {
  ServiceTree._(this.roots, this.unlinked, this._parents);

  factory ServiceTree.build(List<ServiceEntry> masters, List<ServiceEntry> subs) {
    final byId = {
      for (final e in [...masters, ...subs]) e.id: e,
    };
    final masterByName = {for (final m in masters) m.name.trim().toLowerCase(): m.id};
    final parents = <String, List<String>>{};
    for (final s in subs) {
      parents[s.id] = {
        for (final p in s.parentIds)
          if (byId.containsKey(p) && p != s.id) p,
        for (final t in s.typeNames) ?masterByName[t.toLowerCase()],
      }.toList();
    }
    final childrenOf = <String, List<ServiceEntry>>{};
    for (final s in subs) {
      for (final p in parents[s.id]!) {
        (childrenOf[p] ??= []).add(s);
      }
    }
    ServiceNode node(ServiceEntry e, int depth, Set<String> path) => ServiceNode(e, depth, [
      for (final c in childrenOf[e.id] ?? const <ServiceEntry>[])
        if (!path.contains(c.id)) node(c, depth + 1, {...path, c.id}),
    ]);
    final roots = [
      for (final m in masters) node(m, 0, {m.id}),
    ];
    // Reachable from a master service; the rest are unlinked (their own
    // sub-trees still hang under them).
    final reached = <String>{};
    void walk(ServiceNode n) {
      if (!reached.add(n.id)) return;
      n.children.forEach(walk);
    }

    roots.forEach(walk);
    // Linked to nothing reachable: shown on their own, those under another
    // such sub-service inside its sub-tree (and any left by a loop too).
    final unlinked = <ServiceNode>[];
    for (final s in subs) {
      if (reached.contains(s.id) || parents[s.id]!.isNotEmpty) continue;
      final n = node(s, 0, {s.id});
      unlinked.add(n);
      walk(n);
    }
    for (final s in subs) {
      if (reached.contains(s.id)) continue;
      final n = node(s, 0, {s.id});
      unlinked.add(n);
      walk(n);
    }
    return ServiceTree._(roots, unlinked, parents);
  }

  final List<ServiceNode> roots;
  final List<ServiceNode> unlinked;
  final Map<String, List<String>> _parents;

  /// [id] and every entry above it, nearest first.
  List<String> lineage(String id) {
    final out = <String>[];
    final queue = [id];
    while (queue.isNotEmpty) {
      final x = queue.removeAt(0);
      if (out.contains(x)) continue;
      out.add(x);
      queue.addAll(_parents[x] ?? const []);
    }
    return out;
  }

  /// Every node, depth first (a sub-service with several parents once
  /// under each).
  Iterable<ServiceNode> get all sync* {
    Iterable<ServiceNode> walk(ServiceNode n) sync* {
      yield n;
      for (final c in n.children) {
        yield* walk(c);
      }
    }

    for (final r in [...roots, ...unlinked]) {
      yield* walk(r);
    }
  }
}

/// A region's own sub-service switches (`subServices`, a map or a JSON
/// string of `{id: bool}`).
Map<String, bool> regionSubServiceSwitches(Object? raw) {
  Object? j = raw;
  if (raw is String) {
    if (raw.isEmpty) return const {};
    try {
      j = jsonDecode(raw);
    } catch (_) {
      return const {};
    }
  }
  if (j is! Map) return const {};
  return {
    for (final e in j.entries)
      if (e.value is bool) '${e.key}': e.value as bool,
  };
}

/// Whether a service whose [lineage] (itself, then everything above it) is
/// on, given each region's switches, most specific first: for each entry in
/// the lineage the most specific region that switches it decides, and any
/// one off turns the service off.
bool subServiceOn(Iterable<String> lineage, List<Map<String, bool>> switchesMostSpecificFirst) {
  for (final id in lineage) {
    for (final own in switchesMostSpecificFirst) {
      final v = own[id];
      if (v == null) continue;
      if (!v) return false;
      break;
    }
  }
  return true;
}
