// The gateway's one screen: the online switch, what still needs setting up,
// which SIM sends, what this session has done and its log.
import 'dart:async';

import 'package:flutter/material.dart';

import 'core.dart';
import 'engine.dart';
import 'permissions.dart';
import 'settings.dart';
import 'sms_platform.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.engine,
    required this.settings,
    required this.platform,
    required this.permissions,
    required this.account,
    required this.onSignOut,
  });

  final GatewayEngine engine;
  final GatewaySettings settings;
  final SmsPlatform platform;
  final GatewayPermissions permissions;

  /// The signed-in admin, as the app bar shows it.
  final String account;
  final Future<void> Function() onSignOut;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _granted = <GatewayPermission, bool>{};
  bool? _batteryOptimized;
  List<SimCard> _sims = const [];
  late final _label = TextEditingController(text: widget.settings.label ?? '');
  late final _simNumber = TextEditingController(text: widget.settings.simNumber ?? '');

  bool get _smsGranted => _granted[GatewayPermission.sms] ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.engine.addListener(_changed);
    unawaited(
      _refresh().then((_) {
        // Left on: back on as the app opens.
        if (mounted && widget.settings.wantOnline && _smsGranted) unawaited(widget.engine.start());
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system settings: a permission may have changed.
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.engine.removeListener(_changed);
    _label.dispose();
    _simNumber.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    for (final p in GatewayPermission.values) {
      _granted[p] = await widget.permissions.granted(p);
    }
    bool? battery;
    try {
      battery = await widget.platform.batteryOptimized();
    } catch (_) {}
    final sims = (_granted[GatewayPermission.phone] ?? false) ? await widget.platform.sims() : const <SimCard>[];
    if (!mounted) return;
    setState(() {
      _batteryOptimized = battery;
      _sims = sims;
    });
  }

  Future<void> _grant(GatewayPermission p) async {
    final ok = await widget.permissions.request(p);
    if (!ok && mounted) {
      final open = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('${p.label} permission'),
          content: Text('${p.why} Android did not grant it. You can allow it in the app\'s settings.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open settings')),
          ],
        ),
      );
      if (open == true) await widget.permissions.openSettings();
    }
    await _refresh();
  }

  Future<void> _toggle(bool on) async {
    if (on && !_smsGranted) {
      await _grant(GatewayPermission.sms);
      if (!_smsGranted) return;
    }
    widget.settings.wantOnline = on;
    on ? await widget.engine.start() : await widget.engine.stop();
  }

  Future<void> _signOut() async {
    final online = widget.engine.running;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(
          online
              ? 'The gateway will go offline. SMS routed to this phone wait in the queue until it is back.'
              : 'You can sign in again at any time.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true) return;
    widget.settings.wantOnline = false;
    await widget.engine.stop();
    await widget.onSignOut();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    return Scaffold(
      appBar: AppBar(
        title: const Text('GET.ride Gateway'),
        actions: [
          IconButton(
            key: const ValueKey('sign-out'),
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _StatusCard(engine: e, account: widget.account, onToggle: _toggle),
            const SizedBox(height: 12),
            _setupCard(context),
            const SizedBox(height: 12),
            _phoneCard(context),
            const SizedBox(height: 12),
            _StatsRow(stats: e.stats),
            const SizedBox(height: 12),
            _LogCard(entries: e.log.entries),
          ],
        ),
      ),
    );
  }

  Widget _setupCard(BuildContext context) {
    final t = Theme.of(context);
    Widget row(String title, String why, bool? ok, VoidCallback onFix, Key key, {bool required = false}) => ListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ok == true ? Icons.check_circle : (required ? Icons.error_outline : Icons.info_outline),
        color: ok == true ? Colors.green : (required ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
      ),
      title: Text(title),
      subtitle: Text(why),
      trailing: ok == true ? null : TextButton(onPressed: onFix, child: const Text('Allow')),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Setup', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            for (final p in GatewayPermission.values)
              row(p.label, p.why, _granted[p], () => _grant(p), ValueKey('permission-${p.name}'), required: p.required),
            row(
              'Battery',
              'Let the gateway run unrestricted, or Android pauses it while the screen is off.',
              _batteryOptimized == null ? null : !_batteryOptimized!,
              () async {
                await widget.platform.requestBatteryExemption();
                await _refresh();
              },
              const ValueKey('permission-battery'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _phoneCard(BuildContext context) {
    final t = Theme.of(context);
    final selected = widget.settings.subscriptionId;
    final known = _sims.any((s) => s.subscriptionId == selected);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('This phone', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (_sims.length > 1) ...[
              DropdownButtonFormField<int?>(
                key: const ValueKey('sim-picker'),
                // Full width, so a long SIM name is cut short rather than overflowing.
                isExpanded: true,
                initialValue: known ? selected : null,
                decoration: const InputDecoration(labelText: 'Send from', border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Default SMS SIM')),
                  for (final s in _sims)
                    DropdownMenuItem<int?>(
                      value: s.subscriptionId,
                      child: Text(s.title, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() {
                  widget.settings.subscriptionId = v;
                  final number = _sims.where((s) => s.subscriptionId == v).firstOrNull?.number;
                  if (number != null && _simNumber.text.trim().isEmpty) {
                    _simNumber.text = number;
                    widget.settings.simNumber = number;
                  }
                }),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const ValueKey('device-label'),
              controller: _label,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Office gateway (Maxis)',
                helperText: 'How the admin page lists this phone.',
                border: OutlineInputBorder(),
                counterText: '',
              ),
              onChanged: (v) => widget.settings.label = v,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('sim-number'),
              controller: _simNumber,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'SIM number',
                hintText: '+60 12 345 6789',
                helperText: 'The number SMS are sent from. Shown on the admin page.',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => widget.settings.simNumber = v,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.engine, required this.account, required this.onToggle});

  final GatewayEngine engine;
  final String account;
  final Future<void> Function(bool) onToggle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (label, detail, color) = switch (engine.state) {
      GatewayState.off => (
        'Offline',
        engine.stopReason ?? 'Turn on to send and receive GET.ride\'s SMS from this phone.',
        engine.stopReason == null ? t.colorScheme.outline : t.colorScheme.error,
      ),
      GatewayState.starting => ('Starting…', 'Connecting to GET.ride.', Colors.amber.shade700),
      GatewayState.online => ('Online', 'Sending the SMS routed to this phone.', Colors.green),
      GatewayState.reconnecting => (
        'Reconnecting…',
        'No connection to GET.ride. Retrying; nothing is lost meanwhile.',
        Colors.amber.shade700,
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 14, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    key: const ValueKey('gateway-state'),
                    style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Switch(key: const ValueKey('gateway-switch'), value: engine.running, onChanged: onToggle),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              key: const ValueKey('gateway-detail'),
              style: t.textTheme.bodyMedium?.copyWith(
                color: engine.stopReason != null && !engine.running ? t.colorScheme.error : null,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Signed in as $account',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.stats});

  final GatewayStats stats;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget tile(String label, int n, Key key) => Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Text(
                '$n',
                key: key,
                style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(label, style: t.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        tile('Sent', stats.sent, const ValueKey('stat-sent')),
        tile('Failed', stats.failed, const ValueKey('stat-failed')),
        tile('Received', stats.received, const ValueKey('stat-received')),
      ],
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.entries});

  final List<GatewayLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    IconData icon(GatewayLogKind k) => switch (k) {
      GatewayLogKind.sent => Icons.call_made,
      GatewayLogKind.failed => Icons.error_outline,
      GatewayLogKind.received => Icons.call_received,
      GatewayLogKind.info => Icons.info_outline,
      GatewayLogKind.error => Icons.warning_amber,
    };
    Color color(GatewayLogKind k) => switch (k) {
      GatewayLogKind.failed || GatewayLogKind.error => t.colorScheme.error,
      GatewayLogKind.sent || GatewayLogKind.received => t.colorScheme.primary,
      GatewayLogKind.info => t.colorScheme.onSurfaceVariant,
    };
    String time(DateTime at) =>
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Activity', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Nothing yet.', style: t.textTheme.bodySmall),
              )
            else
              for (final e in entries.take(50))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(icon(e.kind), size: 20, color: color(e.kind)),
                  title: Text(e.text),
                  trailing: Text(time(e.at.toLocal()), style: t.textTheme.bodySmall),
                ),
          ],
        ),
      ),
    );
  }
}
