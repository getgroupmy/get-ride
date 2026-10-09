import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/region_pricing.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'boundary_editor.dart';
import 'geo_data.dart';
import 'geo_logic.dart';

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
    final form = await showAdminSheet<RegionForm>(
      context,
      title: entry != null ? 'Edit region' : 'Add ${regionLevelLabel(level)}',
      builder: (_) => _RegionFormBody(initial: initial, level: level, editing: entry != null),
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

  void _map(RegionRow r, bool canEdit) {
    final repo = ref.read(geoAdminRepositoryProvider);
    final entry = r.entry;
    final stored = r.boundary;
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
        onClear: entry == null || stored == null
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
          onPressed: () => ref.invalidate(regionsProvider),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
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
                          ActionChip(label: Text(_country), onPressed: () => _select(state: '', city: '')),
                          if (_state.isNotEmpty) ...[
                            const Icon(Icons.chevron_right, size: 16),
                            ActionChip(label: Text(_state), onPressed: () => _select(city: '')),
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
                  onChanged: (v) => setState(() => _query = v),
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
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) => _RegionTile(
                          row: rows[i],
                          canEdit: canEdit,
                          onOpen: () => _open(rows[i]),
                          onMap: () => _map(rows[i], canEdit),
                          onEdit: () => _edit(entries, row: rows[i]),
                          onDelete: () => _delete(rows[i]),
                        ),
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
  });
  final RegionRow row;
  final bool canEdit;
  final VoidCallback onOpen, onMap;
  final Future<void> Function() onEdit, onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final custom = row.entry != null;
    final hasBoundary = row.boundary != null;
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
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Text(text, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
        );
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: custom ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        child: Icon(icon, color: custom ? scheme.primary : scheme.onSurfaceVariant, size: 20),
      ),
      title: Row(children: [
        Flexible(child: Text(row.name, overflow: TextOverflow.ellipsis)),
        if (custom) badge('Custom', scheme.primary),
        if (hasBoundary) badge('Boundary', Colors.teal),
      ]),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      onTap: row.level == RegionLevel.suburb ? null : onOpen,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
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
  const _RegionFormBody({required this.initial, required this.level, required this.editing});
  final RegionForm initial;
  final RegionLevel level;
  final bool editing;

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
  };
  String? _error;
  bool _filling = false;

  /// Country information from open country data (the `region-defaults`
  /// function), else the built-in tables.
  Future<void> _fillDefaults() async {
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
      ..taxAmount = t('taxAmount');
  }

  void _submit() {
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
            : null);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
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
    const gap = SizedBox(height: 12);
    final on = f.services.values.where((v) => v).length;
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
      const SizedBox(height: 20),
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
            on == 0
                ? f.isCountryRow
                    ? 'None on: every service is offered in this country.'
                    : 'None on: this region follows its parent\'s services.'
                : 'Only these are offered here; the app shows the others as coming soon.',
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
        for (final s in services)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.name),
            subtitle: s.description.isEmpty ? null : Text(s.description, maxLines: 1, overflow: TextOverflow.ellipsis),
            value: f.services[s.id] == true,
            onChanged: (v) => setState(() => f.services = {...f.services, s.id: v}),
          ),
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
