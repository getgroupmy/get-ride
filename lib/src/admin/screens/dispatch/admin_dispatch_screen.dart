// Admin → Dispatch (migration 0251): the console for every stand, the stands
// (on the map, their groups, fixed-fare permission, settlement, the people
// who work there), groups and fleets (members and join requests), the IDs of
// stand admins and fleet owners, and each stand's charges. Each tab follows
// its own page grant; the server checks the same pages
// (admin_table_pages → caller_admin_can_write).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/dispatch.dart';
import '../../../data/dispatch_repository.dart';
import '../../../features/dispatch/dispatch_console.dart';
import '../../../features/dispatch/stand_charges_view.dart';
import '../../../features/dispatch/stand_staff_view.dart' show AccessChips;
import '../../../data/geo_service.dart' show Place;
import '../../../features/ride/map_place_picker.dart';
import '../../../features/ride/place_search.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../profile_search.dart';

const dispatchConsolePage = 'admin-dispatch';
const dispatchStandsPage = 'admin-dispatch-stands';
const dispatchGroupsPage = 'admin-dispatch-groups';
const dispatchAccountsPage = 'admin-dispatch-accounts';

final adminStandsProvider = FutureProvider.autoDispose<List<DispatchStand>>(
  (ref) => ref.watch(dispatchRepositoryProvider).allStands(),
);
final adminGroupsProvider = FutureProvider.autoDispose<List<DispatchGroup>>(
  (ref) => ref.watch(dispatchRepositoryProvider).allGroups(),
);
final adminStandPeopleProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(dispatchRepositoryProvider).standPeople(),
);
final adminAccountsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(dispatchRepositoryProvider).accounts(),
);
final adminGroupPeopleProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, id) => ref.watch(dispatchRepositoryProvider).groupPeople(id),
);

AccessLevel _level(WidgetRef ref, String page) =>
    (ref.watch(adminAccessProvider).value ?? AdminAccess.none).levelFor([page]);

class AdminDispatchScreen extends ConsumerWidget {
  const AdminDispatchScreen({super.key, this.ticking = true});

  final bool ticking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = <(String, Widget)>[
      if (_level(ref, dispatchConsolePage) != AccessLevel.none) ('Console', _AdminConsoleTab(ticking: ticking)),
      if (_level(ref, dispatchStandsPage) != AccessLevel.none) ('Stands', const _StandsTab()),
      if (_level(ref, dispatchGroupsPage) != AccessLevel.none) ('Groups & fleets', const _GroupsTab()),
      if (_level(ref, dispatchAccountsPage) != AccessLevel.none) ('Accounts', const _AccountsTab()),
      if (_level(ref, dispatchStandsPage) != AccessLevel.none) ('Charges', const _ChargesTab()),
    ];
    if (tabs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Dispatch')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'No access',
          message: 'Ask an admin for the Dispatch pages.',
        ),
      );
    }
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Dispatch'),
          bottom: TabBar(isScrollable: true, tabs: [for (final t in tabs) Tab(text: t.$1)]),
        ),
        body: TabBarView(children: [for (final t in tabs) t.$2]),
      ),
    );
  }
}

// ---- Console ------------------------------------------------------------------------------

class _AdminConsoleTab extends ConsumerWidget {
  const _AdminConsoleTab({required this.ticking});
  final bool ticking;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(dispatchRolesProvider),
    onRetry: () => ref.invalidate(dispatchRolesProvider),
    data: (roles) => roles.stands.isEmpty
        ? const EmptyState(
            icon: Icons.storefront_outlined,
            title: 'No stands yet',
            message: 'Add a stand on the Stands tab (or ask for edit on the Dispatch console page).',
          )
        : DispatchConsole(stands: roles.stands, allStands: true, ticking: ticking),
  );
}

// ---- Stands ---------------------------------------------------------------------------------

class _StandsTab extends ConsumerWidget {
  const _StandsTab();

