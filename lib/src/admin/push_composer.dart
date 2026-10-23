/// Admin -> Push Notification's composer (migration 0279): the emoji, the
/// partners by type, and sends scheduled ahead in Malaysia time. Pure.
library;

import 'package:flutter/services.dart' show TextEditingValue, TextSelection;

import '../core/date_order.dart' show formatDateForUser;
import 'push_area.dart';
import 'saved_push.dart' show pushAudienceLabel, normalizePushAudience;

// ---- Emoji ---------------------------------------------------------------------------------------

/// The emoji the Title and Message fields offer.
const pushEmojis = [
  '😊', '😀', '😍', '🥳', '🎉', '🎁', '🎊', '🎈',
  '🚗', '🚕', '🚙', '🛵', '🏍️', '🚚', '📦', '✈️',
  '💰', '💸', '🪙', '💳', '🏷️', '🔥', '⭐', '✨',
  '✅', '⚠️', '❗', '📍', '⏰', '📅', '📣', '🔔',
  '💨', '🌧️', '☀️', '🙏', '❤️', '👍', '👋', '🎃',
];

/// [value] with [text] in place of its selection (at the cursor), the cursor
/// after it. With no cursor the text goes at the end.
TextEditingValue insertAtCursor(TextEditingValue value, String text) {
  final s = value.selection;
  final start = s.isValid ? s.start.clamp(0, value.text.length) : value.text.length;
  final end = s.isValid ? s.end.clamp(start, value.text.length) : start;
  final next = value.text.replaceRange(start, end, text);
  return TextEditingValue(text: next, selection: TextSelection.collapsed(offset: start + text.length));
}

/// [value] with its selection wrapped in [before] and [after] (the toolbar's
/// bold, italic, colour and link); with nothing selected, [placeholder] is
/// put in and selected, so typing replaces it.
TextEditingValue wrapSelection(TextEditingValue value, String before, String after, {String placeholder = 'text'}) {
  final s = value.selection;
  final start = s.isValid ? s.start.clamp(0, value.text.length) : value.text.length;
  final end = s.isValid ? s.end.clamp(start, value.text.length) : start;
  final inner = end > start ? value.text.substring(start, end) : placeholder;
  final next = value.text.replaceRange(start, end, '$before$inner$after');
  return TextEditingValue(
    text: next,
    selection: TextSelection(baseOffset: start + before.length, extentOffset: start + before.length + inner.length),
  );
}

/// [value] with [prefix] at the start of each line the selection touches
/// (a heading's "# ", a bullet's "- "), or taken off when they all have it.
TextEditingValue prefixLines(TextEditingValue value, String prefix) {
  final text = value.text;
  final s = value.selection;
  final from = s.isValid ? s.start.clamp(0, text.length) : text.length;
  final to = s.isValid ? s.end.clamp(from, text.length) : from;
  final lineStart = from == 0 ? 0 : text.lastIndexOf('\n', from - 1) + 1;
  final nl = text.indexOf('\n', to);
  final lineEnd = nl < 0 ? text.length : nl;
  final lines = text.substring(lineStart, lineEnd).split('\n');
  final all = lines.every((l) => l.startsWith(prefix));
  final changed = [for (final l in lines) all ? l.substring(prefix.length) : '$prefix$l'].join('\n');
  final next = text.replaceRange(lineStart, lineEnd, changed);
  return TextEditingValue(text: next, selection: TextSelection.collapsed(offset: lineStart + changed.length));
}

// ---- Partners by type ---------------------------------------------------------------------------

/// A partner row's types (`partner_types`, else the legacy `partner_type`),
/// as send-push reads them (`_shared/push.ts`: typesOfPartner).
List<String> partnerRowTypes(Map<String, dynamic> row) {
  final raw = row['partner_types'];
  final list = <String>[
    if (raw is List)
      for (final t in raw)
        if ('${t ?? ''}'.trim().isNotEmpty) '$t'.trim(),
  ];
  if (list.isNotEmpty) return list;
  final legacy = '${row['partner_type'] ?? ''}'.trim();
  return legacy.isEmpty ? const [] : [legacy];
}

bool _approved(Map<String, dynamic> row) => '${row['status'] ?? ''}'.toLowerCase() == 'approved';

