// Admin > Services & catalogue > Driver service locks (migration 0263):
// keep a service on or off for one driver, several drivers, a partner type,
// a fleet, a region or everyone, optionally until a date. A lock wins over
// the driver's own switch on their Services page, where it shows with a
// padlock; Driver decides gives the choice back. Below the form: the locks
// in force (filter, edit, remove), how many drivers switched each service
// off, and who changed what.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/driver_services.dart';
import '../../../core/format.dart' show formatDateTime;
import '../../../core/partner_type_services.dart' show partnerServiceKey;
import '../../../core/ride_extras.dart' show rideExtraGroups;
import '../../../data/driver_services_repository.dart';
import '../../../data/live_tables.dart';
import '../../../data/ride_option_providers.dart';
import '../../../data/ride_pet_repository.dart' show petConfigProvider;
import '../../../providers.dart';
import '../../../widgets/common.dart';
import '../../../widgets/date_boxes.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../profile_search.dart';
import '../../widgets/admin_widgets.dart';
import '../geo/geo_data.dart' show regionVehicleTypesProvider, regionsProvider;
import '../geo/geo_logic.dart' show RegionEntry, RegionLevel, ServiceOption;
import 'partner_type_services_screen.dart' show partnerTypeNamesForServicesProvider;

const driverServiceLocksPath = '/admin/m/driver-service-locks';

/// The page key that grants this page.
const driverServiceLocksPage = 'admin-settings-driver-service-locks';

// ---- Data ------------------------------------------------------------------------

final driverServiceLocksProvider = FutureProvider.autoDispose<List<LockRule>>((ref) {
  ref.watchAdminLive(driverServiceLocksTable);
  return ref.watch(driverServicesRepositoryProvider).locks();
});

final driverServiceOffCountsProvider = FutureProvider.autoDispose<Map<String, int>>((ref) async {
  ref.watchAdminLive(driverServicePrefsTable);
  ref.watchAdminLive('driver_ride_extras');
  try {
    return await ref.watch(driverServicesRepositoryProvider).offCounts();
  } catch (_) {
    return const {};
  }
});

final driverServiceLockEventsProvider = FutureProvider.autoDispose<List<LockEvent>>((ref) {
  ref.watchAdminLive(driverServiceLockEventsTable);
  return ref.watch(driverServicesRepositoryProvider).events();
});

/// The fleets (Order dispatch, 0251), by name.
final lockFleetsProvider = FutureProvider.autoDispose<List<({String id, String name})>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('dispatch_groups')
      .select('id, name')
      .eq('kind', 'fleet')
      .order('name', ascending: true);
  return [for (final r in rows) (id: '${r['id']}', name: '${r['name'] ?? ''}'.trim())];
});

/// People's names by id, for the targets and the log ([ids] joined by ',').
final lockPeopleProvider = FutureProvider.autoDispose.family<Map<String, String>, String>((ref, ids) async {
  final list = [for (final i in ids.split(',')) if (i.isNotEmpty) i];
  if (list.isEmpty) return const {};
  try {
    final rows = await ref.watch(adminRepositoryProvider).peopleByIds(list);
    return {for (final e in rows.entries) e.key: personLabel(e.value)};
  } catch (_) {
    return const {};
  }
});

/// Finding a driver by name, phone, email or id; a provider so tests can
/// answer it.
final lockPeopleSearchProvider = Provider<Future<List<Map<String, dynamic>>> Function(String)>(
  (ref) => ref.watch(adminRepositoryProvider).searchPeople,
);

/// One service row of the form: its key and name.
typedef LockServiceChoice = ({String key, String name, String group});

/// Every key the form sets: the Vehicle Services, street hail and the
/// add-ons.
final lockServiceChoicesProvider = Provider.autoDispose<List<LockServiceChoice>>((ref) {
  final services = ref.watch(regionVehicleTypesProvider).value ?? const <ServiceOption>[];
  final addOns = rideExtraGroups(
    ref.watch(rideOptionsConfigProvider),
    ref.watch(petConfigProvider),
    ref.watch(assistanceCatalogueProvider),
  );
  return [
    for (final s in services) (key: DriverServiceKey.service(s.name), name: s.name, group: 'Services'),
    (key: DriverServiceKey.hailMeter, name: 'Meter (street hail)', group: 'Street hail'),
    (key: DriverServiceKey.hailDestination, name: 'Street hail with destination', group: 'Street hail'),
    for (final g in addOns)
      for (final i in g.items)
          (
            key: DriverServiceKey.extra(i.key),
            name: g.items.length == 1 && i.label == g.title ? g.title : '${g.title}: ${i.label}',
            group: 'Add-ons',
          ),
  ];
});

