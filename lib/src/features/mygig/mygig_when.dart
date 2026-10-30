// myGiG part B (0330): what the driver sends and when, on the trip
// details: Trip / Hourly / Daily / Weekly / Monthly, the package's options,
// Now / Later (Today, Tomorrow, a day chip, or another date typed in the
// day, month and year boxes with the calendar button, and a time), and how
// it is paid. The booking's terms as the passenger sees them.
import 'package:flutter/material.dart';

import '../../core/mygig.dart' show mygigMoney;
import '../../core/mygig_hire.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/search_select.dart';

/// Trip, then the hire packages the driver may send here.
class MygigKindChips extends StatelessWidget {
  const MygigKindChips({super.key, required this.kinds, required this.selected, required this.onSelected});
  final List<MygigKind> kinds;
  final MygigKind selected;
  final ValueChanged<MygigKind> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
    for (final k in kinds)
      ChoiceChip(
        key: ValueKey('mygig-kind-${k.name}'),
        label: Text(k.chip),
        selected: selected == k,
        onSelected: (_) => onSelected(k),
      ),
  ]);
}

/// The package's options: hours, days, weeks or months, hours a day, the
/// working days, an overnight trip.
class MygigHireOptions extends StatelessWidget {
  const MygigHireOptions({super.key, required this.choice, required this.settings, required this.rates, required this.onChanged,
      this.kmIncluded});
  final MygigBookingChoice choice;
  final MygigHireSettings settings;
  final MygigHireRates rates;
  final ValueChanged<MygigBookingChoice> onChanged;

  /// The km the server's quote includes.
  final double? kmIncluded;

