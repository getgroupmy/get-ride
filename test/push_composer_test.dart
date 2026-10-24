import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/push_area.dart';
import 'package:get_ride/src/admin/push_composer.dart';
import 'package:get_ride/src/admin/saved_push.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/admin/screens/push_composer_widgets.dart';
import 'package:get_ride/src/admin/screens/push_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/notification_delivery.dart';
import 'package:get_ride/src/core/push_message.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';
import 'notice.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// Partners as `partners` keeps them: one with two types, one with the
/// legacy single type, one not approved, one without an account.
final _partners = <Map<String, dynamic>>[
  {'auth_user_id': 'u1', 'partner_types': ['eHailing', 'Teksi'], 'status': 'approved'},
  {'auth_user_id': 'u2', 'partner_types': ['Teksi'], 'status': 'approved'},
  {'auth_user_id': 'u3', 'partner_types': <String>[], 'partner_type': 'eHailing', 'status': 'approved'},
  {'auth_user_id': 'u4', 'partner_types': ['Delivery'], 'status': 'pending'},
  {'auth_user_id': null, 'partner_types': ['Teksi'], 'status': 'approved'},
  {'auth_user_id': 'u5', 'partner_types': ['Courier'], 'status': 'approved'},
];

class _Geo extends GeoAdminRepository {
  _Geo() : super(_db);

  @override
  Future<List<RegionEntry>> regions() async => const [];
}

class _Admin extends AdminRepository {
  _Admin() : super(_db);

  final sends = <Map<String, Object?>>[];
  final dryRuns = <Map<String, Object?>>[];
  final messages = <Map<String, Object?>>[];
  final scheduleWrites = <({String? id, Map<String, dynamic> row})>[];
  final cancelled = <String>[];
  var schedules = <PushSchedule>[];

  @override
  Future<Map<String, dynamic>> sendPush(
    String title,
    String body,
    String audience, {
    Map<String, dynamic>? area,
    bool dryRun = false,
    String? profileId,
    String? image,
    String? messageId,
    List<String> partnerTypes = const [],
    bool? approvedOnly,
  }) async {
    final call = {
      'title': title,
      'body': body,
      'audience': audience,
      'image': image,
      'messageId': messageId,
      'partnerTypes': partnerTypes,
      'approvedOnly': approvedOnly,
    };
    if (dryRun) {
      dryRuns.add(call);
      final n = audience == 'partners'
          ? partnerAccountsOf(_partners, partnerTypes, approvedOnly: approvedOnly ?? false).length
          : 9;
      return {'dryRun': true, 'recipients': n, 'accounts': n, 'unlocated': 0, if (audience == 'partners') 'partners': n};
    }
    sends.add(call);
    return {'sent': 2, 'recipients': 2, 'failed': 0};
  }

  @override
  Future<String> savePushMessage({
    String? id,
    required String title,
    required String body,
    String? image,
    required List<Map<String, dynamic>> blocks,
  }) async {
    messages.add({'id': id, 'title': title, 'image': image, 'blocks': blocks});
    return id ?? 'msg-${messages.length}';
  }

  @override
  Future<Map<String, dynamic>?> pushMessage(String id) async => {
    'id': id,
    'blocks': [
      {
        'type': 'paragraph',
        'spans': [
          {'text': 'Stored text'},
        ],
      },
    ],
  };

  @override
  Future<List<PushSchedule>> pushSchedules() async => schedules;

  @override
  Future<void> savePushSchedule({String? id, required Map<String, dynamic> row}) async =>
      scheduleWrites.add((id: id, row: row));

  @override
  Future<void> cancelPushSchedule(String id) async => cancelled.add(id);

  @override
  Future<({List<Map<String, dynamic>> types, List<Map<String, dynamic>> partners})> pushPartnerAudience() async => (
    types: [
      {'name': 'eHailing', 'enabled': true, 'isDefault': true},
      {'name': 'Teksi', 'enabled': true},
      {'name': 'Delivery', 'enabled': true},
      {'name': 'Fleet', 'enabled': true},
    ],
    partners: _partners,
  );

  @override
  Future<List<SavedPush>> savedPushes() async => const [];

  @override
  Future<List<Map<String, dynamic>>> pushHistory() async => const [];

  @override
  Future<List<NotificationDelivery>> notificationDelivery({int hours = 24}) async => const [];

