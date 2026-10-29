// Admin › Settings › Hourly hire (migration 0326): every hire setting —
// on / off, now and later, the hours, overtime and extensions, an early
// end, the GET.wallet hold, cash, the km per hour, the reminder and the
// auto-end, and the texts riders see. The rates are per Vehicle Service and
// per fare tariff card.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hourly_hire.dart';
import '../../data/hourly_hire_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

class HourlyHireCard extends ConsumerWidget {
  const HourlyHireCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('hourly-hire-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Hourly hire', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(
            'Riders hire a driver and car by the hour, now or later, from the booking panel\'s "Hire by time" side. '
            'The price is the server\'s: hours × the hourly rate set on each Vehicle Service (or a fare tariff card).',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: ref.watch(hourlyHireConfigProvider),
            onRetry: () => ref.invalidate(hourlyHireConfigProvider),
            data: (c) => HourlyHireForm(key: ValueKey(c.toJson().toString()), stored: c, canEdit: canEdit),
          ),
        ]),
      ),
    );
  }
}

class HourlyHireForm extends ConsumerStatefulWidget {
  const HourlyHireForm({super.key, required this.stored, required this.canEdit, this.onSave});

  final HourlyHireConfig stored;
  final bool canEdit;

  /// Saves it (tests); null: the server.
  final Future<void> Function(HourlyHireConfig c)? onSave;

  @override
  ConsumerState<HourlyHireForm> createState() => _HourlyHireFormState();
}

class _HourlyHireFormState extends ConsumerState<HourlyHireForm> {
  late final HourlyHireConfig s = widget.stored;
  late bool _enabled = s.enabled,
      _now = s.allowNow,
      _later = s.allowLater,
      _needsRider = s.extendNeedsRider,
      _riderEnds = s.riderCanEndEarly,
      _hold = s.holdInWallet,
      _cash = s.allowCash;
  late double _step = s.hourStep;
  late HireEarlyEndPays _pays = s.earlyEndPays;
  late HireCashOffLater _cashOff = s.cashOffLater;
  late final _min = TextEditingController(text: _plain(s.minHours));
  late final _max = TextEditingController(text: _plain(s.maxHours));
  late final _stepMin = TextEditingController(text: '${s.stepMinutes}');
  late final _choices = TextEditingController(text: s.extendChoices.join(', '));
  late final _buffer = TextEditingController(text: _plain(s.holdBufferPercent));
  late final _kmh = TextEditingController(text: _plain(s.kmPerHourDefault));
  late final _remind = TextEditingController(text: '${s.reminderBeforeEndMin}');
  late final _autoEnd = TextEditingController(text: '${s.autoEndAfterMin}');
  late final _tile = TextEditingController(text: s.tileTitle);
  late final _trip = TextEditingController(text: s.tripLabel);
  late final _hireText = TextEditingController(text: s.hireLabel);

