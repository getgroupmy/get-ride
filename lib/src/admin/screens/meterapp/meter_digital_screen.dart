// Admin → Settings → Meter Digital Setting (Expo `admin-settings-meter-digital`).
//
// One global rate card plus country / state / city / suburb overrides in
// `meter_digital_settings`, resolved on the driver's device narrowest-first.
// All shaping and validation lives in `meter_logic.dart`; this is the form.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'meter_logic.dart';
import 'meter_store.dart';
import '../../../data/live_tables.dart';

const meterDigitalPage = 'admin-settings-meter-digital';

final meterStoreProvider = Provider((ref) => MeterSettingsStore(ref.watch(supabaseProvider)));

final meterProfilesProvider =
    FutureProvider.autoDispose<List<MeterProfile>>((ref) => ref.watch(meterStoreProvider).fetch());

/// Place-name suggestions from the shared geography tables (best effort).
final _geoNamesProvider = FutureProvider.autoDispose<_GeoNames>((ref) async {
  ref.watchLive('countries');
  ref.watchLive('states');
  ref.watchLive('cities');
  ref.watchLive('suburbs');
  final db = ref.watch(supabaseProvider);
  Future<List<Map<String, dynamic>>> read(String table, String cols) async {
    try {
      return List<Map<String, dynamic>>.from(await db.from(table).select(cols).limit(5000));
    } catch (_) {
      return const [];
    }
  }

  final r = await Future.wait([read('countries', 'name'), read('states', 'country, name'), read('cities', 'country, state, name')]);
  return _GeoNames(r[0], r[1], r[2]);
});

class _GeoNames {
  const _GeoNames(this.countries, this.states, this.cities);
  final List<Map<String, dynamic>> countries;
  final List<Map<String, dynamic>> states;
  final List<Map<String, dynamic>> cities;

  static bool _eq(Object? a, String? b) => '${a ?? ''}'.trim().toLowerCase() == (b ?? '').trim().toLowerCase();

  List<String> options(String field, String? country, String? state) {
    final names = switch (field) {
      'country' => {
          ...countries.map((r) => '${r['name']}'),
          ...states.map((r) => '${r['country'] ?? ''}'),
        },
      'state' => states.where((r) => _eq(r['country'], country)).map((r) => '${r['name']}').toSet(),
      _ => cities.where((r) => _eq(r['country'], country) && _eq(r['state'], state)).map((r) => '${r['name']}').toSet(),
    };
    return (names.where((n) => n.trim().isNotEmpty).toList()..sort());
  }
}

const _levelMeta = [
  ('suburb', 'Suburb cards', 'Beats city, state, country & global', Icons.home_outlined),
  ('city', 'City cards', 'Beats state, country & global', Icons.location_city),
  ('state', 'State cards', 'Beats country & global', Icons.map_outlined),
  ('country', 'Country cards', 'Beats the global card only', Icons.public),
];

