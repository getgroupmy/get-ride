// Admin → Meter & app → EV profiles (migration 0202): how the app reads
// battery, range and odometer from electric cars that don't answer standard
// OBD-II, built from the captures drivers record with "Record for support"
// on the OBD-II reader page. Nothing maker-specific is built in: every
// request here comes from a real capture.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ev_profile.dart';
import '../../../data/ev_profile_repository.dart';
import '../../../data/live_tables.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';

const evProfilesPage = 'admin-settings-ev-profiles';

/// Every profile, active or not.
final adminEvProfilesProvider = FutureProvider.autoDispose<List<EvProfile>>((ref) {
  ref.watchLive('ev_profiles');
  return ref.watch(evProfileRepositoryProvider).adminList();
});

/// The latest captures, newest first.
final adminObdCapturesProvider = FutureProvider.autoDispose<List<EvCapture>>(
  (ref) => ref.watch(evProfileRepositoryProvider).adminCaptures(),
);

String _when(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class AdminEvProfilesScreen extends ConsumerWidget {
  const AdminEvProfilesScreen({super.key});

  Future<void> _open(BuildContext context, EvProfile? p) =>
      Navigator.of(context).push(AppPageRoute<void>(id: 'admin-ev.profile-editor', builder: (_) => EvProfileEditor(profile: p)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: AdminPage(
        title: 'EV profiles',
        page: evProfilesPage,
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey('ev-profile-new'),
          onPressed: () => _open(context, null),
          icon: const Icon(Icons.add),
          label: const Text('New profile'),
        ),
        body: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Profiles'),
                Tab(text: 'OBD captures'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _ProfilesTab(onOpen: (p) => _open(context, p)),
                  const _CapturesTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfilesTab extends ConsumerWidget {
  const _ProfilesTab({required this.onOpen});
  final void Function(EvProfile) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return AsyncView(
      value: ref.watch(adminEvProfilesProvider),
      onRetry: () => ref.invalidate(adminEvProfilesProvider),
      data: (list) => ListView(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 96),
        children: [
          ResponsiveCenter(
            maxWidth: 760,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.electric_car_outlined),
                    title: Text('Battery, range and odometer for electric cars'),
                    subtitle: Text(
                      "Most electric cars don't answer standard OBD-II. A profile tells the app which ECU to ask, "
                      'what to ask and where each value is in the answer. Build it from a driver\'s capture '
                      '(OBD captures tab), test it on the car, then mark it verified. Only active profiles reach '
                      "drivers' phones, and only a verified profile's speed can be used for billing.",
                    ),
                  ),
                ),
                const _BillingSpeedCard(),
                if (list.isEmpty)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.inbox_outlined),
                      title: Text('No profiles yet'),
                      subtitle: Text('Start one from a capture a driver sent for their car.'),
                    ),
                  ),
                ListSearchFilter(count: list.length, hint: 'Search profiles (make, model)', builder: (context, q) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
  for (final p in list)
    if (q.isEmpty || searchSelectMatches('${p.title} ${p.make} ${p.model}', q) || false)
      Card(
                    child: ListTile(
                      key: ValueKey('ev-profile-${p.id}'),
                      leading: Icon(
                        p.active ? Icons.electric_car : Icons.electric_car_outlined,
                        color: p.active ? t.colorScheme.primary : t.colorScheme.outline,
                      ),
                      title: Text(p.title),
                      subtitle: Text(
                        [
                          '${p.make} ${p.model}${p.years == null ? '' : ' · ${p.years}'}',
                          p.active ? 'Active' : 'Off',
                          if (p.verified) 'Verified',
                          '${p.signals.length} signal${p.signals.length == 1 ? '' : 's'}',
                        ].join(' · '),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => onOpen(p),
                    ),
                  ),
])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether a verified profile's speed is what the meter bills on.
class _BillingSpeedCard extends ConsumerWidget {
  const _BillingSpeedCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(evProfilesPage)) == AccessLevel.edit;
    final settings = ref.watch(evSettingsProvider).value;
    return Card(
      child: BusySwitchListTile(
        key: const ValueKey('ev-billing-speed'),
        secondary: const Icon(Icons.speed),
        title: const Text('Use EV speed for meter billing (verified profiles only)'),
        subtitle: Text(
          canEdit
              ? 'On: Meter Digital bills on the speed a verified profile reads, as it does on an engine car. '
                    'Off: EV profiles only show battery, range and odometer, and the meter uses GPS.'
              : 'Changing this needs edit rights on EV profiles.',
        ),
        isThreeLine: true,
        value: settings?.billingSpeed ?? true,
        onChanged: !canEdit || settings == null
            ? null
            : (v) async {
                await runAdminAction(
                  context,
                  () => ref.read(evProfileRepositoryProvider).saveSettings(EvSettings(billingSpeed: v)),
                  success: v ? 'Meter billing uses EV speed again.' : 'Meter billing no longer uses EV speed.',
                );
                ref.invalidate(evSettingsProvider);
              },
      ),
    );
  }
}

class _CapturesTab extends ConsumerWidget {
  const _CapturesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(adminObdCapturesProvider),
      onRetry: () => ref.invalidate(adminObdCapturesProvider),
      data: (list) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(adminObdCapturesProvider),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 96),
          children: [
            ResponsiveCenter(
              maxWidth: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (list.isEmpty)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.inbox_outlined),
                        title: Text('No captures yet'),
                        subtitle: Text(
                          'Drivers record one with "Record for support" on the OBD-II reader page, with the car on.',
                        ),
                      ),
                    ),
                  for (final c in list)
                    Card(
                      child: ListTile(
                        key: ValueKey('obd-capture-${c.id}'),
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: Text(c.vehicle),
                        subtitle: Text(_captureLine(c)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () =>
                            Navigator.of(context)
                                .push(AppPageRoute<void>(id: 'ev-profiles.captures-tab', builder: (_) => ObdCaptureView(capture: c))),
                      ),
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

String _captureLine(EvCapture c) {
  final s = summarizeEvCapture(c.entries);
  return [
    _when(c.createdAt),
    if (c.batteryHint != null) 'Battery ${c.batteryHint}',
    '${c.entries.length} asked, ${s.answered} answered',
    if (c.reader != null) c.reader!,
  ].where((e) => e.isNotEmpty).join(' · ');
}

/// One capture: what was asked and what came back, to copy into a profile.
class ObdCaptureView extends ConsumerWidget {
  const ObdCaptureView({super.key, required this.capture});
  final EvCapture capture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(evProfilesPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    final c = capture;
    return Scaffold(
      appBar: AppBar(
        title: Text(c.vehicle),
        actions: [
          IconButton(
            key: const ValueKey('obd-capture-copy'),
            tooltip: 'Copy as JSON',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(c.toJson())));
              if (context.mounted) showInfo(context, 'Copied as JSON');
            },
          ),
          if (canEdit && c.id != null)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await confirm(context, 'Delete capture?', 'This capture is removed for good.', ok: 'Delete')) {
                  return;
                }
                if (!context.mounted) return;
                final ok = await runAdminAction(
                  context,
                  () => ref.read(evProfileRepositoryProvider).deleteCapture(c.id!),
                  success: 'Capture deleted',
                );
                ref.invalidate(adminObdCapturesProvider);
                if (ok && context.mounted) Navigator.pop(context);
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DetailTable({
            'Vehicle': c.vehicle,
            'Battery (driver)': c.batteryHint,
            'Reader': c.reader,
            'App version': c.appVersion,
            'Recorded': _when(c.createdAt),
            'Summary': _captureLine(c),
          }),
          const SizedBox(height: 12),
          Text('Requests and replies', style: t.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Answered rows come first. A reply starting 7F is the ECU refusing the request; the CAN id at the start '
            'of each line is the ECU that answered.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              key: const ValueKey('obd-capture-table'),
              columnSpacing: 16,
              columns: const [
                DataColumn(label: Text('Header')),
                DataColumn(label: Text('Request')),
                DataColumn(label: Text('Reply')),
                DataColumn(label: Text('ms'), numeric: true),
              ],
              rows: [
                for (final e in [...c.entries.where((e) => e.answered), ...c.entries.where((e) => !e.answered)])
                  DataRow(
                    cells: [
                      DataCell(Text(e.header)),
                      DataCell(Text(e.request)),
                      DataCell(
                        SelectableText(
                          e.reply,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: e.answered ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      DataCell(Text('${e.ms}')),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The text fields of one signal row.
class _SignalRow {
  _SignalRow(EvSignal? s)
    : key = s?.key ?? 'soc',
      signed = s?.signed ?? false,
      header = TextEditingController(text: s?.header ?? ''),
      request = TextEditingController(text: s?.request ?? ''),
      reply = TextEditingController(text: s?.reply ?? ''),
      start = TextEditingController(text: '${s?.start ?? 0}'),
      length = TextEditingController(text: '${s?.length ?? 1}'),
      scale = TextEditingController(text: _number(s?.scale ?? 1)),
      offset = TextEditingController(text: _number(s?.offset ?? 0)),
      unit = TextEditingController(text: s?.unit ?? ''),
      bit = TextEditingController(text: s?.bit == null ? '' : '${s!.bit}');

  String key;
  bool signed;
  final TextEditingController header, request, reply, start, length, scale, offset, unit, bit;

  static String _number(double v) => v == v.roundToDouble() ? v.toInt().toString() : '$v';

  List<TextEditingController> get controllers => [header, request, reply, start, length, scale, offset, unit, bit];

  /// The signal, or what can't be read from the fields.
  (EvSignal?, List<String>) build(int index) {
    final n = index + 1;
    final problems = <String>[];
    int? whole(TextEditingController c, String what) {
      final v = int.tryParse(c.text.trim());
      if (v == null) problems.add('Signal $n: $what must be a whole number.');
      return v;
    }

    double? number(TextEditingController c, String what) {
      final text = c.text.trim();
      if (text.isEmpty) return null;
      final v = double.tryParse(text);
      if (v == null) problems.add('Signal $n: $what must be a number.');
      return v;
    }

    final start = whole(this.start, 'the start byte');
    final length = whole(this.length, 'the length');
    final scale = number(this.scale, 'the scale');
    final offset = number(this.offset, 'the offset');
    final bitText = bit.text.trim();
    final bitValue = bitText.isEmpty ? null : int.tryParse(bitText);
    if (bitText.isNotEmpty && bitValue == null) problems.add('Signal $n: the bit must be a whole number.');
    if (problems.isNotEmpty) return (null, problems);
    final replyText = normalizeHex(reply.text);
    final unitText = unit.text.trim();
    return (
      EvSignal(
        key: key,
        header: normalizeHex(header.text),
        request: normalizeHex(request.text),
        reply: replyText.isEmpty ? null : replyText,
        start: start!,
        length: length!,
        signed: signed,
        scale: scale ?? 1,
        offset: offset ?? 0,
        unit: unitText.isEmpty ? null : unitText,
        bit: bitValue,
      ),
      const <String>[],
    );
  }

  void dispose() {
    for (final c in controllers) {
      c.dispose();
    }
  }
}

/// One profile: identity, setup, detect request and signals, checked as
/// the server checks them before it is saved.
class EvProfileEditor extends ConsumerStatefulWidget {
  const EvProfileEditor({super.key, this.profile});

  /// Null for a new profile.
  final EvProfile? profile;

  @override
  ConsumerState<EvProfileEditor> createState() => _EvProfileEditorState();
}

class _EvProfileEditorState extends ConsumerState<EvProfileEditor> {
  late final _make = TextEditingController(text: widget.profile?.make ?? '');
  late final _model = TextEditingController(text: widget.profile?.model ?? '');
  late final _years = TextEditingController(text: widget.profile?.years ?? '');
  late final _label = TextEditingController(text: widget.profile?.label ?? '');
  late final _init = TextEditingController(text: (widget.profile?.init ?? const []).join(', '));
  late final _detectRequest = TextEditingController(text: widget.profile?.detect?.request ?? '');
  late final _detectHeader = TextEditingController(text: widget.profile?.detect?.header ?? '');
  late final _detectExpect = TextEditingController(text: widget.profile?.detect?.expect ?? '');
  late final _notes = TextEditingController(text: widget.profile?.notes ?? '');
  late bool _active = widget.profile?.active ?? false;
  late bool _verified = widget.profile?.verified ?? false;
  late final List<_SignalRow> _signals = [for (final s in widget.profile?.signals ?? const <EvSignal>[]) _SignalRow(s)];
  List<String> _problems = const [];
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_make, _model, _years, _label, _init, _detectRequest, _detectHeader, _detectExpect, _notes]) {
      c.dispose();
    }
    for (final r in _signals) {
      r.dispose();
    }
    super.dispose();
  }

  String? _opt(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  /// The profile in the fields, and everything wrong with it.
  (EvProfile, List<String>) _build() {
    final problems = <String>[];
    final signals = <EvSignal>[];
    for (var i = 0; i < _signals.length; i++) {
      final (s, p) = _signals[i].build(i);
      problems.addAll(p);
      if (s != null) signals.add(s);
    }
    final init = [
      for (final c in _init.text.split(RegExp(r'[,;\n]+')))
        if (c.trim().isNotEmpty) normalizeEvCommand(c),
    ];
    final request = normalizeHex(_detectRequest.text);
    final header = normalizeHex(_detectHeader.text), expect = normalizeHex(_detectExpect.text);
    final detect = request.isEmpty && header.isEmpty && expect.isEmpty
        ? null
        : EvDetect(request: request, header: header.isEmpty ? null : header, expect: expect.isEmpty ? null : expect);
    final profile = EvProfile(
      id: widget.profile?.id,
      make: _make.text.trim(),
      model: _model.text.trim(),
      years: _opt(_years),
      label: _opt(_label),
      active: _active,
      verified: _verified,
      init: init,
      detect: detect,
      signals: signals,
      notes: _opt(_notes),
    );
    return (profile, [...problems, ...profile.problems()]);
  }

  Future<void> _save() async {
    final (profile, problems) = _build();
    setState(() => _problems = problems);
    if (problems.isNotEmpty) return;
    setState(() => _saving = true);
    final ok = await runAdminAction(
      context,
      () => ref.read(evProfileRepositoryProvider).save(profile),
      success: profile.active ? 'Saved. Drivers\' phones pick it up within a few seconds.' : 'Saved.',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.invalidate(adminEvProfilesProvider);
      Navigator.pop(context);
    }
  }

  Future<void> _delete() async {
    final id = widget.profile?.id;
    if (id == null) return;
    if (!await confirm(context, 'Delete profile?', 'Drivers using it stop seeing their battery.', ok: 'Delete')) {
      return;
    }
    if (!mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(evProfileRepositoryProvider).delete(id),
      success: 'Profile deleted',
    );
    if (!mounted) return;
    if (ok) {
      ref.invalidate(adminEvProfilesProvider);
      Navigator.pop(context);
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    double width = 160,
    bool caps = true,
    Key? key,
    TextInputType? keyboard,
    bool enabled = true,
  }) => SizedBox(
    width: width,
    child: TextField(
      key: key,
      controller: c,
      enabled: enabled,
      keyboardType: keyboard,
      textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.sentences,
      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true),
    ),
  );

  Widget _signalCard(int i, bool canEdit) {
    final r = _signals[i];
    const number = TextInputType.numberWithOptions(decimal: true, signed: true);
    return Card(
      key: ObjectKey(r),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Signal ${i + 1}', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                if (canEdit)
                  IconButton(
                    key: ValueKey('ev-signal-remove-$i'),
                    tooltip: 'Remove signal ${i + 1}',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _signals.removeAt(i).dispose()),
                  ),
              ],
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                SizedBox(
                  width: 200,
                  child: SearchableDropdownFormField<String>(
                    key: ValueKey('ev-signal-key-$i'),
                    initialValue: evSignalKeys.contains(r.key) ? r.key : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Value', isDense: true),
                    items: [
                      for (final k in evSignalKeys)
                        DropdownMenuItem(value: k, child: Text('${evSignalLabels[k]} ($k)')),
                    ],
                    onChanged: canEdit ? (v) => setState(() => r.key = v ?? r.key) : null,
                  ),
                ),
                _field(
                  r.header,
                  'ECU header',
                  hint: '7E4',
                  width: 120,
                  key: ValueKey('ev-signal-header-$i'),
                  enabled: canEdit,
                ),
                _field(
                  r.request,
                  'Request',
                  hint: '220105',
                  width: 140,
                  key: ValueKey('ev-signal-request-$i'),
                  enabled: canEdit,
                ),
                _field(r.reply, 'Reply prefix', hint: 'default', width: 140, enabled: canEdit),
                _field(
                  r.start,
                  'Start byte',
                  width: 90,
                  keyboard: TextInputType.number,
                  key: ValueKey('ev-signal-start-$i'),
                  enabled: canEdit,
                ),
                _field(
                  r.length,
                  'Bytes (1-4)',
                  width: 90,
                  keyboard: TextInputType.number,
                  key: ValueKey('ev-signal-length-$i'),
                  enabled: canEdit,
                ),
                _field(
                  r.scale,
                  'Scale',
                  width: 90,
                  keyboard: number,
                  key: ValueKey('ev-signal-scale-$i'),
                  enabled: canEdit,
                ),
                _field(r.offset, 'Offset', width: 90, keyboard: number, enabled: canEdit),
                _field(r.unit, 'Unit', hint: evSignalUnits[r.key], width: 80, caps: false, enabled: canEdit),
                _field(r.bit, 'Bit (0-7)', hint: 'none', width: 90, keyboard: TextInputType.number, enabled: canEdit),
                SizedBox(
                  width: 120,
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Signed'),
                    value: r.signed,
                    onChanged: canEdit ? (v) => setState(() => r.signed = v ?? false) : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(evProfilesPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
      child: Text(text, style: t.textTheme.titleMedium),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile == null ? 'New EV profile' : widget.profile!.title),
        actions: [
          if (canEdit && widget.profile?.id != null)
            IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              key: const ValueKey('ev-profile-save'),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving…' : 'Save'),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          ResponsiveCenter(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!canEdit)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.visibility_outlined),
                      title: Text('Read-only: your admin access lets you view this profile but not change it.'),
                    ),
                  ),
                if (_problems.isNotEmpty)
                  Card(
                    key: const ValueKey('ev-editor-problems'),
                    color: t.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Fix these before saving:',
                            style: TextStyle(color: t.colorScheme.onErrorContainer, fontWeight: FontWeight.w600),
                          ),
                          for (final p in _problems)
                            Text('• $p', style: TextStyle(color: t.colorScheme.onErrorContainer)),
                        ],
                      ),
                    ),
                  ),
                header('Car'),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    _field(_make, 'Make', width: 200, caps: false, key: const ValueKey('ev-make'), enabled: canEdit),
                    _field(_model, 'Model', width: 200, caps: false, key: const ValueKey('ev-model'), enabled: canEdit),
                    _field(
                      _years,
                      'Years',
                      hint: '2024-2025',
                      width: 140,
                      key: const ValueKey('ev-years'),
                      enabled: canEdit,
                    ),
                    _field(_label, 'Name drivers see (optional)', width: 280, caps: false, enabled: canEdit),
                  ],
                ),
                SwitchListTile(
                  key: const ValueKey('ev-active'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  subtitle: const Text("Sent to drivers' phones and tried on cars that don't answer standard OBD-II"),
                  value: _active,
                  onChanged: canEdit ? (v) => setState(() => _active = v) : null,
                ),
                SwitchListTile(
                  key: const ValueKey('ev-verified'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Verified'),
                  subtitle: const Text(
                    'Checked against the dashboard on a real car. Only then is its speed billed on.',
                  ),
                  value: _verified,
                  onChanged: canEdit ? (v) => setState(() => _verified = v) : null,
                ),
                header('Setup'),
                _field(
                  _init,
                  'Setup commands, in order',
                  hint: 'ATSP6, ATSH7E4',
                  width: 600,
                  key: const ValueKey('ev-init'),
                  enabled: canEdit,
                ),
                const SizedBox(height: 4),
                Text(
                  'AT commands (protocol, header) or hex requests, separated by commas. Sent once before the car is '
                  'read.',
                  style: t.textTheme.bodySmall,
                ),
                header('Detect'),
                Text(
                  'One request only this car answers as expected. The first active profile whose answer starts with '
                  'the expected reply (by default the positive response) is used.',
                  style: t.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    _field(
                      _detectRequest,
                      'Request',
                      hint: '22F190',
                      width: 160,
                      key: const ValueKey('ev-detect-request'),
                      enabled: canEdit,
                    ),
                    _field(
                      _detectHeader,
                      'ECU header (optional)',
                      hint: '7E4',
                      width: 180,
                      key: const ValueKey('ev-detect-header'),
                      enabled: canEdit,
                    ),
                    _field(_detectExpect, 'Expected reply (optional)', hint: 'default', width: 200, enabled: canEdit),
                  ],
                ),
                header('Signals'),
                Text(
                  'Start byte counts from the end of the reply prefix (by default the positive response, e.g. after '
                  '62 01 05). Value = bytes (big-endian) × scale + offset. Bit reads one bit of the start byte '
                  'instead, for a flag such as charging.',
                  style: t.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                if (_signals.isEmpty)
                  const Card(
                    child: ListTile(leading: Icon(Icons.info_outline), title: Text('No signals yet')),
                  ),
                for (var i = 0; i < _signals.length; i++) _signalCard(i, canEdit),
                if (canEdit)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('ev-signal-add'),
                      onPressed: () => setState(() => _signals.add(_SignalRow(null))),
                      icon: const Icon(Icons.add),
                      label: const Text('Add signal'),
                    ),
                  ),
                header('Notes'),
                TextField(
                  controller: _notes,
                  enabled: canEdit,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(hintText: 'Which captures it came from, what was checked'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
