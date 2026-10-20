// Admin > People > Vehicle permits (migration 0254): per country, the
// vehicles with / without / on bypass / with an expired permit, the switch
// that makes permits required, the bypass length, the permit types, the
// plate colours, the expiry reminders and what expires soon. Every permit's
// words and fields come from the country's permit types; nothing here
// knows one country's permits.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/date_order.dart';
import '../../../core/permits.dart';
import '../../../data/permits_repository.dart';
import '../../../providers.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/permit_views.dart';
import '../../../widgets/plate_chip.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'permit_type_editor.dart';

/// The page key that grants this page.
const vehiclePermitsPage = 'admin-vehicle-permits';

// ---- Data ------------------------------------------------------------------------

/// Countries to pick from: the Countries table and any country with permits.
final adminPermitCountriesProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  final db = ref.watch(supabaseProvider);
  final rows = await db.from('countries').select('name').order('name', ascending: true);
  final types = await ref.watch(adminPermitTypesProvider.future);
  final names = <String>{
    for (final r in rows)
      if ('${r['name'] ?? ''}'.trim().isNotEmpty) '${r['name']}'.trim(),
    for (final t in types) t.country,
  };
  return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
});

final adminPermitTypesProvider = FutureProvider.autoDispose<List<PermitType>>(
  (ref) => ref.watch(permitsRepositoryProvider).permitTypes(),
);

final adminPermitSettingsProvider = FutureProvider.autoDispose<List<PermitCountrySettings>>(
  (ref) => ref.watch(permitsRepositoryProvider).countrySettings(),
);

final adminPermitVehiclesProvider = FutureProvider.autoDispose.family<List<VehiclePermits>, String>(
  (ref, country) => ref.watch(permitsRepositoryProvider).adminVehicles(country),
);

final adminReminderDaysProvider = FutureProvider.autoDispose<List<ReminderDays>>(
  (ref) => ref.watch(permitsRepositoryProvider).reminderDays(),
);

final adminExpiringDocsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(permitsRepositoryProvider).expiringDocuments(),
);

/// Required documents by id and name (a driver permit is uploaded as one;
/// each can have its own reminder days).
final adminRequiredDocsProvider = FutureProvider.autoDispose<List<({String id, String name})>>((ref) async {
  final rows = await ref.watch(supabaseProvider).from('required_document').select('id, values').order('position', ascending: true);
  return [
    for (final r in rows)
      (id: '${r['id']}', name: '${(r['values'] as Map?)?['name'] ?? (r['values'] as Map?)?['docName'] ?? 'Document'}'.trim()),
  ];
});

/// The partner types and vehicle services a permit type can name.
final adminPartnerTypeNamesProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  final rows = await ref.watch(supabaseProvider).from('settings_entries').select('values')
      .eq('category', 'partner-type').order('position', ascending: true);
  return [
    for (final r in rows)
      if ('${(r['values'] as Map?)?['name'] ?? ''}'.trim().isNotEmpty) '${(r['values'] as Map?)!['name']}'.trim(),
  ];
});

final adminVehicleServicesProvider = FutureProvider.autoDispose<List<({String id, String name})>>((ref) async {
  final rows = await ref.watch(supabaseProvider).from('settings_entries').select('id, values')
      .eq('category', 'vehicle-services').order('position', ascending: true);
  return [for (final r in rows) (id: '${r['id']}', name: '${(r['values'] as Map?)?['name'] ?? 'Unnamed'}'.trim())];
});

/// The vehicles in [status] of [all].
List<VehiclePermits> vehiclesIn(List<VehiclePermits> all, PermitStatus status) =>
    [for (final v in all) if (v.status == status) v];

/// The tabs, in order.
const permitTabs = [PermitStatus.withPermit, PermitStatus.without, PermitStatus.bypass, PermitStatus.expired];

/// The permit types an admin uploads for [v].
List<PermitType> uploadableTypes(VehiclePermits v, List<PermitType> types) => [
  for (final p in v.permits)
    for (final t in types)
      if (t.id == p.typeId && !t.forDriver && t.uploader != PermitUploader.driver) t,
];

