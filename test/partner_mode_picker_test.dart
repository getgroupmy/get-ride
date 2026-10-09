import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/partner_modes.dart';
import 'package:get_ride/src/features/partner/partner_mode_picker.dart';

void main() {
  Future<PartnerModeOption?> pick(WidgetTester tester, List<PartnerModeOption> assigned, String? tap) async {
    PartnerModeOption? result;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () async {
            result = await showPartnerModePicker(c, assigned);
            done = true;
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Select your service mode'), findsOneWidget);
    await tester.tap(tap == null ? find.byKey(const ValueKey('partner-mode-close')) : find.text(tap));
    await tester.pumpAndSettle();
    expect(done, isTrue);
    return result;
  }

  testWidgets("the partner's assigned services are offered, and the pick is returned", (tester) async {
    final r = await pick(tester, const [
      PartnerModeOption(name: 'TEKSI', description: 'Metered taxi'),
      PartnerModeOption(name: 'eHailing'),
    ], 'TEKSI');
    expect(r?.isTeksi, isTrue);
  });

  testWidgets('with no assigned service the defaults are offered; closing picks nothing', (tester) async {
    expect(await pick(tester, const [], null), isNull);
  });

  testWidgets('the defaults are TEKSI and eHailing', (tester) async {
    final r = await pick(tester, const [], 'eHailing');
    expect(r?.name, 'eHailing');
    expect(r?.isTeksi, isFalse);
  });

  test('a pending mode is taken once', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(pendingPartnerModeProvider.notifier)..set(defaultPartnerModeOptions.first);
    expect(n.take()?.name, 'TEKSI');
    expect(n.take(), isNull);
    expect(c.read(pendingPartnerModeProvider), isNull);
  });
}
