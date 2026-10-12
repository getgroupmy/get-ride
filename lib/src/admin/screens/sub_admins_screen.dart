import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';

import '../admin_access.dart';
import '../admin_categories.g.dart';
import '../admin_providers.dart';
import '../profile_search.dart';
import '../sub_admin_grants.dart';
import '../widgets/admin_widgets.dart';
import '../../data/live_tables.dart';

typedef _GrantsView = ({List<AdminGrant> grants, Map<String, Map<String, dynamic>> people});

final _grantsProvider = FutureProvider.autoDispose<_GrantsView>((ref) async {
  ref.watchLive('admin_access');
  ref.watchAdminLive('profiles');
  final repo = ref.watch(adminRepositoryProvider);
  final grants = (await repo.allGrants()).map(AdminGrant.fromRow).toList();
  final people = await repo.profilesByIds(grants.map((g) => g.profileId).whereType<String>());
  return (grants: grants, people: people);
});

/// Every page key an admin can be granted: modules plus each settings page.
final grantablePages = <String, String>{
  '*': 'All pages (full admin)',
  for (final m in adminModules.values)
    for (final p in m.pages) p: '${m.label} · $p',
  for (final c in crudCategories) c.page: 'Settings · ${c.title}',
};

String _personLabel(Map<String, dynamic>? p, String id) => '${p?['name'] ?? p?['phone'] ?? p?['email'] ?? id}'.trim();

/// Sub-admins (Expo `admin-settings-sub-admin`): who may open which admin
/// pages, and whether they may change anything there. One person holds a
/// level per page, edited together, with a note.
class AdminSubAdminsScreen extends ConsumerStatefulWidget {
  const AdminSubAdminsScreen({super.key});

  @override
  ConsumerState<AdminSubAdminsScreen> createState() => _AdminSubAdminsScreenState();
}

class _AdminSubAdminsScreenState extends ConsumerState<AdminSubAdminsScreen> {
  String _query = '';
  GrantFilter _filter = GrantFilter.all;
  String? _page;