// ---- The page ----------------------------------------------------------------------

/// Who the form's locks are for.
enum _Who {
  one('One driver'),
  several('Several drivers'),
  partnerType('Partner type'),
  fleet('Fleet'),
  region('Region'),
  everyone('Everyone');

  const _Who(this.label);
  final String label;
}

typedef _Person = ({String id, String label});
typedef _Place = ({String country, String? state, String? city});

class DriverServiceLocksScreen extends ConsumerStatefulWidget {
  const DriverServiceLocksScreen({super.key});

  @override
  ConsumerState<DriverServiceLocksScreen> createState() => _DriverServiceLocksScreenState();
}

class _DriverServiceLocksScreenState extends ConsumerState<DriverServiceLocksScreen> {
  _Who _who = _Who.one;
  final _drivers = <_Person>[];
  String? _partnerType;
  ({String id, String name})? _fleet;
  _Place? _region;
  Map<String, LockChoice> _choices = {};
  final _until = TextEditingController();
  final _note = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  LockScope? _filter;
  bool _saving = false;

  @override
  void dispose() {
    _until.dispose();
    _note.dispose();
    super.dispose();
  }

  bool _canEdit() => ref.watch(pageAccessProvider(driverServiceLocksPage)) == AccessLevel.edit;

  /// The targets the form names; null while it names nobody yet.
  List<LockTarget>? get _targets => switch (_who) {
    _Who.one || _Who.several =>
      _drivers.isEmpty ? null : [for (final d in _drivers) LockTarget(scope: LockScope.driver, driverId: d.id)],
    _Who.partnerType => _partnerType == null
        ? null
        : [LockTarget(scope: LockScope.partnerType, partnerType: partnerServiceKey(_partnerType!))],
    _Who.fleet => _fleet == null ? null : [LockTarget(scope: LockScope.fleet, fleetId: _fleet!.id)],
    _Who.region => _region == null
        ? null
        : [LockTarget(scope: LockScope.region, country: _region!.country, state: _region!.state, city: _region!.city)],
    _Who.everyone => const [LockTarget.everyone()],
  };

  /// The form shows what is saved for a single target.
  void _loadSaved() {
    final t = _targets;
    final locks = ref.read(driverServiceLocksProvider).value ?? const <LockRule>[];
    if (t == null || t.length != 1) {
      _choices = {};
      return;
    }
    _choices = choicesFor(t.single, locks);
    final mine = locks.where((l) => l.target == t.single).toList();
    final until = mine.map((l) => l.until).whereType<DateTime>().firstOrNull;
    _until.text = until == null ? '' : isoDate(until.toLocal());
    _note.text = mine.map((l) => l.note).whereType<String>().firstOrNull ?? '';
  }

  void _setWho(_Who w) => setState(() {
    _who = w;
    if (w == _Who.one && _drivers.length > 1) _drivers.removeRange(1, _drivers.length);
    _loadSaved();
  });

  Future<void> _pickDrivers() async {
    final picked = await showAppDialog<List<_Person>>(
      id: 'admin.driver-service-locks.drivers',
      context: context,
      builder: (_) => _DriverSearchDialog(
        search: ref.read(lockPeopleSearchProvider),
        several: _who == _Who.several,
        already: [..._drivers],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _drivers
        ..clear()
        ..addAll(_who == _Who.one ? picked.take(1) : picked);
      _loadSaved();
    });
  }

