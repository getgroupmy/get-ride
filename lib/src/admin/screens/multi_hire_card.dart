// Admin › Settings › Daily hire (migration 0327): every setting of a hire
// for several days — on / off, the most days, the hours a day, the km a day,
// the lead time and how far ahead, the deposit and prepaying, cancelling,
// the same driver and the cut-off, the allowances, the most open bookings,
// and the labels riders see. The rates are per Vehicle Service and per fare
// tariff card.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/multi_day_hire.dart';
import '../../data/hourly_hire_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

/// What each package's card says (0327: daily).
String multiHireCardIntro(String package) => switch (package) {
  _ => 'Riders hire a driver and car for 1 day or more, booked ahead, from the "Hire by time" side. '
      'Each day is its own trip, released before it starts like a scheduled ride. The price is the server\'s: '
      'the day rate set on each Vehicle Service (or a fare tariff card).',
};

class MultiHireCard extends ConsumerWidget {
  const MultiHireCard({super.key, required this.package, required this.title, required this.canEdit});

  final String package;
  final String title;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: ValueKey('$package-hire-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(
            multiHireCardIntro(package),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: ref.watch(multiHireConfigProvider(package)),
            onRetry: () => ref.invalidate(multiHireConfigProvider(package)),
            data: (c) => MultiHireForm(key: ValueKey(c.toJson().toString()), stored: c, canEdit: canEdit),
          ),
        ]),
      ),
    );
  }
}

class MultiHireForm extends ConsumerStatefulWidget {
  const MultiHireForm({super.key, required this.stored, required this.canEdit, this.onSave});

  final MultiHireConfig stored;
  final bool canEdit;

  /// Saves it (tests); null: the server.
  final Future<void> Function(MultiHireConfig c)? onSave;

  @override
  ConsumerState<MultiHireForm> createState() => _MultiHireFormState();
}

class _MultiHireFormState extends ConsumerState<MultiHireForm> {
  late final MultiHireConfig s = widget.stored;
  late bool _enabled = s.enabled,
      _prepay = s.allowPrepay,
      _same = s.sameDriverDefault,
      _split = s.splitDays;
  late HireLateCancel _late = s.lateCancel;
  late final Map<String, TextEditingController> _n = {
    'maxDays': TextEditingController(text: '${s.maxDays}'),
    'minHoursPerDay': TextEditingController(text: _plain(s.minHoursPerDay)),
    'maxHoursPerDay': TextEditingController(text: _plain(s.maxHoursPerDay)),
    'hoursPerDayDefault': TextEditingController(text: _plain(s.hoursPerDayDefault)),
    'kmPerDayDefault': TextEditingController(text: _plain(s.kmPerDayDefault)),
    'leadHours': TextEditingController(text: '${s.leadHours}'),
    'bookAheadDays': TextEditingController(text: '${s.bookAheadDays}'),
    'depositPercent': TextEditingController(text: _plain(s.depositPercent)),
    'freeCancelHours': TextEditingController(text: '${s.freeCancelHours}'),
    'lateCancelPercent': TextEditingController(text: _plain(s.lateCancelPercent)),
    'splitAfterHours': TextEditingController(text: '${s.splitAfterHours}'),
    'overnightAllowance': TextEditingController(text: _plain(s.overnightAllowance)),
    'mealAllowance': TextEditingController(text: _plain(s.mealAllowance)),
    'maxOpenBookings': TextEditingController(text: '${s.maxOpenBookings}'),
  };
  late final _chip = TextEditingController(text: s.chipLabel);
  late final _title = TextEditingController(text: s.title);

