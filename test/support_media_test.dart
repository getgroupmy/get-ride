import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:get_ride/src/core/support_media.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/photo_picker.dart';
import 'package:get_ride/src/data/voice_recorder.dart';
import 'package:get_ride/src/features/support/call/mic_gate.dart';
import 'package:get_ride/src/widgets/voice_note.dart';
import 'package:get_ride/src/features/support/support_chat_screen.dart';
import 'package:get_ride/src/features/support/support_screen.dart' show supportStatusLabel, ticketsProvider;
import 'package:get_ride/src/providers.dart';

import 'chat_media_fakes.dart';
import 'fake_mic.dart';

class _FakeAccount implements AccountRepository {
  final sent = <String>[];

  @override
  Future<void> markTicketRead(String ticketId) async {}

  @override
  Future<void> sendAttachment(String ticketId, Uint8List bytes, {required String name, String? senderName}) async =>
      sent.add('$ticketId:$name:${bytes.length}');

  @override
  Future<void> sendVoiceNote(
    String ticketId,
    Uint8List bytes, {
    required String ext,
    required Duration duration,
    String? senderName,
  }) async => sent.add('$ticketId:voice:$ext:${duration.inSeconds}');

  @override
  Future<SupportTicket> openTicket(String subject) async => SupportTicket({'id': 't9', 'subject': subject});

  @override
  Future<void> sendMessage(String ticketId, String body, {String? senderName}) async => sent.add('$ticketId:$body');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('kinds, content types and paths follow Expo', () {
    expect(fileExt('IMG_0001.JPG'), 'jpg');
    expect(fileExt('clip.mov?x=1'), 'mov');
    expect(fileExt('noext'), '');
    expect(supportMediaKind('heic'), 'image');
    expect(supportMediaKind('mp4'), 'video');
    expect(supportMediaKind('pdf'), isNull);
    expect(supportContentType('image', 'jpeg'), 'image/jpeg');
    expect(supportContentType('video', 'mov'), 'video/quicktime');
    expect(supportContentType('video', 'mp4'), 'video/mp4');
    expect(
      supportMediaPath('t1', 'image', 'jpg', DateTime.fromMillisecondsSinceEpoch(1700000000000), 'ab12cd34'),
      't1/image-1700000000000-ab12cd34.jpg',
    );
  });

  test('ticket previews and file checks', () {
    expect(supportSummary('image', null), '📷 Photo');
    expect(supportSummary('video', null), '🎬 Video');
    expect(supportSummary('text', '  hi  '), 'hi');
    expect(supportSummary('text', ''), 'Message');
    expect(supportMediaProblem('a.pdf', 10), 'Send a photo or a video.');
    expect(supportMediaProblem('a.jpg', 0), isNotNull);
    expect(supportMediaProblem('a.mp4', supportMediaMaxBytes + 1), 'Choose a file under 50 MB.');
    expect(supportMediaProblem('a.mp4', 1024), isNull);
  });

  Future<_FakeAccount> pump(
    WidgetTester tester,
    SupportAttachment? file,
    List<SupportMessage> msgs, {
    List<Override> extra = const [],
    bool camera = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.reset);
    final account = _FakeAccount();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(account),
          profileProvider.overrideWith((ref) async => Profile({'id': 'me', 'name': 'Ali'})),
          supportMessagesProvider.overrideWith((ref, id) => Stream.value(msgs)),
          photoCameraAvailableProvider.overrideWithValue(camera),
          ...extra,
        ],
        child: MaterialApp(
          home: SupportChatScreen(ticketId: 't1', pickAttachment: () async => file),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return account;
  }