  static String _plain(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  List<TextEditingController> get _fields =>
      [_min, _max, _stepMin, _choices, _buffer, _kmh, _remind, _autoEnd, _tile, _trip, _hireText];

  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  /// The form as settings; a problem in plain words instead.
  (HourlyHireConfig?, String?) _draft() {
    double? d(TextEditingController c) => double.tryParse(c.text.trim());
    final nums = [d(_min), d(_max), d(_stepMin), d(_buffer), d(_kmh), d(_remind), d(_autoEnd)];
    if (nums.contains(null)) return (null, 'Every number needs a value.');
    final choices = [
      for (final p in _choices.text.split(RegExp(r'[,\s]+'))) ?int.tryParse(p),
    ];
    if (choices.isEmpty || choices.any((m) => m < 5 || m > 720)) {
      return (null, 'Extension choices are minutes between 5 and 720, such as 30, 60, 120.');
    }
    if (d(_min)! < 0.5 || d(_min)! > 24) return (null, 'The least hours are between 0.5 and 24.');
    if (d(_max)! < d(_min)! || d(_max)! > 72) return (null, 'The most hours are between the least and 72.');
    if (!_now && !_later) return (null, 'Allow hiring now, later or both.');
    for (final (c, what) in [(_tile, 'The tile title'), (_trip, 'The trip label'), (_hireText, 'The hire label')]) {
      final v = c.text.trim();
      if (v.isEmpty || v.length > (c == _tile ? 40 : 30)) {
        return (null, '$what is 1 to ${c == _tile ? 40 : 30} characters.');
      }
    }
    return (
      HourlyHireConfig.fromJson({
        'enabled': _enabled,
        'allowNow': _now,
        'allowLater': _later,
        'minHours': d(_min),
        'maxHours': d(_max),
        'hourStep': _step,
        'stepMinutes': d(_stepMin),
        'extendChoices': choices,
        'extendNeedsRider': _needsRider,
        'riderCanEndEarly': _riderEnds,
        'earlyEndPays': _pays.db,
        'holdInWallet': _hold,
        'holdBufferPercent': d(_buffer),
        'allowCash': _cash,
        'kmPerHourDefault': d(_kmh),
        'reminderBeforeEndMin': d(_remind),
        'autoEndAfterMin': d(_autoEnd),
        'cashOffLater': _cashOff.db,
        'tileTitle': _tile.text.trim(),
        'panelLabels': {'trip': _trip.text.trim(), 'hire': _hireText.text.trim()},
      }),
      null,
    );
  }

  Future<void> _save() async {
    final (c, problem) = _draft();
    if (problem != null || c == null) {
      showInfo(context, problem ?? 'Check the settings.');
      return;
    }
    if (widget.onSave != null) {
      await widget.onSave!(c);
      return;
    }
    final saved = await runAdminAction(
      context,
      () => ref.read(hourlyHireRepositoryProvider).save(c),
      success: 'Hourly hire saved',
    );
    if (saved && mounted) ref.invalidate(hourlyHireConfigProvider);
  }

  Widget _switch(String key, String title, String? sub, bool v, ValueChanged<bool> on) => SwitchListTile(
    key: ValueKey('hire-admin-$key'),
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: sub == null ? null : Text(sub),
    value: v,
    onChanged: widget.canEdit ? (x) => setState(() => on(x)) : null,
  );

  Widget _field(String key, TextEditingController c, String label, String hint, {bool number = true}) => SizedBox(
    width: 240,
    child: TextField(
      key: ValueKey('hire-admin-$key'),
      controller: c,
      enabled: widget.canEdit,
      keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
      decoration: InputDecoration(labelText: label, helperText: hint, helperMaxLines: 2),
      onChanged: (_) => setState(() {}),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final edit = widget.canEdit;
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(title, style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
    );
    Widget wrap(List<Widget> children) => Wrap(spacing: 16, runSpacing: 8, children: children);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _switch('enabled', 'Hourly hire on', 'Off: the Hire by time switch and the Hire a driver tile are hidden.',
          _enabled, (v) => _enabled = v),
      _switch('now', 'Hire now', null, _now, (v) => _now = v),
      _switch('later', 'Hire for later', 'Uses the scheduled rides booking and its settings.', _later, (v) => _later = v),
      section('Hours'),
      wrap([
        _field('min', _min, 'Least hours', '0.5–24 (a Vehicle Service may set its own)'),
        _field('max', _max, 'Most hours', 'Up to 72'),
      ]),
      const SizedBox(height: 8),
      SegmentedButton<double>(
        key: const ValueKey('hire-admin-step'),
        segments: const [
          ButtonSegment(value: 1, label: Text('Whole hours')),
          ButtonSegment(value: 0.5, label: Text('Half hours')),
        ],
        selected: {_step},
        onSelectionChanged: edit ? (v) => setState(() => _step = v.first) : null,
      ),
      section('Overtime and extensions'),
      wrap([
        _field('step-minutes', _stepMin, 'Overtime charged per', 'Minutes, 5–120: each started step is charged'),
        _field('choices', _choices, 'Extension choices', 'Minutes, such as 30, 60, 120', number: false),
      ]),
      _switch('needs-rider', "A driver's extension needs the rider's approval",
          'Off: the driver\'s ask is approved at once.', _needsRider, (v) => _needsRider = v),
      section('Ending early'),
      _switch('rider-ends', 'The rider may end the hire', null, _riderEnds, (v) => _riderEnds = v),
      const SizedBox(height: 4),
      Text('An early end pays', style: t.textTheme.bodyMedium),
      const SizedBox(height: 4),
      SegmentedButton<HireEarlyEndPays>(
        key: const ValueKey('hire-admin-pays'),
        segments: [
          for (final p in HireEarlyEndPays.values) ButtonSegment(value: p, label: Text(p.label)),
        ],
        selected: {_pays},
        onSelectionChanged: edit ? (v) => setState(() => _pays = v.first) : null,
      ),
      section('Payment'),
      _switch('hold', 'Hold the price in GET.wallet', 'Held when booked, settled when the hire ends.',
          _hold, (v) => _hold = v),
      _switch('cash', 'Allow cash', null, _cash, (v) => _cash = v),
      const SizedBox(height: 4),
      Text('A hire booked for later in cash, after cash is turned off', style: t.textTheme.bodyMedium),
      const SizedBox(height: 4),
      SegmentedButton<HireCashOffLater>(
        key: const ValueKey('hire-admin-cash-off'),
        segments: [for (final m in HireCashOffLater.values) ButtonSegment(value: m, label: Text(m.label))],
        selected: {_cashOff},
        onSelectionChanged: edit ? (v) => setState(() => _cashOff = v.first) : null,
      ),
      Text('Decided when the hire is released; the rider is told.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      wrap([
        _field('buffer', _buffer, 'Hold buffer', 'Percent over the price, 0–100'),
        _field('kmh', _kmh, 'Km included per hour', 'Where a Vehicle Service sets none'),
      ]),
      section('Timing'),
      wrap([
        _field('remind', _remind, 'Reminder before the end', 'Minutes; 0: none'),
        _field('auto-end', _autoEnd, 'Auto-end after the time is up', 'Minutes, 5–1440'),
      ]),
      section('What riders see'),
      wrap([
        _field('tile', _tile, 'Home tile title', 'Admin › Display › Home page: target Hire a driver', number: false),
        _field('trip-label', _trip, 'Switch: trips', 'Such as Go somewhere', number: false),
        _field('hire-label', _hireText, 'Switch: hire', 'Such as Hire by time', number: false),
      ]),
      if (edit) ...[
        const SizedBox(height: 12),
        BusyButton.filled(
          key: const ValueKey('hire-admin-save'),
          onPressed: _save,
          icon: const Icon(Icons.save_outlined),
          child: const Text('Save hourly hire'),
        ),
      ],
    ]);
  }
}