  Future<void> _edit(BuildContext context, WidgetRef ref, [DispatchStand? s]) async {
    final saved = await Navigator.of(context).push<bool>(
      AppPageRoute(
        id: 'admin.dispatch-stand',
        builder: (_) => StandEditor(stand: s),
      ),
    );
    if (saved == true) {
      ref.invalidate(adminStandsProvider);
      ref.invalidate(dispatchRolesProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final canEdit = _level(ref, dispatchStandsPage) == AccessLevel.edit;
    final groups = ref.watch(adminGroupsProvider).value ?? const <DispatchGroup>[];
    final people = ref.watch(adminStandPeopleProvider).value ?? const <Map<String, dynamic>>[];
    return AsyncView(
      value: ref.watch(adminStandsProvider),
      onRetry: () => ref.invalidate(adminStandsProvider),
      data: (stands) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'A stand is a pickup point: its place on the map, its kind, the groups or fleets it sends to and '
                  'whether its people may set a fixed fare. Ticket numbers start with its short code. Stand admins '
                  '(Accounts tab) make their own staff and choose what each may do.',
                  style: muted,
                ),
                const SizedBox(height: 8),
                if (canEdit)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const ValueKey('stand-add'),
                      onPressed: () => _edit(context, ref),
                      icon: const Icon(Icons.add),
                      label: const Text('Add stand'),
                    ),
                  ),
                const SizedBox(height: 8),
                if (stands.isEmpty) const EmptyState(icon: Icons.storefront_outlined, title: 'No stands yet'),
                ListSearchFilter(
                  count: stands.length,
                  hint: 'Search stands',
                  fieldKey: const ValueKey('stand-search'),
                  builder: (_, q) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final s in stands)
                        if (q.isEmpty || '${s.name} ${s.code}'.toLowerCase().contains(q.toLowerCase()))
                          _StandCard(
                            stand: s,
                            groups: groups,
                            people: [
                              for (final p in people)
                                if (p['stand_id'] == s.id) p,
                            ],
                            canEdit: canEdit,
                            onEdit: () => _edit(context, ref, s),
                          ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StandCard extends ConsumerWidget {
  const _StandCard({
    required this.stand,
    required this.groups,
    required this.people,
    required this.canEdit,
    required this.onEdit,
  });

  final DispatchStand stand;
  final List<DispatchGroup> groups;
  final List<Map<String, dynamic>> people;
  final bool canEdit;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final sendsTo = [
      for (final g in groups)
        if (stand.groupIds.contains(g.id)) g.name,
    ];
    Future<void> update(Map<String, dynamic> p, Map<String, dynamic> patch) async {
      try {
        await ref.read(dispatchRepositoryProvider).setStandPerson(stand.id, '${p['user_id']}', patch);
        ref.invalidate(adminStandPeopleProvider);
      } catch (e) {
        if (context.mounted) showError(context, dispatchErrorText(e));
      }
    }

    return Card(
      key: ValueKey('stand-${stand.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('${stand.name} · ${stand.code}', style: t.textTheme.titleMedium)),
                if (!stand.active) Text('Off', style: muted),
                if (canEdit) TextButton(onPressed: onEdit, child: const Text('Edit')),
              ],
            ),
            Text(
              [
                stand.kind.label,
                stand.settleInApp
                    ? 'Counter fares paid into the driver\'s wallet'
                    : 'Counter fares settled outside the app',
                if (stand.allowFixedFare) 'Fixed fares allowed',
                stand.fee.label,
              ].join(' · '),
              style: muted,
            ),
            Text(sendsTo.isEmpty ? 'Sends to no group yet' : 'Sends to ${sendsTo.join(', ')}', style: muted),
            if (people.isNotEmpty) const Divider(),
            for (final p in people)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${p['name'] ?? 'Someone'} · ${p['role'] == 'admin' ? 'Stand admin' : 'Staff'}'),
                          if (p['phone'] != null) Text('${p['phone']}', style: muted),
                          if (p['role'] != 'admin')
                            AccessChips(
                              perms: StandPerms.fromStaffRow(p),
                              enabled: canEdit,
                              keyPrefix: '${stand.id}-${p['user_id']}',
                              onToggle: (a) => update(p, StandPerms.fromStaffRow(p).toggled(a).toStaffRow()),
                            ),
                        ],
                      ),
                    ),
                    Switch(value: p['active'] != false, onChanged: canEdit ? (v) => update(p, {'active': v}) : null),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Add or edit a stand.
class StandEditor extends ConsumerStatefulWidget {
  const StandEditor({super.key, this.stand});
  final DispatchStand? stand;

