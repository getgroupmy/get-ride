import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/inbox.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/push_message.dart';
import 'package:get_ride/src/data/notifications_repository.dart';
import 'package:get_ride/src/features/notifications/push_message_screen.dart';
import 'package:get_ride/src/widgets/push_message_view.dart';

const _pic = 'https://ref.supabase.co/storage/v1/object/public/media/image/bonus.jpg';

/// The message the admin approved in the sample, as stored.
final _stored = [
  {
    'type': 'heading',
    'spans': [
      {'text': 'Weekend bonus 🎉'},
    ],
  },
  {
    'type': 'paragraph',
    'spans': [
      {'text': 'Complete '},
      {'text': '10 trips', 'bold': true},
      {'text': ' and get '},
      {'text': 'RM 30 extra', 'bold': true, 'color': 'green'},
      {'text': '.'},
    ],
  },
  {
    'type': 'bullets',
    'items': [
      [
        {'text': 'Any service counts'},
      ],
      [
        {'text': 'Paid into GET.wallet on Monday', 'italic': true},
      ],
    ],
  },
  {
    'type': 'paragraph',
    'spans': [
      {'text': 'See the terms', 'link': 'https://getride.example/terms'},
    ],
  },
  {'type': 'button', 'label': 'Go online now', 'link': '/drive'},
];