// ---- The page -----------------------------------------------------------------------

class VehiclePermitsScreen extends ConsumerStatefulWidget {
  const VehiclePermitsScreen({super.key, this.initialCountry});
  final String? initialCountry;

  @override
  ConsumerState<VehiclePermitsScreen> createState() => _VehiclePermitsScreenState();
}

class _VehiclePermitsScreenState extends ConsumerState<VehiclePermitsScreen> {
  String? _country;
  PermitStatus _tab = PermitStatus.without;
  final _bypassDays = TextEditingController();
  String? _bypassFor;

  @override
  void dispose() {
    _bypassDays.dispose();
    super.dispose();
  }

  String? _pickDefault(List<PermitType> types, List<String> countries) =>
      widget.initialCountry ?? types.firstOrNull?.country ?? countries.firstOrNull;

  Future<void> _chooseCountry(List<String> countries) async {
    final picked = await showSearchPicker<String>(
      context,
      title: 'Country',
      selected: _country,
      choices: [for (final c in countries) (value: c, label: c, subtitle: null, leading: null)],
    );
    if (picked != null && mounted) setState(() => _country = picked);
  }

  void _refresh(String country) {
    ref.invalidate(adminPermitVehiclesProvider(country));
    ref.invalidate(adminPermitSettingsProvider);
    ref.invalidate(adminPermitTypesProvider);
  }