  Future<void> _pickPartnerType() async {
    final names = await ref.read(partnerTypeNamesForServicesProvider.future).catchError((_) => <String>[]);
    if (!mounted) return;
    final picked = await showSearchPicker<String>(
      context,
      title: 'Partner type',
      choices: [for (final n in names) (value: n, label: n, subtitle: null, leading: null)],
      selected: _partnerType,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _partnerType = picked;
      _loadSaved();
    });
  }

  Future<void> _pickFleet() async {
    final fleets = await ref.read(lockFleetsProvider.future).catchError((_) => <({String id, String name})>[]);
    if (!mounted) return;
    if (fleets.isEmpty) {
      showInfo(context, 'No fleets yet (Order dispatch > Fleets).');
      return;
    }
    final picked = await showSearchPicker<String>(
      context,
      title: 'Fleet',
      choices: [for (final f in fleets) (value: f.id, label: f.name, subtitle: null, leading: null)],
      selected: _fleet?.id,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _fleet = fleets.firstWhere((f) => f.id == picked);
      _loadSaved();
    });
  }

  Future<void> _pickRegion() async {
    final regions = await ref.read(regionsProvider.future).catchError((_) => <RegionEntry>[]);
    if (!mounted) return;
    final places = <String, _Place>{};
    for (final r in regions) {
      if (r.country.trim().isEmpty || r.level == RegionLevel.suburb) continue;
      final p = (
        country: r.country.trim(),
        state: r.state.trim().isEmpty ? null : r.state.trim(),
        city: r.city.trim().isEmpty ? null : r.city.trim(),
      );
      places[_placeLabel(p)] = p;
    }
    if (places.isEmpty) {
      showInfo(context, 'No regions yet (Country / States / Cities).');
      return;
    }
    final keys = places.keys.toList()..sort();
    final picked = await showSearchPicker<String>(
      context,
      title: 'Region',
      choices: [
        for (final k in keys)
          (
            value: k,
            label: k,
            subtitle: places[k]!.city != null ? 'City' : (places[k]!.state != null ? 'State' : 'Country'),
            leading: null,
          ),
      ],
      selected: _region == null ? null : _placeLabel(_region!),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _region = places[picked];
      _loadSaved();
    });
  }

  static String _placeLabel(_Place p) => [p.city, p.state, p.country].whereType<String>().join(', ');

  DateTime? get _untilAt {
    final d = parseIsoDate(_until.text.trim());
    return d == null ? null : DateTime(d.year, d.month, d.day, 23, 59, 59);
  }

  Future<void> _save(List<LockServiceChoice> services) async {
    final targets = _targets;
    if (targets == null) {
      showError(context, switch (_who) {
        _Who.one => 'Choose a driver.',
        _Who.several => 'Add the drivers.',
        _Who.partnerType => 'Choose a partner type.',
        _Who.fleet => 'Choose a fleet.',
        _Who.region => 'Choose a region.',
        _Who.everyone => 'Choose who the locks are for.',
      });
      return;
    }
    if (!(_formKey.currentState?.validate() ?? true)) return;
    if (_until.text.trim().isNotEmpty && _untilAt == null) {
      showError(context, 'Enter a whole date, or leave Until empty.');
      return;
    }
    final saved = ref.read(driverServiceLocksProvider).value ?? const <LockRule>[];
    final keys = {
      for (final s in services) s.key,
      for (final l in saved)
        if (targets.contains(l.target)) l.serviceKey,
    };
    setState(() => _saving = true);
    final ok = await runAdminAction(
      context,
      () => ref.read(driverServicesRepositoryProvider).saveLocks(
            targets,
            lockRulesPayload(keys, _choices),
            until: _untilAt,
            note: _note.text,
          ),
      success: 'Locks saved. Drivers see them straight away.',
    );
    if (mounted) setState(() => _saving = false);
    if (ok) {
      ref.invalidate(driverServiceLocksProvider);
      ref.invalidate(driverServiceLockEventsProvider);
    }
  }

  void _edit(LockTarget t, Map<String, String> names) {
    setState(() {
      switch (t.scope) {
        case LockScope.driver:
          _who = _Who.one;
          _drivers
            ..clear()
            ..add((id: t.driverId!, label: names[t.driverId] ?? 'Driver'));
        case LockScope.partnerType:
          _who = _Who.partnerType;
          _partnerType = names['pt:${t.partnerType}'] ?? t.partnerType;
        case LockScope.fleet:
          _who = _Who.fleet;
          _fleet = (id: t.fleetId!, name: names['fleet:${t.fleetId}'] ?? 'Fleet');
        case LockScope.region:
          _who = _Who.region;
          _region = (country: t.country!, state: t.state, city: t.city);
        case LockScope.everyone:
          _who = _Who.everyone;
      }
      _loadSaved();
    });
    Scrollable.ensureVisible(_formKey.currentContext ?? context, duration: const Duration(milliseconds: 250));
  }

  Future<void> _remove(String label, List<LockRule> locks) async {
    final ok = await showAppDialog<bool>(
      id: 'admin.driver-service-locks.remove',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove these locks?'),
        content: Text('$label gets the choice back for ${locks.length == 1 ? 'this service' : 'these ${locks.length} services'}, '
            'at what they had before.'),
        actions: [
          TextButton(key: const ValueKey('dsl-remove-cancel'), onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('dsl-remove-yes'), onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (await runAdminAction(
      context,
      () => ref.read(driverServicesRepositoryProvider).removeLocks(locks.map((l) => l.id)),
      success: 'Locks removed. Drivers decide again.',
    )) {
      ref.invalidate(driverServiceLocksProvider);
      ref.invalidate(driverServiceLockEventsProvider);
      if (mounted) setState(_loadSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _canEdit();
    final value = ref.watch(driverServiceLocksProvider);
    final services = ref.watch(lockServiceChoicesProvider);
    final counts = ref.watch(driverServiceOffCountsProvider).value ?? const <String, int>{};
    final events = ref.watch(driverServiceLockEventsProvider).value ?? const <LockEvent>[];
    final fleets = ref.watch(lockFleetsProvider).value ?? const <({String id, String name})>[];
    final typeNames = ref.watch(partnerTypeNamesForServicesProvider).value ?? const <String>[];
    // A change saved elsewhere refills the form for the same target.
    ref.listen(driverServiceLocksProvider, (prev, next) {
      if (prev?.value == null && next.value != null) setState(_loadSaved);
    });
    return AdminPage(
      title: 'Driver service locks',
      page: driverServiceLocksPage,
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(driverServiceLocksProvider),
        data: (locks) {
          final people = {
            for (final l in locks) ?l.driverId,
            for (final l in locks) ?l.createdBy,
            for (final l in locks) ?l.updatedBy,
            for (final e in events) ?e.actorId,
            for (final e in events) ?e.target.driverId,
          }.toList()
            ..sort();
          final personNames = ref.watch(lockPeopleProvider(people.join(','))).value ?? const <String, String>{};
          final names = <String, String>{
            ...personNames,
            for (final n in typeNames) 'pt:${partnerServiceKey(n)}': n,
            for (final f in fleets) 'fleet:${f.id}': f.name,
          };
          final serviceNames = {for (final s in services) s.key: s.name};
          final t = Theme.of(context);
          final wide = MediaQuery.sizeOf(context).width >= 1000;
          final form = _form(context, services, counts, canEdit);
          final list = _LockList(
            groups: groupLocks(locks),
            filter: _filter,
            onFilter: (f) => setState(() => _filter = f),
            names: names,
            serviceNames: serviceNames,
            canEdit: canEdit,
            onEdit: (g) => _edit(g, names),
            onRemove: _remove,
          );
          final log = _Log(events: events, names: names, serviceNames: serviceNames);
          return ResponsiveCenter(
            maxWidth: 1200,
            child: ListView(
              key: const ValueKey('driver-service-locks'),
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                Text(
                  "Keep a service on or off for drivers. A lock wins over the driver's own switch, and shows with a "
                  "padlock in the driver's app. Driver decides gives the choice back, at what they had before. Every "
                  'change is logged with who made it.',
                  style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)),
                ),
                const SizedBox(height: 16),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 11, child: form),
                      const SizedBox(width: 16),
                      Expanded(flex: 10, child: Column(children: [list, const SizedBox(height: 16), log])),
                    ],
                  )
                else ...[
                  form,
                  const SizedBox(height: 16),
                  list,
                  const SizedBox(height: 16),
                  log,
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _form(BuildContext context, List<LockServiceChoice> services, Map<String, int> counts, bool canEdit) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t));
    final tomorrow = DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 1));
    return _Panel(
      key: const ValueKey('dsl-form'),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Set locks', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Applies to', style: muted),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final w in _Who.values)
                  ChoiceChip(
                    key: ValueKey('dsl-who-${w.name}'),
                    label: Text(w.label),
                    selected: _who == w,
                    onSelected: canEdit ? (_) => _setWho(w) : null,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _targetPicker(context, canEdit),
            const SizedBox(height: 12),
            ListSearchFilter(
              count: services.length,
              hint: 'Search services',
              fieldKey: const ValueKey('dsl-service-search'),
              builder: (context, q) {
                final shown = [
                  for (final s in services)
                    if (q.isEmpty || searchSelectMatches('${s.name} ${s.group}', q)) s,
                ];
                if (shown.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('No service matches.', style: muted),
                  );
                }
                return Container(
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: t.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < shown.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _RuleRow(
                          choice: shown[i],
                          value: _choices[shown[i].key] ?? LockChoice.driver,
                          offCount: counts[shown[i].key] ?? 0,
                          enabled: canEdit,
                          onChanged: (c) => setState(() => _choices[shown[i].key] = c),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            DateBoxesField(
              key: const ValueKey('dsl-until'),
              label: 'Until (optional)',
              controller: _until,
              firstDate: tomorrow,
              beforeFirstText: 'Pick a date after today',
              enabled: canEdit,
              helperText: 'Leave empty for no end date. The locks end at the end of that day.',
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('dsl-note'),
              controller: _note,
              enabled: canEdit,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Note for admins (optional)',
                border: OutlineInputBorder(),
                isDense: true,
                counterText: '',
              ),
            ),
            if (canEdit) ...[
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('dsl-save'),
                onPressed: _saving ? null : () => _save(services),
                child: Text(_saving ? 'Saving…' : 'Save locks'),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text('You can view the locks. Ask a full admin for edit access to change them.', style: muted),
            ],
          ],
        ),
      ),
    );
  }

  Widget _targetPicker(BuildContext context, bool canEdit) {
    final t = Theme.of(context);
    Widget pick(String key, String text, VoidCallback onTap, {IconData icon = Icons.search}) => OutlinedButton.icon(
      key: ValueKey(key),
      onPressed: canEdit ? onTap : null,
      icon: Icon(icon, size: 18),
      label: Align(alignment: Alignment.centerLeft, child: Text(text, overflow: TextOverflow.ellipsis)),
    );
    return switch (_who) {
      _Who.one => pick('dsl-pick-driver', _drivers.isEmpty ? 'Choose a driver' : _drivers.first.label, _pickDrivers),
      _Who.several => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_drivers.isNotEmpty)
            Wrap(
              key: const ValueKey('dsl-drivers'),
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final d in _drivers)
                  InputChip(
                    label: Text(d.label),
                    onDeleted: canEdit ? () => setState(() => _drivers.remove(d)) : null,
                  ),
              ],
            ),
          const SizedBox(height: 6),
          pick(
            'dsl-add-drivers',
            _drivers.isEmpty ? 'Add drivers' : '${_drivers.length} drivers selected. Add more',
            _pickDrivers,
            icon: Icons.person_add_alt,
          ),
        ],
      ),
      _Who.partnerType => pick('dsl-pick-type', _partnerType ?? 'Choose a partner type', _pickPartnerType),
      _Who.fleet => pick('dsl-pick-fleet', _fleet?.name ?? 'Choose a fleet', _pickFleet),
      _Who.region => pick('dsl-pick-region', _region == null ? 'Choose a region' : _placeLabel(_region!), _pickRegion),
      _Who.everyone => Text('All drivers', key: const ValueKey('dsl-everyone'), style: t.textTheme.bodyMedium),
    };
  }
}