  @override
  ConsumerState<StandEditor> createState() => _StandEditorState();
}

class _StandEditorState extends ConsumerState<StandEditor> {
  late final _name = TextEditingController(text: widget.stand?.name ?? '');
  late final _code = TextEditingController(text: widget.stand?.code ?? '');
  late final _address = TextEditingController(text: widget.stand?.address ?? '');
  late StandKind _kind = widget.stand?.kind ?? StandKind.mall;
  late double? _lat = widget.stand?.lat;
  late double? _lng = widget.stand?.lng;
  late bool _fixed = widget.stand?.allowFixedFare ?? false;
  late bool _inApp = widget.stand?.settleInApp ?? true;
  late bool _active = widget.stand?.active ?? true;
  late Set<String> _groups = {...?widget.stand?.groupIds};
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final place = await pickPlaceOnMap(context, start: _lat == null ? null : LatLng(_lat!, _lng!));
    if (place == null || !mounted) return;
    _place(place);
  }

  /// The address from a place search; "Choose on map" goes to [_pick].
  Future<void> _searchAddress() async {
    final pick = await showPlaceSearch(
      context,
      title: 'Stand address',
      near: _lat == null ? null : LatLng(_lat!, _lng!),
      mode: PlaceSearchMode.address,
      fieldLabel: 'Address',
    );
    if (pick == null || !mounted) return;
    if (pick.pickOnMap) return _pick();
    final place = pick.place;
    if (place == null) return;
    _place(place);
  }

  void _place(Place place) => setState(() {
    _lat = place.point.latitude;
    _lng = place.point.longitude;
    _address.text = place.address.isEmpty ? place.name : place.address;
    if (_name.text.trim().isEmpty) _name.text = place.name;
  });

