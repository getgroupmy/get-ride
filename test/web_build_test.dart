import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/web_build.dart';
import 'package:get_ride/src/features/shell/web_build_gate.dart';

void main() {
  group('parseWebBuild', () {
    test('reads the id', () => expect(parseWebBuild('{"build":"abc123"}\n'), 'abc123'));
    test('anything else is no id', () {
      expect(parseWebBuild('<!DOCTYPE html><html>'), isNull);
      expect(parseWebBuild(''), isNull);
      expect(parseWebBuild('{"build":""}'), isNull);
      expect(parseWebBuild('{"build":7}'), isNull);
      expect(parseWebBuild('[]'), isNull);
    });
  });

  group('decideWebRefresh', () {
    test('nothing to do when current, unknown, or not a deployed build', () {
      expect(decideWebRefresh(running: 'a', served: 'a', path: '/'), WebRefresh.none);
      expect(decideWebRefresh(running: 'a', served: null, path: '/'), WebRefresh.none);
      expect(decideWebRefresh(running: '', served: 'b', path: '/'), WebRefresh.none);
    });

    test('behind while in use: offer, never reload under the user', () {
      expect(decideWebRefresh(running: 'a', served: 'b', path: '/'), WebRefresh.offer);
      expect(
        decideWebRefresh(running: 'a', served: 'b', path: '/', hiddenFor: const Duration(minutes: 2)),
        WebRefresh.offer,
      );
    });

    test('behind after a long absence: reload, unless the screen has work to lose', () {
      const away = Duration(minutes: 45);
      expect(decideWebRefresh(running: 'a', served: 'b', path: '/', hiddenFor: away), WebRefresh.reload);
      expect(decideWebRefresh(running: 'a', served: 'b', path: '/wallet', hiddenFor: away), WebRefresh.reload);
      for (final p in [
        '/meter',
        '/meter/printer',
        '/call/1',
        '/ride-call/2',
        '/drive/onboarding',
        '/admin/users',
        '/rides/9/chat',
      ]) {
        expect(
          decideWebRefresh(running: 'a', served: 'b', path: p, hiddenFor: away),
          WebRefresh.offer,
          reason: p,
        );
      }
    });
  });

  group('WebBuildGate', () {
    Widget gate({required String? served, required VoidCallback reload, bool enabled = true}) => MaterialApp(
      home: Scaffold(
        body: WebBuildGate(
          running: 'old',
          enabled: enabled,
          location: () => '/',
          fetchServed: () async => served,
          reload: reload,
          child: const SizedBox.expand(child: Text('app')),
        ),
      ),
    );

    testWidgets('offers a reload when the site is newer', (t) async {
      var reloads = 0;
      await t.pumpWidget(gate(served: 'new', reload: () => reloads++));
      await t.pump();
      expect(find.text('GET.ride has been updated'), findsOneWidget);
      await t.tap(find.text('Reload'));
      expect(reloads, 1);
    });

    testWidgets('Later puts the card away', (t) async {
      await t.pumpWidget(gate(served: 'new', reload: () {}));
      await t.pump();
      await t.tap(find.text('Later'));
      await t.pump();
      expect(find.text('GET.ride has been updated'), findsNothing);
      expect(find.text('app'), findsOneWidget);
    });

    testWidgets('quiet when current, or off the web', (t) async {
      await t.pumpWidget(gate(served: 'old', reload: () {}));
      await t.pump();
      expect(find.text('GET.ride has been updated'), findsNothing);
      await t.pumpWidget(gate(served: 'new', reload: () {}, enabled: false));
      await t.pump();
      expect(find.text('GET.ride has been updated'), findsNothing);
    });
  });
}
