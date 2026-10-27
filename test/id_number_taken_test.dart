// One account per ID number (migration 0303, docs/KIV.md M8): the server's
// ID_NUMBER_TAKEN is "This ID number is already registered", a modal with
// Contact support and OK, wherever the number is saved (registration,
// profile, admin edit), since they all report through showError /
// showErrorNotice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/widgets/common.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _taken = PostgrestException(message: 'ID_NUMBER_TAKEN', code: '23505', hint: idNumberTakenMessage);

GoRouter _router(String start, Widget Function(BuildContext) page) => GoRouter(
  initialLocation: start,
  routes: [
    GoRoute(path: '/drive', builder: (c, _) => Scaffold(body: page(c))),
    GoRoute(path: '/admin/users', builder: (c, _) => Scaffold(body: page(c))),
    GoRoute(path: '/account/support', builder: (_, _) => const Scaffold(body: Text('support screen'))),
  ],
);

Widget _button(String label, void Function(BuildContext) onTap) =>
    Builder(builder: (c) => TextButton(onPressed: () => onTap(c), child: Text(label)));

void main() {
  group('the mapping', () {
    test('ID_NUMBER_TAKEN from the trigger', () {
      expect(isIdNumberTaken(_taken), isTrue);
      expect(errorText(_taken), idNumberTakenMessage);
    });

    test('the unique index, when two saves race', () {
      const raced = PostgrestException(
        message: 'duplicate key value violates unique constraint "profiles_ic_key_uidx"',
        code: '23505',
      );
      expect(isIdNumberTaken(raced), isTrue);
      expect(errorText(raced), idNumberTakenMessage);
    });

    test('other refusals are not it', () {
      expect(isIdNumberTaken(const PostgrestException(message: 'duplicate key', code: '23505')), isFalse);
      expect(isIdNumberTaken(const PostgrestException(message: 'GET_CREDIT_TOO_LOW', hint: 'Top up')), isFalse);
      expect(isIdNumberTaken(Exception('ID_NUMBER_TAKEN')), isFalse);
    });

    test('the words', () {
      expect(idNumberTakenTitle, 'This ID number is already registered');
      expect(idNumberTakenMessage, contains('Sign in to that account, or contact support'));
      expect(idNumberTakenMessage, contains('900101-14-5678 and 900101145678 are the same'));
      expect('$idNumberTakenTitle $idNumberTakenMessage', isNot(contains('→')));
    });
  });

  for (final b in Brightness.values) {
    group('the modal (${b.name})', () {
      Future<void> pump(WidgetTester tester, GoRouter router) async {
        await tester.pumpWidget(MaterialApp.router(theme: appTheme(b), routerConfig: router));
        await tester.pumpAndSettle();
      }

      testWidgets('showError: title, message, Contact support opens support', (tester) async {
        await pump(tester, _router('/drive', (_) => _button('save', (c) => showError(c, _taken))));
        await tester.tap(find.text('save'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('id-taken')), findsOneWidget);
        expect(find.text(idNumberTakenTitle), findsOneWidget);
        expect(find.text(idNumberTakenMessage), findsOneWidget);
        expect(find.text('OK'), findsOneWidget);
        await tester.tap(find.text('Contact support'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('id-taken')), findsNothing);
        expect(find.text('support screen'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('showErrorNotice (registration): the same modal; OK closes it', (tester) async {
        await pump(tester, _router('/drive', (_) => _button('save', (c) => showErrorNotice(c, _taken))));
        await tester.tap(find.text('save'));
        await tester.pumpAndSettle();
        expect(find.text(idNumberTakenTitle), findsOneWidget);
        expect(find.text('Contact support'), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.text(idNumberTakenTitle), findsNothing);
        expect(find.text('support screen'), findsNothing);
      });

      testWidgets('in the admin pages: the same words, no Contact support', (tester) async {
        await pump(tester, _router('/admin/users', (_) => _button('save', (c) => showError(c, _taken))));
        await tester.tap(find.text('save'));
        await tester.pumpAndSettle();
        expect(find.text(idNumberTakenTitle), findsOneWidget);
        expect(find.text(idNumberTakenMessage), findsOneWidget);
        expect(find.text('Contact support'), findsNothing);
      });
    });
  }
}