  Widget _step(BuildContext context, String key, String label, num value, num min, num max, num step,
      ValueChanged<num> set) {
    final t = Theme.of(context);
    final text = value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return Row(key: ValueKey(key), children: [
      Expanded(child: Text(label)),
      IconButton(
        tooltip: 'Fewer',
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: value - step >= min - 1e-9 ? () => set(value - step) : null,
      ),
      Text(text, style: t.textTheme.titleMedium),
      IconButton(
        tooltip: 'More',
        icon: const Icon(Icons.add_circle_outline),
        onPressed: value + step <= max + 1e-9 ? () => set(value + step) : null,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = choice;
    final s = settings;
    Widget hpd() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Hours a day', style: t.textTheme.bodySmall),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final h in s.dayHourChoices)
          ChoiceChip(
            key: ValueKey('mygig-hpd-${h.round()}'),
            label: Text('${h == h.roundToDouble() ? h.toStringAsFixed(0) : h} hours'),
            selected: c.hoursPerDay == h,
            onSelected: (_) => onChanged(c.copyWith(hoursPerDay: h)),
          ),
      ]),
    ]);
    Widget weekdays() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Working days', style: t.textTheme.bodySmall),
      const SizedBox(height: 4),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (var d = 1; d <= 7; d++)
          FilterChip(
            key: ValueKey('mygig-wd-$d'),
            label: Text(mygigWeekdayNames[d - 1]),
            selected: c.weekdays.contains(d),
            onSelected: (on) {
              final next = [...c.weekdays.where((x) => x != d), if (on) d]..sort();
              onChanged(c.copyWith(weekdays: next));
            },
          ),
      ]),
    ]);
    final km = kmIncluded;
    return Card(
      key: const ValueKey('mygig-hire-options'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (c.kind == MygigKind.hourly)
            _step(context, 'mygig-hours', 'Hours', c.hours, s.minHours, s.maxHours, 1,
                (v) => onChanged(c.copyWith(hours: v.toDouble()))),
          if (c.kind == MygigKind.daily) ...[
            _step(context, 'mygig-days', 'Days in a row', c.days, 1, s.maxDays, 1, (v) => onChanged(c.copyWith(days: v.toInt()))),
            hpd(),
            SwitchListTile(
              key: const ValueKey('mygig-overnight'),
              contentPadding: EdgeInsets.zero,
              value: c.overnight,
              title: const Text('Overnight trip'),
              subtitle: Text('${mygigMoney(rates.overnight)} a night for your stay away from home'),
              onChanged: (v) => onChanged(c.copyWith(overnight: v)),
            ),
          ],
          if (c.kind == MygigKind.weekly) ...[
            _step(context, 'mygig-weeks', 'Weeks', c.periods, 1, s.maxWeeks, 1, (v) => onChanged(c.copyWith(periods: v.toInt()))),
            weekdays(),
            const SizedBox(height: 8),
            hpd(),
          ],
          if (c.kind == MygigKind.monthly) ...[
            _step(context, 'mygig-months', 'Months', c.periods, 1, s.maxMonths, 1,
                (v) => onChanged(c.copyWith(periods: v.toInt()))),
            weekdays(),
            const SizedBox(height: 8),
            hpd(),
            if (s.holidaysSkipped)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Public holidays in the period are skipped (set by get.ride).', style: t.textTheme.bodySmall),
              ),
          ],
          const SizedBox(height: 6),
          Text(
            '${km == null ? '' : 'Includes ${km.round()} km and fuel. '}After that: overtime ${mygigMoney(rates.overtime)} an hour, '
            'extra km ${mygigMoney(rates.extraKm)}.${c.kind.multiDay ? ' You drive every day of the booking.' : ''}',
            key: const ValueKey('mygig-hire-includes'),
            style: t.textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

/// Now or later: the day (Today, Tomorrow, the day after, or another date
/// typed in the boxes, with the calendar button) and the time.
class MygigWhenPicker extends StatefulWidget {
  const MygigWhenPicker({super.key, required this.choice, required this.settings, required this.now, required this.onChanged});
  final MygigBookingChoice choice;
  final MygigHireSettings settings;
  final DateTime now;
  final ValueChanged<MygigBookingChoice> onChanged;

  @override
  State<MygigWhenPicker> createState() => _MygigWhenPickerState();
}

class _MygigWhenPickerState extends State<MygigWhenPicker> {
  /// 0 today, 1 tomorrow, 2 the day after, -1 another date.
  int _dayChip = 0;
  DateTime? _other;
  int _minute = 18 * 60 + 30;

  @override
  void initState() {
    super.initState();
    final at = widget.choice.at;
    if (at != null) {
      _minute = at.hour * 60 + at.minute;
      final diff = DateTime(at.year, at.month, at.day).difference(_today).inDays;
      if (diff >= 0 && diff <= 2) {
        _dayChip = diff;
      } else {
        _dayChip = -1;
        _other = DateTime(at.year, at.month, at.day);
      }
    } else {
      // The next quarter hour past the lead time, so the first choice can be sent.
      final f = widget.now.add(Duration(minutes: widget.settings.leadMin(widget.choice.kind) + 15));
      final q = DateTime(f.year, f.month, f.day, f.hour, (f.minute ~/ 15 + 1) * 15);
      _minute = q.hour * 60 + q.minute;
      final diff = DateTime(q.year, q.month, q.day).difference(_today).inDays;
      if (diff <= 2) {
        _dayChip = diff;
      } else {
        _dayChip = -1;
        _other = DateTime(q.year, q.month, q.day);
      }
      if (widget.choice.isLater) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _emit();
        });
      }
    }
  }

  DateTime get _today => DateTime(widget.now.year, widget.now.month, widget.now.day);

  DateTime? get _day => _dayChip >= 0 ? _today.add(Duration(days: _dayChip)) : _other;

  void _emit({bool? later}) {
    final day = _day;
    final at = day == null ? null : DateTime(day.year, day.month, day.day, _minute ~/ 60, _minute % 60);
    widget.onChanged(widget.choice.copyWith(later: later ?? widget.choice.later, at: at, clearAt: at == null));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = widget.choice;
    final canNow = !c.kind.multiDay;
    final later = c.isLater;
    final s = widget.settings;
    return Column(key: const ValueKey('mygig-when'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<bool>(
        key: const ValueKey('mygig-when-seg'),
        segments: [
          ButtonSegment(value: false, label: const Text('Now'), enabled: canNow),
          ButtonSegment(value: true, label: Text(canNow ? 'Later' : 'Starts on')),
        ],
        selected: {later},
        onSelectionChanged: (v) => _emit(later: v.first),
      ),
      if (later) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i <= 2; i++)
            ChoiceChip(
              key: ValueKey('mygig-day-$i'),
              label: Text(mygigDayText(_today.add(Duration(days: i)), widget.now)),
              selected: _dayChip == i,
              onSelected: (_) {
                setState(() => _dayChip = i);
                _emit();
              },
            ),
          ChoiceChip(
            key: const ValueKey('mygig-day-other'),
            label: const Text('Other date'),
            selected: _dayChip == -1,
            onSelected: (_) {
              setState(() => _dayChip = -1);
              _emit();
            },
          ),
        ]),
        if (_dayChip == -1) ...[
          const SizedBox(height: 8),
          DateBoxesField(
            key: const ValueKey('mygig-date'),
            label: 'Start date',
            initialValue: _other,
            firstDate: _today,
            lastDate: _today.add(Duration(days: s.aheadDays)),
            beforeFirstText: 'That day has passed. Choose a later date.',
            afterLastText: 'Bookings go up to ${s.aheadDays} days ahead.',
            onChanged: (d) {
              setState(() => _other = d);
              _emit();
            },
          ),
        ],
        const SizedBox(height: 8),
        SearchableDropdownFormField<int>(
          key: ValueKey('mygig-time-$_minute'),
          initialValue: _minute,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Start time', prefixIcon: Icon(Icons.schedule)),
          items: [for (final m in mygigTimeChoices) DropdownMenuItem(value: m, child: Text(mygigClock(m)))],
          onChanged: (m) {
            if (m == null) return;
            setState(() => _minute = m);
            _emit();
          },
        ),
        const SizedBox(height: 6),
        Text(mygigLeadNote(c.kind, s), key: const ValueKey('mygig-lead-note'), style: t.textTheme.bodySmall),
      ],
    ]);
  }
}