  Future<void> _edit(_GrantsView view, {String? profileId}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => GrantEditorScreen(
          allGrants: view.grants,
          person: profileId == null ? null : {...?view.people[profileId], 'id': profileId},
        ),
      ),
    );
    if (saved == true) {
      ref.invalidate(_grantsProvider);
      ref.invalidate(adminAccessProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(moduleAccessProvider('sub-admins')) == AccessLevel.edit;
    final me = ref.watch(currentUserIdProvider);
    final async = ref.watch(_grantsProvider);
    return AdminPage(
      title: 'Sub-admins',
      module: 'sub-admins',
      floatingActionButton: canEdit && async.hasValue
          ? FloatingActionButton.extended(
              key: const ValueKey('grant-access'),
              onPressed: () => _edit(async.value!),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Grant access'),
            )
          : null,
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(_grantsProvider),
        data: (v) {
          final byPerson = <String, List<AdminGrant>>{};
          for (final g in v.grants) {
            byPerson.putIfAbsent(g.profileId ?? '?', () => []).add(g);
          }
          final shown = byPerson.entries
              .where(
                (e) => grantPersonMatches(
                  person: v.people[e.key],
                  profileId: e.key,
                  grants: e.value,
                  pageLabels: grantablePages,
                  query: _query,
                  filter: _filter,
                  page: _page,
                ),
              )
              .toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            children: [
              TextField(
                key: const ValueKey('sub-admin-search'),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search name, phone, email, page or note…',
                  isDense: true,
                ),
                onChanged: (q) => setState(() => _query = q),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (f, label) in [
                    (GrantFilter.all, 'All'),
                    (GrantFilter.read, 'View only'),
                    (GrantFilter.edit, 'Can edit'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: DropdownButtonFormField<String?>(
                      key: const ValueKey('sub-admin-page-filter'),
                      initialValue: _page,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Page', isDense: true),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('Any page')),
                        for (final e in grantablePages.entries)
                          if (e.key != '*')
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value, overflow: TextOverflow.ellipsis),
                            ),
                      ],
                      onChanged: (p) => setState(() => _page = p),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (shown.isEmpty)
                EmptyState(
                  icon: Icons.admin_panel_settings_outlined,
                  title: byPerson.isEmpty ? 'No sub-admins yet' : 'Nobody matches',
                ),
              for (final e in shown)
                Card(
                  child: ExpansionTile(
                    key: ValueKey('sub-admin-${e.key}'),
                    leading: const Icon(Icons.admin_panel_settings_outlined),
                    title: Text('${_personLabel(v.people[e.key], e.key)}${e.key == me ? ' (you)' : ''}'),
                    subtitle: Text(
                      [
                        if (v.people[e.key]?['phone'] != null) '${v.people[e.key]!['phone']}',
                        e.value.any((g) => g.page == '*')
                            ? 'Full admin'
                            : '${e.value.length} page${e.value.length == 1 ? '' : 's'}',
                      ].join(' · '),
                    ),
                    trailing: canEdit
                        ? IconButton(
                            key: ValueKey('sub-admin-edit-${e.key}'),
                            tooltip: 'Edit access',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _edit(v, profileId: e.key),
                          )
                        : null,
                    children: [
                      if (e.value.map((g) => g.notes).whereType<String>().toSet() case final notes
                          when notes.isNotEmpty)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.sticky_note_2_outlined),
                          title: Text(notes.join(' · ')),
                        ),
                      for (final g in e.value)
                        ListTile(
                          title: Text(grantablePages[g.page] ?? g.page),
                          leading: StatusChip(g.edit ? 'edit' : 'read'),
                          trailing: canEdit && g.id != null
                              ? BusyIconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: 'Revoke',
                                  onPressed: () async {
                                    final self = e.key == me && g.page == '*';
                                    if (!await confirm(
                                      context,
                                      'Revoke access?',
                                      self
                                          ? 'This removes your own full admin access. You may lose access to this panel.'
                                          : 'Revoke ${grantablePages[g.page] ?? g.page}?',
                                      ok: 'Revoke',
                                    )) {
                                      return;
                                    }
                                    if (!context.mounted) return;
                                    if (await runAdminAction(
                                      context,
                                      () => ref.read(adminRepositoryProvider).revoke(g.id!),
                                    )) {
                                      ref.invalidate(_grantsProvider);
                                      ref.invalidate(adminAccessProvider);
                                    }
                                  },
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// One person's access, every page at once: find the person (name, phone,
/// email or id), set a level per page or all of them, add a note, save.
/// Pops true when something was written.
class GrantEditorScreen extends ConsumerStatefulWidget {
  const GrantEditorScreen({super.key, required this.allGrants, this.person});

  /// Every grant, so a person picked here opens on what they already hold.
  final List<AdminGrant> allGrants;

  /// Set when editing someone already listed; null to find a person.
  final Map<String, dynamic>? person;

  @override
  ConsumerState<GrantEditorScreen> createState() => _GrantEditorScreenState();
}

class _GrantEditorScreenState extends ConsumerState<GrantEditorScreen> {
  late Map<String, dynamic>? _person = widget.person;
  late Map<String, GrantLevel> _levels;
  final _notes = TextEditingController();
  final _search = TextEditingController();
  String _pageQuery = '';
  List<Map<String, dynamic>>? _results;
  bool _searching = false;
  String? _searchError;

  List<AdminGrant> get _existing {
    final id = _person?['id'];
    return id == null ? const [] : widget.allGrants.where((g) => g.profileId == id).toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final existing = _existing;
    _levels = initialGrantLevels(grantablePages.keys, existing);
    _notes.text = existing.map((g) => g.notes).whereType<String>().firstOrNull ?? '';
  }

  @override
  void dispose() {
    _notes.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final q = _search.text.trim();
    if (!isProfileUuid(q) && peopleSearchTerm(q) == null) {
      setState(() => _searchError = 'Type at least two characters.');
      return;
    }
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final rows = await ref.read(adminRepositoryProvider).searchPeople(q);
      if (mounted) setState(() => _results = rows);
    } catch (e) {
      if (mounted) setState(() => _searchError = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _pick(Map<String, dynamic> p) => setState(() {
    _person = p;
    _results = null;
    _load();
  });

  Future<void> _save() async {
    final person = _person;
    if (person == null) return;
    final id = '${person['id']}';
    final plan = planGrantChanges(_existing, _levels, notes: _notes.text);
    if (plan.upserts.isEmpty && plan.deletes.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    final me = ref.read(currentUserIdProvider);
    final hadFull = _existing.any((g) => g.page == '*' && g.edit);
    if (id == me && hadFull && _levels['*'] != GrantLevel.edit) {
      final ok = await confirm(
        context,
        'Remove your own full access?',
        'You will lose access to pages you are not granted here, possibly this one.',
        ok: 'Remove',
      );
      if (!ok || !mounted) return;
    }
    final notes = _notes.text.trim();
    final saved = await runAdminAction(
      context,
      () => ref
          .read(adminRepositoryProvider)
          .setGrants(profileId: id, upserts: plan.upserts, deletes: plan.deletes, notes: notes.isEmpty ? null : notes),
      success: 'Access saved for ${_personLabel(person, id)}',
    );
    if (saved && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final person = _person;
    final q = _pageQuery.trim().toLowerCase();
    final pages = grantablePages.entries
        .where((e) => q.isEmpty || e.value.toLowerCase().contains(q) || e.key.toLowerCase().contains(q))
        .toList();
    final granted = _levels.values.where((l) => l != GrantLevel.none).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.person == null ? 'Grant access' : 'Edit access'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: BusyButton.filled(
              key: const ValueKey('grant-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
              onPressed: person == null ? null : _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (person == null) ...[
            Text('Who', style: t.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('grant-person-search'),
              controller: _search,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _find(),
              decoration: InputDecoration(
                labelText: 'Name, phone, email or account id',
                errorText: _searchError,
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: _find),
              ),
            ),
            if (_results != null && _results!.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No account matches. They need to sign up first.'),
              ),
            for (final r in _results ?? const <Map<String, dynamic>>[])
              ListTile(
                key: ValueKey('grant-person-${r['id']}'),
                leading: const Icon(Icons.person_outline),
                title: Text(_personLabel(r, '${r['id']}')),
                subtitle: Text([r['phone'], r['email'], r['display_id']].whereType<Object>().join(' · ')),
                trailing: widget.allGrants.any((g) => g.profileId == r['id']) ? const StatusChip('admin') : null,
                onTap: () => _pick(r),
              ),
          ] else ...[
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.person),
                title: Text(_personLabel(person, '${person['id']}')),
                subtitle: Text([person['phone'], person['email']].whereType<Object>().join(' · ')),
                trailing: widget.person == null
                    ? TextButton(
                        onPressed: () => setState(() {
                          _person = null;
                          _load();
                        }),
                        child: const Text('Change'),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('grant-notes'),
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Notes', hintText: 'e.g. Support team, night shift'),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Text('Pages · $granted granted', style: t.textTheme.titleSmall)),
                const Text('Set all:'),
                for (final (l, label) in [
                  (GrantLevel.none, 'None'),
                  (GrantLevel.read, 'View'),
                  (GrantLevel.edit, 'Edit'),
                ])
                  TextButton(
                    key: ValueKey('grant-all-${l.name}'),
                    onPressed: () => setState(() => _levels = setAllGrantLevels(_levels, l)),
                    child: Text(label),
                  ),
              ],
            ),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.filter_list),
                hintText: 'Filter pages',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _pageQuery = v),
            ),
            const SizedBox(height: 8),
            for (final e in pages)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.value,
                        style: e.key == '*' ? t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700) : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SegmentedButton<GrantLevel>(
                      key: ValueKey('grant-level-${e.key}'),
                      showSelectedIcon: false,
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                      segments: const [
                        ButtonSegment(value: GrantLevel.none, label: Text('None')),
                        ButtonSegment(value: GrantLevel.read, label: Text('View')),
                        ButtonSegment(value: GrantLevel.edit, label: Text('Edit')),
                      ],
                      selected: {_levels[e.key] ?? GrantLevel.none},
                      onSelectionChanged: (s) => setState(() => _levels = {..._levels, e.key: s.first}),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
