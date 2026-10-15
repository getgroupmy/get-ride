import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ev_profile.dart';
import '../../core/installed_app.dart';
import '../../data/ev_profile_repository.dart';
import '../../data/obd/obd_session.dart';

/// Hands a job the reader to itself (the shared session's [ObdSession.exclusive]).
/// A seam so tests can script the car.
typedef EvExclusiveLink = Future<T> Function<T>(Future<T> Function(EvSend send) job);

final evCaptureLinkProvider = Provider<EvExclusiveLink>((ref) => ref.read(obdSessionProvider.notifier).exclusive);

/// Opens "Record for support" over [context].
Future<void> showEvCaptureSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const EvCaptureSheet(),
);

enum _Stage { form, running, done, sent }

/// Record for support: asks the car the generic capture script
/// ([evCaptureScript]) through the connected reader and sends what it
/// answered to support, who build the car's EV profile from it.
class EvCaptureSheet extends ConsumerStatefulWidget {
  const EvCaptureSheet({super.key});

  @override
  ConsumerState<EvCaptureSheet> createState() => _EvCaptureSheetState();
}

class _EvCaptureSheetState extends ConsumerState<EvCaptureSheet> {
  final _vehicle = TextEditingController();
  final _battery = TextEditingController();
  final _scanHeader = TextEditingController();
  final _scanFrom = TextEditingController();
  final _scanTo = TextEditingController();

  _Stage _stage = _Stage.form;
  String? _error;
  bool _cancelled = false;
  bool _sending = false;
  int _done = 0;
  int _total = 0;
  String _asking = '';
  String? _reader;
  List<EvCaptureEntry> _entries = const [];