class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(14), child: child),
  );
}

/// One service: Driver decides / Keep on / Keep off.
class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.choice,
    required this.value,
    required this.offCount,
    required this.enabled,
    required this.onChanged,
  });

  final LockServiceChoice choice;
  final LockChoice value;
  final int offCount;
  final bool enabled;
  final ValueChanged<LockChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t));
    return Padding(
      key: ValueKey('dsl-rule-${choice.key}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 140),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(choice.name, style: t.textTheme.bodyMedium),
                Text(
                  offCount == 0
                      ? choice.group
                      : '${choice.group} · $offCount ${offCount == 1 ? 'driver has' : 'drivers have'} it off',
                  key: ValueKey('dsl-count-${choice.key}'),
                  style: muted,
                ),
              ],
            ),
          ),
          SegmentedButton<LockChoice>(
            key: ValueKey('dsl-seg-${choice.key}'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final c in LockChoice.values)
                ButtonSegment(value: c, label: Text(c.label, key: ValueKey('dsl-${c.id}-${choice.key}'))),
            ],
            selected: {value},
            onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
          ),
        ],
      ),
    );
  }
}

/// A target in words.
String _targetLabel(LockTarget t, Map<String, String> names) => switch (t.scope) {
  LockScope.driver => names[t.driverId] ?? 'A driver',
  LockScope.partnerType => names['pt:${t.partnerType}'] ?? t.partnerType ?? 'Partner type',
  LockScope.fleet => names['fleet:${t.fleetId}'] ?? 'A fleet',
  LockScope.region => t.regionLabel,
  LockScope.everyone => 'Everyone',
};