class AdminMeterDigitalScreen extends ConsumerWidget {
  const AdminMeterDigitalScreen({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref, MeterProfile profile, List<MeterProfile> all) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MeterCardEditor(initial: profile, stored: all),
    ));
    ref.invalidate(meterProfilesProvider);
    if (saved == true && context.mounted) {
      final dropped = describeMissingMeterColumns(ref.read(meterStoreProvider).missingGroups);
      if (dropped != null) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Saved, with one part left out'),
            content: Text(dropped),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ),
        );
      }
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, MeterProfile p) async {
    final tail = p.level == 'master'
        ? ' — with no global card, the meter bills on the built-in TEKSI tariff.'
        : '.';
    if (!await confirm(context, 'Delete rate card?',
        '${meterProfileScopeLabel(p)} will be removed. Hires there fall back to the next scope$tail',
        ok: 'Delete')) {
      return;
    }
    if (!context.mounted) return;
    if (await runAdminAction(context, () => ref.read(meterStoreProvider).delete(p.id), success: 'Rate card deleted')) {
      ref.invalidate(meterProfilesProvider);
    }
  }

  Future<void> _toggleActive(BuildContext context, WidgetRef ref, MeterProfile p) async {
    if (await runAdminAction(context, () => ref.read(meterStoreProvider).save(p.copyWith(active: !p.active)))) {
      ref.invalidate(meterProfilesProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(meterDigitalPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    return AdminPage(
      title: 'Meter Digital Setting',
      page: meterDigitalPage,
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(meterProfilesProvider),
        ),
      ],
      body: AsyncView(
        value: ref.watch(meterProfilesProvider),
        onRetry: () => ref.invalidate(meterProfilesProvider),
        data: (profiles) {
          final global = profiles.where((p) => p.level == 'master').firstOrNull;
          final missing = describeMissingMeterColumns(ref.read(meterStoreProvider).missingGroups);
          return ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            ResponsiveCenter(
              maxWidth: 820,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('Card priority: Suburb → City → State → Country → Global'),
                    subtitle: const Text("The driver's meter resolves the first matching card for where the hire "
                        'starts. With no card at all it bills on the built-in TEKSI tariff. Sensors, launch, '
                        'console panels and fare rates are all set per card.'),
                  ),
                ),
                if (missing != null)
                  Card(
                    color: t.colorScheme.errorContainer,
                    child: Padding(padding: const EdgeInsets.all(16), child: Text(missing)),
                  ),
                const SizedBox(height: 12),
                Text('Global card', style: t.textTheme.titleMedium),
                Text('What every meter uses unless a narrower card matches', style: t.textTheme.bodySmall),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.speed),
                    title: Text('${global?.label ?? 'Global rate card'}${global == null ? ' (not configured)' : ''}'),
                    subtitle: Text(describeMeterRates(global ?? defaultMeterProfile).join(' · ')),
                    trailing: Icon(canEdit ? Icons.edit_outlined : Icons.chevron_right),
                    onTap: () => _open(
                      context,
                      ref,
                      global ?? createMeterProfileDraft('master').copyWith(label: () => 'Global rate card'),
                      profiles,
                    ),
                  ),
                ),
                for (final (level, title, desc, icon) in _levelMeta) ...[
                  const SizedBox(height: 20),
                  Row(children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(title, style: t.textTheme.titleMedium)),
                    if (canEdit)
                      TextButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add'),
                        onPressed: () => _open(context, ref, createMeterProfileDraft(level), profiles),
                      ),
                  ]),
                  Text(desc, style: t.textTheme.bodySmall),
                  if (profiles.where((p) => p.level == level).isEmpty)
                    const Card(child: ListTile(leading: Icon(Icons.inbox_outlined), title: Text('No cards'))),
                  for (final p in profiles.where((p) => p.level == level))
                    Opacity(
                      opacity: p.active ? 1 : 0.55,
                      child: Card(
                        child: ListTile(
                          title: Text(meterProfileScopeLabel(p)),
                          subtitle: Text(
                            '${p.label != null ? '${p.label} · ' : ''}'
                            '${[...describeMeterRates(p).take(3), ...describeMeterLeave(p.leave)].join(' · ')}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _open(context, ref, p, profiles),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            BusySwitch(
                              value: p.active,
                              onChanged: canEdit ? (_) => _toggleActive(context, ref, p) : null,
                            ),
                            if (canEdit)
                              BusyIconButton(
                                tooltip: 'Delete',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(context, ref, p),
                              ),
                          ]),
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 40),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

class MeterCardEditor extends ConsumerStatefulWidget {
  const MeterCardEditor({super.key, required this.initial, required this.stored});
  final MeterProfile initial;

  /// The cards as last fetched — the base a live panel toggle writes onto.
  final List<MeterProfile> stored;

  @override
  ConsumerState<MeterCardEditor> createState() => _MeterCardEditorState();
}

