import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/region_pricing.dart';
import '../../../core/region_service_switches.dart';
import '../../../core/ride_bidding.dart' show RegionBlock;
import '../../../core/service_tree.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/keyboard_dismiss.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'boundary_editor.dart';
import 'geo_data.dart';
import 'geo_logic.dart';
import 'country_phone_screen.dart';
import 'region_rules_editor.dart';
import '../../../widgets/chip_button.dart';

const regionsPage = 'admin-settings-country-states-cities';

/// Countries / states / cities / suburbs with per-region settings and
/// geofences (Expo `admin-settings-country-states-cities.tsx`).
class AdminRegionsScreen extends ConsumerStatefulWidget {
  const AdminRegionsScreen({super.key});

  @override
  ConsumerState<AdminRegionsScreen> createState() => _AdminRegionsScreenState();
}

class _AdminRegionsScreenState extends ConsumerState<AdminRegionsScreen> {
  String _country = '', _state = '', _city = '', _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  RegionLevel get _level => currentRegionLevel(_country, _state, _city);

  void _select({String? country, String? state, String? city}) {
    dismissKeyboard();
    setState(() {
      if (country != null) _country = country;
      if (state != null) _state = state;
      if (city != null) _city = city;
      _query = '';
      _search.clear();
    });
  }

  void _back() {
    if (_city.isNotEmpty) {
      _select(city: '');
    } else if (_state.isNotEmpty) {
      _select(state: '');
    } else {
      _select(country: '');
    }
  }

  void _open(RegionRow r) {
    switch (r.level) {
      case RegionLevel.country:
        _select(country: r.country);
      case RegionLevel.state:
        _select(state: r.state);
      case RegionLevel.city:
        _select(city: r.city);
      case RegionLevel.suburb:
        break;
    }
  }

  Future<void> _edit(List<RegionEntry> entries, {RegionRow? row}) async {
    dismissKeyboard();
    final entry = row?.entry;
    final initial = entry != null
        ? RegionForm.fromEntry(entry)
        : RegionForm(
            country: row?.country ?? _country,
            state: row?.state ?? _state,
            city: row?.city ?? _city,
            suburb: row?.suburb ?? '',
          );
    if (entry == null && row?.level == RegionLevel.country) {
      final def = countryDefaultsForName(row!.country);
      if (def != null) {
        initial.emergencyNumber = def.emergencyNumber;
        initial.languageCode = def.languageCode;
      }
    }
    // The level of the row being edited, else of the page: it decides the
    // one name the sheet asks for (its parents are the page).
    final level = entry != null ? regionLevelOf(entry.values) : (row?.level ?? _level);
    // The regions above it, for what each service follows.
    final above = regionLevelsAbove(entries, level, country: initial.country, state: initial.state, city: initial.city);
    final form = await showAdminSheet<RegionForm>(
      context,
      title: entry != null ? 'Edit region' : 'Add ${regionLevelLabel(level)}',
      builder: (_) => _RegionFormBody(initial: initial, level: level, editing: entry != null, above: above),
    );
    if (form == null || !mounted) return;
    final repo = ref.read(geoAdminRepositoryProvider);
    final target = entry ?? findRegionDuplicate(entries, form.country, form.state, form.city, form.suburb);
    final ok = await runAdminAction(
      context,
      () => repo.saveRegion(
        id: target?.id,
        values: {...?target?.values, ...form.toValues()},
        position: target?.position ?? 0,
      ),
      success: 'Region saved',
    );
    if (ok) ref.invalidate(regionsProvider);
  }

  Future<void> _delete(RegionRow r) async {
    final e = r.entry;
    if (e == null) return;
    if (!await confirm(context, 'Delete entry', 'This will remove the saved entry. Continue?', ok: 'Delete')) return;
    if (!mounted) return;
    final ok = await runAdminAction(context, () => ref.read(geoAdminRepositoryProvider).deleteRegion(e.id),
        success: 'Entry deleted');
    if (ok) ref.invalidate(regionsProvider);
  }

