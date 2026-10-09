import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/admin/screens/geo/region_rules_editor.dart';
import 'package:get_ride/src/core/region_rules.dart';

void main() {
  Future<List<RegionRule> Function()> pumpEditor(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    var rules = <RegionRule>[];
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          regionServicesProvider.overrideWith((ref) async => const [ServiceOption(id: 'car', name: 'Car')]),
          regionVehicleTypesProvider.overrideWith((ref) async => const [ServiceOption(id: 'premium', name: 'Premium')]),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: RegionRulesSection(rules: rules, onChanged: (r) => setState(() => rules = r)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return () => rules;
  }

  for (final brightness in Brightness.values) {
    testWidgets('adds a weekend surcharge for one vehicle type (${brightness.name})', (tester) async {
      final rules = await pumpEditor(tester, brightness: brightness);
      expect(find.text('No rules.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('region-rule-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(RuleKind.surcharge.label).last);
      await tester.pumpAndSettle();

      // Nothing named yet: it says so instead of saving.
      await tester.tap(find.byKey(const ValueKey('rule-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rule-error')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('rule-name')), 'Weekend');
      await tester.enterText(find.byKey(const ValueKey('rule-amount')), '10');
      await tester.tap(find.byKey(const ValueKey('rule-vehicle-premium')));
      await tester.tap(find.text(ScheduleMode.days.label));
      await tester.pumpAndSettle();
      // Days mode with no day picked is refused too.
      await tester.tap(find.byKey(const ValueKey('rule-save')));
      await tester.pumpAndSettle();
      expect(find.text('Pick at least one day.'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('rule-day-6')));
      await tester.tap(find.byKey(const ValueKey('rule-day-6')));
      await tester.tap(find.byKey(const ValueKey('rule-day-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rule-save')));
      await tester.pumpAndSettle();

      expect(rules(), hasLength(1));
      final r = rules().single;
      expect(r.kind, RuleKind.surcharge);
      expect(r.name, 'Weekend');
      expect(r.amount, 10);
      expect(r.target.vehicleTypes, {'premium'});
      expect(r.schedule.days, {6, 7});
      expect(find.textContaining('Premium'), findsWidgets, reason: 'the row names the vehicle type');

      // Paused, then removed.
      await tester.tap(find.descendant(of: find.byKey(ValueKey('region-rule-${r.id}')), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(rules().single.enabled, isFalse);
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(rules(), isEmpty);
    });
  }
}