/// The locks in force, by target.
class _LockList extends StatelessWidget {
  const _LockList({
    required this.groups,
    required this.filter,
    required this.onFilter,
    required this.names,
    required this.serviceNames,
    required this.canEdit,
    required this.onEdit,
    required this.onRemove,
  });

  final List<({LockTarget target, List<LockRule> locks})> groups;
  final LockScope? filter;
  final ValueChanged<LockScope?> onFilter;
  final Map<String, String> names;
  final Map<String, String> serviceNames;
  final bool canEdit;
  final ValueChanged<LockTarget> onEdit;
  final void Function(String label, List<LockRule> locks) onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final muted = t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t));
    final now = DateTime.now();
    final shownGroups = [for (final g in groups) if (filter == null || g.target.scope == filter) g];
    return _Panel(
      key: const ValueKey('dsl-list'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Current locks', style: t.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                key: const ValueKey('dsl-filter-all'),
                label: const Text('All'),
                selected: filter == null,
                onSelected: (_) => onFilter(null),
              ),
              for (final s in LockScope.values)
                ChoiceChip(
                  key: ValueKey('dsl-filter-${s.id}'),
                  label: Text(s == LockScope.driver ? 'Drivers' : s.label),
                  selected: filter == s,
                  onSelected: (_) => onFilter(s),
                ),
            ],
          ),
          ListSearchFilter(
            count: shownGroups.length,
            from: 1,
            hint: 'Search locks',
            fieldKey: const ValueKey('dsl-list-search'),
            builder: (context, q) {
              final shown = [
                for (final g in shownGroups)
                  if (q.isEmpty ||
                      searchSelectMatches(
                        '${_targetLabel(g.target, names)} ${g.locks.map((l) => describeServiceKey(l.serviceKey, serviceNames)).join(' ')}',
                        q,
                      ))
                    g,
              ];
              if (shown.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(groups.isEmpty ? 'No locks: drivers decide every service.' : 'No lock matches.', style: muted),
                );
              }
              return Column(
                children: [
                  for (final g in shown)
                    Container(
                      key: ValueKey('dsl-group-${g.target.id}'),
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(_targetLabel(g.target, names), style: t.textTheme.titleSmall)),
                              StatusChip('pending', label: g.target.scope == LockScope.driver ? 'Driver' : g.target.scope.label),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final l in g.locks)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: l.activeAt(now)
                                        ? (l.on ? cs.secondaryContainer : cs.tertiaryContainer)
                                        : cs.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                  child: Text(
                                    '${describeServiceKey(l.serviceKey, serviceNames)}: ${lockModeLabel(l.on)}'
                                    '${l.until == null ? '' : (l.activeAt(now) ? ' until ' : ' ended ')}'
                                    '${l.until == null ? '' : formatDateForUser(l.until!.toLocal())}',
                                    style: t.textTheme.labelSmall?.copyWith(
                                      color: l.activeAt(now)
                                          ? (l.on ? cs.onSecondaryContainer : cs.onTertiaryContainer)
                                          : mutedTextColor(t, background: cs.surfaceContainerHighest),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            [
                              'Set by ${names[g.locks.first.updatedBy ?? g.locks.first.createdBy] ?? 'an admin'}',
                              if (g.locks.first.updatedAt != null) formatDateTime(g.locks.first.updatedAt),
                              if (g.locks.any((l) => l.note != null)) g.locks.map((l) => l.note).whereType<String>().first,
                            ].join(' · '),
                            style: muted,
                          ),
                          if (canEdit)
                            Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 8,
                              children: [
                                TextButton(
                                  key: ValueKey('dsl-edit-${g.target.id}'),
                                  onPressed: () => onEdit(g.target),
                                  child: const Text('Edit'),
                                ),
                                TextButton(
                                  key: ValueKey('dsl-remove-${g.target.id}'),
                                  onPressed: () => onRemove(_targetLabel(g.target, names), g.locks),
                                  child: const Text('Remove'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Who changed what, the latest first.
class _Log extends StatelessWidget {
  const _Log({required this.events, required this.names, required this.serviceNames});
  final List<LockEvent> events;
  final Map<String, String> names;
  final Map<String, String> serviceNames;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t));
    String line(LockEvent e) {
      final who = names[e.actorId] ?? (e.actorId == null ? 'get.ride' : 'An admin');
      final what = describeServiceKey(e.serviceKey, serviceNames);
      final whom = _targetLabel(e.target, names);
      final until = e.until == null ? '' : ' until ${formatDateForUser(e.until!.toLocal())}';
      return switch (e.action) {
        'removed' => '$who gave $what back to $whom',
        'changed' => '$who changed $what for $whom to ${lockModeLabel(e.on == true).toLowerCase()}$until',
        _ => '$who kept $what ${e.on == true ? 'on' : 'off'} for $whom$until',
      };
    }

    return _Panel(
      key: const ValueKey('dsl-log'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Changes', style: t.textTheme.titleMedium),
          const SizedBox(height: 6),
          if (events.isEmpty)
            Text('No changes yet.', style: muted)
          else
            for (final e in events.take(50))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(line(e), style: t.textTheme.bodyMedium),
                    if (e.at != null) Text(formatDateTime(e.at), style: muted),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// Finding drivers by name, phone, email or account id; pops with the
/// ones picked (one, unless [several]).
class _DriverSearchDialog extends StatefulWidget {
  const _DriverSearchDialog({required this.search, required this.several, required this.already});
  final Future<List<Map<String, dynamic>>> Function(String) search;
  final bool several;
  final List<_Person> already;

  @override
  State<_DriverSearchDialog> createState() => _DriverSearchDialogState();
}

class _DriverSearchDialogState extends State<_DriverSearchDialog> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _results;
  late final List<_Person> _picked = [...widget.already];
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final q = _q.text.trim();
    if (!isProfileUuid(q) && peopleSearchTerm(q) == null) {
      setState(() => _error = 'Type at least two characters.');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final rows = await widget.search(q);
      if (mounted) setState(() => _results = rows);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('dsl-driver-dialog'),
      title: Text(widget.several ? 'Add drivers' : 'Choose a driver'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('dsl-driver-search'),
                controller: _q,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _find(),
                decoration: InputDecoration(
                  labelText: 'Name, phone, email or account id',
                  errorText: _error,
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : IconButton(
                          key: const ValueKey('dsl-driver-find'),
                          tooltip: 'Search',
                          icon: const Icon(Icons.search),
                          onPressed: _find,
                        ),
                ),
              ),
              if (_results != null && _results!.isEmpty)
                const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Nobody matches.')),
              for (final r in _results ?? const <Map<String, dynamic>>[])
                () {
                  final id = '${r['id']}';
                  final picked = _picked.any((p) => p.id == id);
                  return ListTile(
                    key: ValueKey('dsl-driver-$id'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(picked ? Icons.check_circle : Icons.person_outline),
                    title: Text(personLabel(r)),
                    subtitle: Text(personDetails(r)),
                    onTap: () {
                      final p = (id: id, label: personLabel(r));
                      if (!widget.several) {
                        Navigator.pop(context, [p]);
                        return;
                      }
                      setState(() => picked ? _picked.removeWhere((x) => x.id == id) : _picked.add(p));
                    },
                  );
                }(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (widget.several)
          FilledButton(
            key: const ValueKey('dsl-driver-done'),
            onPressed: () => Navigator.pop(context, _picked),
            child: Text(_picked.isEmpty ? 'Done' : 'Done (${_picked.length})'),
          ),
      ],
    );
  }
}