  static String _plain(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  @override
  void dispose() {
    for (final c in [..._n.values, _chip, _title]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The form as settings; a problem in plain words instead.
  (MultiHireConfig?, String?) _draft() {
    final v = <String, double>{};
    for (final e in _n.entries) {
      final d = double.tryParse(e.value.text.trim());
      if (d == null || d < 0) return (null, 'Every number needs a value of 0 or more.');
      v[e.key] = d;
    }
    if (v['maxDays']! < 1 || v['maxDays']! > 60) return (null, 'The most days are between 1 and 60.');
    if (v['minHoursPerDay']! < 1 || v['minHoursPerDay']! > 24) return (null, 'The least hours a day are between 1 and 24.');
    if (v['maxHoursPerDay']! < v['minHoursPerDay']! || v['maxHoursPerDay']! > 24) {
      return (null, 'The most hours a day are between the least and 24.');
    }
    if (v['depositPercent']! > 100 || v['lateCancelPercent']! > 100) return (null, 'Percents are 0 to 100.');
    for (final (c, what, max) in [(_chip, 'The chip label', 20), (_title, 'The title', 40)]) {
      final x = c.text.trim();
      if (x.isEmpty || x.length > max) return (null, '$what is 1 to $max characters.');
    }
    return (
      MultiHireConfig.fromJson(s.package, {
        ...v,
        'enabled': _enabled,
        'allowPrepay': _prepay,
        'sameDriverDefault': _same,
        'splitDays': _split,
        'lateCancelMode': _late.db,
        'labels': {'chip': _chip.text.trim(), 'title': _title.text.trim()},
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
      () => ref.read(hourlyHireRepositoryProvider).savePackage(c),
      success: '${c.title} saved',
    );
    if (saved && mounted) ref.invalidate(multiHireConfigProvider(c.package));
  }

  String get _k => s.package;

  Widget _switch(String key, String title, String? sub, bool v, ValueChanged<bool> on) => SwitchListTile(
    key: ValueKey('$_k-admin-$key'),
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: sub == null ? null : Text(sub),
    value: v,
    onChanged: widget.canEdit ? (x) => setState(() => on(x)) : null,
  );

  Widget _field(String key, String label, String hint, {TextEditingController? controller, bool number = true}) =>
      SizedBox(
        width: 240,
        child: TextField(
          key: ValueKey('$_k-admin-$key'),
          controller: controller ?? _n[key],
          enabled: widget.canEdit,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          decoration: InputDecoration(labelText: label, helperText: hint, helperMaxLines: 2),
          onChanged: (_) => setState(() {}),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(title, style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
    );
    Widget wrap(List<Widget> children) => Wrap(spacing: 16, runSpacing: 8, children: children);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _switch('enabled', '${s.title} on', 'Off: the chip on the Hire by time side is hidden.', _enabled, (v) => _enabled = v),
      section('Days and hours'),
      wrap([
        _field('maxDays', 'Most days', '1–60'),
        _field('minHoursPerDay', 'Least hours a day', '1–24, in half hours'),
        _field('maxHoursPerDay', 'Most hours a day', 'Up to 24'),
        _field('hoursPerDayDefault', 'Hours a day to start from', 'Within the least and the most'),
        _field('kmPerDayDefault', 'Km included a day', 'Where a Vehicle Service sets none'),
      ]),
      section('Booking ahead'),
      wrap([
        _field('leadHours', 'Book at least', 'Hours before the first day'),
        _field('bookAheadDays', 'Book up to', 'Days ahead'),
        _field('maxOpenBookings', 'Most hires booked at once', 'Per rider, 1–20'),
      ]),
      section('Payment'),
      wrap([_field('depositPercent', 'Deposit at booking', 'Percent of the price from GET.wallet; the rest on day 1')]),
      _switch('prepay', 'Riders may pay it all at booking', null, _prepay, (v) => _prepay = v),
      section('Cancelling'),
      wrap([_field('freeCancelHours', 'Free to cancel until', 'Hours before the first day')]),
      const SizedBox(height: 4),
      Text('A late cancel costs', style: t.textTheme.bodyMedium),
      const SizedBox(height: 4),
      SegmentedButton<HireLateCancel>(
        key: ValueKey('$_k-admin-late'),
        segments: [for (final m in HireLateCancel.values) ButtonSegment(value: m, label: Text(m.label))],
        selected: {_late},
        onSelectionChanged: widget.canEdit ? (v) => setState(() => _late = v.first) : null,
      ),
      if (_late == HireLateCancel.percent)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _field('lateCancelPercent', 'Kept on a late cancel', 'Percent of the price'),
        ),
      section('The driver'),
      _switch('same', 'The same driver every day, unless the rider switches it off', null, _same, (v) => _same = v),
      wrap([_field('splitAfterHours', 'Cut-off for one driver', 'Hours before the first day')]),
      _switch('split', 'At the cut-off, find a driver for each day',
          'Off: a hire no one driver took by the cut-off is cancelled and refunded.', _split, (v) => _split = v),
      section('Allowances'),
      wrap([
        _field('overnightAllowance', 'Overnight allowance', 'A night away from home, where a Vehicle Service sets none'),
        _field('mealAllowance', 'Driver meal allowance', 'A day; 0: none'),
      ]),
      section('What riders see'),
      wrap([
        _field('chip', 'Chip label', 'Such as Daily', controller: _chip, number: false),
        _field('title', 'Title', 'Such as Daily hire', controller: _title, number: false),
      ]),
      if (widget.canEdit) ...[
        const SizedBox(height: 12),
        BusyButton.filled(
          key: ValueKey('$_k-admin-save'),
          onPressed: _save,
          icon: const Icon(Icons.save_outlined),
          child: Text('Save ${s.title.toLowerCase()}'),
        ),
      ],
    ]);
  }
}