  Future<void> _map(RegionRow r, bool canEdit) async {
    dismissKeyboard();
    final repo = ref.read(geoAdminRepositoryProvider);
    final entry = r.entry;
    var stored = r.boundary;
    // The list carries only a mark; the shape is read now.
    if (stored == null && entry != null && r.hasBoundary) {
      String? raw;
      final ok = await runAdminAction(context, () async => raw = await repo.boundaryOf(entry));
      if (!ok || !mounted) return;
      stored = parseBoundary(raw);
    }
    if (!mounted) return;
    BoundaryEditorPage.open(
      context,
      BoundaryEditorPage(
        title: 'Boundary',
        query: r.query,
        canEdit: canEdit,
        initial: stored,
        near: entry == null ? null : latLngOf(entry.values, lonKey: 'lng'),
        onSave: (shape) async {
          await repo.saveRegion(
            id: entry?.id,
            values: regionBoundaryValues(r, shape, DateTime.now()),
            position: entry?.position ?? 0,
          );
          ref.invalidate(regionsProvider);
        },
        onClear: entry == null || !r.hasBoundary
            ? null
            : () async {
                await repo.saveRegion(id: entry.id, values: withoutBoundary(entry.values), position: entry.position);
                ref.invalidate(regionsProvider);
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(regionsPage)) == AccessLevel.edit;
    final async = ref.watch(regionsProvider);
    final entries = async.value ?? const <RegionEntry>[];
    final level = _level;
    return AdminPage(
      title: 'Regions',
      page: regionsPage,
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () {
            ref.invalidate(regionsProvider);
            ref.invalidate(regionServiceCheckProvider);
          },
        ),
      ],
      addAction: PageAddAction(
        onPressed: () => _edit(entries),
        icon: const Icon(Icons.add),
        label: Text('Add ${regionLevelLabel(level)}'),
      ),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(regionsProvider),
        data: (entries) {
          final rows = buildRegionRows(entries, selCountry: _country, selState: _state, selCity: _city, query: _query);
          return ResponsiveCenter(
            maxWidth: 900,
            padding: EdgeInsets.zero,
            child: Column(children: [
              if (_country.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                  child: Row(children: [
                    TextButton.icon(onPressed: _back, icon: const Icon(Icons.arrow_back, size: 16), label: const Text('Back')),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: [
                          ActionChipButton(label: Text(_country), onPressed: () => _select(state: '', city: '')),
                          if (_state.isNotEmpty) ...[
                            const Icon(Icons.chevron_right, size: 16),
                            ActionChipButton(label: Text(_state), onPressed: () => _select(city: '')),
                          ],
                          if (_city.isNotEmpty) ...[
                            const Icon(Icons.chevron_right, size: 16),
                            Chip(label: Text(_city)),
                          ],
                        ]),
                      ),
                    ),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search ${regionLevelLabel(level)}…',
                    isDense: true,
                    helperText: '${rows.length} ${regionLevelLabel(level, plural: true)}',
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: (v) => setState(() => _query = v),
                  onSubmitted: (_) => dismissKeyboard(),
                ),
              ),
              Expanded(
                child: rows.isEmpty
                    ? EmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'Nothing here yet',
                        message: level == RegionLevel.suburb
                            ? 'Add a suburb for this city to get started.'
                            : 'Try a different search or add a custom entry.',
                      )
                    : ListView.separated(
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.only(bottom: addActionListBottomPadding(context)),
                        itemCount: rows.length + (_country.isEmpty ? 1 : 0),
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, j) {
                          // The countries' page opens with the service check (0302).
                          if (_country.isEmpty && j == 0) return _ServiceCheckCard(canEdit: canEdit);
                          final i = _country.isEmpty ? j - 1 : j;
                          return _RegionTile(
                          row: rows[i],
                          canEdit: canEdit,
                          onOpen: () => _open(rows[i]),
                          onMap: () => _map(rows[i], canEdit),
                          onPhone: countryIsoOf(rows[i]) == null
                              ? null
                              : () => openCountryPhoneRules(context,
                                  iso: countryIsoOf(rows[i])!, name: rows[i].name, canEdit: canEdit),
                          onEdit: () => _edit(entries, row: rows[i]),
                          onDelete: () => _delete(rows[i]),
                        );
                        },
                      ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _RegionTile extends StatelessWidget {
  const _RegionTile({
    required this.row,
    required this.canEdit,
    required this.onOpen,
    required this.onMap,
    required this.onEdit,
    required this.onDelete,
    this.onPhone,
  });
  final RegionRow row;
  final bool canEdit;
  final VoidCallback onOpen, onMap;

  /// A country with an ISO code: its phone numbers and sign-in (0292).
  final VoidCallback? onPhone;
  final Future<void> Function() onEdit, onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final custom = row.entry != null;
    final hasBoundary = row.hasBoundary;
    final icon = switch (row.level) {
      RegionLevel.country => Icons.public,
      RegionLevel.state => Icons.place_outlined,
      RegionLevel.city => Icons.location_city,
      RegionLevel.suburb => Icons.home_outlined,
    };
    final v = row.entry?.values;
    final subtitle = switch (row.level) {
      RegionLevel.country => 'Tap to view states',
      RegionLevel.state => 'Tap to view cities',
      RegionLevel.city => 'Tap to view suburbs',
      RegionLevel.suburb => v == null
          ? ''
          : '${v['lat'] is num ? (v['lat'] as num).toStringAsFixed(4) : '—'}, '
              '${v['lng'] is num ? (v['lng'] as num).toStringAsFixed(4) : '—'}',
    };
    Widget badge(String text, Color c) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Text(text, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
        );
    final badges = [
      if (custom) badge('Custom', scheme.primary),
      if (hasBoundary) badge('Boundary', Colors.teal),
      if (v?['blocked'] == true) badge('Blocked', scheme.error),
    ];
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: custom ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        child: Icon(icon, color: custom ? scheme.primary : scheme.onSurfaceVariant, size: 20),
      ),
      // The name has the title to itself: the badges sit under it, so a row
      // with several of them (and four buttons) never squeezes it to nothing.
      title: Text(row.name, key: ValueKey('region-name-${row.key}'), maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: badges.isEmpty && subtitle.isEmpty
          ? null
          : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (badges.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Wrap(spacing: 6, runSpacing: 4, children: badges),
                ),
              if (subtitle.isNotEmpty) Text(subtitle),
            ]),
      onTap: row.level == RegionLevel.suburb ? null : onOpen,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (onPhone != null)
          IconButton(
            key: ValueKey('region-phone-${row.key}'),
            tooltip: 'Phone numbers and sign-in',
            icon: const Icon(Icons.smartphone),
            onPressed: onPhone,
          ),
        IconButton(
          tooltip: 'Boundary on a map',
          icon: Icon(Icons.map_outlined, color: hasBoundary ? scheme.primary : null),
          onPressed: onMap,
        ),
        if (canEdit) BusyIconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
        if (canEdit && custom)
          BusyIconButton(tooltip: 'Delete', icon: Icon(Icons.delete_outline, color: scheme.error), onPressed: onDelete),
        if (row.level != RegionLevel.suburb) const Icon(Icons.chevron_right),
      ]),
    );
  }
}