/// The partner accounts of [rows] whose types overlap [types] (any case),
/// each account once however many types it has; every partner when
/// [types] is empty. [approvedOnly]: approved partners only. send-push
/// picks the same people (`partnerAccounts`).
Set<String> partnerAccountsOf(Iterable<Map<String, dynamic>> rows, Iterable<String> types, {bool approvedOnly = true}) {
  final wanted = {for (final t in types) t.toLowerCase()};
  final out = <String>{};
  for (final r in rows) {
    final id = '${r['auth_user_id'] ?? ''}'.trim();
    if (id.isEmpty || (approvedOnly && !_approved(r))) continue;
    if (wanted.isEmpty || partnerRowTypes(r).any((t) => wanted.contains(t.toLowerCase()))) out.add(id);
  }
  return out;
}

/// The chips: each of [options] (the admin's partner types, in their order),
/// then any other type a partner has, with how many partners have it.
List<({String type, int count})> partnerTypeCounts(
  Iterable<Map<String, dynamic>> rows,
  List<String> options, {
  bool approvedOnly = true,
}) {
  final names = <String, String>{for (final o in options) o.toLowerCase(): o};
  final extra = <String, String>{};
  final ids = <String, Set<String>>{};
  for (final r in rows) {
    final id = '${r['auth_user_id'] ?? ''}'.trim();
    if (id.isEmpty || (approvedOnly && !_approved(r))) continue;
    for (final t in partnerRowTypes(r)) {
      final k = t.toLowerCase();
      if (!names.containsKey(k)) extra.putIfAbsent(k, () => t);
      ids.putIfAbsent(k, () => {}).add(id);
    }
  }
  final others = extra.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final t in [...names.values, ...others]) (type: t, count: ids[t.toLowerCase()]?.length ?? 0),
  ];
}

// ---- Scheduled sends ----------------------------------------------------------------------------

enum PushRepeat { once, daily, weekly, monthly }

PushRepeat pushRepeatFrom(Object? raw) =>
    PushRepeat.values.firstWhere((r) => r.name == '${raw ?? ''}'.trim().toLowerCase(), orElse: () => PushRepeat.once);

/// Schedules are in Malaysia time, UTC+8 all year.
const malaysiaOffset = Duration(hours: 8);

/// [at] as Malaysia's wall clock (a UTC DateTime whose fields read as the
/// time in Kuala Lumpur).
DateTime malaysiaClock(DateTime at) => at.toUtc().add(malaysiaOffset);

/// The instant of a Malaysian wall-clock time.
DateTime fromMalaysiaClock(int year, int month, int day, int hour, int minute) =>
    DateTime.utc(year, month, day, hour, minute).subtract(malaysiaOffset);

int _daysIn(int year, int month) => DateTime.utc(year, month + 1, 0).day;

/// The next time after [prev] for [repeat]: a day or a week on, or the next
/// month on [anchor]'s day (the last day of a shorter month) at [anchor]'s
/// time, all in Malaysia time. Null for once. The database moves a schedule
/// on the same way (push_schedule_next).
DateTime? nextPushTime(DateTime prev, DateTime anchor, PushRepeat repeat) {
  switch (repeat) {
    case PushRepeat.once:
      return null;
    case PushRepeat.daily:
      return prev.toUtc().add(const Duration(days: 1));
    case PushRepeat.weekly:
      return prev.toUtc().add(const Duration(days: 7));
    case PushRepeat.monthly:
      final p = malaysiaClock(prev), a = malaysiaClock(anchor);
      final year = p.month == 12 ? p.year + 1 : p.year;
      final month = p.month == 12 ? 1 : p.month + 1;
      final day = a.day < _daysIn(year, month) ? a.day : _daysIn(year, month);
      return fromMalaysiaClock(year, month, day, a.hour, a.minute);
  }
}

/// The first time after [now] in [anchor]'s series (the next send of a
/// schedule that missed some); null for once.
DateTime? nextPushTimeAfter(DateTime prev, DateTime anchor, PushRepeat repeat, DateTime now) {
  var next = nextPushTime(prev, anchor, repeat);
  while (next != null && !next.isAfter(now)) {
    next = nextPushTime(next, anchor, repeat);
  }
  return next;
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String _ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return '$n${switch (n % 10) {
    1 => 'st',
    2 => 'nd',
    3 => 'rd',
    _ => 'th',
  }}';
}