  @override
  Future<List<SettingEntry>> settings(SettingsCategory c) async => const [];
}

/// 23 Oct 2026, 10:00 in Kuala Lumpur.
final _now = DateTime.utc(2026, 10, 23, 2);

Future<_Admin> _pump(WidgetTester tester, {Brightness brightness = Brightness.light, double width = 1200}) async {
  final admin = _Admin();
  await tester.binding.setSurfaceSize(Size(width, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith((_) async => AdminAccess([const AdminGrant(page: '*', edit: true)])),
        adminRepositoryProvider.overrideWithValue(admin),
        geoAdminRepositoryProvider.overrideWithValue(_Geo()),
      ],
      child: MaterialApp(theme: appTheme(brightness), home: AdminPushScreen(now: () => _now)),
    ),
  );
  await tester.pumpAndSettle();
  return admin;
}

/// Send's button spins while its confirmation is open, so the dialog is
/// waited for rather than settled.
Future<void> _openDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _settle(WidgetTester tester) async {
  // The reach is counted half a second after the last change.
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

void main() {
  group('schedule times (logic)', () {
    DateTime my(int y, int m, int d, int h, [int min = 0]) => fromMalaysiaClock(y, m, d, h, min);

    test('Malaysia time is UTC+8', () {
      expect(my(2026, 10, 25, 9), DateTime.utc(2026, 10, 25, 1));
      expect(malaysiaClock(DateTime.utc(2026, 10, 31, 23, 30)), DateTime.utc(2026, 11, 1, 7, 30));
      expect(malaysiaTimeText(my(2026, 10, 25, 9)), '25/10/2026 09:00');
    });

    test('daily and weekly', () {
      final at = my(2026, 10, 25, 9);
      expect(nextPushTime(at, at, PushRepeat.daily), my(2026, 10, 26, 9));
      expect(nextPushTime(at, at, PushRepeat.weekly), my(2026, 11, 1, 9));
      expect(nextPushTime(at, at, PushRepeat.once), isNull);
      // Across the year's end.
      expect(nextPushTime(my(2026, 12, 31, 23, 30), at, PushRepeat.daily), my(2027, 1, 1, 23, 30));
    });

    test('monthly keeps the day, on the last day of a shorter month', () {
      final jan31 = my(2027, 1, 31, 9);
      final feb = nextPushTime(jan31, jan31, PushRepeat.monthly)!;
      expect(feb, my(2027, 2, 28, 9));
      final mar = nextPushTime(feb, jan31, PushRepeat.monthly)!;
      expect(mar, my(2027, 3, 31, 9), reason: 'back to the 31st');
      expect(nextPushTime(mar, jan31, PushRepeat.monthly), my(2027, 4, 30, 9));
      // A leap year's February.
      expect(nextPushTime(my(2028, 1, 30, 9), my(2028, 1, 30, 9), PushRepeat.monthly), my(2028, 2, 29, 9));
      // December to January.
      expect(nextPushTime(my(2026, 12, 15, 8), my(2026, 12, 15, 8), PushRepeat.monthly), my(2027, 1, 15, 8));
      // The day is Malaysia's: 07:30 on the 1st there is still the 31st in UTC.
      final nov1 = my(2026, 11, 1, 7, 30);
      expect(nextPushTime(nov1, nov1, PushRepeat.monthly), my(2026, 12, 1, 7, 30));
    });

    test('a schedule that missed some goes next in the future', () {
      final start = my(2026, 10, 1, 9);
      expect(nextPushTimeAfter(start, start, PushRepeat.daily, my(2026, 10, 10, 12)), my(2026, 10, 11, 9));
      expect(nextPushTimeAfter(start, start, PushRepeat.once, my(2026, 10, 10, 12)), isNull);
    });

    test('labels and limits', () {
      final sat = my(2026, 10, 24, 9);
      expect(pushRepeatLabel(PushRepeat.weekly, sat), 'Every week (Saturday)');
      expect(pushRepeatLabel(PushRepeat.monthly, my(2026, 10, 1, 9)), 'Every month (1st)');
      expect(pushRepeatLabel(PushRepeat.monthly, my(2026, 10, 22, 9)), 'Every month (22nd)');
      expect(pushRepeatLabel(PushRepeat.monthly, my(2026, 10, 13, 9)), 'Every month (13th)');
      expect(pushRepeatLabel(PushRepeat.daily), 'Every day');
      expect(pushRepeatFrom('MONTHLY'), PushRepeat.monthly);
      expect(pushRepeatFrom('hourly'), PushRepeat.once);
      expect(scheduleTimeProblem(null, _now), 'Choose the date and time.');
      expect(scheduleTimeProblem(_now, _now), 'Choose a time in the future.');
      expect(scheduleTimeProblem(_now.add(const Duration(days: 400)), _now), 'Choose a time within a year.');
      expect(scheduleTimeProblem(_now.add(const Duration(hours: 1)), _now), isNull);
    });

    test('a schedule row and its read-back', () {
      final row = pushScheduleRow(
        title: ' Weekend bonus ',
        body: 'RM 30',
        audience: 'drivers',
        sendAt: my(2026, 10, 25, 9),
        repeat: PushRepeat.weekly,
        partnerTypes: ['eHailing'],
        area: const PushArea.region(country: 'Malaysia', city: 'Kajang'),
      );
      expect(row['audience'], 'partners');
      expect(row['title'], 'Weekend bonus');
      expect(row['send_at'], '2026-10-25T01:00:00.000Z');
      expect(row['repeat'], 'weekly');
      expect(pushScheduleRow(title: 't', body: 'b', audience: 'users', sendAt: _now, repeat: PushRepeat.once,
          partnerTypes: ['x'])['partner_types'], isEmpty, reason: 'Partner Service types only for partners');
      final s = PushSchedule.fromRow({...row, 'id': 's1', 'next_at': '2026-11-01T01:00:00Z', 'status': 'active'});
      expect(s.when, my(2026, 11, 1, 9));
      expect(s.toText, 'Partners: eHailing in Kajang, Malaysia');
    });
  });

  group('partners by type (logic)', () {
    test('a partner with two types is counted under each, and once in all', () {
      final counts = partnerTypeCounts(_partners, ['eHailing', 'Teksi', 'Delivery', 'Fleet']);
      expect(counts, [
        (type: 'eHailing', count: 2),
        (type: 'Teksi', count: 2),
        (type: 'Delivery', count: 0),
        (type: 'Fleet', count: 0),
        (type: 'Courier', count: 1),
      ]);
      expect(partnerAccountsOf(_partners, ['eHailing', 'teksi']), {'u1', 'u2', 'u3'},
          reason: 'u1 has both and is one partner');
      expect(partnerAccountsOf(_partners, const []).length, 4, reason: 'none chosen: every approved partner');
    });

    test('approved only is the default; off counts everyone', () {
      expect(partnerTypeCounts(_partners, ['Delivery']).first.count, 0);
      expect(partnerTypeCounts(_partners, ['Delivery'], approvedOnly: false).first.count, 1);
      expect(partnerAccountsOf(_partners, const [], approvedOnly: false).length, 5);
    });

    test('the legacy single type counts', () {
      expect(partnerRowTypes({'partner_types': null, 'partner_type': ' Teksi '}), ['Teksi']);
      expect(partnerRowTypes({'partner_types': ['A', ' ', 'B']}), ['A', 'B']);
    });
  });

  group('typing helpers (logic)', () {
    test('an emoji goes in at the cursor', () {
      const v = TextEditingValue(text: 'Hello world', selection: TextSelection.collapsed(offset: 5));
      final out = insertAtCursor(v, ' 🎉');
      expect(out.text, 'Hello 🎉 world');
      expect(out.selection.baseOffset, 5 + ' 🎉'.length);
      expect(insertAtCursor(const TextEditingValue(text: 'Hi'), '!').text, 'Hi!', reason: 'no cursor: at the end');
      expect(
        insertAtCursor(const TextEditingValue(text: 'abc', selection: TextSelection(baseOffset: 1, extentOffset: 2)), 'X').text,
        'aXc',
      );
    });

    test('the toolbar wraps the selection, or a placeholder', () {
      const v = TextEditingValue(text: 'get RM 30', selection: TextSelection(baseOffset: 4, extentOffset: 9));
      expect(wrapSelection(v, '**', '**').text, 'get **RM 30**');
      final empty = wrapSelection(const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0)), '_', '_');
      expect(empty.text, '_text_');
      expect(empty.selection, const TextSelection(baseOffset: 1, extentOffset: 5));
    });

    test('headings and bullets go on whole lines, and come off again', () {
      const v = TextEditingValue(text: 'one\ntwo\nthree', selection: TextSelection(baseOffset: 1, extentOffset: 6));
      final listed = prefixLines(v, '- ');
      expect(listed.text, '- one\n- two\nthree');
      expect(prefixLines(listed.copyWith(selection: const TextSelection(baseOffset: 0, extentOffset: 8)), '- ').text,
          'one\ntwo\nthree');
    });

    test('about forty emoji', () {
      expect(pushEmojis.length, inInclusiveRange(36, 48));
      expect(pushEmojis.toSet().length, pushEmojis.length);
    });
  });

  for (final b in Brightness.values) {
    group('composer (${b.name})', () {
      testWidgets('emoji go into the title at the cursor, and the preview follows', (tester) async {
        await _pump(tester, brightness: b);
        await tester.enterText(find.byKey(const ValueKey('push-title')), 'Weekend bonus');
        await tester.tap(find.byKey(const ValueKey('push-title-emoji')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('push-emoji-4')));
        await tester.pumpAndSettle();
        expect(find.descendant(of: find.byKey(const ValueKey('push-preview')), matching: find.text('Weekend bonus🎉')),
            findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('partners: chips with counts, and the reach counts by type', (tester) async {
        final admin = await _pump(tester, brightness: b);
        await tester.tap(find.text('Partners'));
        await _settle(tester);
        expect(find.byKey(const ValueKey('push-partner-types')), findsOneWidget);
        expect(find.text('eHailing  2'), findsOneWidget);
        expect(find.text('Courier  1'), findsOneWidget, reason: 'a type partners have but the settings lack');
        expect(admin.dryRuns.last['approvedOnly'], isTrue, reason: 'approved only by default');
        expect(find.textContaining('4 partners match'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('push-ptype-eHailing')));
        await tester.tap(find.byKey(const ValueKey('push-ptype-Teksi')));
        await _settle(tester);
        expect(admin.dryRuns.last['partnerTypes'], ['eHailing', 'Teksi']);
        expect(find.textContaining('3 partners match, each counted once'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('push-approved-only')));
        await _settle(tester);
        expect(admin.dryRuns.last['approvedOnly'], isFalse);
        expect(find.text('Delivery  1'), findsOneWidget, reason: 'the partner waiting for approval counts now');
      });

      testWidgets('a full message is stored and sent with the push', (tester) async {
        final admin = await _pump(tester, brightness: b);
        await tester.enterText(find.byKey(const ValueKey('push-title')), 'Weekend bonus');
        await tester.enterText(find.byKey(const ValueKey('push-body')), 'RM 30 extra');
        await tester.enterText(find.byKey(const ValueKey('push-rich')), '# Weekend bonus\n\nGet {green:RM 30}');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('push-preview-message')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('push-send')));
        await _openDialog(tester);
        await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Send')));
        await tester.pumpAndSettle();
        expect(admin.messages.single['blocks'], [
          {
            'type': 'heading',
            'spans': [
              {'text': 'Weekend bonus'},
            ],
          },
          {
            'type': 'paragraph',
            'spans': [
              {'text': 'Get '},
              {'text': 'RM 30', 'color': 'green'},
            ],
          },
        ]);
        expect(admin.sends.single['messageId'], 'msg-1');
        expect(admin.sends.single['approvedOnly'], isNull, reason: 'not a partner send');
        expect(find.text('Sent to 2 of 2 devices.'), findsOneWidget);
      });

      testWidgets('the toolbar types bold and a button', (tester) async {
        await _pump(tester, brightness: b);
        await tester.tap(find.byKey(const ValueKey('push-rich-bold')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('push-rich-button')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('push-link-label')), 'Top up');
        await tester.enterText(find.byKey(const ValueKey('push-link-target')), 'javascript:alert(1)');
        await tester.tap(find.byKey(const ValueKey('push-link-done')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Use a page of the app'), findsOneWidget, reason: 'refused');
        await tester.enterText(find.byKey(const ValueKey('push-link-target')), '/wallet');
        await tester.tap(find.byKey(const ValueKey('push-link-done')));
        await tester.pumpAndSettle();
        final text = tester.widget<TextField>(find.byKey(const ValueKey('push-rich'))).controller!.text;
        expect(text, '**text**\n[[Top up]](/wallet)\n');
        expect(find.descendant(of: find.byKey(const ValueKey('push-preview')), matching: find.widgetWithText(FilledButton, 'Top up')),
            findsOneWidget);
      });
    });
  }

  testWidgets('schedules a weekly partner push in Malaysia time', (tester) async {
    final admin = await _pump(tester, width: 600);
    await tester.enterText(find.byKey(const ValueKey('push-title')), 'Weekend bonus');
    await tester.enterText(find.byKey(const ValueKey('push-body')), 'RM 30 extra');
    await tester.tap(find.text('Partners'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('push-ptype-Teksi')));
    await _settle(tester);
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();
    // Tomorrow, 24 Oct (a Saturday), 09:00 by default.
    expect(find.byKey(const ValueKey('push-date')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('push-repeat-new-once')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every week (Saturday)').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Schedule'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('push-send')));
    await _openDialog(tester);
    expect(find.textContaining('24/10/2026 09:00 Malaysia time, then every week (saturday)'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Schedule')));
    await tester.pumpAndSettle();
    final w = admin.scheduleWrites.single;
    expect(w.id, isNull);
    expect(w.row['send_at'], '2026-10-24T01:00:00.000Z');
    expect(w.row['repeat'], 'weekly');
    expect(w.row['partner_types'], ['Teksi']);
    expect(w.row['approved_only'], isTrue);
    expect(w.row['message_id'], isNull, reason: 'no full message');
    expect(admin.sends, isEmpty, reason: 'nothing goes now');
  });

  testWidgets('a past time is refused', (tester) async {
    final admin = await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('push-title')), 'T');
    await tester.enterText(find.byKey(const ValueKey('push-body')), 'B');
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();
    // Today at 09:00: an hour ago in Kuala Lumpur.
    await tester.enterText(find.byKey(const ValueKey('date-box-day')), '23');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('push-send')));
    await _openDialog(tester);
    expect(admin.scheduleWrites, isEmpty);
    await closeNotice(tester);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('the Scheduled list edits and cancels', (tester) async {
    final admin = _Admin();
    final at = fromMalaysiaClock(2026, 10, 31, 18, 0);
    admin.schedules = [
      PushSchedule(
        id: 's1',
        title: 'Halloween ride promo 🎃',
        body: 'Spooky fares',
        audience: 'users',
        sendAt: at,
        nextAt: at,
        messageId: 'm9',
        area: const PushArea.region(country: 'Malaysia', city: 'Kajang'),
      ),
    ];
    await tester.binding.setSurfaceSize(const Size(1200, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith((_) async => AdminAccess([const AdminGrant(page: '*', edit: true)])),
        adminRepositoryProvider.overrideWithValue(admin),
        geoAdminRepositoryProvider.overrideWithValue(_Geo()),
      ],
      child: MaterialApp(theme: appTheme(Brightness.dark), home: AdminPushScreen(now: () => _now)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Halloween ride promo 🎃'), findsOneWidget);
    expect(find.textContaining('31/10/2026 18:00 · Once\nPassengers in Kajang, Malaysia'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('push-schedule-edit-s1')));
    await tester.pumpAndSettle();
    expect(find.text('Edit scheduled notification'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('push-rich'))).controller!.text, 'Stored text');
    await tester.enterText(find.byKey(const ValueKey('push-title')), 'Halloween promo');
    await tester.tap(find.byKey(const ValueKey('push-send')));
    await _openDialog(tester);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Save')));
    await tester.pumpAndSettle();
    final w = admin.scheduleWrites.single;
    expect(w.id, 's1');
    expect(w.row['title'], 'Halloween promo');
    expect(w.row.containsKey('send_at'), isFalse, reason: 'the time was not changed');
    expect(admin.messages.single['id'], 'm9', reason: 'the same full message is updated');

    await closeNotice(tester);
    await tester.tap(find.byKey(const ValueKey('push-schedule-cancel-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Stop sending'));
    await tester.pumpAndSettle();
    expect(admin.cancelled, ['s1']);
  });

  for (final b in Brightness.values) {
    testWidgets('the preview shows the picture and the page (${b.name})', (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: appTheme(b),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: PushPreview(
                  title: 'Weekend bonus',
                  body: 'RM 30 extra',
                  imageUrl: 'https://x.test/p.png',
                  blocks: parsePushMarkup('# Hi\n\n- one'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('push-preview-image')), findsOneWidget);
      expect(find.text('‹ Notifications'), findsOneWidget);
      expect(find.byKey(const ValueKey('push-message-bullets-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
