// The pickup time wheel (Choose date and time): the days a ride can be
// booked for, the 15-minute slots on them, and the clamp that keeps the
// wheels on a time that can be booked. Pure.
import 'package:intl/intl.dart';

import 'scheduled_rides.dart';

/// The wheel's minute steps.
const pickupSlotMinutes = 15;
const pickupMinutes = [0, 15, 30, 45];

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// The soonest slot that can be booked at [now]: at least the lead time
/// away, on the next quarter hour.
DateTime firstPickupSlot(DateTime now, ScheduledRidesConfig c) {
  final t = now.add(Duration(minutes: c.minLeadMinutes));
  final on = t.second == 0 && t.millisecond == 0 && t.microsecond == 0 && t.minute % pickupSlotMinutes == 0;
  final base = DateTime(t.year, t.month, t.day, t.hour, t.minute - t.minute % pickupSlotMinutes);
  return on ? base : base.add(const Duration(minutes: pickupSlotMinutes));
}

/// The furthest slot that can be booked at [now]; never before the first.
DateTime lastPickupSlot(DateTime now, ScheduledRidesConfig c) {
  final t = latestPickup(now, c);
  final last = DateTime(t.year, t.month, t.day, t.hour, t.minute - t.minute % pickupSlotMinutes);
  final first = firstPickupSlot(now, c);
  return last.isBefore(first) ? first : last;
}

/// The days on the date wheel, the first slot's to the last's.
List<DateTime> pickupDays(DateTime now, ScheduledRidesConfig c) {
  final first = _day(firstPickupSlot(now, c));
  final last = _day(lastPickupSlot(now, c));
  return [for (var d = first; !d.isAfter(last); d = DateTime(d.year, d.month, d.day + 1)) d];
}

/// [at] on a slot inside what can be booked at [now].
DateTime clampPickup(DateTime at, DateTime now, ScheduledRidesConfig c) {
  final first = firstPickupSlot(now, c);
  final last = lastPickupSlot(now, c);
  final on = DateTime(at.year, at.month, at.day, at.hour, at.minute - at.minute % pickupSlotMinutes);
  if (on.isBefore(first)) return first;
  if (on.isAfter(last)) return last;
  return on;
}

/// "Today", or "Fri 16 Oct".
String pickupDayLabel(DateTime day, DateTime now) =>
    _day(day) == _day(now) ? 'Today' : DateFormat('EEE d MMM').format(day);

/// The wheels' four positions for [at]: the hour 1–12 (index 0 is 1), the
/// minute step and AM (0) or PM (1).
({int hour, int minute, int pm}) pickupWheelOf(DateTime at) =>
    (hour: (at.hour + 11) % 12, minute: at.minute ~/ pickupSlotMinutes, pm: at.hour >= 12 ? 1 : 0);

/// The time the wheels show: [day] at [hour] (0 is 1 o'clock), [minute]
/// step, AM or PM.
DateTime pickupFromWheel(DateTime day, int hour, int minute, int pm) {
  final h12 = hour % 12 + 1;
  final h = (h12 % 12) + (pm == 1 ? 12 : 0);
  return DateTime(day.year, day.month, day.day, h, pickupMinutes[minute % pickupMinutes.length]);
}

/// "5:45 PM".
String pickupClock(DateTime at) => DateFormat('h:mm a').format(at);
