import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/features/support/call/mic_gate.dart';

import 'fake_mic.dart';

/// A button that asks [ensureMicForCall] and records the answer.
Future<List<bool>> _pump(WidgetTester tester, FakeMic mic) async {
  final answers = <bool>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [micPermissionProvider.overrideWithValue(mic)],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () async => answers.add(await ensureMicForCall(context, ref)),
              child: const Text('Call'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Call'));
  await tester.pumpAndSettle();
  return answers;
}

void main() {
  testWidgets('with the microphone on, the call goes ahead at once', (tester) async {
    final answers = await _pump(tester, FakeMic());
    expect(answers, [true]);
    expect(find.byKey(const ValueKey('mic-needed')), findsNothing);
  });

  testWidgets('with it off, nothing is placed until it is on: Not now leaves it unplaced', (tester) async {
    final mic = FakeMic(granted: false);
    final answers = await _pump(tester, mic);
    expect(find.byKey(const ValueKey('mic-needed')), findsOneWidget);
    expect(answers, isEmpty, reason: 'no call while the question is open');
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(answers, [false]);
    expect(mic.settingsOpened, 0);
  });

  testWidgets('Open Settings, switch it on, come back: the call goes ahead', (tester) async {
    final mic = FakeMic(granted: false, grantInSettings: true);
    final answers = await _pump(tester, mic);
    await tester.tap(find.byKey(const ValueKey('mic-open-settings')));
    await tester.pumpAndSettle();
    expect(mic.settingsOpened, 1);
    expect(answers, isEmpty, reason: 'waiting for the rider to come back');
    // Back in the app.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });

  testWidgets('back from Settings with it still off: no call', (tester) async {
    final mic = FakeMic(granted: false);
    final answers = await _pump(tester, mic);
    await tester.tap(find.byKey(const ValueKey('mic-open-settings')));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });
}
