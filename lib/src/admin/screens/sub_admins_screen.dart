import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';

import '../admin_access.dart';
import '../admin_categories.g.dart';
import '../admin_providers.dart';
import '../profile_search.dart';
import '../sub_admin_grants.dart';
import 'catalogue/driver_service_locks_screen.dart' show driverServiceLocksPage;
import 'catalogue/partner_type_services_screen.dart' show partnerTypeServicesPage;
import '../../core/city_to_city.dart' show c2cPage;
import '../../core/city_to_city_seats.dart' show c2cSeatsPage;
import '../../core/ride_safety.dart' show rideSafetyPage;
import '../../core/business_accounts.dart' show businessAccountsPage;
import '../../core/city_ride_extras.dart' show cityRideExtrasPage;
import '../../core/rider_audio.dart' show riderAudioPage;
import '../../core/premium_plus.dart' show premiumPlusPage;
import '../../core/family.dart' show familyAdminPage;
import '../../core/mygig.dart' show mygigAdminPage;
import '../../core/office_nas.dart' show officeNasPage;
import '../../core/rider_live_map.dart' show riderLiveMapPage;
import 'geo/place_types_screen.dart' show placeTypesPage;
import '../god_view_people.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/god_view_people_section.dart';
import '../widgets/region_scope_picker.dart' show pickRegionScope;
import '../../core/partner_type_rules.dart' show RegionScope;
import '../../data/live_tables.dart';
import '../../widgets/search_select.dart';

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
  partnerTypeServicesPage: 'Settings · Partner Service type services',
  driverServiceLocksPage: 'Settings · Driver service locks',
  placeTypesPage: 'Settings · Place types',
  c2cPage: 'Settings · City to City',
  c2cSeatsPage: 'Settings · City to City per-seat trips',
  rideSafetyPage: 'Settings · Ride safety',
  businessAccountsPage: 'People · Business accounts',
  cityRideExtrasPage: 'Settings · City ride extras',
  riderAudioPage: 'Settings · Rider audio protection',
  premiumPlusPage: 'Settings · Premium and GET.Plus',
  familyAdminPage: 'People · Family',
  mygigAdminPage: 'Operations · myGiG',
  officeNasPage: 'Settings · Office NAS',
  riderLiveMapPage: 'Settings · Rider live map',
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

  /// Grant access or Edit access, at their own addresses
  /// (/admin/sub-admins/grant, /admin/sub-admins/ID/edit) so a reload
  /// stays on them.
  Future<void> _edit(_GrantsView view, {String? profileId}) async {
    final saved = await context.push<bool>(subAdminEditorPath(profileId));
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
      addAction: canEdit && async.hasValue
          ? PageAddAction(
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
            padding: EdgeInsets.fromLTRB(16, 12, 16, addActionListBottomPadding(context)),
            children: [
              TextField(
                key: const ValueKey('sub-admin-search'),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  // Short enough for large text; what it searches stays
                  // under the field.
                  hintText: 'Search sub-admins',
                  helperText: 'Name, phone, email, page or note',
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
                    child: SearchableDropdownFormField<String?>(
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
/// Where Grant access (no [profileId]) or Edit access for [profileId] is.
String subAdminEditorPath(String? profileId) =>
    profileId == null ? '/admin/sub-admins/grant' : '/admin/sub-admins/${Uri.encodeComponent(profileId)}/edit';

final _grantPersonProvider = FutureProvider.autoDispose.family<Map<String, dynamic>?, String>((ref, id) async {
  final people = await ref.watch(adminRepositoryProvider).profilesByIds([id]);
  return people[id];
});

/// Grant access, or Edit access for [profileId], as a page of its own: it
/// loads the grants and the person itself, so its address opens it again
/// after a reload.
class GrantEditorPage extends ConsumerWidget {
  const GrantEditorPage({super.key, this.profileId});

  final String? profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = profileId;
    final title = id == null ? 'Grant access' : 'Edit access';
    Widget page(Widget body) => Scaffold(appBar: AppBar(title: Text(title)), body: body);
    if (ref.watch(moduleAccessProvider('sub-admins')) != AccessLevel.edit) {
      return page(
        ref.watch(adminAccessProvider).isLoading
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(icon: Icons.lock_outline, title: "You can't change admin access"),
      );
    }
    final view = ref.watch(_grantsProvider);
    final grants = view.value;
    if (grants == null) {
      return page(AsyncView(value: view, onRetry: () => ref.invalidate(_grantsProvider), data: (_) => const SizedBox()));
    }
    if (id == null) return GrantEditorScreen(allGrants: grants.grants);
    final known = grants.people[id];
    if (known != null) return GrantEditorScreen(allGrants: grants.grants, person: {...known, 'id': id});
    // Not holding any access yet: the person read by id.
    final person = ref.watch(_grantPersonProvider(id));
    return person.value == null && !person.hasError && person.isLoading
        ? page(const Center(child: CircularProgressIndicator()))
        : person.hasError
        ? page(AsyncView(value: person, onRetry: () => ref.invalidate(_grantPersonProvider(id)), data: (_) => const SizedBox()))
        : person.value == null
        ? page(const EmptyState(icon: Icons.person_off_outlined, title: 'No such person'))
        : GrantEditorScreen(allGrants: grants.grants, person: {...person.value!, 'id': id});
  }
}

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

  /// The region God View is limited to for this person (0270).
  RegionScope _godRegion = RegionScope.all;

  RegionScope get _savedGodRegion =>
      RegionScope.fromJson(_existing.where((g) => g.page == godViewPage).firstOrNull?.region);

  /// God View with no region limit, set on purpose ({"everywhere": true}, 0284).
  bool _godEverywhere = false;

  bool get _savedGodEverywhere =>
      _existing.where((g) => g.page == godViewPage).firstOrNull?.region?['everywhere'] == true;

  /// The region Reports is limited to for this person (0280).
  RegionScope _reportsRegion = RegionScope.all;

  RegionScope get _savedReportsRegion =>
      RegionScope.fromJson(_existing.where((g) => g.page == reportsPage).firstOrNull?.region);

  /// Who God View shows them: the region less a hide list, only a list, or
  /// nobody (0285). Read from the server for a grant that exists.
  GodViewPeople _godPeople = GodViewPeople.none;
  GodViewPeople _savedGodPeople = GodViewPeople.none;
  bool _godPeopleLoading = false;
  String? _godPeopleError;
  int _godPeopleTicket = 0;

  void _load() {
    final existing = _existing;
    _godRegion = _savedGodRegion;
    _godEverywhere = _savedGodEverywhere;
    _reportsRegion = _savedReportsRegion;
    _levels = initialGrantLevels(grantablePages.keys, existing);
    _notes.text = existing.map((g) => g.notes).whereType<String>().firstOrNull ?? '';
    _loadGodPeople();
  }

  void _loadGodPeople() {
    final id = _person?['id'];
    final ticket = ++_godPeopleTicket;
    _godPeople = _savedGodPeople = GodViewPeople.none;
    _godPeopleError = null;
    _godPeopleLoading = id != null && _existing.any((g) => g.page == godViewPage);
    if (!_godPeopleLoading) return;
    ref.read(adminRepositoryProvider).godViewPeople('$id').then(
      (v) {
        if (!mounted || ticket != _godPeopleTicket) return;
        setState(() {
          _godPeople = _savedGodPeople = v;
          _godPeopleLoading = false;
        });
      },
      onError: (Object e) {
        if (!mounted || ticket != _godPeopleTicket) return;
        setState(() {
          _godPeopleError = errorText(e);
          _godPeopleLoading = false;
        });
      },
    );
  }

  /// People to add to a God View list, each marked user or partner.
  Future<List<GodViewListedPerson>> _searchGodPeople(String q) async {
    final repo = ref.read(adminRepositoryProvider);
    final rows = await repo.searchPeople(q);
    final partners = await repo.partnerProfileIds(rows.map((r) => '${r['id']}'));
    return [for (final r in rows) GodViewListedPerson.fromRow(r, partner: partners.contains('${r['id']}'))];
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
    final godView = (_levels[godViewPage] ?? GrantLevel.none) != GrantLevel.none;
    final reports = (_levels[reportsPage] ?? GrantLevel.none) != GrantLevel.none;
    final regionChanged = (godView && (_godRegion != _savedGodRegion || _godEverywhere != _savedGodEverywhere)) || (reports && _reportsRegion != _savedReportsRegion);
    // Who God View shows them: a sub-admin's only, once read (0285).
    final peopleChanged = godView &&
        (_levels['*'] ?? GrantLevel.none) == GrantLevel.none &&
        !_godPeopleLoading &&
        _godPeopleError == null &&
        _godPeople.differsFrom(_savedGodPeople);
    if (plan.upserts.isEmpty && plan.deletes.isEmpty && !regionChanged && !peopleChanged) {
      _close(false);
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
    final repo = ref.read(adminRepositoryProvider);
    final godPeople = _godPeople;
    final saved = await runAdminAction(
      context,
      () async {
        await repo.setGrants(
          profileId: id,
          upserts: plan.upserts,
          deletes: plan.deletes,
          notes: notes.isEmpty ? null : notes,
          regions: {
            if (godView) godViewPage: _godEverywhere ? const {'everywhere': true} : (_godRegion.isAll ? null : _godRegion.toJson()),
            if (reports) reportsPage: _reportsRegion.isAll ? null : _reportsRegion.toJson(),
          },
        );
        // After the grant, which the lists hang on.
        if (peopleChanged) await repo.saveGodViewPeople(id, godPeople);
      },
      success: 'Access saved for ${_personLabel(person, id)}',
    );
    if (saved && mounted) {
      ref.invalidate(_grantsProvider);
      ref.invalidate(adminAccessProvider);
      _close(true);
    }
  }

  /// Back to the list: popped with [saved] when it was opened from there,
  /// gone to when the page was opened by its address (a reload).
  void _close(bool saved) {
    if (Navigator.of(context).canPop()) {
      Navigator.pop(context, saved);
    } else {
      context.go('/admin/sub-admins');
    }
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
                      // Each read as "<page>: View, selected" (or not).
                      segments: [
                        for (final (l, label) in const [
                          (GrantLevel.none, 'None'),
                          (GrantLevel.read, 'View'),
                          (GrantLevel.edit, 'Edit'),
                        ])
                          ButtonSegment(
                            value: l,
                            label: Semantics(
                              selected: (_levels[e.key] ?? GrantLevel.none) == l,
                              inMutuallyExclusiveGroup: true,
                              label: '${e.value}: $label',
                              excludeSemantics: true,
                              child: Text(label),
                            ),
                          ),
                      ],
                      selected: {_levels[e.key] ?? GrantLevel.none},
                      onSelectionChanged: (s) => setState(() => _levels = {..._levels, e.key: s.first}),
                    ),
                  ],
                ),
              ),
            // God View shows a sub-admin the people in this region only, less
            // a hide list; or only a list of people; or nobody (0285).
            if (pages.any((e) => e.key == godViewPage) &&
                (_levels[godViewPage] ?? GrantLevel.none) != GrantLevel.none &&
                (_levels['*'] ?? GrantLevel.none) == GrantLevel.none)
              GodViewPeopleSection(
                key: const ValueKey('grant-god-view-people'),
                people: _godPeople,
                loading: _godPeopleLoading,
                error: _godPeopleError,
                search: _searchGodPeople,
                onChanged: (v) => setState(() => _godPeople = v),
                regionChildren: [
                  ListTile(
                    key: const ValueKey('grant-god-view-region'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.public),
                    title: const Text('God View region'),
                    subtitle: Text(
                      _godEverywhere
                          ? 'Everywhere: they see everyone on God View'
                          : _godRegion.isAll
                          ? 'Not set: they see nobody on God View until you pick one'
                          : _godRegion.label,
                    ),
                    trailing: _godEverywhere
                        ? null
                        : TextButton(
                            onPressed: () async {
                              final picked = await pickRegionScope(context, title: 'God View region', initial: _godRegion);
                              if (picked != null && mounted) setState(() => _godRegion = picked);
                            },
                            child: Text(_godRegion.isAll ? 'Pick' : 'Change'),
                          ),
                  ),
                  SwitchListTile(
                    key: const ValueKey('grant-god-view-everywhere'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Everywhere'),
                    subtitle: const Text('No region limit: every person on God View'),
                    value: _godEverywhere,
                    onChanged: (v) => setState(() => _godEverywhere = v),
                  ),
                ],
              ),
            // Reports show a sub-admin the rides, partners and SOS in this region only.
            if (pages.any((e) => e.key == reportsPage) &&
                (_levels[reportsPage] ?? GrantLevel.none) != GrantLevel.none &&
                (_levels['*'] ?? GrantLevel.none) == GrantLevel.none)
              ListTile(
                key: const ValueKey('grant-reports-region'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.summarize_outlined),
                title: const Text('Reports region'),
                subtitle: Text(
                  _reportsRegion.isAll
                      ? 'Not set: their reports show no rides, partners, vehicles, SOS or ratings until you pick one'
                      : _reportsRegion.label,
                ),
                trailing: TextButton(
                  onPressed: () async {
                    final picked = await pickRegionScope(context, title: 'Reports region', initial: _reportsRegion);
                    if (picked != null && mounted) setState(() => _reportsRegion = picked);
                  },
                  child: Text(_reportsRegion.isAll ? 'Pick' : 'Change'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
