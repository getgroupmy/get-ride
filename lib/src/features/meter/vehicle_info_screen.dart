import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/fuel_range.dart';
import '../../core/obd.dart';
import '../../core/obd_pid_catalog.dart';
import '../../core/vehicle_info.dart';
import '../../core/vehicle_scan.dart';
import '../../data/obd/obd_session.dart';
import '../../data/vehicle_fuel_store.dart';
import '../../widgets/busy.dart';
import '../../widgets/side_menu_host.dart';

/// Everything the linked OBD-II reader can tell about the vehicle it is
/// plugged into (Expo `app/vehicle-information.tsx`): identity (VIN,
/// calibration IDs, ECU name), trouble codes and readiness monitors, every
/// mode-01 parameter the car lists as supported, the adapter's details, and
/// the short list of writes, each behind a warning.
///
/// It borrows the shared reader session rather than opening its own: a
/// dongle serves one client at a time.
class VehicleInfoScreen extends ConsumerStatefulWidget {
  const VehicleInfoScreen({super.key});

  @override
  ConsumerState<VehicleInfoScreen> createState() => _VehicleInfoScreenState();
}

class _VehicleInfoScreenState extends ConsumerState<VehicleInfoScreen> {
  VehicleScanReport? _report;
  ScanProgress? _progress;
  String? _scanError;
  bool _scanning = false;
  FuelProfile _fuelProfile = defaultFuelProfile();

  @override
  void initState() {
    super.initState();
    // The range maths rests on the stored profile, scan or no scan.
    ref.read(vehicleFuelStoreProvider).load().then((p) {
      if (mounted) setState(() => _fuelProfile = p);
    }, onError: (Object _) {});
    // Read the vehicle as soon as the screen opens on a live link, and again
    // after a dropped link comes back.
    ref.listenManual(obdSessionProvider, (prev, next) {
      if (next.linked && (prev == null || !prev.linked) && _report == null) unawaited(Future.microtask(_scan));
    }, fireImmediately: true);
  }

  /// One command through the shared link; fails when the reader went away.
  Future<String> _send(String command) async {
    final reply = await ref.read(obdSessionProvider.notifier).request(command);
    if (reply == null) throw StateError('The OBD-II reader is not connected.');
    return reply;
  }