/// A box of words: [ok] green, [warn] amber, [bad] red, else plain.
class MygigNote extends StatelessWidget {
  const MygigNote({super.key, required this.icon, required this.title, required this.body, this.ok = false, this.warn = false,
      this.bad = false});
  final IconData icon;
  final String title;
  final String body;
  final bool ok, warn, bad;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final bg = bad ? cs.errorContainer : warn ? cs.tertiaryContainer : ok ? cs.secondaryContainer : cs.surfaceContainerHighest;
    final fg = bad ? cs.onErrorContainer : warn ? cs.onTertiaryContainer : ok ? cs.onSecondaryContainer : cs.onSurface;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.titleSmall?.copyWith(color: fg)),
            Text(body, style: t.textTheme.bodySmall?.copyWith(color: fg)),
          ]),
        ),
      ]),
    );
  }
}

/// The booking's terms as the passenger sees them where they accept (the
/// app, the trip link, the driver's phone): when, the package, what is paid
/// now and what later, and until when it is free to cancel. [booking] is
/// the offer's (mygig_create's `booking`), [quote] its price.
class MygigBookingTerms extends StatelessWidget {
  const MygigBookingTerms({super.key, required this.booking, required this.total, required this.now, this.kmIncluded});
  final Map<String, dynamic> booking;
  final double total;
  final DateTime now;
  final double? kmIncluded;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final kind = mygigKindFrom(booking['kind']);
    final later = booking['when'] == 'later';
    final at = DateTime.tryParse('${booking['at'] ?? ''}')?.toLocal();
    final payNow = booking['payNow'] is num ? (booking['payNow'] as num).toDouble() : 0.0;
    final balance = booking['balance'] is num ? (booking['balance'] as num).toDouble() : 0.0;
    final byLink = booking['payNowBy'] == 'link';
    final plan = '${booking['plan'] ?? ''}';
    final until = DateTime.tryParse('${booking['freeCancelUntil'] ?? ''}')?.toLocal();
    final lines = <String>[
      [
        kind.label,
        if (later && at != null) 'from ${mygigWhenText(at, now)}',
      ].join(' · '),
      if (kmIncluded != null && kind.hire) 'Includes ${kmIncluded!.round()} km. Overtime and extra km are added each day.',
      switch (plan) {
        'deposit' => 'Deposit ${mygigMoney(payNow)} now${byLink ? ' by link' : ''}; the balance ${mygigMoney(balance)} before day 1.',
        'full' => '${mygigMoney(payNow)} in full now${byLink ? ' by link' : ''}.',
        'link_first' => '${mygigMoney(payNow)} by link now: the booking is confirmed once it is paid.',
        'start' => '${mygigMoney(total)} is charged when your driver starts.',
        'business' => 'On your business account’s monthly invoice.',
        _ => 'Paid as a myGiG ride.',
      },
      if (later && until != null) 'Free to cancel until ${mygigWhenText(until, now)}; after that what you paid now is kept.',
    ];
    return Card(
      key: const ValueKey('mygig-booking-terms'),
      color: t.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(later ? Icons.event_available : Icons.schedule, color: t.colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(child: Text(lines.first, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSecondaryContainer))),
          ]),
          for (final l in lines.skip(1))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSecondaryContainer)),
            ),
        ]),
      ),
    );
  }
}