/// "Once", "Every day", "Every week (Saturday)", "Every month (25th)", for a
/// schedule starting [at].
String pushRepeatLabel(PushRepeat r, [DateTime? at]) {
  final my = at == null ? null : malaysiaClock(at);
  return switch (r) {
    PushRepeat.once => 'Once',
    PushRepeat.daily => 'Every day',
    PushRepeat.weekly => my == null ? 'Every week' : 'Every week (${_weekdays[my.weekday - 1]})',
    PushRepeat.monthly => my == null ? 'Every month' : 'Every month (${_ordinal(my.day)})',
  };
}

String _two(int n) => n.toString().padLeft(2, '0');

/// "25/10/2026 09:00" in the user's date order, Malaysia time.
String malaysiaTimeText(DateTime at) {
  final my = malaysiaClock(at);
  return '${formatDateForUser(DateTime(my.year, my.month, my.day))} ${_two(my.hour)}:${_two(my.minute)}';
}

/// Why [sendAt] cannot be scheduled; null when it can (a minute ahead, at
/// most a year).
String? scheduleTimeProblem(DateTime? sendAt, DateTime now) {
  if (sendAt == null) return 'Choose the date and time.';
  if (!sendAt.isAfter(now.add(const Duration(minutes: 1)))) return 'Choose a time in the future.';
  if (sendAt.isAfter(now.add(const Duration(days: 366)))) return 'Choose a time within a year.';
  return null;
}

/// One scheduled push (`push_schedules`).
class PushSchedule {
  const PushSchedule({
    required this.id,
    required this.title,
    required this.body,
    required this.audience,
    required this.sendAt,
    this.imageUrl,
    this.messageId,
    this.partnerTypes = const [],
    this.approvedOnly = true,
    this.area = const PushArea.everywhere(),
    this.repeat = PushRepeat.once,
    this.nextAt,
    this.lastSentAt,
    this.lastResult,
    this.status = 'active',
  });

  factory PushSchedule.fromRow(Map<String, dynamic> r) {
    DateTime? t(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toUtc();
    return PushSchedule(
      id: '${r['id']}',
      title: '${r['title'] ?? ''}',
      body: '${r['body'] ?? ''}',
      audience: normalizePushAudience(r['audience']),
      sendAt: t(r['send_at']) ?? DateTime.now().toUtc(),
      imageUrl: r['image_url'] as String?,
      messageId: r['message_id'] as String?,
      partnerTypes: [for (final p in (r['partner_types'] as List?) ?? const []) '$p'],
      approvedOnly: r['approved_only'] != false,
      area: PushArea.fromJson(r['area']),
      repeat: pushRepeatFrom(r['repeat']),
      nextAt: t(r['next_at']),
      lastSentAt: t(r['last_sent_at']),
      lastResult: r['last_result'] is Map ? Map<String, dynamic>.from(r['last_result'] as Map) : null,
      status: '${r['status'] ?? 'active'}',
    );
  }

  final String id;
  final String title;
  final String body;
  final String audience;
  final DateTime sendAt;
  final String? imageUrl;
  final String? messageId;
  final List<String> partnerTypes;
  final bool approvedOnly;
  final PushArea area;
  final PushRepeat repeat;
  final DateTime? nextAt;
  final DateTime? lastSentAt;
  final Map<String, dynamic>? lastResult;
  final String status;

  /// When it goes next.
  DateTime get when => nextAt ?? sendAt;

  /// "Partners: eHailing, Teksi in Kajang, Selangor, Malaysia".
  String get toText {
    final who = audience == 'partners' && partnerTypes.isNotEmpty
        ? 'Partners: ${partnerTypes.join(', ')}'
        : pushAudienceLabel(audience);
    return area.label.isEmpty ? who : '$who ${area.label}';
  }
}

/// The `push_schedules` row to write.
Map<String, dynamic> pushScheduleRow({
  required String title,
  required String body,
  required String audience,
  required DateTime sendAt,
  required PushRepeat repeat,
  PushArea area = const PushArea.everywhere(),
  String? imageUrl,
  String? messageId,
  List<String> partnerTypes = const [],
  bool approvedOnly = true,
}) {
  final a = normalizePushAudience(audience);
  return {
    'title': title.trim(),
    'body': body.trim(),
    'audience': a,
    'send_at': sendAt.toUtc().toIso8601String(),
    'repeat': repeat.name,
    'area': area.toJson(),
    'image_url': imageUrl,
    'message_id': messageId,
    'partner_types': a == 'partners' ? partnerTypes : const <String>[],
    'approved_only': approvedOnly,
  };
}