  Future<void> _save() async {
    final s = DispatchStand(
      id: widget.stand?.id ?? '',
      name: _name.text,
      code: _code.text.trim().toUpperCase(),
      kind: _kind,
      address: _address.text.trim().isEmpty ? null : _address.text.trim(),
      lat: _lat,
      lng: _lng,
      allowFixedFare: _fixed,
      settleInApp: _inApp,
      fee: widget.stand?.fee ?? const StandFee(),
      groupIds: _groups.toList(),
      active: _active,
      ownerId: widget.stand?.ownerId,
    );
    setState(() => _error = s.problem);
    if (s.problem != null) return;
    setState(() => _busy = true);
    try {
      await ref.read(dispatchRepositoryProvider).saveStand(s, id: widget.stand?.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e'.contains('code') ? 'That short code is taken.' : dispatchErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final groups = ref.watch(adminGroupsProvider).value ?? const <DispatchGroup>[];
    return Scaffold(
      appBar: AppBar(title: Text(widget.stand == null ? 'Add stand' : 'Edit stand')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 640,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('stand-name'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('stand-code'),
                        controller: _code,
                        textCapitalization: TextCapitalization.characters,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(labelText: 'Short code', border: OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SearchableDropdownFormField<StandKind>(
                        key: const ValueKey('stand-kind'),
                        initialValue: _kind,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Kind', border: OutlineInputBorder()),
                        items: [for (final k in StandKind.values) DropdownMenuItem(value: k, child: Text(k.label))],
                        onChanged: (v) => setState(() => _kind = v ?? _kind),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Text(
                    'Starts each ticket: ${_code.text.trim().isEmpty ? 'PAV' : _code.text.trim().toUpperCase()}-0041',
                    key: const ValueKey('stand-code-example'),
                    style: muted,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('stand-address'),
                  controller: _address,
                  readOnly: true,
                  onTap: _searchAddress,
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    hintText: 'Search a place or address',
                    suffixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _lat == null
                            ? 'Not on the map yet'
                            : '${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}',
                        style: muted,
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('stand-map'),
                      onPressed: _pick,
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Pick on the map'),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Its people may set a fixed fare'),
                  value: _fixed,
                  onChanged: (v) => setState(() => _fixed = v),
                ),
                Text('Paid at the counter', style: muted),
                const SizedBox(height: 4),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text("Pay the driver's wallet")),
                    ButtonSegment(value: false, label: Text('Settled outside the app')),
                  ],
                  selected: {_inApp},
                  onSelectionChanged: (v) => setState(() => _inApp = v.first),
                ),
                const SizedBox(height: 10),
                Text('Sends to', style: muted),
                ListSearchFilter(
                  count: groups.length,
                  hint: 'Search groups',
                  fieldKey: const ValueKey('stand-group-search'),
                  builder: (_, q) => Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final g in groups)
                        if (q.isEmpty || g.name.toLowerCase().contains(q.toLowerCase()))
                          FilterChip(
                            key: ValueKey('stand-group-${g.id}'),
                            label: Text('${g.name} · ${g.kind.label}'),
                            selected: _groups.contains(g.id),
                            onSelected: (on) =>
                                setState(() => _groups = on ? {..._groups, g.id} : ({..._groups}..remove(g.id))),
                          ),
                    ],
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
                Text('The stand fee and the platform fee are on the Charges tab.', style: muted),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      key: const ValueKey('stand-error'),
                      style: TextStyle(color: t.colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey('stand-save'),
                  onPressed: _busy ? null : _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Groups and fleets -------------------------------------------------------------------------

class _GroupsTab extends ConsumerWidget {
  const _GroupsTab();

  Future<void> _edit(BuildContext context, WidgetRef ref, [DispatchGroup? g]) async {
    final saved = await showAppDialog<DispatchGroup>(
      id: 'admin.dispatch-group',
      context: context,
      builder: (_) => _GroupEditor(group: g),
    );
    if (saved == null || !context.mounted) return;
    try {
      await ref.read(dispatchRepositoryProvider).saveGroup(saved, id: g?.id);
      ref.invalidate(adminGroupsProvider);
    } catch (e) {
      if (context.mounted) showError(context, dispatchErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final canEdit = _level(ref, dispatchGroupsPage) == AccessLevel.edit;
    return AsyncView(
      value: ref.watch(adminGroupsProvider),
      onRetry: () => ref.invalidate(adminGroupsProvider),
      data: (groups) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final k in GroupKind.values) Text('${k.label}: ${k.description}', style: muted),
                Text(
                  'Drivers ask to join from their app: an admin approves closed and open groups, a fleet\'s owner '
                  'their fleet. Orders only reach drivers who are online and free.',
                  style: muted,
                ),
                const SizedBox(height: 8),
                if (canEdit)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const ValueKey('group-add'),
                      onPressed: () => _edit(context, ref),
                      icon: const Icon(Icons.add),
                      label: const Text('Add group'),
                    ),
                  ),
                const SizedBox(height: 8),
                if (groups.isEmpty) const EmptyState(icon: Icons.groups_outlined, title: 'No groups yet'),
                ListSearchFilter(
                  count: groups.length,
                  hint: 'Search groups',
                  fieldKey: const ValueKey('admin-group-search'),
                  builder: (_, q) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final g in groups)
                        if (q.isEmpty || g.name.toLowerCase().contains(q.toLowerCase()))
                          Card(
                            key: ValueKey('group-${g.id}'),
                            child: ListTile(
                              title: Text('${g.name} · ${g.kind.label}${g.active ? '' : ' · Off'}'),
                              subtitle: Text(g.howItWorks),
                              onTap: () => Navigator.of(context).push(
                                AppPageRoute<void>(
                                  id: 'admin.dispatch-group-members',
                                  builder: (_) => GroupMembersPage(group: g, canEdit: canEdit),
                                ),
                              ),
                              trailing: canEdit
                                  ? TextButton(onPressed: () => _edit(context, ref, g), child: const Text('Edit'))
                                  : const Icon(Icons.chevron_right),
                            ),
                          ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupEditor extends StatefulWidget {
  const _GroupEditor({this.group});
  final DispatchGroup? group;

  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends State<_GroupEditor> {
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late final _secs = TextEditingController(text: '${widget.group?.membersFirstSec ?? 30}');
  late GroupKind _kind = widget.group?.kind ?? GroupKind.closed;
  late bool _join = widget.group?.allowJoin ?? true;
  late bool _active = widget.group?.active ?? true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _secs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.group == null ? 'Add group' : 'Edit group'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('group-name'),
              controller: _name,
              decoration: InputDecoration(labelText: 'Name', errorText: _error),
            ),
            const SizedBox(height: 10),
            SegmentedButton<GroupKind>(
              segments: [for (final k in GroupKind.values) ButtonSegment(value: k, label: Text(k.label))],
              selected: {_kind},
              onSelectionChanged: (v) => setState(() => _kind = v.first),
            ),
            const SizedBox(height: 6),
            Text(_kind.description, style: Theme.of(context).textTheme.bodySmall),
            if (_kind == GroupKind.open)
              TextField(
                key: const ValueKey('group-secs'),
                controller: _secs,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Members first for (seconds)'),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Drivers may ask to join'),
              value: _join,
              onChanged: (v) => setState(() => _join = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const ValueKey('group-save'),
        onPressed: () {
          final name = _name.text.trim();
          if (name.isEmpty) return setState(() => _error = 'Give the group a name');
          Navigator.pop(
            context,
            DispatchGroup(
              id: widget.group?.id ?? '',
              name: name,
              kind: _kind,
              membersFirstSec: (int.tryParse(_secs.text.trim()) ?? 30).clamp(0, 600),
              allowJoin: _join,
              active: _active,
              fleetOwnerPartnerId: widget.group?.fleetOwnerPartnerId,
              note: widget.group?.note,
            ),
          );
        },
        child: const Text('Save'),
      ),
    ],
  );
}

/// A group's drivers and the drivers asking to join.
class GroupMembersPage extends ConsumerWidget {
  const GroupMembersPage({super.key, required this.group, required this.canEdit});
  final DispatchGroup group;
  final bool canEdit;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() f) async {
    try {
      await f();
      ref.invalidate(adminGroupPeopleProvider(group.id));
    } catch (e) {
      if (context.mounted) showError(context, dispatchErrorText(e));
    }
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final query = await showAppDialog<String>(
      id: 'admin.dispatch-add-driver',
      context: context,
      builder: (c) {
        final ctl = TextEditingController();
        return AlertDialog(
          title: const Text('Add a driver'),
          content: TextField(
            key: const ValueKey('add-driver-query'),
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name, phone or account id'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Search')),
          ],
        );
      },
    );
    if (query == null || query.trim().isEmpty || !context.mounted) return;
    final found = await ref.read(adminRepositoryProvider).searchPeople(query);
    if (!context.mounted) return;
    final id = await showSearchPicker<String>(
      context,
      title: 'Add to ${group.name}',
      choices: [
        for (final p in found) (value: '${p['id']}', label: personLabel(p), subtitle: personDetails(p), leading: null),
      ],
    );
    if (id != null && context.mounted) {
      await _run(context, ref, () => ref.read(dispatchRepositoryProvider).addMember(group.id, id));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final repo = ref.read(dispatchRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: Text(group.name)),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              key: const ValueKey('member-add'),
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add driver'),
            )
          : null,
      body: AsyncView(
        value: ref.watch(adminGroupPeopleProvider(group.id)),
        onRetry: () => ref.invalidate(adminGroupPeopleProvider(group.id)),
        data: (people) {
          final pending = [
            for (final p in people)
              if (p['status'] == 'pending') p,
          ];
          final rest = [
            for (final p in people)
              if (p['status'] != 'pending') p,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              ResponsiveCenter(
                maxWidth: 760,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(group.howItWorks, style: muted),
                    const SizedBox(height: 12),
                    Text('Asking to join (${pending.length})', style: t.textTheme.titleMedium),
                    if (pending.isEmpty) Text('Nobody waiting.', style: muted),
                    for (final p in pending)
                      ListTile(
                        key: ValueKey('pending-${p['driver_id']}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text([p['name'], p['plate']].whereType<String>().join(' · ')),
                        subtitle: const Text('Asked from the driver app'),
                        trailing: canEdit
                            ? Wrap(
                                spacing: 4,
                                children: [
                                  FilledButton(
                                    key: ValueKey('approve-${p['driver_id']}'),
                                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                                    onPressed: () => _run(
                                      context,
                                      ref,
                                      () => repo.decide(group.id, '${p['driver_id']}', 'approved'),
                                    ),
                                    child: const Text('Approve'),
                                  ),
                                  OutlinedButton(
                                    key: ValueKey('reject-${p['driver_id']}'),
                                    onPressed: () => _run(
                                      context,
                                      ref,
                                      () => repo.decide(group.id, '${p['driver_id']}', 'rejected'),
                                    ),
                                    child: const Text('Reject'),
                                  ),
                                ],
                              )
                            : null,
                      ),
                    const Divider(height: 24),
                    Text(
                      'Drivers (${rest.where((p) => p['status'] == 'approved').length})',
                      style: t.textTheme.titleMedium,
                    ),
                    ListSearchFilter(
                      count: rest.length,
                      hint: 'Search drivers',
                      fieldKey: const ValueKey('member-search'),
                      builder: (_, q) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final p in rest)
                            if (q.isEmpty || '${p['name']} ${p['plate']}'.toLowerCase().contains(q.toLowerCase()))
                              ListTile(
                                key: ValueKey('member-${p['driver_id']}'),
                                contentPadding: EdgeInsets.zero,
                                title: Text([p['name'], p['plate']].whereType<String>().join(' · ')),
                                subtitle: Text(p['status'] == 'approved' ? 'Member' : 'Not approved'),
                                trailing: canEdit
                                    ? TextButton(
                                        onPressed: () =>
                                            _run(context, ref, () => repo.removeMember(group.id, '${p['driver_id']}')),
                                        child: const Text('Remove'),
                                      )
                                    : null,
                              ),
                        ],
                      ),
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

// ---- Accounts --------------------------------------------------------------------------------

class _AccountsTab extends ConsumerStatefulWidget {
  const _AccountsTab();

  @override
  ConsumerState<_AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends ConsumerState<_AccountsTab> {
  String _kind = 'stand_admin';
  final _name = TextEditingController();
  final _phone = TextEditingController();
  Set<String> _stands = {};
  String? _fleet;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    String? problem;
    if (_name.text.trim().isEmpty) problem = 'Give the name or company.';
    if (problem == null && (digits.length < 8 || digits.length > 15)) problem = "The phone number doesn't look right.";
    if (problem == null && _kind == 'stand_admin' && _stands.isEmpty) problem = 'Pick their stand.';
    if (problem == null && _kind == 'fleet_owner' && _fleet == null) problem = 'Pick their fleet.';
    setState(() => _error = problem);
    if (problem != null) return;
    setState(() => _busy = true);
    try {
      final made = await ref
          .read(dispatchRepositoryProvider)
          .grant(
            kind: _kind,
            name: _name.text,
            phone: _phone.text,
            standIds: _kind == 'stand_admin' ? _stands.toList() : const [],
            groupId: _kind == 'fleet_owner' ? _fleet : null,
          );
      if (!mounted) return;
      _name.clear();
      _phone.clear();
      ref.invalidate(adminAccountsProvider);
      ref.invalidate(adminStandPeopleProvider);
      showInfo(context, made ? 'ID made. They get an SMS to set their PIN.' : 'Role given to the existing account.');
    } catch (e) {
      if (mounted) setState(() => _error = e is DispatchAccountError ? '$e' : dispatchErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final canEdit = _level(ref, dispatchAccountsPage) == AccessLevel.edit;
    final stands = ref.watch(adminStandsProvider).value ?? const <DispatchStand>[];
    final fleets = [
      for (final g in ref.watch(adminGroupsProvider).value ?? const <DispatchGroup>[])
        if (g.kind == GroupKind.fleet) g,
    ];
    final accounts = ref.watch(adminAccountsProvider);

    final form = Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Create an ID', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              key: const ValueKey('account-kind'),
              segments: const [
                ButtonSegment(value: 'stand_admin', label: Text('Stand admin')),
                ButtonSegment(value: 'fleet_owner', label: Text('Fleet owner')),
              ],
              selected: {_kind},
              onSelectionChanged: (v) => setState(() => _kind = v.first),
            ),
            const SizedBox(height: 6),
            Text(
              _kind == 'fleet_owner'
                  ? 'Runs one fleet: sees its drivers and orders, adds drivers and vehicles, and approves drivers who '
                        'ask to join.'
                  : 'Runs one or more stands: uses the console and creates IDs for their own staff, choosing what '
                        'each one may do.',
              style: muted,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('account-name'),
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name / company',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('account-phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone (their sign-in ID)',
                hintText: '+60 12-345 6789',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            if (_kind == 'stand_admin') ...[
              Text('Stands', style: muted),
              ListSearchFilter(
                count: stands.length,
                hint: 'Search stands',
                fieldKey: const ValueKey('account-stand-search'),
                builder: (_, q) => Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in stands)
                      if (q.isEmpty || s.name.toLowerCase().contains(q.toLowerCase()))
                        FilterChip(
                          key: ValueKey('account-stand-${s.id}'),
                          label: Text(s.name),
                          selected: _stands.contains(s.id),
                          onSelected: (on) =>
                              setState(() => _stands = on ? {..._stands, s.id} : ({..._stands}..remove(s.id))),
                        ),
                  ],
                ),
              ),
            ] else
              SearchableDropdownFormField<String>(
                key: const ValueKey('account-fleet'),
                initialValue: _fleet,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Fleet', border: OutlineInputBorder(), isDense: true),
                items: [for (final g in fleets) DropdownMenuItem(value: g.id, child: Text(g.name))],
                onChanged: (v) => setState(() => _fleet = v),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const ValueKey('account-error'),
                  style: TextStyle(color: t.colorScheme.error),
                ),
              ),
            const SizedBox(height: 10),
            FilledButton(
              key: const ValueKey('account-create'),
              onPressed: _busy || !canEdit ? null : _create,
              child: const Text('Create ID'),
            ),
            const SizedBox(height: 6),
            Text(
              'They get an SMS to set their own PIN on first sign-in. Same app as riders and drivers; they see only '
              'what their role allows.',
              style: muted,
            ),
          ],
        ),
      ),
    );

    final list = Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('IDs', style: t.textTheme.titleMedium),
            if (accounts.isLoading && accounts.value == null) const LinearProgressIndicator(),
            if (accounts.hasValue && accounts.value!.isEmpty) Text('No IDs yet.', style: muted),
            ListSearchFilter(
              count: accounts.value?.length ?? 0,
              hint: 'Search IDs',
              fieldKey: const ValueKey('account-search'),
              builder: (_, q) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final a in accounts.value ?? const <Map<String, dynamic>>[])
                    if (q.isEmpty || '${a['name']} ${a['phone']}'.toLowerCase().contains(q.toLowerCase()))
                      ListTile(
                        key: ValueKey('account-${a['kind']}-${a['user_id']}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${a['name'] ?? ''} · ${a['kind'] == 'fleet_owner' ? 'Fleet owner' : 'Stand admin'}',
                        ),
                        subtitle: Text(
                          [
                            '${a['phone'] ?? ''}',
                            [
                              for (final p in (a['places'] as List?) ?? const [])
                                if (p is Map) '${p['name']}',
                            ].join(', '),
                            if (a['kind'] == 'stand_admin') '${a['staff'] ?? 0} staff',
                            if (a['active'] == false) 'Disabled',
                          ].where((s) => s.isNotEmpty).join(' · '),
                        ),
                        trailing: canEdit
                            ? TextButton(
                                onPressed: () async {
                                  try {
                                    await ref
                                        .read(dispatchRepositoryProvider)
                                        .setAccountActive('${a['kind']}', '${a['user_id']}', a['active'] == false);
                                    ref.invalidate(adminAccountsProvider);
                                    ref.invalidate(adminStandPeopleProvider);
                                  } catch (e) {
                                    if (context.mounted) showError(context, dispatchErrorText(e));
                                  }
                                },
                                child: Text(a['active'] == false ? 'Enable' : 'Disable'),
                              )
                            : null,
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (_, c) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (c.maxWidth >= 860)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: form),
                const SizedBox(width: 16),
                Expanded(child: list),
              ],
            )
          else ...[
            form,
            const SizedBox(height: 16),
            list,
          ],
        ],
      ),
    );
  }
}

// ---- Charges ---------------------------------------------------------------------------------

class _ChargesTab extends ConsumerWidget {
  const _ChargesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(adminStandsProvider),
    onRetry: () => ref.invalidate(adminStandsProvider),
    data: (stands) => stands.isEmpty
        ? const EmptyState(icon: Icons.payments_outlined, title: 'No stands yet')
        : StandChargesView(
            stands: stands,
            admin: true,
            editable: _level(ref, dispatchStandsPage) == AccessLevel.edit,
            onSaved: () => ref.invalidate(adminStandsProvider),
          ),
  );
}