class _MeterCardEditorState extends ConsumerState<MeterCardEditor> {
  late MeterProfile _draft = widget.initial;
  late final Map<String, TextEditingController> _num = {
    for (final e in meterFieldsOf(widget.initial).entries) e.key: TextEditingController(text: e.value),
  };
  late final _label = TextEditingController(text: widget.initial.label ?? '');
  late final _currency = TextEditingController(text: widget.initial.currency);
  late final _url = TextEditingController(text: widget.initial.leave.ehailingUrl ?? '');
  late final _caption = TextEditingController(text: widget.initial.leave.ehailingLabel ?? '');
  late final Map<String, TextEditingController> _stores = {
    for (final p in storePlatforms) p: TextEditingController(text: widget.initial.leave.ehailingStores[p] ?? ''),
  };
  late final Map<String, TextEditingController> _scope = {
    'country': TextEditingController(text: widget.initial.country ?? ''),
    'state': TextEditingController(text: widget.initial.state ?? ''),
    'city': TextEditingController(text: widget.initial.city ?? ''),
    'suburb': TextEditingController(text: widget.initial.suburb ?? ''),
  };

  final Map<String, FocusNode> _focus = {for (final k in ['country', 'state', 'city', 'suburb']) k: FocusNode()};
  bool _busy = false;
  String? _panelBusy;
  ({String kind, String text})? _panelNote;

