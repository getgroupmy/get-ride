// Admin > Office NAS > Maps (migration 0319, deploy/nas-maps): the NAS's
// own maps. Its status (routes, search, the web map, its tunnel, the weekly
// refresh), connecting it with a one-time code and disconnecting it (full
// admins only), the Default rule and region rules (each part on or off, how
// long to wait for the NAS), and what it answered with what that saved.
// Every change saves at once. Which users get the NAS, and in what order
// with the other providers, is set in Admin > Maps.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/nas_maps.dart';
import '../../../core/office_nas.dart' show officeNasPage;
import '../../../data/nas_maps_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../widgets/region_scope_picker.dart' show pickRegionScope;
import '../catalogue/catalogue_widgets.dart' show canEditPage;
import '../maps/maps_logic.dart' show mapProviderLabel;

class OfficeNasMapsTab extends ConsumerStatefulWidget {
  const OfficeNasMapsTab({super.key});

  @override
  ConsumerState<OfficeNasMapsTab> createState() => _OfficeNasMapsTabState();
}

class _OfficeNasMapsTabState extends ConsumerState<OfficeNasMapsTab> {
  NasMapsSettings? _settings;
  bool _saved = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The NAS checks in every minute: keep its status fresh.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) ref.invalidate(nasMapsStatusProvider);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _save(NasMapsSettings next) async {
    final before = _settings;
    setState(() {
      _settings = next;
      _saved = false;
    });
    late NasMapsSettings stored;
    final ok = await runAdminAction(context, () async {
      stored = await ref.read(nasMapsRepositoryProvider).save(next);
    });
    if (!mounted) return;
    setState(() {
      _settings = ok ? stored : before;
      _saved = ok;
    });
  }

  Future<void> _connect() async {
    final name = await showAppDialog<String>(
      id: 'admin-office-nas.maps-connect',
      context: context,
      builder: (_) => const _ConnectDialog(),
    );
    if (name == null || !mounted) return;
    ({String code, DateTime? expiresAt})? answer;
    final ok = await runAdminAction(context, () async {
      answer = await ref.read(nasMapsRepositoryProvider).pairingCode(name);
    });
    if (!ok || answer == null || !mounted) return;
    final until = answer!.expiresAt == null ? null : DateFormat('HH:mm').format(answer!.expiresAt!);
    await showAppDialog<void>(
      id: 'admin-office-nas.maps-code',
      context: context,
      builder: (c) {
        final t = Theme.of(c);
        return AlertDialog(
          title: const Text('Connection code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                answer!.code,
                key: const ValueKey('nas-maps-code'),
                style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 4),
              ),
              const SizedBox(height: 12),
              Text(
                'Put this code in the NAS maps .env as PAIR_CODE and start it (deploy/nas-maps/README.md). It works '
                'once, ${until == null ? 'for 10 minutes' : 'until $until'}. The NAS only calls out to GET.ride; '
                'GET.ride reaches its maps through its Cloudflare Tunnel, so no ports are opened on your network.',
                style: t.textTheme.bodySmall,
              ),
            ],
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))],
        );
      },
    );
    ref.invalidate(nasMapsStatusProvider);
  }

  Future<void> _disconnect(NasMapsServer s) async {
    if (!await confirm(
      context,
      'Disconnect ${s.label}?',
      'GET.ride stops asking it at once and its key stops working. The maps go back to the other providers in '
          'Admin > Maps.',
      ok: 'Disconnect',
    )) {
      return;
    }
    if (!mounted) return;
    await runAdminAction(context, () => ref.read(nasMapsRepositoryProvider).remove(s.id));
    ref.invalidate(nasMapsStatusProvider);
  }

  Future<void> _editRegion(NasMapsSettings s, [NasMapsRegion? existing]) async {
    var region = existing;
    if (region == null) {
      final scope = await pickRegionScope(context, title: 'Region rule for');
      if (scope == null || scope.isAll || !mounted) return;
      String? v(String x) => x.isEmpty ? null : x;
      region = NasMapsRegion(
        country: scope.country,
        state: v(scope.state),
        city: v(scope.city),
        suburb: v(scope.suburb),
      );
      final same = s.regions.where((r) => r.samePlace(region!));
      if (same.isNotEmpty) region = same.first;
    }
    final rule = await showAppDialog<NasMapsRule>(
      id: 'admin-office-nas.region',
      context: context,
      builder: (_) => _RegionRuleDialog(region: region!, defaults: s.defaultRule),
    );
    if (rule == null || !mounted) return;
    await _save(s.withRegion(region.withRule(rule)));
  }

  Future<void> _editPrices(NasMapsSettings s) async {
    final prices = await showAppDialog<_Prices>(
      id: 'admin-office-nas.prices',
      context: context,
      builder: (_) => _PricesDialog(route: s.routeCost, search: s.searchCost),
    );
    if (prices == null || !mounted) return;
    await _save(s.copyWith(routeCost: prices.$1, searchCost: prices.$2));
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, officeNasPage);
    final fullAdmin = ref.watch(adminAccessProvider).value?.isFullAdmin ?? false;
    final async = ref.watch(nasMapsStatusProvider);
    return AsyncView(
      value: async,
      onRetry: () => ref.invalidate(nasMapsStatusProvider),
      data: (status) {
        final s = _settings ?? status.settings;
        return ResponsiveCenter(
          maxWidth: 900,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _StatusCard(
                status: status,
                onConnect: fullAdmin ? _connect : null,
                onDisconnect: fullAdmin ? _disconnect : null,
              ),
              const SizedBox(height: 16),
              _DefaultRuleCard(settings: s, canEdit: canEdit, saved: _saved, onChange: _save),
              const SizedBox(height: 16),
              _RegionsCard(
                settings: s,
                canEdit: canEdit,
                onAdd: () => _editRegion(s),
                onEdit: (r) => _editRegion(s, r),
                onRemove: (r) => _save(s.withoutRegion(r)),
              ),
              const SizedBox(height: 16),
              _UsageCard(status: status, settings: s, onEditPrices: canEdit ? () => _editPrices(s) : null),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog();

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final _label = TextEditingController(text: 'Office NAS');

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect the NAS maps'),
    content: TextField(
      key: const ValueKey('nas-maps-label'),
      controller: _label,
      autofocus: true,
      maxLength: 80,
      decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. DS224+ at the office'),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const ValueKey('nas-maps-get-code'),
        onPressed: () => Navigator.pop(context, _label.text.trim()),
        child: const Text('Get code'),
      ),
    ],
  );
}

