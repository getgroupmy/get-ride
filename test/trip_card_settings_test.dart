// Admin → Display Settings → Trip card (trip_card_settings_card.dart) and
// its preview (widgets/trip_card_preview.dart), in light and dark: the
// switches and the done minutes save, a read-only admin can't change them,
// and the preview draws App Page Settings' trip card colours.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/trip_card_settings_card.dart';
import 'package:get_ride/src/core/page_inventory.g.dart';
import 'package:get_ride/src/core/page_styles.dart';
import 'package:get_ride/src/core/trip_card.dart';
import 'package:get_ride/src/data/trip_card_controller.dart' show tripCardColorsOf;
import 'package:get_ride/src/widgets/page_style_host.dart';

Widget _app(Widget child, {Brightness b = Brightness.light, PageStyles styles = PageStyles.none}) => MaterialApp(
  theme: ThemeData(brightness: b),
  home: PageStyleScope(
    styles: styles,
    child: Scaffold(body: ListView(children: [child])),
  ),
);

void main() {
  for (final b in Brightness.values) {
    group('in ${b.name} mode', () {
      testWidgets('each switch and the done minutes save', (tester) async {
        tester.view.physicalSize = const Size(360, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        TripCardSettings? saved;
        var value = const TripCardSettings();
        await tester.pumpWidget(
          _app(
            StatefulBuilder(
              builder: (_, set) => TripCardSettingsCard(
                value: value,
                onChanged: (v) => set(() => value = saved = v),
              ),
            ),
            b: b,
          ),
        );
        expect(find.text('Ride'), findsOneWidget);
        expect(find.text('Courier'), findsOneWidget);
        expect(find.text('Freight'), findsOneWidget);
        expect(find.text('Driver card'), findsOneWidget);
        expect(find.text('5 min'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('trip-card-courier')));
        await tester.pumpAndSettle();
        expect(saved, const TripCardSettings(courier: false));

        await tester.tap(find.byKey(const ValueKey('trip-card-driver')));
        await tester.pumpAndSettle();
        expect(saved!.driver, isFalse);

        await tester.tap(find.byTooltip('More minutes'));
        await tester.pumpAndSettle();
        expect(saved!.doneMinutes, 6);
        for (var i = 0; i < 6; i++) {
          await tester.tap(find.byTooltip('Fewer minutes'));
          await tester.pumpAndSettle();
        }
        expect(saved!.doneMinutes, 0);
        expect(find.text('The card clears as soon as the trip ends.'), findsOneWidget);
        saved = null;
        await tester.tap(find.byTooltip('Fewer minutes'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(saved, isNull, reason: 'no fewer than 0');
        expect(tester.takeException(), isNull);
      });

      testWidgets('a read-only admin sees the values but cannot change them', (tester) async {
        await tester.pumpWidget(
          _app(const TripCardSettingsCard(value: TripCardSettings(freight: false, doneMinutes: 9), onChanged: null), b: b),
        );
        final freight = tester.widget<SwitchListTile>(
          find.descendant(of: find.byKey(const ValueKey('trip-card-freight')), matching: find.byType(SwitchListTile)),
        );
        expect(freight.value, isFalse);
        expect(freight.onChanged, isNull);
        expect(find.text('9 min'), findsOneWidget);
      });

      testWidgets("the preview shows the card in App Page Settings' colours", (tester) async {
        tester.view.physicalSize = const Size(360, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final styles = PageStyles({
          tripCardSurface: {'cardBackground': '#FF102030', 'cardBackground.dark': '#FF203040'},
        });
        await tester.pumpWidget(
          _app(const TripCardSettingsCard(value: TripCardSettings(), onChanged: null), b: b, styles: styles),
        );
        await tester.ensureVisible(find.byKey(const ValueKey('trip-card-preview')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('trip-card-preview')));
        await tester.pumpAndSettle();
        expect(find.text('Trip card preview'), findsOneWidget);
        expect(find.text('Ali is 6 min away', findRichText: true), findsOneWidget);
        expect(find.text('WXY 4821'), findsOneWidget);
        expect(find.text('You will arrive at 4:05 PM', findRichText: true), findsOneWidget);
        final box = tester.widget<Container>(find.byKey(const ValueKey('trip-card-toPickup')));
        final colour = (box.decoration! as BoxDecoration).color;
        expect(colour, b == Brightness.dark ? const Color(0xFF203040) : const Color(0xFF102030));
        expect(tester.takeException(), isNull);
      });
    });
  }

  test('the trip card is in App Page Settings, with its four colours', () {
    final entry = pageInventory.firstWhere((s) => s.id == tripCardSurface);
    expect(entry.kind, SurfaceKind.sheet);
    expect(entry.title, 'Trip card · Preview');
    final keys = [for (final t in elementTokens[tripCardSurface]!) t.key];
    expect(keys, ['cardBackground', 'cardAccent', 'cardText', 'cardMuted']);
  });

  test("the colours sent to the phone: the ride flow's blues on black by default, the admin's when set", () {
    final light = tripCardColorsOf(PageStyles.none, Brightness.light);
    final dark = tripCardColorsOf(PageStyles.none, Brightness.dark);
    expect(light.accent, 0xFF0C7AB8);
    expect(dark.accent, 0xFF2DABE2);
    expect(light.background, 0xFF000000);
    expect(dark.background, 0xFF000000);
    expect(dark.text, 0xFFFFFFFF);
    final set = tripCardColorsOf(
      PageStyles({
        tripCardSurface: {'cardAccent': '#FFFF8800'},
      }),
      Brightness.light,
    );
    expect(set.accent, 0xFFFF8800);
  });
}
