import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/support_media.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/support/support_chat_screen.dart';
import 'package:get_ride/src/providers.dart';

class _FakeAccount implements AccountRepository {
  final sent = <String>[];

  @override
  Future<void> markTicketRead(String ticketId) async {}

  @override
  Future<void> sendAttachment(String ticketId, Uint8List bytes, {required String name, String? senderName}) async =>
      sent.add('$ticketId:$name:${bytes.length}');

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

  Future<_FakeAccount> pump(WidgetTester tester, SupportAttachment? file, List<SupportMessage> msgs) async {
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
}