  @override
  void dispose() {
    for (final c in [..._num.values, ..._stores.values, ..._scope.values, _label, _currency, _url, _caption]) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  bool get _canEdit => ref.read(pageAccessProvider(meterDigitalPage)) == AccessLevel.edit;

  String? _orNull(String s) => s.trim().isEmpty ? null : s.trim();

  /// The draft with every text field folded back on — the card as it saves.
  MeterProfile _merged() {
    final withText = _draft.copyWith(
      label: () => _orNull(_label.text),
      currency: _currency.text.trim().isEmpty ? defaultMeterProfile.currency : _currency.text.trim().toUpperCase(),
      country: () => _orNull(_scope['country']!.text),
      state: () => _orNull(_scope['state']!.text),
      city: () => _orNull(_scope['city']!.text),
      suburb: () => _orNull(_scope['suburb']!.text),
      leave: _draft.leave.copyWith(
        ehailingUrl: () => _orNull(_url.text),
        ehailingLabel: () => _orNull(_caption.text),
        ehailingStores: MeterLeaveStores(
          ios: _orNull(_stores['ios']!.text),
          android: _orNull(_stores['android']!.text),
          huawei: _orNull(_stores['huawei']!.text),
        ),
      ),
    );
    return mergeMeterFields(withText, {for (final e in _num.entries) e.key: e.value.text});
  }

  Future<void> _submit() async {
    final merged = _merged();
    final invalid = validateMeterProfile(merged);
    if (invalid != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Check the card'),
          content: Text(invalid),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final ok = await runAdminAction(context, () => ref.read(meterStoreProvider).save(merged), success: 'Rate card saved');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  /// A panel's Show or Tap switch — written through immediately (only the
  /// ten panel columns), and put back if the database refuses it.
  Future<void> _applyPanel(String id, {bool? show, bool? tap}) async {
    final previous = _draft.panels;
    final panels = setMeterPanelAccess(previous, id, show: show, tap: tap);
    setState(() => _draft = _draft.copyWith(panels: panels));

    if (!canApplyMeterPanelLive(_draft)) {
      setState(() => _panelNote = (kind: 'draft', text: 'Panels apply live once this card is created.'));
      return;
    }

    final stored = widget.stored.where((p) => p.id == _draft.id.trim()).firstOrNull ??
        (_draft.level == 'master' ? widget.stored.where((p) => p.level == 'master').firstOrNull : null);
    MeterProfile base;
    if (stored != null) {
      base = stored;
    } else {
      final merged = _merged();
      final invalid = validateMeterProfile(merged.copyWith(panels: panels));
      if (invalid != null) {
        setState(() {
          _draft = _draft.copyWith(panels: previous);
          _panelNote = (kind: 'error', text: invalid);
        });
        return;
      }
      base = merged;
    }

    setState(() => _panelBusy = id);
    try {
      final newId = await ref.read(meterStoreProvider).savePanels(base, panels);
      if (!mounted) return;
      setState(() {
        if (newId != null && _draft.id.trim().isEmpty) _draft = _draft.copyWith(id: newId);
        _panelNote = (kind: 'saved', text: "Applied live — drivers' consoles update without a Save.");
      });
      ref.invalidate(meterProfilesProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _draft = _draft.copyWith(panels: previous);
        _panelNote = (kind: 'error', text: errorText(e));
      });
    } finally {
      if (mounted) setState(() => _panelBusy = null);
    }
  }

  // --- Small form pieces -------------------------------------------------------

  Widget _group(IconData icon, String title, [String? hint]) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Divider(),
        Row(children: [
          Icon(icon, size: 18, color: t.colorScheme.primary),
          const SizedBox(width: 8),
          Text(title, style: t.textTheme.titleMedium),
        ]),
        if (hint != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(hint, style: t.textTheme.bodySmall)),
      ]),
    );
  }

  Widget _segmented(String label, List<(String, String, String?)> options, String value, ValueChanged<String> onPick) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (key, text, hint) in options)
            Tooltip(
              message: hint ?? '',
              child: ChoiceChip(
                label: Text(text),
                selected: value == key,
                onSelected: _canEdit ? (_) => onPick(key) : null,
              ),
            ),
        ]),
        if (options.where((o) => o.$1 == value && o.$3 != null).firstOrNull case final o?)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(o.$3!, style: t.textTheme.bodySmall)),
      ]),
    );
  }

  Widget _switch(String label, String hint, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text(hint),
        value: value,
        onChanged: _canEdit ? onChanged : null,
      );

  Widget _numField(String key, String label, [String? suffix]) => SizedBox(
        width: 200,
        child: TextField(
          controller: _num[key],
          enabled: _canEdit,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true),
        ),
      );

  Widget _grid(List<Widget> children) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Wrap(spacing: 12, runSpacing: 12, children: children),
      );

  Widget _geoField(String field, String label, String hint) {
    final geo = ref.watch(_geoNamesProvider).value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: RawAutocomplete<String>(
        textEditingController: _scope[field],
        focusNode: _focus[field],
        optionsBuilder: (v) {
          if (geo == null || field == 'suburb') return const [];
          final q = v.text.trim().toLowerCase();
          return geo
              .options(field, _scope['country']!.text, _scope['state']!.text)
              .where((n) => q.isEmpty || n.toLowerCase().contains(q))
              .take(8);
        },
        onSelected: (name) {
          if (field == 'country') {
            _scope['state']!.clear();
            _scope['city']!.clear();
          } else if (field == 'state') {
            _scope['city']!.clear();
          }
        },
        fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: _canEdit,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280, maxWidth: 400),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [for (final o in options) ListTile(dense: true, title: Text(o), onTap: () => onSelected(o))],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(meterDigitalPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    final d = _draft;
    final level = d.level;
    final cur = _currency.text.trim().isEmpty ? 'MYR' : _currency.text.trim().toUpperCase();
    final pickedApp = meterLeaveAppById(d.leave.ehailingAppId);
    final linkInvalid = d.leave.ehailing == 'link' && _url.text.trim().isNotEmpty && normalizeMeterLeaveUrl(_url.text) == null;
    final title = level == 'master' ? 'Global rate card' : '${d.id.isNotEmpty ? 'Edit' : 'Add'} $level card';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (canEdit)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: BusyButton.filled(
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? 'Saving…' : (d.id.isNotEmpty ? 'Save rate card' : 'Create rate card')),
              ),
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
        ResponsiveCenter(
          maxWidth: 720,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!canEdit)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.visibility_outlined),
                  title: Text('Read-only: rate cards can be viewed but not changed.'),
                ),
              ),
            if (level != 'master') ...[
              _group(Icons.map_outlined, 'Scope'),
              _geoField('country', 'Country', 'e.g. Malaysia'),
              if (['state', 'city', 'suburb'].contains(level)) _geoField('state', 'State', 'e.g. Selangor'),
              if (['city', 'suburb'].contains(level)) _geoField('city', 'City', 'e.g. Petaling Jaya'),
              if (level == 'suburb') _geoField('suburb', 'Suburb', 'e.g. Bangsar'),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _label,
              enabled: canEdit,
              decoration: const InputDecoration(labelText: 'Card name (optional)', hintText: 'e.g. KL city tariff'),
            ),

            // Sensors
            _group(Icons.satellite_alt_outlined, 'Sensors'),
            _segmented(
              'The meter may bill on',
              const [
                ('gps', 'GPS only', 'Ignore the reader — always bill on GPS'),
                ('gps+obd', 'GPS + OBD', 'Bill on the vehicle, fall back to GPS'),
                ('obd', 'OBD only', 'Never bill on GPS'),
              ],
              d.sourceMode,
              (k) => setState(() => _draft = _draft.copyWith(sourceMode: k)),
            ),
            _switch(
              'Start without odometer',
              'Applies only with no reader linked — a hire opened on a connected reader always requires the '
                  'odometer (PID A6). Off means no hire opens without it at all.',
              d.allowStartWithoutOdometer,
              (v) => setState(() => _draft = _draft.copyWith(allowStartWithoutOdometer: v)),
            ),
            _switch(
              'Read the odometer',
              "Ask the reader for the odometer at pickup and drop-off. Turn off for fleets whose cars don't "
                  "publish it — otherwise a connected reader that can't return it blocks the hire.",
              d.readOdometer,
              (v) => setState(() => _draft = _draft.copyWith(readOdometer: v)),
            ),

            // Launch
            _group(Icons.rocket_launch_outlined, 'Driver launch'),
            _switch(
              'Open the meter on launch',
              'Drivers with the TEKSI partner type land on the meter console when they sign in or reopen the '
                  'app, instead of the passenger map. An in-progress ride is still restored first, and leaving '
                  'the console does not bounce them back into it. The meter opens on whichever vehicle the driver '
                  'still has claimed, and asks them to pick one when they have none.',
              d.autoLaunch,
              (v) => setState(() => _draft = _draft.copyWith(autoLaunch: v)),
            ),

            // Leave
            _group(
              Icons.door_front_door_outlined,
              'Leave the meter',
              'The back key on an idle meter asks the driver where they are going. These two answers are what it '
                  'offers — the third is always “stay on the meter”. A running hire cannot be left at all.',
            ),
            _switch(
              'Passenger key exits the app',
              'Instead of opening passenger mode, the key closes the app without signing the driver out — the next '
                  'launch comes straight back to the meter. Android only: iOS gives no app a way to close itself, '
                  'so iPhone drivers are told to swipe up instead.',
              d.leave.passenger == 'exit',
              (v) => setState(() => _draft = _draft.copyWith(leave: _draft.leave.copyWith(passenger: v ? 'exit' : 'passenger'))),
            ),
            _segmented(
              'E-hailing key opens',
              const [
                ('app', 'This app', 'Opens the partner e-hailing screen'),
                ('link', 'Another app', 'Opens the app at the link below'),
              ],
              d.leave.ehailing,
              (k) => setState(() => _draft = _draft.copyWith(leave: _draft.leave.copyWith(ehailing: k))),
            ),
            if (d.leave.ehailing == 'link') ...[
              Text('Dispatch app', style: t.textTheme.labelLarge),
              Text(
                'Pick the app your drivers take jobs in, or choose Other app and enter its link by hand. Detecting '
                'which apps are installed is only possible in the Expo app on a phone, so it is not shown here.',
                style: t.textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              RadioGroup<String>(
                groupValue: d.leave.ehailingAppId ?? '',
                onChanged: (v) {
                  if (!canEdit || v == null) return;
                  _pickApp(v.isEmpty ? null : v);
                },
                child: Column(children: [
                  for (final app in meterLeaveApps)
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: app.id,
                      enabled: canEdit,
                      title: Text(app.name),
                      subtitle: Text('${app.androidPackage ?? ''} · ${describeAppIosRoute(app)}'),
                    ),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: '',
                    enabled: canEdit,
                    title: const Text('Other app'),
                    subtitle: const Text('Open whatever the link below names'),
                  ),
                ]),
              ),
              TextField(
                controller: _url,
                enabled: canEdit,
                keyboardType: TextInputType.url,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'App link',
                  hintText: 'e.g. driverapp:// or https://dispatch.example.com',
                  errorText: linkInvalid
                      ? 'A link has to start with a scheme — driverapp://, https:// — so the device knows which app to open.'
                      : null,
                  helperMaxLines: 3,
                  helperText: linkInvalid
                      ? null
                      : pickedApp != null
                          ? 'Optional for ${pickedApp.name} on Android, which opens by package. '
                              '${pickedApp.iosScheme != null ? "iPhones use the app's own scheme." : 'iPhones need it — without one they are offered the App Store instead.'}'
                          : "The driver's phone opens whichever app claims this link. The meter stays open behind it.",
                ),
              ),
              const SizedBox(height: 16),
              Text("Store links (for drivers who don't have the app)", style: t.textTheme.labelLarge),
              Text(
                "Offered when the app cannot be opened on a driver's phone. Huawei is listed on its own because an "
                'HMS device has no Play Store.',
                style: t.textTheme.bodySmall,
              ),
              for (final p in storePlatforms)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: _stores[p],
                    enabled: canEdit,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: storeLabels[p],
                      hintText: switch (p) {
                        'android' => 'https://play.google.com/store/apps/details?id=…',
                        'ios' => 'https://apps.apple.com/app/id…',
                        _ => 'https://appgallery.huawei.com/app/…',
                      },
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _caption,
                enabled: canEdit,
                maxLength: meterLeaveMaxLabelLength,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Key caption (optional)', hintText: 'E-HAILING APP'),
              ),
            ],

            // Panels
            _group(
              Icons.grid_view,
              'Console panels',
              'Show puts the tab on the console; Tap decides whether the driver can open it. A panel that is shown '
                  'but not tappable is visible and locked. These switches take effect immediately — they are saved as '
                  'you move them, no Save needed.',
            ),
            if (_panelNote case final note?)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  note.text,
                  style: TextStyle(
                    color: switch (note.kind) {
                      'error' => t.colorScheme.error,
                      'draft' => t.colorScheme.onSurfaceVariant,
                      _ => t.colorScheme.primary,
                    },
                  ),
                ),
              ),
            Row(children: [
              Expanded(child: Text('Panel', style: t.textTheme.labelMedium)),
              SizedBox(width: 64, child: Center(child: Text('Show', style: t.textTheme.labelMedium))),
              SizedBox(width: 64, child: Center(child: Text('Tap', style: t.textTheme.labelMedium))),
            ]),
            for (final id in meterPanelIds)
              Row(children: [
                Expanded(child: Text('${meterPanelLabels[id]}${id == 'meter' ? ' (always on)' : ''}')),
                SizedBox(
                  width: 64,
                  child: BusySwitch(
                    value: d.panels[id]?.show ?? true,
                    onChanged: !canEdit || id == 'meter' || _panelBusy == id ? null : (v) => _applyPanel(id, show: v),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: BusySwitch(
                    value: d.panels[id]?.tap ?? true,
                    onChanged: !canEdit || id == 'meter' || !(d.panels[id]?.show ?? true) || _panelBusy == id
                        ? null
                        : (v) => _applyPanel(id, tap: v),
                  ),
                ),
              ]),

            // Rates
            _group(Icons.speed, 'Fare rates'),
            SizedBox(
              width: 200,
              child: TextField(
                controller: _currency,
                enabled: canEdit,
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Currency'),
              ),
            ),
            _grid([
              _numField('flagFare', 'Flag / minimum fare', cur),
              _numField('flagDistanceM', 'Flag distance', 'm'),
              _numField('minimumFare', 'Fare floor (0 = none)', cur),
            ]),
            _segmented(
              'Distance charge',
              const [('block', 'Per block', null), ('per_km', 'Per km', null), ('off', 'No distance charge', null)],
              d.rates.distanceMode,
              (k) => setState(() => _draft = _draft.copyWith(rates: _draft.rates.copyWith(distanceMode: k))),
            ),
            if (d.rates.distanceMode == 'block')
              _grid([_numField('distanceBlockM', 'Block length', 'm'), _numField('distanceBlockCharge', 'Charge per block', cur)]),
            if (d.rates.distanceMode == 'per_km') _grid([_numField('perKmCharge', 'Charge per km', cur)]),
            _segmented(
              'Time charge',
              const [
                ('block', 'Per block', null),
                ('per_minute', 'Per minute', null),
                ('per_second', 'Per second', null),
                ('off', 'No time charge', null),
              ],
              d.rates.timeMode,
              (k) => setState(() => _draft = _draft.copyWith(rates: _draft.rates.copyWith(timeMode: k))),
            ),
            if (d.rates.timeMode == 'block')
              _grid([_numField('timeBlockS', 'Block length', 's'), _numField('timeBlockCharge', 'Charge per block', cur)]),
            if (d.rates.timeMode == 'per_minute') _grid([_numField('perMinuteCharge', 'Charge per minute', cur)]),
            if (d.rates.timeMode == 'per_second') _grid([_numField('perSecondCharge', 'Charge per second', cur)]),
            if (d.rates.distanceMode != 'off' && d.rates.timeMode != 'off')
              _segmented(
                'Distance & time combine',
                const [('max', 'Whichever is greater', null), ('sum', 'Added together', null)],
                d.rates.chargeMode,
                (k) => setState(() => _draft = _draft.copyWith(rates: _draft.rates.copyWith(chargeMode: k))),
              ),
            _segmented(
              'Charging starts',
              const [('flag', 'Past the flag distance', null), ('start', 'From the start of the hire', null)],
              d.rates.chargeFrom,
              (k) => setState(() => _draft = _draft.copyWith(rates: _draft.rates.copyWith(chargeFrom: k))),
            ),

            _group(Icons.nightlight_outlined, 'Night shift'),
            _grid([
              _numField('nightMultiplier', 'Surcharge multiplier', '×'),
              _numField('nightStartHour', 'Starts at', 'h'),
              _numField('nightEndHour', 'Ends at', 'h'),
            ]),

            _group(Icons.luggage_outlined, 'Extras', 'Charges a meter cannot measure. The driver adds them by hand at the end of a hire.'),
            _grid([
              _numField('extraLuggageCharge', 'Per bag', cur),
              _numField('freeLuggage', 'Bags included'),
              _numField('extraPassengerCharge', 'Per passenger', cur),
              _numField('freePassengers', 'Passengers included'),
              _numField('extraStep', 'Free-form extra step', cur),
              _numField('maxExtra', 'Extras ceiling', cur),
            ]),

            const Divider(height: 32),
            _switch(
              'Active',
              'An inactive card is skipped — hires fall through to the next scope.',
              d.active,
              (v) => setState(() => _draft = _draft.copyWith(active: v)),
            ),
            const SizedBox(height: 8),
            _PreviewCard(build: _merged),
            const SizedBox(height: 40),
          ]),
        ),
      ]),
    );
  }

  void _pickApp(String? appId) {
    final current = _merged().leave;
    final next = pickMeterLeaveApp(current, appId);
    for (final p in storePlatforms) {
      _stores[p]!.text = next.ehailingStores[p] ?? '';
    }
    setState(() => _draft = _draft.copyWith(leave: _draft.leave.copyWith(ehailingAppId: () => next.ehailingAppId)));
  }
}