Widget _dot(BuildContext context, bool? ok) {
  final scheme = Theme.of(context).colorScheme;
  return Icon(
    ok == null ? Icons.remove_circle_outline : (ok ? Icons.check_circle : Icons.error),
    size: 18,
    color: ok == null ? scheme.outline : (ok ? scheme.primary : scheme.error),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, this.onConnect, this.onDisconnect});

  final NasMapsStatus status;
  final VoidCallback? onConnect;
  final ValueChanged<NasMapsServer>? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final svc = status.service;
    final now = DateTime.now();
    final date = DateFormat('d MMM y');
    final refresh = svc?.refresh;
    final checks = <(String, NasCheck?, String?)>[
      ('Routes (OSRM)', svc?.osrm, null),
      ('Search (Photon)', svc?.photon, null),
      ('Web map (tiles)', svc?.tiles, svc?.tiles?.bytes == null ? null : nasBytes(svc!.tiles!.bytes)),
      ('Tunnel, from outside', svc?.tunnel, null),
    ];
    return Card(
      key: const ValueKey('nas-maps-status'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 12,
                  color: svc?.online == true ? t.colorScheme.primary : t.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status.servers.isEmpty
                        ? 'Not connected'
                        : [
                            svc?.headline ?? 'Never checked in',
                            if (svc?.lastSeen != null) 'last seen ${nasAgo(svc!.lastSeen!, now)}',
                          ].join(' · '),
                    key: const ValueKey('nas-maps-headline'),
                    style: t.textTheme.titleMedium,
                  ),
                ),
                if (onConnect != null)
                  TextButton(
                    key: const ValueKey('nas-maps-connect'),
                    onPressed: onConnect,
                    child: Text(status.servers.isEmpty ? 'Connect the NAS' : 'Connect again'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (status.servers.isEmpty)
              Text(
                'Run deploy/nas-maps on the NAS (Docker, about 5 GB of memory), then connect it here with a code. '
                'GET.ride then asks it for routes and searches before the paid providers, and asks the next one '
                'whenever it is off or slow.',
                style: t.textTheme.bodySmall,
              )
            else ...[
              for (final s in status.servers)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [s.label, ?s.model, if (s.appVersion != null) 'Version ${s.appVersion}'].join(' · '),
                        key: ValueKey('nas-maps-server-${s.id}'),
                        style: t.textTheme.bodySmall,
                      ),
                    ),
                    if (onDisconnect != null)
                      TextButton(
                        key: ValueKey('nas-maps-disconnect-${s.id}'),
                        onPressed: () => onDisconnect!(s),
                        child: const Text('Disconnect'),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              for (final (label, check, extra) in checks)
                if (check != null || label != 'Tunnel, from outside')
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        _dot(context, check?.ok),
                        const SizedBox(width: 8),
                        Expanded(child: Text(label)),
                        Text(
                          [if (check?.ms != null) '${check!.ms} ms', ?extra].join(' · '),
                          style: t.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
              if (svc != null && (svc.mapsUrl == null || !svc.secretSet))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'The NAS has not told GET.ride its tunnel address and secret yet: set MAPS_URL and MAPS_SECRET '
                    'in its .env.',
                    key: const ValueKey('nas-maps-no-tunnel'),
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
                  ),
                ),
              const Divider(height: 24),
              Text('Weekly refresh', style: t.textTheme.titleSmall),
              const SizedBox(height: 4),
              if (refresh?.running == true) ...[
                Text(refresh!.stageLabel, key: const ValueKey('nas-maps-refresh')),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: refresh.percent == null ? null : refresh.percent! / 100),
              ] else
                Text(
                  [
                    refresh?.lastOkAt == null
                        ? 'Not refreshed yet'
                        : 'Last refreshed ${date.format(refresh!.lastOkAt!)}',
                    if (refresh?.dataDate != null) 'OpenStreetMap of ${date.format(refresh!.dataDate!)}',
                    if (refresh?.nextAt != null) 'next ${date.format(refresh!.nextAt!)}',
                  ].join(' · '),
                  key: const ValueKey('nas-maps-refresh'),
                  style: t.textTheme.bodySmall,
                ),
              if (refresh?.lastError != null && refresh?.running != true)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    refresh!.lastError!,
                    key: const ValueKey('nas-maps-refresh-error'),
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Text(
              'Who gets the NAS, and before or after which provider, is set in Admin > Maps: pick '
              '"${mapProviderLabel('nas')}" in the lists.',
              style: t.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeoutSlider extends StatelessWidget {
  const _TimeoutSlider({required this.value, required this.onChanged, this.sliderKey});
  final int value;
  final ValueChanged<int>? onChanged;
  final Key? sliderKey;

  @override
  Widget build(BuildContext context) => Slider(
    key: sliderKey,
    min: nasTimeoutMin.toDouble(),
    max: nasTimeoutMax.toDouble(),
    divisions: (nasTimeoutMax - nasTimeoutMin) ~/ 100,
    label: nasSeconds(value),
    value: value.clamp(nasTimeoutMin, nasTimeoutMax).toDouble(),
    onChanged: onChanged == null ? null : (v) => onChanged!(v.round()),
  );
}

class _DefaultRuleCard extends StatefulWidget {
  const _DefaultRuleCard({required this.settings, required this.canEdit, required this.saved, required this.onChange});

  final NasMapsSettings settings;
  final bool canEdit;
  final bool saved;
  final ValueChanged<NasMapsSettings> onChange;

  @override
  State<_DefaultRuleCard> createState() => _DefaultRuleCardState();
}

class _DefaultRuleCardState extends State<_DefaultRuleCard> {
  // The slider's value while it is dragged; saved when let go.
  int? _dragging;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rule = widget.settings.defaultRule;
    final timeout = _dragging ?? rule.timeoutMs ?? nasTimeoutDefault;
    void set(NasMapsRule r) => widget.onChange(widget.settings.copyWith(defaultRule: r));
    return Card(
      key: const ValueKey('nas-maps-default'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Default rule', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Everywhere without a region rule of its own.', style: t.textTheme.bodySmall),
            for (final p in NasMapsPart.values)
              SwitchListTile(
                key: ValueKey('nas-maps-default-${p.name}'),
                contentPadding: EdgeInsets.zero,
                title: Text(p.label),
                subtitle: Text(p.help),
                value: rule.part(p) ?? true,
                onChanged: widget.canEdit ? (v) => set(rule.withPart(p, v)) : null,
              ),
            const SizedBox(height: 8),
            Text('Wait for the NAS ${nasSeconds(timeout)}', style: t.textTheme.titleSmall),
            Slider(
              key: const ValueKey('nas-maps-default-timeout'),
              min: nasTimeoutMin.toDouble(),
              max: nasTimeoutMax.toDouble(),
              divisions: (nasTimeoutMax - nasTimeoutMin) ~/ 100,
              label: nasSeconds(timeout),
              value: timeout.toDouble(),
              onChanged: widget.canEdit ? (v) => setState(() => _dragging = v.round()) : null,
              onChangeEnd: widget.canEdit
                  ? (v) {
                      setState(() => _dragging = null);
                      set(rule.withTimeout(v.round()));
                    }
                  : null,
            ),
            Text(
              'A route or search the NAS has not answered by then goes to the next provider in Admin > Maps.'
              '${widget.saved ? ' Saved.' : ''}',
              key: const ValueKey('nas-maps-default-note'),
              style: t.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _RegionsCard extends StatelessWidget {
  const _RegionsCard({
    required this.settings,
    required this.canEdit,
    required this.onAdd,
    required this.onEdit,
    required this.onRemove,
  });

  final NasMapsSettings settings;
  final bool canEdit;
  final VoidCallback onAdd;
  final ValueChanged<NasMapsRegion> onEdit;
  final ValueChanged<NasMapsRegion> onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final regions = [...settings.regions]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Card(
      key: const ValueKey('nas-maps-regions'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Region rules', style: t.textTheme.titleMedium)),
                if (canEdit)
                  TextButton.icon(
                    key: const ValueKey('nas-maps-add-region'),
                    onPressed: onAdd,
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Change the Default rule in a country, state, city or suburb, e.g. search off in Singapore. The most '
              'specific region holding the place wins; a rule changes only what it sets. The web map follows the '
              'Default rule only: it loads before the app knows where the user is.',
              style: t.textTheme.bodySmall,
            ),
            if (regions.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('No region rules: the Default rule applies everywhere.', style: t.textTheme.bodySmall),
              ),
            for (final r in regions)
              ListTile(
                key: ValueKey('nas-maps-region-${r.name}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.place_outlined),
                title: Text(r.name),
                subtitle: Text(nasRuleSummary(r.rule)),
                onTap: canEdit ? () => onEdit(r) : null,
                trailing: canEdit
                    ? IconButton(
                        key: ValueKey('nas-maps-region-remove-${r.name}'),
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => onRemove(r),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

/// One region's rule: each part as the Default rule, on or off, and its
/// own wait or the Default's.
class _RegionRuleDialog extends StatefulWidget {
  const _RegionRuleDialog({required this.region, required this.defaults});
  final NasMapsRegion region;
  final NasMapsRule defaults;

  @override
  State<_RegionRuleDialog> createState() => _RegionRuleDialogState();
}

class _RegionRuleDialogState extends State<_RegionRuleDialog> {
  late NasMapsRule _rule = widget.region.rule;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ownWait = _rule.timeoutMs != null;
    return AlertDialog(
      key: const ValueKey('nas-maps-region-dialog'),
      title: Text(widget.region.name),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final p in NasMapsPart.values) ...[
                Text(p.label, style: t.textTheme.titleSmall),
                const SizedBox(height: 4),
                SegmentedButton<int>(
                  key: ValueKey('nas-maps-region-${p.name}'),
                  segments: [
                    ButtonSegment(value: 0, label: Text('Default (${widget.defaults.part(p) ?? true ? 'on' : 'off'})')),
                    const ButtonSegment(value: 1, label: Text('On')),
                    const ButtonSegment(value: 2, label: Text('Off')),
                  ],
                  selected: {
                    switch (_rule.part(p)) {
                      null => 0,
                      true => 1,
                      false => 2,
                    },
                  },
                  onSelectionChanged: (v) => setState(
                    () => _rule = _rule.withPart(p, switch (v.first) {
                      1 => true,
                      2 => false,
                      _ => null,
                    }),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SwitchListTile(
                key: const ValueKey('nas-maps-region-own-wait'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  ownWait
                      ? 'Wait for the NAS ${nasSeconds(_rule.timeoutMs)}'
                      : 'Wait as the Default rule (${nasSeconds(widget.defaults.timeoutMs)})',
                ),
                value: ownWait,
                onChanged: (v) => setState(
                  () => _rule = _rule.withTimeout(v ? (widget.defaults.timeoutMs ?? nasTimeoutDefault) : null),
                ),
              ),
              if (ownWait)
                _TimeoutSlider(
                  sliderKey: const ValueKey('nas-maps-region-timeout'),
                  value: _rule.timeoutMs!,
                  onChanged: (v) => setState(() => _rule = _rule.withTimeout(v)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('nas-maps-region-save'),
          onPressed: () => Navigator.pop(context, _rule),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.status, required this.settings, this.onEditPrices});

  final NasMapsStatus status;
  final NasMapsSettings settings;
  final VoidCallback? onEditPrices;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final saved = NasMapsStatus(settings: settings, days30: status.days30).savedUsd30;
    TableRow row(List<String> cells, {bool head = false}) => TableRow(
      children: [
        for (final c in cells)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(c, style: head ? t.textTheme.labelSmall : null),
          ),
      ],
    );
    return Card(
      key: const ValueKey('nas-maps-usage'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('What the NAS answered', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(3),
                1: FlexColumnWidth(2),
                2: FlexColumnWidth(2),
                3: FlexColumnWidth(2),
              },
              children: [
                row(['', 'Today', '30 days', 'Average'], head: true),
                for (final (k, label) in nasUsageKinds)
                  row([
                    label,
                    '${status.today[k]?.served ?? 0}',
                    '${status.days30[k]?.served ?? 0}',
                    nasSeconds(status.days30[k]?.avgMs),
                  ]),
              ],
            ),
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                final missed = status.days30.values.fold(const NasUsage(), (a, b) => a + b);
                return Text(
                  missed.failed + missed.timedOut == 0
                      ? 'Nothing passed on in 30 days.'
                      : 'Passed on to the next provider in 30 days: ${missed.timedOut} too slow, ${missed.failed} failed.',
                  key: const ValueKey('nas-maps-passed-on'),
                  style: t.textTheme.bodySmall,
                );
              },
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Saved in 30 days: about ${nasUsd(saved)}',
                    key: const ValueKey('nas-maps-saved'),
                    style: t.textTheme.titleSmall,
                  ),
                ),
                if (onEditPrices != null)
                  TextButton(
                    key: const ValueKey('nas-maps-prices'),
                    onPressed: onEditPrices,
                    child: const Text('Prices'),
                  ),
              ],
            ),
            Text(
              'At Google\'s prices: ${nasUsd(settings.routeCost)} per 1,000 routes and distances, '
              '${nasUsd(settings.searchCost)} per 1,000 searches and address lookups.',
              style: t.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Google's prices: USD per 1,000 routes, per 1,000 searches.
typedef _Prices = (double, double);

class _PricesDialog extends StatefulWidget {
  const _PricesDialog({required this.route, required this.search});
  final double route;
  final double search;

  @override
  State<_PricesDialog> createState() => _PricesDialogState();
}

class _PricesDialogState extends State<_PricesDialog> {
  late final _route = TextEditingController(text: _fmt(widget.route));
  late final _search = TextEditingController(text: _fmt(widget.search));

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';

  double? _value(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    return v == null || v < 0 || v > 100 ? null : v;
  }

  @override
  void dispose() {
    _route.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _value(_route) != null && _value(_search) != null;
    final input = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
    return AlertDialog(
      title: const Text("Google's prices"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('nas-maps-price-route'),
            controller: _route,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: input,
            decoration: const InputDecoration(labelText: 'USD per 1,000 routes', helperText: '0 to 100'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('nas-maps-price-search'),
            controller: _search,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: input,
            decoration: const InputDecoration(labelText: 'USD per 1,000 searches', helperText: '0 to 100'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('nas-maps-price-save'),
          onPressed: ok ? () => Navigator.pop(context, (_value(_route)!, _value(_search)!)) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