void main() {
  group('blocks (logic)', () {
    test('a stored message reads back as it was written', () {
      final blocks = decodePushBlocks(_stored);
      expect(blocks.map((b) => b.type), [
        PushBlockType.heading,
        PushBlockType.paragraph,
        PushBlockType.bullets,
        PushBlockType.paragraph,
        PushBlockType.button,
      ]);
      expect(blocks[1].spans[3], const PushSpan('RM 30 extra', bold: true, color: PushColor.green));
      expect(encodePushBlocks(blocks), _stored);
    });

    test('unknown block types and empty blocks are dropped', () {
      final blocks = decodePushBlocks([
        {'type': 'html', 'html': '<script>alert(1)</script>'},
        {'type': 'video', 'url': _pic},
        {'type': 'paragraph', 'spans': []},
        {'type': 'heading', 'spans': [{'text': '   '}]},
        {'type': 'bullets', 'items': [[], [{'text': 7}]]},
        'paragraph',
        null,
        {'type': 'paragraph', 'spans': [{'text': 'kept'}, {'bold': true}]},
      ]);
      expect(blocks, [const PushBlock.paragraph([PushSpan('kept')])]);
      expect(decodePushBlocks('[{"type":"paragraph"}]'), isEmpty, reason: 'only a decoded list is read');
      expect(decodePushBlocks(null), isEmpty);
    });

    test('colours are only the palette', () {
      final b = decodePushBlocks([
        {
          'type': 'paragraph',
          'spans': [
            {'text': 'a', 'color': 'GREEN'},
            {'text': 'b', 'color': '#ff0000'},
            {'text': 'c', 'color': 'pink'},
          ],
        },
      ]).single;
      expect(b.spans.first.color, PushColor.green);
      expect(b.spans.last, const PushSpan('bc'), reason: 'an unknown colour is no colour (and joins its neighbour)');
    });

    test('links only http(s) or an in-app route', () {
      for (final ok in ['https://x.test/a?b=1', 'http://x.test', '/wallet', '/drive/scheduled?tab=mine', '/account/notifications']) {
        expect(isSafePushLink(ok), isTrue, reason: ok);
      }
      for (final bad in [
        'javascript:alert(1)',
        'JAVASCRIPT:alert(1)',
        'data:text/html,hi',
        'file:///etc/passwd',
        '//evil.test/x',
        'tel:+60123',
        'intent://x',
        'wallet',
        '/a b',
        'https://',
        '',
        null,
      ]) {
        expect(isSafePushLink(bad), isFalse, reason: '$bad');
      }
      final blocks = decodePushBlocks([
        {
          'type': 'paragraph',
          'spans': [
            {'text': 'bad', 'link': 'javascript:alert(1)'},
            {'text': 'good', 'link': '/wallet'},
          ],
        },
        {'type': 'button', 'label': 'Bad', 'link': 'javascript:x'},
        {'type': 'button', 'label': '', 'link': '/wallet'},
        {'type': 'image', 'url': 'http://x.test/a.png'},
        {'type': 'image', 'url': _pic},
      ]);
      expect(blocks, [
        const PushBlock.paragraph([PushSpan('bad'), PushSpan('good', link: '/wallet')]),
        const PushBlock.image(_pic),
      ]);
    });

    test('lengths are capped', () {
      final b = decodePushBlocks([
        for (var i = 0; i < 80; i++)
          {
            'type': 'paragraph',
            'spans': [
              {'text': 'x' * 3000},
            ],
          },
        {'type': 'button', 'label': 'L' * 100, 'link': '/wallet'},
      ]);
      expect(b.length, 60);
      expect(b.first.spans.single.text.length, 2000);
    });

    test('the admin markup reads into blocks and back', () {
      const markup = '# Weekend bonus 🎉\n\n'
          'Complete **10 trips** and get {green:**RM 30 extra**}.\n'
          'On _Saturday_ only.\n\n'
          '- Any service counts\n'
          '- Paid into GET.wallet\n\n'
          '[See the terms](https://getride.example/terms)\n\n'
          '[[Go online now]](/drive)\n\n'
          '![](https://x.test/p.png)';
      final blocks = parsePushMarkup(markup);
      expect(blocks.map((b) => b.type), [
        PushBlockType.heading,
        PushBlockType.paragraph,
        PushBlockType.bullets,
        PushBlockType.paragraph,
        PushBlockType.button,
        PushBlockType.image,
      ]);
      expect(blocks[1].spans, const [
        PushSpan('Complete '),
        PushSpan('10 trips', bold: true),
        PushSpan(' and get '),
        PushSpan('RM 30 extra', bold: true, color: PushColor.green),
        PushSpan('.\nOn '),
        PushSpan('Saturday', italic: true),
        PushSpan(' only.'),
      ]);
      expect(blocks[3].spans.single, const PushSpan('See the terms', link: 'https://getride.example/terms'));
      expect(blocks[4], const PushBlock.button('Go online now', '/drive'));
      expect(parsePushMarkup(pushMarkup(blocks)), blocks, reason: 'markup round-trips');
      expect(parsePushMarkup(pushMarkup(decodePushBlocks(_stored))), decodePushBlocks(_stored));
    });

    test('markup that is not safe or not closed stays plain text', () {
      final b = parsePushMarkup('[click](javascript:alert(1)) **open {pink:x} a\\*b');
      expect(b.single.spans.every((s) => s.link == null && s.color == null && !s.bold), isTrue);
      expect(pushBlocksText(b), contains('a*b'));
      expect(parsePushMarkup('[[Pay]](javascript:x)'), isEmpty);
      expect(parsePushMarkup('  \n\n '), isEmpty);
    });

    test('marker characters in text survive the round trip', () {
      const spans = [PushSpan('2*3 = 6_ok [x] {y}\\')];
      final blocks = [const PushBlock.paragraph(spans)];
      expect(parsePushMarkup(pushMarkup(blocks)), blocks);
    });

    test('colours keep their contrast in both themes', () {
      for (final c in PushColor.values) {
        final light = Color(pushColorValue(c, dark: false)), dark = Color(pushColorValue(c, dark: true));
        expect(light.computeLuminance(), lessThan(0.25), reason: '$c on white');
        expect(dark.computeLuminance(), greaterThan(0.35), reason: '$c on a dark page');
      }
    });

    test('a push with a full message opens its page, from the push and the notifications page', () {
      const data = {'audience': 'partners', 'message_id': 'abc-1', 'image': _pic};
      expect(pushRouteFor(data), '/account/notifications/abc-1');
      expect(pushRouteFor(const {'audience': 'all'}), isNull);
      final item = InboxItem(id: 'n1', title: 'T', body: 'B', data: data, createdAt: DateTime(2026, 10, 25));
      expect(item.route, '/account/notifications/abc-1');
      // A trip push keeps its own page.
      expect(pushRouteFor(const {'type': 'ride_status', 'request_id': 'r1', 'message_id': 'x'}), '/ride/r1');
    });
  });

  for (final b in Brightness.values) {
    group('message page (${b.name})', () {
      Future<void> pump(WidgetTester tester, Map<String, dynamic>? row) async {
        await tester.binding.setSurfaceSize(const Size(420, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(ProviderScope(
          overrides: [
            pushMessageProvider.overrideWith((ref, id) async => row),
            notificationsProvider.overrideWith((ref) => Stream.value(const <InboxItem>[])),
          ],
          child: MaterialApp(theme: appTheme(b), home: const PushMessageScreen(messageId: 'm1')),
        ));
        await tester.pumpAndSettle();
      }

      testWidgets('draws the picture on top, then the blocks', (tester) async {
        await pump(tester, {'id': 'm1', 'title': 'Weekend bonus', 'body': 'RM 30', 'image_url': _pic, 'blocks': _stored});
        expect(find.text('Weekend bonus'), findsOneWidget, reason: 'the bar');
        expect(find.byKey(const ValueKey('push-message-image')), findsOneWidget);
        final image = tester.getTopLeft(find.byKey(const ValueKey('push-message-image'))).dy;
        final heading = tester.getTopLeft(find.byKey(const ValueKey('push-message-heading-0'))).dy;
        expect(image, lessThan(heading));
        expect(find.textContaining('Any service counts', findRichText: true), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Go online now'), findsOneWidget);
        // The green is the theme's green for this brightness.
        final para = tester.widget<RichText>(
          find.descendant(of: find.byKey(const ValueKey('push-message-paragraph-1')), matching: find.byType(RichText)),
        );
        final spans = <InlineSpan>[];
        para.text.visitChildren((s) {
          spans.add(s);
          return true;
        });
        final green = spans.whereType<TextSpan>().firstWhere((s) => s.text == 'RM 30 extra');
        expect(green.style?.color, Color(pushColorValue(PushColor.green, dark: b == Brightness.dark)));
        expect(green.style?.fontWeight, FontWeight.w700);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a message with no blocks shows its title and text', (tester) async {
        await pump(tester, {'id': 'm1', 'title': 'Hello', 'body': 'Plain text only', 'blocks': []});
        expect(find.textContaining('Plain text only', findRichText: true), findsOneWidget);
        expect(find.byKey(const ValueKey('push-message-image')), findsNothing);
      });

      testWidgets('a message this account cannot read says it is not there', (tester) async {
        await pump(tester, null);
        expect(find.byKey(const ValueKey('push-message-missing')), findsOneWidget);
      });
    });
  }

  testWidgets('links and buttons hand their target to the page', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(body: PushMessageView(blocks: decodePushBlocks(_stored), onLink: opened.add)),
      ),
    ));
    await tester.tap(find.widgetWithText(FilledButton, 'Go online now'));
    // The link is a span of its paragraph: its recognizer is what a tap on it runs.
    final para = tester.widget<RichText>(
      find.descendant(of: find.byKey(const ValueKey('push-message-paragraph-3')), matching: find.byType(RichText)),
    );
    TapGestureRecognizer? tap;
    para.text.visitChildren((s) {
      if (s is TextSpan && s.text == 'See the terms') tap = s.recognizer as TapGestureRecognizer?;
      return true;
    });
    tap!.onTap!();
    expect(opened, ['/drive', 'https://getride.example/terms']);
  });
}