  testWidgets('a picked photo is sent; photos and videos show as media', (tester) async {
    final account = await pump(
      tester,
      (bytes: Uint8List(2048), name: 'IMG_1.jpg'),
      [
        SupportMessage({'id': 'm1', 'sender_role': 'admin', 'type': 'video', 'media_url': 'https://x.test/v.mp4'}),
        SupportMessage({'id': 'm2', 'sender_role': 'user', 'type': 'text', 'body': 'hello'}),
      ],
    );
    expect(find.byKey(const ValueKey('support-video-m1')), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('support-attach')));
    await tester.pumpAndSettle();
    expect(account.sent, ['t1:IMG_1.jpg:2048']);
  });

  testWidgets('a file that is not a photo or video is refused before upload', (tester) async {
    final account = await pump(tester, (bytes: Uint8List(10), name: 'notes.pdf'), const []);
    await tester.tap(find.byKey(const ValueKey('support-attach')));
    await tester.pumpAndSettle();
    expect(account.sent, isEmpty);
    expect(find.text('Send a photo or a video.'), findsOneWidget);
  });

  testWidgets('a photo can be snapped with the camera', (tester) async {
    final account = await pump(
      tester,
      null,
      const [],
      camera: true,
      extra: [
        photoPickerProvider.overrideWithValue((source) async => (bytes: Uint8List(512), name: 'snap.jpg')),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('support-attach')));
    // The attach key spins while the sheet is up, so the screen never settles.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.byKey(const ValueKey('photo-camera')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(account.sent, ['t1:snap.jpg:512']);
  });

  testWidgets('a voice note is recorded and sent; voice notes play in the thread', (tester) async {
    final rec = FakeRecorder(clip: fakeClip(4));
    final player = FakePlayback();
    final account = await pump(
      tester,
      null,
      [
        SupportMessage({
          'id': 'a1',
          'sender_role': 'admin',
          'type': 'audio',
          'media_url': 'https://x.test/a.m4a',
          'media_duration': 9,
        }),
      ],
      extra: [
        micPermissionProvider.overrideWithValue(FakeMic()),
        voiceRecorderFactoryProvider.overrideWithValue(() => rec),
        voicePlaybackFactoryProvider.overrideWithValue(() => player),
      ],
    );
    expect(find.byKey(const ValueKey('support-voice-a1')), findsOneWidget);
    expect(find.text('0:09'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-note-play')));
    await tester.pump();
    expect(player.played, ['https://x.test/a.m4a']);

    await tester.tap(find.byKey(const ValueKey('support-voice')));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('voice-recording')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-send')));
    await tester.pump();
    await tester.pump();
    expect(account.sent, ['t1:voice:m4a:4']);
  });

  test("a new chat's address becomes its ticket's", () {
    expect(supportTicketAddress('/account/support/new', 't9'), '/account/support/t9');
    expect(supportTicketAddress('/account/support/t1', 't9'), isNull);
    expect(supportStatusLabel('open'), 'Open');
    expect(supportStatusLabel('in_progress'), 'In progress');
  });

  testWidgets('after the first message the address is the ticket, so a reload keeps the chat', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.reset);
    final account = _FakeAccount();
    final router = GoRouter(
      initialLocation: '/account/support/new',
      routes: [
        GoRoute(
          path: '/account/support/:ticketId',
          builder: (_, s) => SupportChatScreen(ticketId: s.pathParameters['ticketId']!),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(account),
          profileProvider.overrideWith((ref) async => Profile({'id': 'me', 'name': 'Ali'})),
          supportMessagesProvider.overrideWith((ref, id) => Stream.value(const <SupportMessage>[])),
          photoCameraAvailableProvider.overrideWithValue(false),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My card was charged twice');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('support-send')));
    await tester.pumpAndSettle();
    expect(account.sent, ['t9:My card was charged twice']);
    expect(router.routeInformationProvider.value.uri.path, '/account/support/t9');
  });

  testWidgets('the chat is headed by its ticket and status', (tester) async {
    await pump(
      tester,
      null,
      const [],
      extra: [
        ticketsProvider.overrideWith(
          (ref) async => [SupportTicket({'id': 't1', 'subject': 'Support request', 'ticket_number': 4, 'status': 'open'})],
        ),
      ],
    );
    expect(find.text('#4 · Support request'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });
}

