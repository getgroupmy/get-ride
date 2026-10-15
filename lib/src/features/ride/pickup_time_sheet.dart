// Choose date and time: the scheduled ride's pickup on four wheels (day,
// hour, minute, AM/PM) under one highlighted row, with one button to
// confirm. A wheel turned to a time that can't be booked rolls back to the
// nearest one that can.
import 'package:flutter/material.dart';

import '../../core/pickup_slots.dart';
import '../../core/scheduled_rides.dart';
import 'confirm_parts.dart' show confirmAccent;

/// The pickup sheet; null when it is closed without confirming.
Future<DateTime?> showPickupTimeSheet(
  BuildContext context,
  ScheduledRidesConfig config, {
  DateTime? initial,
  DateTime Function() clock = DateTime.now,
}) => showModalBottomSheet<DateTime>(
  context: context,
  isScrollControlled: true,
  builder: (_) => PickupTimeSheet(config: config, initial: initial, clock: clock),
);

class PickupTimeSheet extends StatefulWidget {
  const PickupTimeSheet({super.key, required this.config, this.initial, this.clock = DateTime.now});

  final ScheduledRidesConfig config;
  final DateTime? initial;
  final DateTime Function() clock;

  @override
  State<PickupTimeSheet> createState() => _PickupTimeSheetState();
}

const _rowHeight = 44.0;
const _rows = 5;

class _PickupTimeSheetState extends State<PickupTimeSheet> {
  late final DateTime _opened = widget.clock();
  late final List<DateTime> _days = pickupDays(_opened, widget.config);
  late DateTime _at = clampPickup(widget.initial ?? _opened, _opened, widget.config);
  late final FixedExtentScrollController _day, _hour, _minute, _pm;
  String? _problem;

  @override
  void initState() {
    super.initState();
    final w = pickupWheelOf(_at);
    _day = FixedExtentScrollController(initialItem: _dayIndex(_at));
    _hour = FixedExtentScrollController(initialItem: w.hour);
    _minute = FixedExtentScrollController(initialItem: w.minute);
    _pm = FixedExtentScrollController(initialItem: w.pm);
  }

  @override
  void dispose() {
    _day.dispose();
    _hour.dispose();
    _minute.dispose();
    _pm.dispose();
    super.dispose();
  }

  int _dayIndex(DateTime at) {
    final i = _days.indexWhere((d) => d.year == at.year && d.month == at.month && d.day == at.day);
    return i < 0 ? 0 : i;
  }

  static int _wrap(int i, int n) => i % n;

  /// The time the wheels stand on, kept inside what can be booked; the
  /// wheels that are off it roll there.
  void _settle({DateTime? now}) {
    final raw = pickupFromWheel(
      _days[_day.selectedItem.clamp(0, _days.length - 1)],
      _wrap(_hour.selectedItem, 12),
      _wrap(_minute.selectedItem, pickupMinutes.length),
      _pm.selectedItem.clamp(0, 1),
    );
    final at = clampPickup(raw, now ?? widget.clock(), widget.config);
    if (at != _at) {
      setState(() {
        _at = at;
        if (now == null) _problem = null;
      });
    }
    final w = pickupWheelOf(at);
    _roll(_day, _dayIndex(at));
    _rollLooping(_hour, w.hour, 12);
    _rollLooping(_minute, w.minute, pickupMinutes.length);
    _roll(_pm, w.pm);
  }

  void _roll(FixedExtentScrollController c, int to) {
    if (c.hasClients && c.selectedItem != to) {
      c.animateToItem(to, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  /// The looping wheels take the short way round.
  void _rollLooping(FixedExtentScrollController c, int to, int n) {
    if (!c.hasClients) return;
    final cur = c.selectedItem;
    var step = (to - _wrap(cur, n)) % n;
    if (step > n ~/ 2) step -= n;
    if (step != 0) c.animateToItem(cur + step, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  void _confirm() {
    final now = widget.clock();
    final problem = pickupTimeProblem(_at, now, widget.config);
    if (problem == null) {
      Navigator.pop(context, _at);
      return;
    }
    // Open long enough for the soonest slot to pass: move on to the next.
    setState(() => _problem = problem);
    _settle(now: now);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = widget.config;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final days = c.maxDaysAhead == 1 ? '1 day' : '${c.maxDaysAhead} days';
    final footer = c.lateCancelFee > 0
        ? 'Free cancellation until ${pickupClock(freeCancelUntil(_at, c))}. Your driver will be there at '
              '${pickupClock(_at)}.'
        : 'Your driver will be there at ${pickupClock(_at)}. You can cancel before pickup.';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          key: const ValueKey('pickup-time-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose date and time', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Book your pickup from ${c.minLeadMinutes} minutes to $days ahead.', style: muted),
            const SizedBox(height: 16),
            SizedBox(
              height: _rowHeight * _rows,
              child: Stack(
                children: [
                  // The chosen row, across all four wheels.
                  Center(
                    child: Container(
                      key: const ValueKey('pickup-band'),
                      height: _rowHeight,
                      decoration: BoxDecoration(
                        color: t.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  NotificationListener<ScrollEndNotification>(
                    onNotification: (_) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _settle();
                      });
                      return false;
                    },
                    child: Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: _Wheel(
                            key: const ValueKey('pickup-day-wheel'),
                            label: 'Day',
                            controller: _day,
                            labels: [for (final d in _days) pickupDayLabel(d, _opened)],
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: _Wheel(
                            key: const ValueKey('pickup-hour-wheel'),
                            label: 'Hour',
                            controller: _hour,
                            labels: [for (var h = 1; h <= 12; h++) '$h'],
                            looping: true,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: _Wheel(
                            key: const ValueKey('pickup-minute-wheel'),
                            label: 'Minute',
                            controller: _minute,
                            labels: [for (final m in pickupMinutes) m.toString().padLeft(2, '0')],
                            looping: true,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: _Wheel(
                            key: const ValueKey('pickup-ampm-wheel'),
                            label: 'AM or PM',
                            controller: _pm,
                            labels: const ['AM', 'PM'],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _problem ?? footer,
              key: const ValueKey('pickup-footer'),
              textAlign: TextAlign.center,
              style: _problem == null ? muted : t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 56,
              child: FilledButton(
                key: const ValueKey('pickup-confirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: confirmAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                onPressed: _confirm,
                child: const Text('Confirm time'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One column: the row on the band in full ink, the rest fading away.
class _Wheel extends StatelessWidget {
  const _Wheel({super.key, required this.label, required this.controller, required this.labels, this.looping = false});

  final String label;
  final FixedExtentScrollController controller;
  final List<String> labels;
  final bool looping;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurface, fontWeight: FontWeight.w600);
    final children = [
      for (final l in labels)
        Center(
          child: Text(l, style: style, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
        ),
    ];
    return Semantics(
      label: label,
      child: ListWheelScrollView.useDelegate(
        controller: controller,
        itemExtent: _rowHeight,
        physics: const FixedExtentScrollPhysics(),
        diameterRatio: 1.8,
        perspective: 0.004,
        overAndUnderCenterOpacity: 0.4,
        childDelegate: looping
            ? ListWheelChildLoopingListDelegate(children: children)
            : ListWheelChildListDelegate(children: children),
      ),
    );
  }
}