  Future<void> _scan() async {
    if (_scanning) return;
    if (!ref.read(obdSessionProvider).linked) {
      setState(() => _scanError = 'The OBD-II reader is not connected.');
      return;
    }
    final session = ref.read(obdSessionProvider.notifier);
    setState(() {
      _scanning = true;
      _scanError = null;
      _progress = const ScanProgress(done: 0, total: 1, label: 'Starting');
    });
    // The adapter answers one command at a time: hand it the whole link.
    session.setPollingPaused(true);
    try {
      final report = await scanVehicle(
        _send,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        shouldContinue: () => mounted,
      );
      if (mounted) setState(() => _report = report);
      // Odometer + fuel level together are one measurement of this vehicle's
      // own burn: the profile learns from it once enough ground is covered.
      final snap = readFuelSnapshot(report.readings);
      final odo = snap.odometerKm, level = snap.fuelLevelPercent;
      try {
        final r = await ref
            .read(vehicleFuelStoreProvider)
            .recordFuelSample(
              report.vin,
              odo != null && level != null
                  ? FuelSample(odometerKm: odo, fuelLevelPercent: level, at: DateTime.now().millisecondsSinceEpoch)
                  : null,
            );
        if (mounted) setState(() => _fuelProfile = r.profile);
      } catch (_) {
        // A storage failure is not a failed scan: the vehicle answered.
      }
    } catch (e) {
      if (mounted) setState(() => _scanError = _message(e, 'Could not read from the vehicle.'));
    } finally {
      session.setPollingPaused(false);
      if (mounted) {
        setState(() {
          _scanning = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _editFuel() async {
    final saved = await showDialog<FuelProfile>(
      context: context,
      builder: (_) => _FuelEditor(profile: _fuelProfile),
    );
    if (saved == null) return;
    final p = await ref.read(vehicleFuelStoreProvider).save(saved);
    if (mounted) setState(() => _fuelProfile = p);
  }

  static String _message(Object e, String fallback) {
    final text = '$e'.replaceFirst(RegExp(r'^(Exception|Bad state|StateError):\s*'), '');
    return text.isEmpty ? fallback : text;
  }

  @override
  Widget build(BuildContext context) {
    final obd = ref.watch(obdSessionProvider);
    final report = _report;
    return Scaffold(
      appBar: AppBar(
        leading: sideMenuLeading(context),
        title: const Text('Vehicle information'),
        actions: [
          if (obd.linked)
            BusyIconButton(tooltip: 'Read again', icon: const Icon(Icons.refresh), onPressed: _scanning ? null : _scan),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _ReaderCard(obd: obd, scanning: _scanning, progress: _progress, error: _scanError, report: report),
          if (obd.linked || report != null) ...[
            const _Header('Odometer & fuel'),
            _FuelCard(
              report: report,
              obd: obd,
              profile: _fuelProfile,
              onEdit: _editFuel,
              onResetMeasured: () async {
                final p = await ref.read(vehicleFuelStoreProvider).resetMeasuredConsumption();
                if (mounted) setState(() => _fuelProfile = p);
              },
            ),
            if (report != null) ..._reportSections(report),
          ],
          const _Header('Write to vehicle'),
          _WritesCard(obd: obd, send: _send, onVehicleChanged: () => setState(() => _report = null), rescan: _scan),
        ],
      ),
    );
  }

  List<Widget> _reportSections(VehicleScanReport r) {
    final vin = decodeVin(r.vin);
    final codes = [for (final m in dtcModes) ...?r.dtcs[m.key]];
    final monitor = r.monitor;
    return [
      const _Header('Vehicle identity'),
      Card(
        child: Column(
          children: [
            if (r.identity.isEmpty) const _Row('Identity', 'The vehicle did not report any (mode 09).'),
            for (final v in r.identity) _Row(v.label, v.value),
            if (vin != null) ...[
              _Row('Manufacturer code', '${vin.wmi}${vin.region == null ? '' : ' · ${vin.region}'}'),
              if (vin.modelYears.isNotEmpty) _Row('Model year', _modelYear(vin.modelYears)),
              _Row('Plant · serial', '${vin.plantCode} · ${vin.serial}'),
            ],
          ],
        ),
      ),
      _Header('Diagnostic trouble codes', trailing: codes.isEmpty ? null : '${codes.length}'),
      Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in dtcModes)
              ListTile(
                key: ValueKey('dtc-${m.key.name}'),
                title: Text(m.label),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.hint),
                    if (r.dtcs[m.key] == null)
                      const Text('Could not be read.')
                    else if (r.dtcs[m.key]!.isEmpty)
                      const Text('None')
                    else
                      for (final c in r.dtcs[m.key]!)
                        Text('$c — ${describeDtc(c)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
          ],
        ),
      ),
      if (monitor != null) ...[
        const _Header('Emissions readiness'),
        Card(
          child: Column(
            children: [
              _Row('Check-engine light', monitor.milOn ? 'On' : 'Off'),
              _Row('Confirmed faults', '${monitor.dtcCount}'),
              _Row('Engine type', monitor.compressionIgnition ? 'Diesel (compression)' : 'Petrol (spark)'),
              for (final m in monitor.monitors.where((m) => m.supported))
                _Row(m.label, m.complete ? 'Ready' : 'Not ready'),
            ],
          ),
        ),
      ],
      _Header('Live parameters', trailing: '${r.readings.length} of ${r.supportedPids.length}'),
      for (final g in groupReadings(r.readings, pidGroupOrder))
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(g.group.label, style: Theme.of(context).textTheme.titleSmall),
              ),
              for (final v in g.readings) _Row(v.known ? v.label : '${v.label} (PID ${v.pid})', v.value),
            ],
          ),
        ),
      if (r.unreadablePids.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Listed as supported but did not answer: ${r.unreadablePids.join(', ')}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      const _Header('Reader'),
      Card(child: Column(children: [for (final a in r.adapter) _Row(a.label, a.value)])),
    ];
  }

  /// The newest candidate that is not in the future (Expo's rule).
  static String _modelYear(List<int> years) {
    final now = DateTime.now().year;
    final ok = years.where((y) => y <= now + 1).toList();
    return '${ok.isEmpty ? years.first : ok.last}';
  }
}

/// Odometer, fuel level and distance to empty. The first two come off the
/// bus; the third is not an OBD-II parameter at all, so it is worked out from
/// the tank size the driver entered and a consumption figure — and the card
/// always says which figure it used.
class _FuelCard extends StatelessWidget {
  const _FuelCard({
    required this.report,
    required this.obd,
    required this.profile,
    required this.onEdit,
    required this.onResetMeasured,
  });