  @override
  void dispose() {
    _cancelled = true;
    for (final c in [_vehicle, _battery, _scanHeader, _scanFrom, _scanTo]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The optional range scan, or why it can't run; (null, null) when unused.
  (EvRangeScan?, String?) _range() {
    final h = normalizeHex(_scanHeader.text), f = normalizeHex(_scanFrom.text), t = normalizeHex(_scanTo.text);
    if (h.isEmpty && f.isEmpty && t.isEmpty) return (null, null);
    final from = int.tryParse(f, radix: 16), to = int.tryParse(t, radix: 16);
    if (from == null || to == null) return (null, 'Enter the first and last identifier in hex, e.g. 0100 and 01FF.');
    final scan = EvRangeScan(header: h, from: from, to: to);
    return (scan, scan.problem);
  }

  Future<void> _start() async {
    final vehicle = _vehicle.text.trim();
    if (vehicle.isEmpty) return setState(() => _error = 'Enter the make, model and year.');
    final battery = _battery.text.trim();
    if (battery.isNotEmpty) {
      final n = num.tryParse(battery.replaceAll('%', '').trim());
      if (n == null || n < 0 || n > 100) return setState(() => _error = 'Enter the battery as a number from 0 to 100.');
    }
    final (range, rangeProblem) = _range();
    if (rangeProblem != null) return setState(() => _error = rangeProblem);
    final steps = evCaptureScript(range: range);
    setState(() {
      _error = null;
      _cancelled = false;
      _stage = _Stage.running;
      _done = 0;
      _total = steps.length;
      _asking = '';
    });
    try {
      final link = ref.read(evCaptureLinkProvider);
      final (reader, entries) = await link((send) async {
        String? reader;
        try {
          reader = cleanReaderName(await send('ATI'));
        } on StateError {
          rethrow;
        } catch (_) {}
        final entries = await runEvCapture(
          send,
          steps,
          shouldContinue: () => !_cancelled,
          onProgress: (done, total, step) {
            if (!mounted) return;
            setState(() {
              _done = done;
              _total = total;
              _asking = step.request.isEmpty ? '' : '${step.header}: ${step.request}';
            });
          },
        );
        return (reader, entries);
      });
      if (!mounted) return;
      setState(() {
        _reader = reader;
        _entries = entries;
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.form;
        _error = '$e'.replaceFirst(RegExp(r'^(Bad state|StateError|Exception):\s*'), '');
      });
    }
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final battery = _battery.text.trim();
    try {
      await ref
          .read(evProfileRepositoryProvider)
          .uploadCapture(
            EvCapture(
              vehicle: _vehicle.text.trim(),
              batteryHint: battery.isEmpty ? null : '${battery.replaceAll('%', '').trim()}%',
              reader: _reader,
              appVersion: InstalledApp.version,
              entries: _entries,
            ),
          );
      if (mounted) setState(() => _stage = _Stage.sent);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send it. Check the phone is online and try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final linked = ref.watch(obdSessionProvider.select((s) => s.linked));
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            key: const ValueKey('ev-capture-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Record for support', style: t.textTheme.titleLarge),
              const SizedBox(height: 8),
              ...switch (_stage) {
                _Stage.form => _form(t, linked),
                _Stage.running => _running(t),
                _Stage.done => _summary(t),
                _Stage.sent => _sent(t),
              },
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const ValueKey('ev-capture-error'),
                  style: TextStyle(color: t.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _form(ThemeData t, bool linked) => [
    const Text(
      "If your electric car doesn't show its battery here, record what it answers and send it to support. "
      'Support uses it to add your car.',
    ),
    const SizedBox(height: 8),
    Card(
      margin: EdgeInsets.zero,
      color: t.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.power_settings_new, color: t.colorScheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Switch the car on (Ready, as for driving) and keep it parked. It takes about a minute. '
                'The app only asks questions: nothing in the car is changed.',
                style: TextStyle(color: t.colorScheme.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      key: const ValueKey('ev-capture-vehicle'),
      controller: _vehicle,
      textCapitalization: TextCapitalization.words,
      decoration: const InputDecoration(labelText: 'Make, model and year'),
    ),
    TextField(
      key: const ValueKey('ev-capture-battery'),
      controller: _battery,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        labelText: 'Battery now, % (optional)',
        helperText: 'As the dashboard shows it: it helps support find the battery in the answers.',
      ),
    ),
    ExpansionTile(
      key: const ValueKey('ev-capture-advanced'),
      tilePadding: EdgeInsets.zero,
      title: const Text('Advanced: also scan a range'),
      subtitle: const Text('Only when support asks for it'),
      children: [
        TextField(
          controller: _scanHeader,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'ECU header', hintText: 'e.g. 7E4'),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _scanFrom,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'First identifier (hex)'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _scanTo,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Last identifier (hex)'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    ),
    const SizedBox(height: 12),
    if (!linked)
      Text(
        'Connect the OBD-II reader first.',
        key: const ValueKey('ev-capture-offline'),
        style: TextStyle(color: t.colorScheme.error),
      ),
    FilledButton.icon(
      key: const ValueKey('ev-capture-start'),
      onPressed: linked ? _start : null,
      icon: const Icon(Icons.fiber_manual_record),
      label: const Text('Start recording'),
    ),
  ];

  List<Widget> _running(ThemeData t) => [
    const Text('Recording… Keep the car on and the phone near the reader.'),
    const SizedBox(height: 12),
    LinearProgressIndicator(
      key: const ValueKey('ev-capture-progress'),
      value: _total <= 0 ? null : (_done / _total).clamp(0.0, 1.0),
    ),
    const SizedBox(height: 4),
    Text(_asking.isEmpty ? '$_done of $_total' : '$_done of $_total · asking $_asking', style: t.textTheme.bodySmall),
    const SizedBox(height: 12),
    OutlinedButton(
      key: const ValueKey('ev-capture-cancel'),
      onPressed: _cancelled ? null : () => setState(() => _cancelled = true),
      child: Text(_cancelled ? 'Stopping…' : 'Cancel'),
    ),
  ];

  List<Widget> _summary(ThemeData t) {
    final s = summarizeEvCapture(_entries);
    final answered = [
      for (final e in _entries)
        if (e.answered) e,
    ];
    return [
      Text(
        _cancelled ? 'Stopped. ${_entries.length} of $_total questions were asked.' : 'Done.',
        style: t.textTheme.titleMedium,
      ),
      const SizedBox(height: 4),
      Text(
        '${s.answered} answered, ${s.refused} refused by the car, ${s.silent} with no answer.',
        key: const ValueKey('ev-capture-summary'),
      ),
      if (s.answered == 0) ...[
        const SizedBox(height: 4),
        const Text(
          'Nothing answered. Check the car is on (Ready) — support can still use this to see what your '
          'reader can reach.',
        ),
      ],
      if (answered.isNotEmpty) ...[
        const SizedBox(height: 8),
        for (final e in answered.take(6))
          Text(
            '${e.header} ${e.request} → ${e.reply.split(RegExp(r'[\r\n]+')).first}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.textTheme.bodySmall,
          ),
      ],
      if (_reader != null) ...[const SizedBox(height: 4), Text('Reader: $_reader', style: t.textTheme.bodySmall)],
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const ValueKey('ev-capture-send'),
        onPressed: _sending || _entries.isEmpty ? null : _send,
        icon: const Icon(Icons.send_outlined),
        label: Text(_sending ? 'Sending…' : 'Send to support'),
      ),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Discard')),
    ];
  }

  List<Widget> _sent(ThemeData t) => [
    Row(
      children: [
        Icon(Icons.check_circle_outline, color: t.colorScheme.primary),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Sent. Thank you — support will use it to add your car. Once it is added, the battery shows here '
            'by itself.',
            key: ValueKey('ev-capture-sent'),
          ),
        ),
      ],
    ),
    const SizedBox(height: 12),
    FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
  ];
}

/// The reader's own name from its ATI answer (`ELM327 v1.5`).
String? cleanReaderName(String raw) {
  final line = raw
      .replaceAll('>', '')
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && l.toUpperCase() != 'ATI')
      .firstOrNull;
  if (line == null) return null;
  return line.length > 120 ? line.substring(0, 120) : line;
}
