/// Saved, re-sendable push notifications (Expo
/// `admin-settings-push-notification.tsx`). They live where Expo kept them:
/// `settings_entries` rows under the `push-notification` category, one row
/// per notification with `{title, body, audience, updatedAt}` in `values`.
/// Reads are public and writes are admin-only (`caller_is_admin()`), so no
/// migration is needed.
library;

import 'admin_settings_models.dart';

const savedPushCategory = SettingsCategory(
  key: 'push-notification',
  page: 'admin-settings-push-notification',
  title: 'Saved notifications',
  subtitle: 'Push notifications kept to send again',
  table: 'settings_entries',
  fields: [
    SettingsField('title', 'Title', FieldKind.text, required: true),
    SettingsField('body', 'Message', FieldKind.text, required: true),
    SettingsField('audience', 'Audience', FieldKind.text),
  ],
);

/// Audience keys `send-push` understands, with their labels.
const pushAudienceLabels = {'all': 'Everyone', 'users': 'Passengers', 'partners': 'Partners'};

/// A stored audience as a `send-push` key. `drivers` is the legacy key for
/// partners; anything unknown means everyone (Expo `normalizeAudience`).
String normalizePushAudience(Object? value) {
  final v = '${value ?? 'all'}'.trim().toLowerCase();
  if (v == 'partners' || v == 'drivers') return 'partners';
  if (v == 'users') return 'users';
  return 'all';
}

String pushAudienceLabel(Object? value) => pushAudienceLabels[normalizePushAudience(value)]!;

class SavedPush {
  const SavedPush({
    required this.id,
    required this.title,
    required this.body,
    required this.audience,
    this.updatedAt,
    this.values = const {},
  });

  factory SavedPush.fromEntry(SettingEntry e) => SavedPush(
    id: e.id,
    values: e.values,
    title: '${e.values['title'] ?? ''}'.trim(),
    body: '${e.values['body'] ?? ''}'.trim(),
    audience: normalizePushAudience(e.values['audience']),
    updatedAt: e.values['updatedAt'] == null ? null : '${e.values['updatedAt']}',
  );

  final String id;
  final String title;
  final String body;
  final String audience;
  final String? updatedAt;

  /// Everything stored on the row, kept when it is edited.
  final Map<String, dynamic> values;

  /// A row missing its title or message cannot be sent.
  bool get sendable => title.isNotEmpty && body.isNotEmpty;
}

/// Saved notifications, most recently edited first.
List<SavedPush> savedPushesFrom(Iterable<SettingEntry> entries) {
  final list = entries.map(SavedPush.fromEntry).toList();
  list.sort((a, b) => (b.updatedAt ?? '').compareTo(a.updatedAt ?? ''));
  return list;
}

/// Why a notification cannot be saved or sent yet; null when it can.
String? validatePushDraft(String title, String body) {
  if (title.trim().isEmpty) return 'Add a title.';
  if (body.trim().isEmpty) return 'Add a message.';
  return null;
}

/// What `send-push` reported, for the admin who pressed Send.
String pushResultText(Map<String, dynamic> r, String audience) {
  final recipients = (r['recipients'] as num?)?.toInt() ?? 0;
  final failed = (r['failed'] as num?)?.toInt() ?? 0;
  if (recipients == 0) return 'No registered devices match "${pushAudienceLabel(audience)}" yet.';
  return 'Sent to ${r['sent'] ?? 0} of $recipients devices${failed != 0 ? ' ($failed failed)' : ''}.';
}

/// The `values` to store. Editing keeps any keys the row already had (an
/// Expo-written row may carry more), the same way Expo merged on update.
Map<String, dynamic> savedPushValues({
  Map<String, dynamic>? existing,
  required String title,
  required String body,
  required String audience,
  required DateTime now,
}) => {
  ...?existing,
  'title': title.trim(),
  'body': body.trim(),
  'audience': normalizePushAudience(audience),
  'updatedAt': now.toUtc().toIso8601String(),
};