/// The card in words plus a sample fare, recomputed on demand.
class _PreviewCard extends StatefulWidget {
  const _PreviewCard({required this.build});
  final MeterProfile Function() build;

  @override
  State<_PreviewCard> createState() => _PreviewCardState();
}

class _PreviewCardState extends State<_PreviewCard> {
  @override
  Widget build(BuildContext context) {
    final p = widget.build();
    const km = 5.0;
    const minutes = 15;
    final elapsed = minutes * 60000;
    final chargeable = p.rates.chargeFrom == 'flag' && km * 1000 > p.rates.flagDistanceM
        ? (elapsed * (km * 1000 - p.rates.flagDistanceM) / (km * 1000)).round()
        : 0;
    final fare = computeMeterFareTotal(p.rates, distanceM: km * 1000, elapsedMs: elapsed, chargeableMs: chargeable);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Preview', style: Theme.of(context).textTheme.titleSmall)),
            IconButton(tooltip: 'Recalculate', icon: const Icon(Icons.refresh), onPressed: () => setState(() {})),
          ]),
          for (final l in describeMeterRates(p)) Text('• $l'),
          for (final l in describeMeterLeave(p.leave)) Text('• $l'),
          const SizedBox(height: 8),
          Text('Sample day fare, 5 km in 15 min: ${p.currency} ${fare.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