class _RegionFormBody extends ConsumerStatefulWidget {
  const _RegionFormBody({required this.initial, required this.level, required this.editing, this.above = const []});
  final RegionForm initial;
  final RegionLevel level;
  final bool editing;

  /// The regions above it, nearest first (what Inherit follows).
  final List<ServiceSwitchLevel> above;

  @override
  ConsumerState<_RegionFormBody> createState() => _RegionFormBodyState();
}

class _RegionFormBodyState extends ConsumerState<_RegionFormBody> {
  late final RegionForm f = widget.initial;
  late final Map<String, TextEditingController> _c = {
    'country': TextEditingController(text: f.country),
    'state': TextEditingController(text: f.state),
    'city': TextEditingController(text: f.city),
    'suburb': TextEditingController(text: f.suburb),
    'lat': TextEditingController(text: f.lat),
    'lng': TextEditingController(text: f.lng),
    'currencyName': TextEditingController(text: f.currencyName),
    'currencySymbol': TextEditingController(text: f.currencySymbol),
    'emergencyNumber': TextEditingController(text: f.emergencyNumber),
    'callingCode': TextEditingController(text: f.callingCode),
    'languageCode': TextEditingController(text: f.languageCode),
    'dateFormat': TextEditingController(text: f.dateFormat),
    'timezone': TextEditingController(text: f.timezone),
    'taxName': TextEditingController(text: f.taxName),
    'taxAmount': TextEditingController(text: f.taxAmount),
    'handoverShare': TextEditingController(text: f.handoverShare),
  };
  String? _error;
  bool _filling = false;

