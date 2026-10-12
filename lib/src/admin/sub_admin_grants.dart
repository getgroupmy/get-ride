// Sub-admin grants (Expo `admin-settings-sub-admin`): one person, many pages,
// a level per page. Pure, so the screen only gathers and writes.
import 'admin_access.dart';

/// What a person may do on one page in the editor: nothing, view, or edit.
enum GrantLevel { none, read, edit }

GrantLevel grantLevelOf(AdminGrant? g) => g == null ? GrantLevel.none : (g.edit ? GrantLevel.edit : GrantLevel.read);

/// The writes that turn [existing] (one person's grants) into [desired]:
/// rows to upsert by (profile, page) and grant ids to delete. A page whose
/// level and notes are unchanged is left alone.
({List<({String page, bool edit})> upserts, List<String> deletes}) planGrantChanges(
  List<AdminGrant> existing,
  Map<String, GrantLevel> desired, {
  String? notes,
}) {
  final byPage = {for (final g in existing) g.page: g};
  final upserts = <({String page, bool edit})>[];
  final deletes = <String>[];
  final note = _clean(notes);
  for (final e in desired.entries) {
    final had = byPage[e.key];
    if (e.value == GrantLevel.none) {
      if (had?.id != null) deletes.add(had!.id!);
      continue;
    }
    final edit = e.value == GrantLevel.edit;
    if (had != null && had.edit == edit && _clean(had.notes) == note) continue;
    upserts.add((page: e.key, edit: edit));
  }
  // A grant on a page the editor doesn't list (an old page key) is kept.
  return (upserts: upserts, deletes: deletes);
}

String? _clean(String? s) {
  final t = s?.trim() ?? '';
  return t.isEmpty ? null : t;
}

/// The editor's starting levels: every grantable page, at what the person
/// holds now.
Map<String, GrantLevel> initialGrantLevels(Iterable<String> pages, List<AdminGrant> existing) {
  final byPage = {for (final g in existing) g.page: g};
  return {for (final p in pages) p: grantLevelOf(byPage[p])};
}

/// "Set all" in the editor: every page but the full-admin `*` row.
Map<String, GrantLevel> setAllGrantLevels(Map<String, GrantLevel> levels, GrantLevel to) => {
  for (final e in levels.entries) e.key: e.key == '*' ? e.value : to,
};

/// The grant list's filter: by level held anywhere, or by one page.
enum GrantFilter { all, read, edit }

/// Whether a person's grants pass the list's search and filters. The search
/// matches name, phone, email, account id and the labels of the pages held.
bool grantPersonMatches({
  required Map<String, dynamic>? person,
  required String profileId,
  required List<AdminGrant> grants,
  required Map<String, String> pageLabels,
  String query = '',
  GrantFilter filter = GrantFilter.all,
  String? page,
}) {
  if (page != null && !grants.any((g) => g.page == page || g.page == '*')) return false;
  final scoped = page == null ? grants : grants.where((g) => g.page == page || g.page == '*');
  switch (filter) {
    case GrantFilter.read:
      if (!scoped.any((g) => !g.edit)) return false;
    case GrantFilter.edit:
      if (!scoped.any((g) => g.edit)) return false;
    case GrantFilter.all:
      break;
  }
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final hay = [
    person?['name'],
    person?['phone'],
    person?['email'],
    person?['display_id'],
    profileId,
    for (final g in grants) pageLabels[g.page] ?? g.page,
    for (final g in grants) g.notes,
  ].whereType<Object>().join(' ').toLowerCase();
  return hay.contains(q);
}