  Future<void> _saveSettings(String country, Map<String, dynamic> values, {String? success}) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(permitsRepositoryProvider).saveCountrySettings(country, values),
      success: success,
    );
    if (ok) ref.invalidate(adminPermitSettingsProvider);
  }

  Future<void> _bypass(String country, VehiclePermits v, bool on) async {
    final id = v.vehicleId;
    if (id == null) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(permitsRepositoryProvider).setBypass(id, on),
      success: on ? 'Bypass started for ${v.plate ?? 'the vehicle'}' : 'Bypass ended for ${v.plate ?? 'the vehicle'}',
    );
    if (ok) _refresh(country);
  }

  Future<void> _upload(String country, VehiclePermits v, List<PermitType> types) async {
    final choices = uploadableTypes(v, types);
    if (choices.isEmpty) return;
    var type = choices.first;
    if (choices.length > 1) {
      final picked = await showSearchPicker<PermitType>(
        context,
        title: 'Which permit?',
        choices: [for (final t in choices) (value: t, label: t.name, subtitle: t.issuer.isEmpty ? null : t.issuer, leading: null)],
      );
      if (picked == null || !mounted) return;
      type = picked;
    }
    final existing = v.permits.where((p) => p.typeId == type.id).firstOrNull;
    final saved = await showPermitUploadDialog(context, vehicle: v, type: type, existing: existing);
    if (saved == true) _refresh(country);
  }

  @override
  Widget build(BuildContext context) {
    final edit = ref.watch(pageAccessProvider(vehiclePermitsPage)) == AccessLevel.edit ||
        ref.watch(pageAccessProvider('admin-vehicles')) == AccessLevel.edit;
    final types = ref.watch(adminPermitTypesProvider);
    final countries = ref.watch(adminPermitCountriesProvider).value ?? const <String>[];
    final allTypes = types.value ?? const <PermitType>[];
    final country = _country ?? _pickDefault(allTypes, countries);
    final settingsRows = ref.watch(adminPermitSettingsProvider).value ?? const <PermitCountrySettings>[];
    final settings = settingsFor(settingsRows, country);
    if (country != null && _bypassFor != country) {
      _bypassFor = country;
      _bypassDays.text = '${settings.bypassDays}';
    }
    final countryTypes = [for (final t in allTypes) if (t.country.toLowerCase() == (country ?? '').toLowerCase()) t];
    final t = Theme.of(context);

    return AdminPage(
      title: 'Vehicle permits',
      page: vehiclePermitsPage,
      body: ResponsiveCenter(
        maxWidth: 900,
        child: ListView(
          key: const ValueKey('vehicle-permits'),
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Text('Country', style: t.textTheme.titleSmall),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  key: const ValueKey('permit-country'),
                  onPressed: countries.isEmpty ? null : () => _chooseCountry(countries),
                  icon: const Icon(Icons.public, size: 18),
                  label: Text(country ?? 'Choose'),
                ),
              ],
            ),
            if (country != null) ...[
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('permit-enforce'),
                      title: const Text('Require vehicle permits'),
                      subtitle: Text(settings.enforce
                          ? "Vehicles without a valid permit can't go online or take rides in $country."
                          : 'Off: vehicles without a permit still take rides. Turn on once permits are uploaded.'),
                      value: settings.enforce,
                      onChanged: edit
                          ? (v) => _saveSettings(country, {'enforce': v},
                              success: v ? 'Permits are now required in $country' : 'Permits are no longer required in $country')
                          : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Row(
                        children: [
                          const Expanded(child: Text('Bypass lasts')),
                          SizedBox(
                            width: 80,
                            child: TextField(
                              key: const ValueKey('permit-bypass-days'),
                              controller: _bypassDays,
                              enabled: edit,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              decoration: const InputDecoration(isDense: true, suffixText: 'days'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            key: const ValueKey('permit-bypass-days-save'),
                            onPressed: !edit
                                ? null
                                : () {
                                    final n = int.tryParse(_bypassDays.text.trim());
                                    if (n == null || n < 1 || n > 60) {
                                      showError(context, 'Enter 1 to 60 days.');
                                      return;
                                    }
                                    _saveSettings(country, {'bypass_days': n}, success: 'Bypass is now $n days');
                                  },
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Bypass: the vehicle can take rides for ${settings.bypassDays} days without a permit, and passengers '
                "see no permit. When it ends, the vehicle goes back to Without.",
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              _VehicleList(
                country: country,
                types: allTypes,
                tab: _tab,
                bypassDays: settings.bypassDays,
                edit: edit,
                onTab: (s) => setState(() => _tab = s),
                onBypass: (v, on) => _bypass(country, v, on),
                onUpload: (v) => _upload(country, v, allTypes),
              ),
              const SizedBox(height: 24),
              Text('Settings for $country', style: t.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      key: const ValueKey('permit-types-open'),
                      leading: const Icon(Icons.badge_outlined),
                      title: const Text('Permit types'),
                      subtitle: Text(countryTypes.isEmpty
                          ? 'None yet'
                          : countryTypes.map((e) => e.shortName.isNotEmpty ? e.shortName : e.name).join(', ')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(AppPageRoute<void>(
                        id: 'vehicle-permits.permit-types',
                        builder: (_) => PermitTypesPage(country: country),
                      )),
                    ),
                    ListTile(
                      key: const ValueKey('plate-colours-open'),
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('Plate colours'),
                      subtitle: Text(settings.plateColours == null ? 'Default colours' : 'Colours of their own'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(AppPageRoute<void>(
                        id: 'vehicle-permits.plate-colours',
                        builder: (_) => PlateColoursPage(country: country),
                      )),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  ListTile(
                    key: const ValueKey('expiry-reminders-open'),
                    leading: const Icon(Icons.notifications_active_outlined),
                    title: const Text('Expiry reminders'),
                    subtitle: const Text('Days before a document or permit expires that its holder is reminded'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(AppPageRoute<void>(
                      id: 'vehicle-permits.expiry-reminders',
                      builder: (_) => const ExpiryRemindersPage(),
                    )),
                  ),
                  ListTile(
                    key: const ValueKey('expiring-soon-open'),
                    leading: const Icon(Icons.event_busy_outlined),
                    title: const Text('Expiring soon'),
                    subtitle: const Text('Documents and permits that expire in the coming weeks'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(AppPageRoute<void>(
                      id: 'vehicle-permits.expiring-soon',
                      builder: (_) => const ExpiringSoonPage(),
                    )),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The tabs and the vehicles in the chosen one.
class _VehicleList extends ConsumerWidget {
  const _VehicleList({
    required this.country,
    required this.types,
    required this.tab,
    required this.bypassDays,
    required this.edit,
    required this.onTab,
    required this.onBypass,
    required this.onUpload,
  });

  final String country;
  final List<PermitType> types;
  final PermitStatus tab;
  final int bypassDays;
  final bool edit;
  final ValueChanged<PermitStatus> onTab;
  final void Function(VehiclePermits v, bool on) onBypass;
  final ValueChanged<VehiclePermits> onUpload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminPermitVehiclesProvider(country));
    final all = async.value ?? const <VehiclePermits>[];
    final shown = vehiclesIn(all, tab);
    final today = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in permitTabs)
              ChoiceChip(
                key: ValueKey('permit-tab-${s.wire}'),
                label: Text('${s.label} (${vehiclesIn(all, s).length})'),
                selected: s == tab,
                onSelected: (_) => onTab(s),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (async.isLoading && all.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (async.hasError)
          Text(errorText(async.error!))
        else if (shown.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('None.', key: ValueKey('permit-list-empty')))
        else
          ListSearchFilter(
            count: shown.length,
            hint: 'Search plate or car',
            builder: (context, q) => Column(
              children: [
                for (final v in shown)
                  if (q.isEmpty || searchSelectMatches('${v.plate ?? ''} ${v.label ?? ''}', q))
                    VehiclePermitRow(
                      vehicle: v,
                      today: today,
                      bypassDays: bypassDays,
                      canUpload: uploadableTypes(v, types).isNotEmpty,
                      edit: edit,
                      onBypass: (on) => onBypass(v, on),
                      onUpload: () => onUpload(v),
                      onOpen: v.vehicleId == null
                          ? null
                          : () => GoRouter.maybeOf(context)?.push('/admin/m/vehicle-edit?id=${v.vehicleId}'),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One vehicle in the list: plate, car, note, actions.
class VehiclePermitRow extends StatelessWidget {
  const VehiclePermitRow({
    super.key,
    required this.vehicle,
    required this.today,
    required this.bypassDays,
    required this.canUpload,
    required this.edit,
    required this.onBypass,
    required this.onUpload,
    this.onOpen,
  });

  final VehiclePermits vehicle;
  final DateTime today;
  final int bypassDays;
  final bool canUpload;
  final bool edit;
  final ValueChanged<bool> onBypass;
  final VoidCallback onUpload;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final v = vehicle;
    final note = permitListNote(
      status: v.status,
      permits: v.permits,
      bypassUntil: v.bypassUntil,
      joinedAt: v.joinedAt,
      today: today,
    );
    final warn = t.brightness == Brightness.dark ? const Color(0xFFF4C95D) : const Color(0xFF8A5A00);
    return Card(
      key: ValueKey('permit-row-${v.vehicleId}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if ((v.plate ?? '').isNotEmpty) ...[
                  PlateChip(plate: v.plate!, fontSize: 13, colours: v.colours),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(v.label ?? '', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      Text(
                        note.text,
                        key: ValueKey('permit-note-${v.vehicleId}'),
                        style: t.textTheme.bodySmall?.copyWith(color: note.highlight ? warn : t.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (v.status == PermitStatus.bypass && edit)
                  OutlinedButton(
                    key: ValueKey('permit-end-bypass-${v.vehicleId}'),
                    onPressed: () => onBypass(false),
                    child: const Text('End bypass'),
                  ),
                if ((v.status == PermitStatus.without || v.status == PermitStatus.expired) && edit)
                  OutlinedButton(
                    key: ValueKey('permit-bypass-${v.vehicleId}'),
                    onPressed: () => onBypass(true),
                    child: Text('Bypass $bypassDays ${bypassDays == 1 ? 'day' : 'days'}'),
                  ),
                if (canUpload && edit)
                  FilledButton(
                    key: ValueKey('permit-upload-${v.vehicleId}'),
                    onPressed: onUpload,
                    child: Text(v.status == PermitStatus.withPermit ? 'Upload new' : 'Upload permit'),
                  ),
                if (onOpen != null)
                  TextButton(key: ValueKey('permit-open-${v.vehicleId}'), onPressed: onOpen, child: const Text('Open')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Expiry reminders ------------------------------------------------------------------

/// Admin > Vehicle permits > Expiry reminders: the default days, and any
/// country, permit type or document with days of its own (empty: the default).
class ExpiryRemindersPage extends ConsumerWidget {
  const ExpiryRemindersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edit = ref.watch(pageAccessProvider(vehiclePermitsPage)) == AccessLevel.edit;
    final rows = ref.watch(adminReminderDaysProvider);
    final types = ref.watch(adminPermitTypesProvider).value ?? const <PermitType>[];
    final docs = ref.watch(adminRequiredDocsProvider).value ?? const <({String id, String name})>[];
    final countries = ref.watch(adminPermitCountriesProvider).value ?? const <String>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Expiry reminders')),
      body: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(errorText(e))),
        data: (list) => ExpiryRemindersEditor(
          rows: list,
          types: types,
          documents: docs,
          countries: countries,
          edit: edit,
          onSave: (scope, key, days) async {
            final ok = await runAdminAction(
              context,
              () => ref.read(permitsRepositoryProvider).saveReminderDays(scope, key, days),
              success: 'Reminder days saved',
            );
            if (ok) ref.invalidate(adminReminderDaysProvider);
            return ok;
          },
        ),
      ),
    );
  }
}

/// The editor itself (tested on its own).
class ExpiryRemindersEditor extends StatefulWidget {
  const ExpiryRemindersEditor({
    super.key,
    required this.rows,
    required this.onSave,
    this.types = const [],
    this.documents = const [],
    this.countries = const [],
    this.edit = true,
  });

  final List<ReminderDays> rows;
  final List<PermitType> types;
  final List<({String id, String name})> documents;
  final List<String> countries;
  final bool edit;
  final Future<bool> Function(ReminderScope scope, String key, List<int> days) onSave;

  @override
  State<ExpiryRemindersEditor> createState() => _ExpiryRemindersEditorState();
}

class _ExpiryRemindersEditorState extends State<ExpiryRemindersEditor> {
  String _label(ReminderDays r) => switch (r.scope) {
    ReminderScope.defaultDays => 'Default',
    ReminderScope.country => r.scopeKey,
    ReminderScope.permitType =>
      widget.types.where((t) => t.id == r.scopeKey).map((t) => '${t.name} (${t.country})').firstOrNull ?? 'Permit type',
    ReminderScope.document => widget.documents.where((d) => d.id == r.scopeKey).map((d) => d.name).firstOrNull ?? 'Document',
  };

  Future<void> _editDays(ReminderScope scope, String key, String title, List<int>? current) async {
    final days = await showAppDialog<List<int>>(
      id: 'vehicle-permits.reminder-days',
      context: context,
      builder: (_) => ReminderDaysDialog(title: title, initial: current ?? const [], allowEmpty: scope != ReminderScope.defaultDays),
    );
    if (days == null) return;
    await widget.onSave(scope, key, days);
  }

  Future<void> _add() async {
    final choices = <SearchChoice<(ReminderScope, String, String)>>[
      for (final c in widget.countries) (value: (ReminderScope.country, c, c), label: c, subtitle: 'Country', leading: null),
      for (final t in widget.types)
        if (t.id != null)
          (value: (ReminderScope.permitType, t.id!, t.name), label: t.name, subtitle: 'Permit type · ${t.country}', leading: null),
      for (final d in widget.documents)
        (value: (ReminderScope.document, d.id, d.name), label: d.name, subtitle: 'Document', leading: null),
    ];
    final picked = await showSearchPicker(context, title: 'Days of its own for', choices: choices);
    if (picked == null || !mounted) return;
    await _editDays(picked.$1, picked.$2, picked.$3, null);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final def = widget.rows.where((r) => r.scope == ReminderScope.defaultDays).firstOrNull;
    final own = widget.rows.where((r) => r.scope != ReminderScope.defaultDays).toList();
    return ListView(
      key: const ValueKey('expiry-reminders'),
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'A reminder goes to the driver (push and Notifications) this many days before a document or permit '
          'expires, and on the day it expires. Each is sent once.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            key: const ValueKey('reminder-default'),
            title: const Text('Default'),
            subtitle: Text(def == null || def.days.isEmpty ? 'None' : '${reminderDaysText(def.days)} days before'),
            trailing: widget.edit ? const Icon(Icons.edit_outlined) : null,
            onTap: widget.edit
                ? () => _editDays(ReminderScope.defaultDays, '', 'Default reminder days', def?.days)
                : null,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Text('Days of their own', style: t.textTheme.titleSmall)),
            if (widget.edit)
              TextButton.icon(
                key: const ValueKey('reminder-add'),
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
          ],
        ),
        if (own.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('None: every document uses the default.')),
        for (final r in own)
          Card(
            child: ListTile(
              key: ValueKey('reminder-${r.scope.wire}-${r.scopeKey}'),
              title: Text(_label(r)),
              subtitle: Text('${r.scope.label} · ${reminderDaysText(r.days)} days before'),
              trailing: widget.edit
                  ? IconButton(
                      key: ValueKey('reminder-remove-${r.scope.wire}-${r.scopeKey}'),
                      tooltip: 'Use the default',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => widget.onSave(r.scope, r.scopeKey, const []),
                    )
                  : null,
              onTap: widget.edit ? () => _editDays(r.scope, r.scopeKey, _label(r), r.days) : null,
            ),
          ),
      ],
    );
  }
}

/// Edits one list of days: each day a chip to remove, a box to add one.
class ReminderDaysDialog extends StatefulWidget {
  const ReminderDaysDialog({super.key, required this.title, required this.initial, this.allowEmpty = true});
  final String title;
  final List<int> initial;
  final bool allowEmpty;

  @override
  State<ReminderDaysDialog> createState() => _ReminderDaysDialogState();
}

class _ReminderDaysDialogState extends State<ReminderDaysDialog> {
  late List<int> _days = [...widget.initial]..sort((a, b) => b.compareTo(a));
  final _add = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  void _addDays() {
    final r = parseReminderDays('${_add.text} ${_days.join(' ')}');
    setState(() {
      _error = r.error;
      if (r.days != null) {
        _days = r.days!;
        _add.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in _days)
                InputChip(
                  key: ValueKey('reminder-day-$d'),
                  label: Text('$d ${d == 1 ? 'day' : 'days'}'),
                  onDeleted: () => setState(() => _days.remove(d)),
                ),
              if (_days.isEmpty) Text(widget.allowEmpty ? 'None: the default applies.' : 'No reminders.'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('reminder-day-input'),
                  controller: _add,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: 'Add days', hintText: 'e.g. 60', errorText: _error),
                  onSubmitted: (_) => _addDays(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                key: const ValueKey('reminder-day-add'),
                tooltip: 'Add',
                onPressed: _addDays,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const ValueKey('reminder-days-save'),
        onPressed: () => Navigator.pop(context, _days),
        child: const Text('Save'),
      ),
    ],
  );
}

// ---- Expiring soon -------------------------------------------------------------------------

class ExpiringSoonPage extends ConsumerWidget {
  const ExpiringSoonPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(adminExpiringDocsProvider);
    final today = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Expiring soon')),
      body: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(errorText(e))),
        data: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.event_available_outlined, title: 'Nothing expires soon')
            : ListSearchFilter(
                count: list.length,
                hint: 'Search name, plate or holder',
                builder: (context, q) => ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final r in list)
                      if (q.isEmpty || searchSelectMatches('${r['name']} ${r['plate'] ?? ''} ${r['holder'] ?? ''}', q))
                        Card(
                          child: ListTile(
                            title: Text('${r['name'] ?? 'Document'}${r['plate'] == null ? '' : ' · ${r['plate']}'}'),
                            subtitle: Text([
                              if ('${r['holder'] ?? ''}'.isNotEmpty) '${r['holder']}',
                              _expiresText(r['expiry_date'], today),
                              if ((r['sent'] as List?)?.isNotEmpty ?? false)
                                'reminded ${(r['sent'] as List).join(', ')} days before',
                            ].join(' · ')),
                            onTap: r['vehicle_id'] != null
                                ? () => GoRouter.maybeOf(context)?.push('/admin/m/vehicle-edit?id=${r['vehicle_id']}')
                                : (r['partner_id'] != null
                                    ? () => GoRouter.maybeOf(context)?.push('/admin/m/partner-edit?id=${r['partner_id']}')
                                    : null),
                          ),
                        ),
                  ],
                ),
              ),
      ),
    );
  }

  static String _expiresText(Object? date, DateTime today) {
    final d = DateTime.tryParse('${date ?? ''}');
    final n = daysUntil(d, today);
    if (n == null) return '';
    if (n < 0) return 'expired ${formatDateForUser(d)}';
    if (n == 0) return 'expires today';
    return 'expires in $n ${n == 1 ? 'day' : 'days'} (${formatDateForUser(d)})';
  }
}

// ---- One vehicle (on its edit page) -----------------------------------------------------------

final adminVehiclePermitCardProvider = FutureProvider.autoDispose.family<VehiclePermits?, String>(
  (ref, id) => ref.watch(permitsRepositoryProvider).adminVehicle(id),
);

/// The vehicle's permits on Admin > Vehicle: status, each permit with View,
/// and Upload / Bypass / End bypass.
class VehiclePermitsSection extends ConsumerWidget {
  const VehiclePermitsSection({super.key, required this.vehicleId, this.canEdit = true});
  final String vehicleId;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(adminVehiclePermitCardProvider(vehicleId)).value;
    if (v == null || v.permits.isEmpty) return const SizedBox.shrink();
    final types = ref.watch(adminPermitTypesProvider).value ?? const <PermitType>[];
    final rows = ref.watch(adminPermitSettingsProvider).value ?? const <PermitCountrySettings>[];
    final days = settingsFor(rows, v.countries.firstOrNull).bypassDays;
    final today = DateTime.now();
    void reload() {
      ref.invalidate(adminVehiclePermitCardProvider(vehicleId));
      for (final c in v.countries) {
        ref.invalidate(adminPermitVehiclesProvider(c));
      }
    }

    Future<void> bypass(bool on) async {
      final ok = await runAdminAction(context, () => ref.read(permitsRepositoryProvider).setBypass(vehicleId, on),
          success: on ? 'Bypass started' : 'Bypass ended');
      if (ok) reload();
    }

    Future<void> upload() async {
      final choices = uploadableTypes(v, types);
      if (choices.isEmpty) return;
      var type = choices.first;
      if (choices.length > 1) {
        final picked = await showSearchPicker<PermitType>(
          context,
          title: 'Which permit?',
          choices: [for (final t in choices) (value: t, label: t.name, subtitle: null, leading: null)],
        );
        if (picked == null || !context.mounted) return;
        type = picked;
      }
      if (!context.mounted) return;
      final saved = await showPermitUploadDialog(context, vehicle: v, type: type,
          existing: v.permits.where((p) => p.typeId == type.id).firstOrNull);
      if (saved == true) reload();
    }

    return Column(
      key: const ValueKey('vehicle-permits-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        VehiclePermitRow(
          vehicle: v,
          today: today,
          bypassDays: days,
          canUpload: uploadableTypes(v, types).isNotEmpty,
          edit: canEdit,
          onBypass: bypass,
          onUpload: upload,
        ),
        for (final p in v.permits) ...[
          const SizedBox(height: 8),
          PermitBox(permit: p, badge: permitBadge(p, today, bypassUntil: v.bypassUntil)),
        ],
      ],
    );
  }
}