  /// Country information from open country data (the `region-defaults`
  /// function), else the built-in tables.
  Future<void> _fillDefaults() async {
    dismissKeyboard();
    _read();
    final name = f.country.trim();
    if (name.isEmpty) {
      showInfo(context, 'Enter the country first.');
      return;
    }
    setState(() => _filling = true);
    final api = await ref.read(geoAdminRepositoryProvider).regionDefaults(name);
    if (!mounted) return;
    final filled = applyRegionDefaults(f, api);
    setState(() {
      _filling = false;
      for (final k in const [
        'currencyName', 'currencySymbol', 'callingCode', 'emergencyNumber', 'languageCode', 'dateFormat',
        'timezone', 'lat', 'lng',
      ]) {
        _c[k]!.text = switch (k) {
          'currencyName' => f.currencyName,
          'currencySymbol' => f.currencySymbol,
          'callingCode' => f.callingCode,
          'emergencyNumber' => f.emergencyNumber,
          'languageCode' => f.languageCode,
          'dateFormat' => f.dateFormat,
          'timezone' => f.timezone,
          'lat' => f.lat,
          _ => f.lng,
        };
      }
    });
    showInfo(
      context,
      filled.isEmpty
          ? 'No details found for "$name". Check the spelling, or fill them in by hand.'
          : '${api == null ? 'Filled from the built-in list' : 'Filled'}: ${filled.join(', ')}.',
    );
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _read() {
    String t(String k) => _c[k]!.text;
    f
      ..country = t('country')
      ..state = t('state')
      ..city = t('city')
      ..suburb = t('suburb')
      ..lat = t('lat')
      ..lng = t('lng')
      ..currencyName = t('currencyName')
      ..currencySymbol = t('currencySymbol')
      ..emergencyNumber = t('emergencyNumber')
      ..callingCode = t('callingCode')
      ..languageCode = t('languageCode')
      ..dateFormat = t('dateFormat')
      ..timezone = t('timezone')
      ..taxName = t('taxName')
      ..taxAmount = t('taxAmount')
      ..handoverShare = t('handoverShare');
  }

  void _submit() {
    dismissKeyboard();
    _read();
    final err =
        validateRegionForm(widget.level, country: f.country, state: f.state, city: f.city, suburb: f.suburb) ??
        (f.setsPricing
            ? regionPricingProblem(
                taxEnabled: f.taxEnabled,
                taxName: f.taxName,
                taxKind: RegionTax.kindFrom(f.taxKind),
                taxAmount: f.taxAmount,
              )
            : null) ??
        handoverShareProblem(f.handoverShare);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    // Older apps read only the list of master services on here.
    final masters = ref.read(regionServicesProvider).value ?? const <ServiceOption>[];
    f.settleServicesForOlderApps([for (final s in masters) s.id], widget.above);
    Navigator.pop(context, f);
  }

  Widget _field(String key, String label, {String? hint, TextInputType? keyboard}) => TextField(
        controller: _c[key],
        decoration: InputDecoration(labelText: label, hintText: hint),
        keyboardType: keyboard,
        onChanged: (_) => setState(_read),
      );

  Widget _pair(Widget a, Widget b) => Row(children: [Expanded(child: a), const SizedBox(width: 12), Expanded(child: b)]);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final services = ref.watch(regionServicesProvider).value ?? const <ServiceOption>[];
    final tree = ref.watch(serviceTreeProvider).value;
    final rootById = {for (final n in tree?.roots ?? const <ServiceNode>[]) n.id: n};
    final masterIds = [for (final s in services) s.id];
    final levels = [f.switchLevel(), ...widget.above];
    bool isMaster(String id) => rootById.containsKey(id);
    String nameOf(String id) =>
        tree?.all.where((n) => n.id == id).firstOrNull?.entry.name ??
        services.where((s) => s.id == id).firstOrNull?.name ??
        id;
    // A sub-service and what sits under it, indented by depth, each with its
    // own Inherit / On / Off, and what holds here and where it comes from.
    Iterable<Widget> subTree(ServiceNode n) sync* {
      final verdict = resolveServiceSwitch(n.id, levels, master: false);
      var status = serviceSwitchSource(verdict, widget.above);
      if (verdict.on && tree != null) {
        final line = tree.lineage(n.id);
        if (!serviceOffered(line, levels, isMaster: isMaster)) {
          final off = line.skip(1).where((id) => !resolveServiceSwitch(id, levels, master: isMaster(id)).on).firstOrNull;
          status = off == null ? 'Off (a service above it is off)' : 'Off (under ${nameOf(off)}, which is off)';
        }
      }
      yield Padding(
        padding: EdgeInsets.only(left: 20.0 * n.depth),
        child: _ServiceSwitchRow(
          key: ValueKey('region-sub-${n.id}-${n.depth}'),
          id: n.id,
          title: n.entry.name,
          detail: n.entry.category != 'vehicle-services' ? n.entry.category : null,
          sub: true,
          value: ServiceSwitch.of(f.subServices[n.id]),
          status: status,
          on: !status.startsWith('Off'),
          onChanged: (v) => setState(() => f.setSubSwitch(n.id, v)),
        ),
      );
      for (final c in n.children) {
        yield* subTree(c);
      }
    }

    const gap = SizedBox(height: 12);
    final on = masterIds.where((id) => resolveServiceSwitch(id, levels, master: true).on).length;
    final parentLine = regionParentLine(f, widget.level);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (parentLine.isNotEmpty) ...[
        Row(children: [
          Icon(Icons.place_outlined, size: 16, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(parentLine,
                key: const ValueKey('region-parent'),
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
        ]),
        gap,
      ],
      switch (widget.level) {
        RegionLevel.country => _field('country', 'Country', hint: 'e.g. Malaysia'),
        RegionLevel.state => _field('state', 'State', hint: 'e.g. Selangor'),
        RegionLevel.city => _field('city', 'City', hint: 'e.g. Petaling Jaya'),
        RegionLevel.suburb => _field('suburb', 'Suburb', hint: 'e.g. Bangsar'),
      },
      if (widget.level == RegionLevel.country) ...[
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: Text('Country information', style: t.textTheme.titleSmall)),
          _filling
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : TextButton(
                  key: const ValueKey('region-fill-defaults'),
                  onPressed: _fillDefaults,
                  child: const Text('Fill defaults'),
                ),
        ]),
        gap,
        _pair(_field('currencyName', 'Currency name', hint: 'e.g. MYR'),
            _field('currencySymbol', 'Currency symbol', hint: 'e.g. RM')),
        gap,
        _pair(_field('emergencyNumber', 'Emergency number', hint: 'e.g. 999', keyboard: TextInputType.phone),
            _field('callingCode', 'Calling code', hint: 'e.g. +60', keyboard: TextInputType.phone)),
        gap,
        _pair(_field('languageCode', 'Language code', hint: 'e.g. en-MY'),
            _field('dateFormat', 'Date format', hint: 'e.g. DD/MM/YYYY')),
      ],
      if (widget.level != RegionLevel.suburb) ...[gap, _field('timezone', 'Time zone', hint: 'e.g. Asia/Kuala_Lumpur')],
      const SizedBox(height: 12),
      SwitchListTile(
        key: const ValueKey('region-blocked'),
        contentPadding: EdgeInsets.zero,
        secondary: Icon(Icons.block, color: f.blocked ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
        title: const Text('Block'),
        subtitle: Text(switch (f.blocked ? f.blockAt : RegionBlock.none) {
          RegionBlock.none => 'Open: rides can start, stop and end here.',
          RegionBlock.pickup =>
            "Pickups blocked: no ride starts here. Rides from elsewhere can still stop and end here. "
                'Covers everything inside it.',
          RegionBlock.drop =>
            "Drop-offs blocked: rides can start here, but none stops or ends here. Covers everything inside it.",
          RegionBlock.both =>
            "Blocked: riders can't start, stop or end a ride here — the app says GET.ride is unavailable. "
                'Covers everything inside it.',
        }),
        value: f.blocked,
        onChanged: (v) => setState(() => f.blocked = v),
      ),
      if (f.blocked)
        Padding(
          padding: const EdgeInsets.only(left: 40, bottom: 4),
          child: SegmentedButton<RegionBlock>(
            key: const ValueKey('region-block-at'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: RegionBlock.pickup, label: Text('Pickup'), icon: Icon(Icons.hail)),
              ButtonSegment(value: RegionBlock.drop, label: Text('Drop-off'), icon: Icon(Icons.flag_outlined)),
              ButtonSegment(value: RegionBlock.both, label: Text('Both'), icon: Icon(Icons.block)),
            ],
            selected: {f.blockAt},
            onSelectionChanged: (v) => setState(() => f.blockAt = v.first),
          ),
        ),
      const SizedBox(height: 8),
      Row(children: [
        Icon(Icons.build_outlined, size: 16, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(child: Text('Services', style: t.textTheme.titleSmall)),
        Text('$on/${services.length} on', style: t.textTheme.bodySmall),
      ]),
      if (services.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            f.isCountryRow
                ? 'Inherit: on, unless a rule says otherwise. Off: the app shows it as coming soon here, and '
                    'the service check (Regions page) can refuse bookings for it.'
                : 'Inherit follows ${widget.above.isEmpty ? 'the region above' : widget.above.first.name}. '
                    'On or Off decides here and in the regions inside this one that inherit.',
            key: const ValueKey('region-services-note'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
      if (services.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('No services defined yet. Add some in Service Settings.', style: t.textTheme.bodySmall),
        )
      else
        for (final s in services) ...[
          Builder(builder: (_) {
            final verdict = resolveServiceSwitch(s.id, levels, master: true);
            return _ServiceSwitchRow(
              key: ValueKey('region-service-${s.id}'),
              id: s.id,
              title: s.name,
              detail: s.description.isEmpty ? null : s.description,
              value: ServiceSwitch.of(levels.first.say(s.id, master: true)),
              status: serviceSwitchSource(verdict, widget.above),
              on: verdict.on,
              onChanged: (v) => setState(() => f.setMasterSwitch(s.id, v, masterIds)),
            );
          }),
          // Its sub-services, to any depth (core/service_tree.dart), each
          // switched on or off here on its own.
          for (final c in rootById[s.id]?.children ?? const <ServiceNode>[]) ...subTree(c),
        ],
      if (tree != null && tree.unlinked.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Sub-services under no master service', style: t.textTheme.labelMedium),
        ),
        for (final n in tree.unlinked) ...subTree(n),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Bidding (OfferMe)'),
        subtitle: Text(f.biddingEnabled
            ? 'Riders & drivers can raise/lower the fare in this region.'
            : 'Fare is locked to the recommended price — no +/- in this region.'),
        value: f.biddingEnabled,
        onChanged: (v) => setState(() => f.biddingEnabled = v),
      ),
      const SizedBox(height: 20),
      Row(children: [
        Icon(Icons.payments_outlined, size: 16, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(child: Text('Fare pricing', style: t.textTheme.titleSmall)),
      ]),
      if (!f.isCountryRow)
        SwitchListTile(
          key: const ValueKey('region-pricing-override'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Own fare pricing'),
          subtitle: Text(f.pricingOverride
              ? 'This region sets its own decimals and tax.'
              : 'Uses the decimals and tax of the region above it.'),
          value: f.pricingOverride,
          onChanged: (v) => setState(() => f.pricingOverride = v),
        ),
      if (f.setsPricing) ...[
        SwitchListTile(
          key: const ValueKey('region-whole-fare'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Price without decimals'),
          subtitle: Text(f.wholeFare
              ? 'Booking fares round up to a whole amount; no decimals are shown or typed. Tolls and other '
                  'charges keep their decimals. Meter Digital keeps its own rate cards.'
              : 'Booking fares are shown and typed with decimals.'),
          value: f.wholeFare,
          onChanged: (v) => setState(() => f.wholeFare = v),
        ),
        SwitchListTile(
          key: const ValueKey('region-tax'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Tax'),
          subtitle: Text(f.taxEnabled ? 'Added on top of the fare.' : 'No tax on fares in this region.'),
          value: f.taxEnabled,
          onChanged: (v) => setState(() => f.taxEnabled = v),
        ),
        if (f.taxEnabled) ...[
          _field('taxName', 'Tax name', hint: 'e.g. SST'),
          gap,
          SegmentedButton<String>(
            key: const ValueKey('region-tax-kind'),
            segments: const [
              ButtonSegment(value: 'percent', label: Text('% of fare'), icon: Icon(Icons.percent)),
              ButtonSegment(value: 'fixed', label: Text('Fixed amount'), icon: Icon(Icons.attach_money)),
            ],
            selected: {f.taxKind},
            onSelectionChanged: (v) => setState(() => f.taxKind = v.first),
          ),
          gap,
          _field(
            'taxAmount',
            f.taxKind == 'percent' ? 'Tax (%)' : 'Tax amount',
            hint: f.taxKind == 'percent' ? 'e.g. 6' : 'e.g. 1.50',
            keyboard: const TextInputType.numberWithOptions(decimal: true),
          ),
        ],
      ],
      const SizedBox(height: 20),
      RegionRulesSection(rules: f.rules, onChanged: (rules) => setState(() => f.rules = rules)),
      gap,
      // Trip handover (0199): the share passed back to the first driver.
      _field(
        'handoverShare',
        'Handover share (%)',
        hint: 'Blank: as the region above, or App Settings',
        keyboard: const TextInputType.numberWithOptions(decimal: true),
      ),
      gap,
      _pair(
        _field('lat', 'Latitude', keyboard: const TextInputType.numberWithOptions(decimal: true, signed: true)),
        _field('lng', 'Longitude', keyboard: const TextInputType.numberWithOptions(decimal: true, signed: true)),
      ),
      if (_error != null) ...[
        gap,
        Text(_error!, style: TextStyle(color: t.colorScheme.error)),
      ],
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _submit,
        icon: const Icon(Icons.check),
        label: Text(widget.editing ? 'Update' : 'Save'),
      ),
    ]);
  }
}

/// One service in the region editor: its name, what holds here and where
/// it comes from ("On (from Selangor)"), and Inherit / On / Off.
class _ServiceSwitchRow extends StatelessWidget {
  const _ServiceSwitchRow({
    super.key,
    required this.id,
    required this.title,
    required this.value,
    required this.status,
    required this.on,
    required this.onChanged,
    this.detail,
    this.sub = false,
  });

  final String id;
  final String title;
  final String? detail;
  final bool sub;
  final ServiceSwitch value;
  final String status;
  final bool on;
  final ValueChanged<ServiceSwitch> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final colour = on ? scheme.primary : scheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (sub) ...[
            Icon(Icons.subdirectory_arrow_right, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.textTheme.bodyLarge),
              if (detail != null)
                Text(detail!, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Row(children: [
                Icon(on ? Icons.check_circle_outline : Icons.block, size: 16, color: colour),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(status,
                      key: ValueKey('region-switch-status-$id'),
                      style: t.textTheme.labelMedium?.copyWith(color: colour, fontWeight: FontWeight.w600)),
                ),
              ]),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: SegmentedButton<ServiceSwitch>(
            key: ValueKey('region-switch-$id'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: [
              for (final v in ServiceSwitch.values) ButtonSegment(value: v, label: Text(v.label)),
            ],
            selected: {value},
            onSelectionChanged: (v) => onChanged(v.first),
          ),
        ),
      ]),
    );
  }
}