  final VehicleScanReport? report;
  final ObdSessionState obd;
  final FuelProfile profile;
  final Future<void> Function() onEdit;
  final Future<void> Function() onResetMeasured;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final snap = readFuelSnapshot(report?.readings ?? const []);
    // The level and speed are in the 1 Hz sweep, so they stay live between scans.
    final liveLevel = obd.linked ? obd.telemetry['fuelLevel'] : null;
    final liveSpeed = obd.linked ? obd.telemetry['speed'] : null;
    final fuel = computeFuelRange(
      snap.copyWith(fuelLevelPercent: liveLevel ?? snap.fuelLevelPercent, speedKmh: liveSpeed ?? snap.speedKmh),
      profile,
    );
    Widget stat(IconData icon, Color? color, String value, String label, Key key) => Expanded(
      child: Column(
        children: [
          Icon(icon, size: 18, color: color ?? t.colorScheme.outline),
          FittedBox(
            child: Text(
              value,
              key: key,
              style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Text(label, style: t.textTheme.bodySmall, textAlign: TextAlign.center),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  stat(Icons.speed, null, formatKm(fuel.odometerKm), 'km odometer', const ValueKey('fuel-odometer')),
                  stat(
                    Icons.local_gas_station,
                    fuelLevelColor(fuel.fuelLevelPercent),
                    formatPercent(fuel.fuelLevelPercent),
                    '% in the tank',
                    const ValueKey('fuel-level'),
                  ),
                  stat(
                    Icons.navigation_outlined,
                    null,
                    fuel.rangeKm == null ? '—' : '${fuel.estimated ? '≈' : ''}${formatKm(fuel.rangeKm)}',
                    'km remaining',
                    const ValueKey('fuel-range'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 8,
                  value: fuelBarFraction(fuel.fuelLevelPercent),
                  color: fuelLevelColor(fuel.fuelLevelPercent),
                ),
              ),
            ),
            if (fuel.fuelLevelPercent == null)
              const _Row('Fuel level', 'Not reported by this vehicle')
            else
              _Row(
                'Fuel remaining',
                '${formatLitres(fuel.litresRemaining)} L of ${formatLitres(profile.tankCapacityL)} L',
              ),
            _Row('Consumption used', '${formatConsumption(fuel.consumption.l100)} L/100 km'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Range is worked out from a ${formatLitres(profile.tankCapacityL)} L tank at '
                '${formatConsumption(fuel.consumption.l100)} L/100 km — ${fuel.consumption.source.label}. OBD-II '
                "publishes neither tank size nor distance to empty, so this is the app's own estimate, not the "
                'figure on your dashboard.',
                style: t.textTheme.bodySmall,
              ),
            ),
            if (fuel.odometerKm == null && report != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  'This vehicle does not answer the odometer parameter (mode 01 PID A6). Most cars built before the '
                  'late 2010s keep the odometer on the instrument cluster and never put it on the diagnostic bus.',
                  style: t.textTheme.bodySmall,
                ),
              ),
              if (fuel.distanceSinceClearedKm != null)
                _Row('Distance since codes cleared', '${formatKm(fuel.distanceSinceClearedKm)} km'),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  BusyButton.text(
                    key: const ValueKey('fuel-edit'),
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    child: const Text('Tank & consumption'),
                  ),
                  if (profile.measuredL100 != null)
                    BusyButton.text(onPressed: onResetMeasured, child: const Text('Forget measured consumption')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FuelEditor extends StatefulWidget {
  const _FuelEditor({required this.profile});
  final FuelProfile profile;

  @override
  State<_FuelEditor> createState() => _FuelEditorState();
}

class _FuelEditorState extends State<_FuelEditor> {
  late final _tank = TextEditingController(text: formatLitres(widget.profile.tankCapacityL));
  late final _consumption = TextEditingController(text: formatConsumption(widget.profile.consumptionL100));
  String? _error;

  @override
  void dispose() {
    _tank.dispose();
    _consumption.dispose();
    super.dispose();
  }

  void _save() {
    final check = validateFuelProfileInput(_tank.text, _consumption.text);
    final v = check.value;
    if (!check.ok || v == null) {
      setState(() => _error = check.error ?? 'Check the values and try again.');
      return;
    }
    Navigator.pop(context, widget.profile.copyWith(tankCapacityL: v.tankCapacityL, consumptionL100: v.consumptionL100));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Tank & consumption'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'OBD-II does not report the tank size, so enter it from the owner\'s manual. The consumption is used '
          'until the app has measured this vehicle\'s own.',
        ),
        TextField(
          key: const ValueKey('fuel-tank'),
          controller: _tank,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Tank size', suffixText: 'L'),
        ),
        TextField(
          key: const ValueKey('fuel-consumption'),
          controller: _consumption,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Average consumption', suffixText: 'L/100 km'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

class _ReaderCard extends StatelessWidget {
  const _ReaderCard({
    required this.obd,
    required this.scanning,
    required this.progress,
    required this.error,
    required this.report,
  });

  final ObdSessionState obd;
  final bool scanning;
  final ScanProgress? progress;
  final String? error;
  final VehicleScanReport? report;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = progress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 12, color: obd.linked ? Colors.green : t.colorScheme.outline),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    obd.linked ? 'Connected${obd.adapter == null ? '' : ' — ${obd.adapter!.name}'}' : 'Not connected',
                    style: t.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (!obd.linked) ...[
              const SizedBox(height: 8),
              const Text(
                'Plug the OBD-II reader in with the ignition on and connect it. This screen reads everything the '
                'reader can tell about the vehicle.',
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(onPressed: () => context.push('/meter/reader'), child: const Text('OBD-II reader')),
            ],
            if (scanning && p != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: p.total <= 0 ? null : (p.done / p.total).clamp(0.0, 1.0)),
              const SizedBox(height: 4),
              Text('Reading: ${p.label}', style: t.textTheme.bodySmall),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: TextStyle(color: t.colorScheme.error)),
            ],
            if (report != null && !scanning) ...[
              const SizedBox(height: 4),
              Text(
                'Read ${TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(report!.finishedAt)).format(context)}',
                style: t.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The writes: each behind a warning, gated on a real link and, for the ones
/// that reach the car, on it standing still — re-checked when confirmed.
class _WritesCard extends ConsumerStatefulWidget {
  const _WritesCard({required this.obd, required this.send, required this.onVehicleChanged, required this.rescan});

  final ObdSessionState obd;
  final SendCommand send;
  final VoidCallback onVehicleChanged;
  final Future<void> Function() rescan;

  @override
  ConsumerState<_WritesCard> createState() => _WritesCardState();
}

class _WritesCardState extends ConsumerState<_WritesCard> {
  WriteContext _context(ObdSessionState s) =>
      WriteContext(online: s.linked, simulated: false, speedKmh: s.telemetry['speed']);

  Future<void> _open(VehicleWriteAction action) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _WriteDialog(action: action, send: widget.send),
    );
    if (changed == true && action.target == WriteTarget.vehicle) {
      widget.onVehicleChanged();
      unawaited(widget.rescan());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _context(widget.obd);
    return Card(
      child: Column(
        children: [
          for (final a in vehicleWriteActions)
            Builder(
              builder: (context) {
                final avail = evaluateWriteAvailability(a, ctx);
                return ListTile(
                  key: ValueKey('write-${a.id.id}'),
                  enabled: avail.allowed,
                  leading: Icon(_icon(a.id), color: a.destructive && avail.allowed ? Colors.red : null),
                  title: Text(a.label),
                  subtitle: Text(avail.reason ?? a.description),
                  trailing: Chip(label: Text(a.target == WriteTarget.vehicle ? 'ECU' : 'Reader')),
                  onTap: avail.allowed ? () => _open(a) : null,
                );
              },
            ),
        ],
      ),
    );
  }

  static IconData _icon(VehicleWriteId id) => switch (id) {
    VehicleWriteId.clearDtc => Icons.cleaning_services_outlined,
    VehicleWriteId.setProtocol => Icons.memory,
    VehicleWriteId.resetAdapter => Icons.restart_alt,
    VehicleWriteId.rawCommand => Icons.terminal,
  };
}

class _WriteDialog extends ConsumerStatefulWidget {
  const _WriteDialog({required this.action, required this.send});
  final VehicleWriteAction action;
  final SendCommand send;

  @override
  ConsumerState<_WriteDialog> createState() => _WriteDialogState();
}

class _WriteDialogState extends ConsumerState<_WriteDialog> {
  final _raw = TextEditingController();
  var _protocol = '0';
  var _busy = false;
  ({bool ok, String message})? _result;

  @override
  void dispose() {
    _raw.dispose();
    super.dispose();
  }

  Future<void> _perform() async {
    final a = widget.action;
    final s = ref.read(obdSessionProvider);
    // Re-check against the link as it is now: the car may have started moving.
    final avail = evaluateWriteAvailability(
      a,
      WriteContext(online: s.linked, simulated: false, speedKmh: s.telemetry['speed']),
    );
    if (!avail.allowed) {
      setState(() => _result = (ok: false, message: avail.reason ?? 'This write is not available right now.'));
      return;
    }
    final session = ref.read(obdSessionProvider.notifier);
    setState(() {
      _busy = true;
      _result = null;
    });
    session.setPollingPaused(true);
    try {
      final send = widget.send;
      final ({bool ok, String message}) result;
      switch (a.id) {
        case VehicleWriteId.clearDtc:
          final raw = await send('04');
          result = isWriteAcknowledged(raw, '44')
              ? (
                  ok: true,
                  message:
                      'Codes cleared. The readiness monitors are now "not ready" until the vehicle completes a '
                      'drive cycle.',
                )
              : (ok: false, message: 'The vehicle refused the request: ${raw.trim()}');
        case VehicleWriteId.setProtocol:
          final raw = await send('ATSP$_protocol');
          final ok = isWriteAcknowledged(raw);
          final name = ok ? parseAtText(await send('ATDP')) : null;
          result = ok
              ? (ok: true, message: 'Protocol set${name == null ? '' : ' — now $name'}.')
              : (ok: false, message: 'The adapter refused the change: ${raw.trim()}');
        case VehicleWriteId.resetAdapter:
          await send('ATZ');
          // ATZ restores power-on defaults: re-run the handshake, or echo comes
          // back on and every later reply is unparseable.
          for (final c in elmInitCommands.skip(1)) {
            await send(c);
          }
          result = (ok: true, message: 'Reader reset and re-initialised.');
        case VehicleWriteId.rawCommand:
          final check = validateRawCommand(_raw.text);
          if (!check.ok || check.command == null) {
            result = (ok: false, message: check.error ?? 'Invalid command.');
          } else {
            final raw = (await send(check.command!)).trim();
            result = (ok: true, message: raw.isEmpty ? '(no response)' : raw);
          }
      }
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) {
        setState(() => _result = (ok: false, message: _VehicleInfoScreenState._message(e, 'The command failed.')));
      }
    } finally {
      session.setPollingPaused(false);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    final t = Theme.of(context);
    final result = _result;
    // A one-shot write that worked has nothing left to confirm; the raw
    // console stays open, since one command is usually the start of a session.
    final done = result?.ok == true && a.id != VehicleWriteId.rawCommand;
    final check = _raw.text.trim().isEmpty ? null : validateRawCommand(_raw.text);
    return AlertDialog(
      title: Text(a.warningTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(a.warningBody),
            if (a.id == VehicleWriteId.setProtocol) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _protocol,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Protocol'),
                items: [for (final e in elmProtocolNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: _busy ? null : (v) => setState(() => _protocol = v ?? '0'),
              ),
            ],
            if (a.id == VehicleWriteId.rawCommand) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('raw-command'),
                controller: _raw,
                enabled: !_busy,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'Command',
                  hintText: 'e.g. ATRV or 0100',
                  helperText: check == null || !check.ok
                      ? null
                      : (check.write == true
                            ? 'Writes to the vehicle'
                            : (check.target == WriteTarget.adapter ? 'Reader command' : 'Vehicle read')),
                  errorText: check != null && !check.ok ? check.error : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: 12),
              Text(
                result.message,
                key: const ValueKey('write-result'),
                style: TextStyle(
                  color: result.ok ? Colors.green : t.colorScheme.error,
                  fontFamily: a.id == VehicleWriteId.rawCommand ? 'monospace' : null,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: done
          ? [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Close'))]
          : [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context, result?.ok == true),
                child: Text(result == null ? 'Cancel' : 'Close'),
              ),
              BusyButton.filled(
                style: a.destructive ? FilledButton.styleFrom(backgroundColor: t.colorScheme.error) : null,
                onPressed: _busy || (a.id == VehicleWriteId.rawCommand && check?.ok != true) ? null : _perform,
                child: Text(a.confirmLabel),
              ),
            ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text, {this.trailing});
  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
    child: Row(
      children: [
        Expanded(child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelLarge)),
        if (trailing != null) Text(trailing!, style: Theme.of(context).textTheme.labelLarge),
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
