// Place fees (migration 0324) on screen, light and dark: the admin's fee
// editor and settings form, and the rider's fee lines on the fare, in the
// fare details and on the vehicle card.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/place_fees_tab.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/place_fees.dart';
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/features/ride/confirm_parts.dart';
import 'package:get_ride/src/features/ride/place_fee_parts.dart';

Widget _app(Brightness b, Widget child) => MaterialApp(
  theme: appTheme(b),
  home: Scaffold(body: child),
);

String rm(double v) => 'RM ${v.toStringAsFixed(2)}';

const _rows = <PlaceFeeRow>[
  (label: 'KLIA kerbside fee (pickup)', amount: 'RM 5.00', note: 'For the kerbside lane'),
  (label: 'Mall entry fee (drop-off)', amount: 'RM 2.00', note: null),
];

void main() {
  for (final b in Brightness.values) {
    group('${b.name} mode', () {
      setUp(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.physicalSize = const Size(900, 2600);
        binding.platformDispatcher.views.first.devicePixelRatio = 1;
      });
      tearDown(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.resetPhysicalSize();
        binding.platformDispatcher.views.first.resetDevicePixelRatio();
      });

      testWidgets('admin fee editor: every field, checked, saved', (tester) async {
        PlaceFee? saved;
        await tester.pumpWidget(_app(
          b,
          PlaceFeeEditor(
            fee: const PlaceFee(areaId: 'a1', amount: 5),
            services: const ['Ride', 'Comfort', 'Premium'],
            onSave: (f) => saved = f,
          ),
        ));
        expect(find.text('Add fee'), findsOneWidget);
        // No name: refused, and why.
        await tester.tap(find.byKey(const ValueKey('place-fee-save')));
        await tester.pump();
        expect(find.byKey(const ValueKey('place-fee-error')), findsOneWidget);
        expect(saved, isNull);

        await tester.enterText(find.byKey(const ValueKey('place-fee-name')), 'KLIA kerbside fee');
        await tester.enterText(find.byKey(const ValueKey('place-fee-note')), 'For the kerbside lane');
        await tester.tap(find.byKey(const ValueKey('place-fee-end-each')));
        await tester.pump();
        await tester.tap(find.text('% of fare'));
        await tester.pump();
        await tester.enterText(find.byKey(const ValueKey('place-fee-amount')), '10');
        await tester.enterText(find.byKey(const ValueKey('place-fee-min')), '3');
        await tester.enterText(find.byKey(const ValueKey('place-fee-max')), '8');
        await tester.tap(find.byKey(const ValueKey('place-fee-service-Comfort')));
        await tester.pump();
        expect(find.text('Only: Comfort'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('place-fee-day-0')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('place-fee-goes-driver')));
        await tester.tap(find.byKey(const ValueKey('place-fee-goes-driver')));
        await tester.pump();
        expect(find.textContaining('commission base'), findsOneWidget);
        await tester.ensureVisible(find.byType(Switch).first);
        await tester.tap(find.byType(Switch).first);
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('place-fee-save')));
        await tester.tap(find.byKey(const ValueKey('place-fee-save')));
        await tester.pump();
        expect(find.byKey(const ValueKey('place-fee-error')), findsNothing);
        final f = saved!;
        expect(f.name, 'KLIA kerbside fee');
        expect(f.riderNote, 'For the kerbside lane');
        expect(f.appliesTo, PlaceFeeEnd.each);
        expect(f.percent, isTrue);
        expect((f.amount, f.minAmount, f.maxAmount), (10.0, 3.0, 8.0));
        expect(f.services, ['Comfort']);
        expect(f.days, [1, 2, 3, 4, 5, 6]);
        expect(f.goesTo, PlaceFeeGoesTo.driver);
        expect(f.countStops, isTrue);
        expect(f.toRow()['area_id'], 'a1');
        expect(tester.takeException(), isNull);
      });

      testWidgets('admin fee editor: a least over the most is refused', (tester) async {
        PlaceFee? saved;
        await tester.pumpWidget(_app(
          b,
          PlaceFeeEditor(
            fee: const PlaceFee(
              id: 'f1',
              areaId: 'a1',
              name: 'Fee',
              amount: 10,
              amountKind: PlaceFeeAmountKind.percent,
            ),
            onSave: (f) => saved = f,
            onDelete: () {},
          ),
        ));
        expect(find.text('Edit fee'), findsOneWidget);
        expect(find.byKey(const ValueKey('place-fee-delete')), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('place-fee-min')), '9');
        await tester.enterText(find.byKey(const ValueKey('place-fee-max')), '2');
        await tester.ensureVisible(find.byKey(const ValueKey('place-fee-save')));
        await tester.tap(find.byKey(const ValueKey('place-fee-save')));
        await tester.pump();
        expect(find.text("The least can't be more than the most."), findsOneWidget);
        expect(saved, isNull);
      });

      testWidgets('admin settings: every value saved', (tester) async {
        PlaceFeeSettings? saved;
        await tester.pumpWidget(_app(
          b,
          PlaceFeeSettingsForm(settings: PlaceFeeSettings.defaults, onSave: (s) => saved = s),
        ));
        await tester.tap(find.byType(Switch).first);
        await tester.pump();
        await tester.enterText(find.byKey(const ValueKey('place-fee-zone')), 'Asia/Singapore');
        await tester.enterText(find.byKey(const ValueKey('place-fee-badge-text')), 'with fee');
        await tester.enterText(find.byKey(const ValueKey('place-fee-hint-text')), '{name}: {amount}');
        await tester.enterText(find.byKey(const ValueKey('place-fee-cap')), '25');
        await tester.ensureVisible(find.byKey(const ValueKey('place-fee-settings-save')));
        await tester.tap(find.byKey(const ValueKey('place-fee-settings-save')));
        await tester.pump();
        expect(saved?.toJson(), {
          'lockScheduled': false,
          'timeZone': 'Asia/Singapore',
          'percentOf': 'fare',
          'showMapLabel': true,
          'showAddressHint': true,
          'showCardBadge': true,
          'showOutline': true,
          'badgeText': 'with fee',
          'addressHintText': '{name}: {amount}',
          'maxTotal': 25.0,
        });
      });

      testWidgets('confirm step: one line per fee, above the taxes and total', (tester) async {
        await tester.pumpWidget(_app(
          b,
          ConfirmFareSection(
            recommended: 30,
            adjust: 0,
            money: rm,
            bidding: false,
            onAdjust: (_) {},
            placeFees: _rows,
            tax: '+ SST 6%: RM 2.22\nTotal: RM 39.22',
          ),
        ));
        expect(find.text('+ KLIA kerbside fee (pickup): RM 5.00'), findsOneWidget);
        expect(find.text('+ Mall entry fee (drop-off): RM 2.00'), findsOneWidget);
        expect(find.text('For the kerbside lane'), findsNothing, reason: 'notes are in the fare details');
        final fee = tester.getTopLeft(find.byKey(const ValueKey('place-fee-line-1'))).dy;
        final tax = tester.getTopLeft(find.byKey(const ValueKey('fare-tax'))).dy;
        expect(fee, lessThan(tax));
        final style = tester.widget<Text>(find.byKey(const ValueKey('place-fee-line-0'))).style;
        expect(style?.color, appTheme(b).colorScheme.onSurfaceVariant);
        expect(tester.takeException(), isNull);
      });

      testWidgets('fare details: each fee with its note', (tester) async {
        await tester.pumpWidget(_app(
          b,
          const FareInfoSheet(service: RideService('Comfort', '', 1, 4), rates: [], placeFees: _rows),
        ));
        expect(find.text('+ KLIA kerbside fee (pickup): RM 5.00'), findsOneWidget);
        expect(find.text('For the kerbside lane'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('vehicle card: the badge under a price with place fees', (tester) async {
        await tester.pumpWidget(_app(
          b,
          ConfirmServiceCard(
            service: const RideService('Comfort', '', 1, 4),
            price: 'RM 35.00',
            selected: false,
            onTap: () {},
            badge: 'incl. place fee',
          ),
        ));
        expect(find.byKey(const ValueKey('place-fee-badge-Comfort')), findsOneWidget);
        expect(find.text('incl. place fee'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('map label', (tester) async {
        await tester.pumpWidget(_app(b, const Center(child: PlaceFeeMapLabel(text: 'KLIA · RM 5.00'))));
        expect(find.text('KLIA · RM 5.00'), findsOneWidget);
      });
    });
  }
}