/// Admin → Regions → Service check (migration 0302): what the server does
/// with a booking whose service is off at its pickup, with the counts and
/// the latest bookings it kept.
class _ServiceCheckCard extends ConsumerWidget {
  const _ServiceCheckCard({required this.canEdit});

  /// EDIT on the Regions page.
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final async = ref.watch(regionServiceCheckProvider);
    final check = async.value;
    final editable = canEdit && (check?.canEdit ?? false);
    Future<void> set(RegionCheckMode m) async {
      final ok = await runAdminAction(
        context,
        () => ref.read(geoAdminRepositoryProvider).setRegionServiceCheck(m),
        success: 'Service check: ${m.label}',
      );
      if (ok) ref.invalidate(regionServiceCheckProvider);
    }

    return Card(
      key: const ValueKey('region-service-check'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.fact_check_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text('Service check', style: t.textTheme.titleSmall)),
          ]),
          const SizedBox(height: 4),
          Text(
            'When a rider books a service that is off at the pickup (an older app, or a direct call).',
            style: t.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          if (async.isLoading && check == null)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (check == null)
            Text("Can't read the service check right now.", style: t.textTheme.bodySmall)
          else ...[
            SegmentedButton<RegionCheckMode>(
              key: const ValueKey('region-service-check-mode'),
              showSelectedIcon: false,
              segments: [
                for (final m in RegionCheckMode.values) ButtonSegment(value: m, label: Text(m.label)),
              ],
              selected: {check.mode},
              onSelectionChanged: editable ? (v) => set(v.first) : null,
            ),
            const SizedBox(height: 8),
            Text(check.mode.explanation, key: const ValueKey('region-service-check-explanation'), style: t.textTheme.bodyMedium),
            const SizedBox(height: 6),
            Text(
              'Recorded: ${check.day} in 24 hours · ${check.week} in 7 days · ${check.month} in 30 days',
              key: const ValueKey('region-service-check-counts'),
              style: t.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (!editable)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Only an admin who can edit Regions can change it.',
                    style: t.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ExpansionTile(
              key: const ValueKey('region-service-check-latest'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text('Latest recorded (${check.recent.length})', style: t.textTheme.labelLarge),
              children: [
                if (check.recent.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('None yet.', style: t.textTheme.bodySmall),
                  ),
                for (final r in check.recent)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(r.refused ? Icons.block : Icons.visibility_outlined,
                        color: r.refused ? scheme.error : scheme.onSurfaceVariant),
                    title: Text(r.service),
                    subtitle: Text([
                      formatDateTime(r.at),
                      if (r.place.isNotEmpty) r.place,
                      if (r.later) 'Booked for later',
                    ].join(' · ')),
                    trailing: Text(r.refused ? 'Refused' : 'Recorded',
                        style: t.textTheme.labelSmall?.copyWith(color: r.refused ? scheme.error : scheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}
