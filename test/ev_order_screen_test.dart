import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/ev_order_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ev/ev_order_screen.dart';
import 'package:get_ride/src/providers.dart';

/// An in-memory `ev_orders`, with the production catalogue.
class _FakeRepo implements EvOrderRepository {
  _FakeRepo({this.stored = const []});
  final List<EvOrder> stored;
  final orders = <String, Map<String, dynamic>>{};
  String? active;

  @override
  Future<EvCatalog> catalog() async => EvCatalog(
        vehicles: [
          (
            id: 'jy',
            values: <String, dynamic>{
              'make': 'JUNEYAO',
              'model': 'JY AIR',
              'price': 75000,
              'taxes': jsonEncode([
                {'name': 'SST', 'amount': 7500, 'enabled': true},
              ]),
              'exteriorColors': jsonEncode([
                {'id': 'e1', 'name': 'Pearl White', 'enabled': true},
                {'id': 'e2', 'name': 'Sky Blue', 'enabled': true},
              ]),
              'interiorColors': jsonEncode([
                {'id': 'i1', 'name': 'Charcoal', 'enabled': true},
              ]),
              'accessories': jsonEncode([
                {'id': 'a1', 'name': 'Wireless Charger', 'price': 450, 'enabled': true},
              ]),
            },
          ),
        ],
        advisors: [
          (id: 'da1', values: <String, dynamic>{'name': 'Siti', 'daNumber': 'DA-0001', 'dealership': 'TEKSI KL'}),
        ],
        financeOptions: [
          (id: 'cash', values: <String, dynamic>{'name': 'Full Cash', 'type': 'Cash', 'paymentMode': 'Full Balance'}),
          (id: 'hp', values: <String, dynamic>{'name': 'HP 60m', 'type': 'Hire Purchase'}),
        ],
        fees: [
          (id: 'f', values: <String, dynamic>{'country': 'Malaysia', 'currency': 'RM', 'amount': 3000, 'isDefault': true}),
        ],
        checklist: const ['Keys handed over', 'Charging cable'],
      );

  @override
  Future<List<EvOrder>> myOrders() async => [
        ...stored,
        for (final e in orders.entries) (id: e.key, values: e.value, createdAt: DateTime(2026)),
      ];

  @override
  Future<EvOrder?> order(String id) async {
    final v = orders[id] ?? stored.where((o) => o.id == id).firstOrNull?.values;
    return v == null ? null : (id: id, values: v, createdAt: DateTime(2026));
  }

  @override
  Future<String> create(Map<String, dynamic> values) async {
    orders['o1'] = {...values};
    active = 'o1';
    return 'o1';
  }

  @override
  Future<Map<String, dynamic>> patch(String id, Map<String, dynamic> patch) async {
    final base = orders[id] ?? {...?stored.where((o) => o.id == id).firstOrNull?.values};
    return orders[id] = {...base, ...patch};
  }

  @override
  Future<String> uploadIdImage(String orderId, Uint8List bytes, String ext) async => 'https://x/id.$ext';

  @override
  Future<String?> activeOrderId() async => active;

  @override
  Future<void> rememberActive(String? id) async => active = id;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<_FakeRepo> _pump(WidgetTester tester, {_FakeRepo? repo}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final r = repo ?? _FakeRepo();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      evOrderRepositoryProvider.overrideWithValue(r),
      profileProvider.overrideWith((_) async => Profile({'id': 'u1', 'name': 'Aina', 'phone': '+60123'})),
    ],
    child: const MaterialApp(home: EvOrderScreen()),
  ));
  await tester.pumpAndSettle();
  return r;
}

Future<void> _next(WidgetTester tester) async {
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a custom build is ordered, set up and scheduled without anything being charged', (tester) async {
    final repo = await _pump(tester);
    expect(find.text('Step 1 of 9'), findsOneWidget);
    final next = find.widgetWithText(FilledButton, 'Continue');
    expect(tester.widget<FilledButton>(next).onPressed, isNull, reason: 'pick a model first');

    await tester.tap(find.text('JUNEYAO JY AIR'));
    await tester.pump();
    expect(find.text('From RM 75,000 · tax RM 7,500'), findsOneWidget);
    await _next(tester);

    // Specification: the first colours are preselected; add an accessory.
    await tester.tap(find.text('Sky Blue'));
    await tester.tap(find.text('Wireless Charger'));
    await tester.pump();
    expect(find.text('RM 82,950'), findsOneWidget, reason: '75,000 + 7,500 tax + 450');
    await _next(tester);

    // Order fee: recorded as due.
    expect(find.text('RM 3,000'), findsWidgets);
    expect(find.textContaining('Nothing is charged in the app'), findsOneWidget);
    await tester.tap(find.text('Place order'));
    await tester.pumpAndSettle();
    final placed = repo.orders['o1']!;
    expect(placed['depositPaid'], isFalse);
    expect(placed['depositStatus'], 'due');
    expect(placed['exteriorColor'], 'Sky Blue');
    expect(placed['accessories'], 'Wireless Charger');
    expect(placed['customerName'], 'Aina');
    expect(repo.active, 'o1');
    expect(find.text('Step 4 of 9'), findsOneWidget);

    // Ownership.
    await tester.tap(find.text('Confirm owner details'));
    // The "order placed" message makes way first.
    await tester.pumpAndSettle();
    expect(find.text('Please fill in the full name, ID number, address.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Full name (as on the ID)'), 'Aina Binti Ali');
    await tester.enterText(find.widgetWithText(TextField, 'ID number'), '900101-14-5678');
    await tester.enterText(find.widgetWithText(TextField, 'Address'), 'Jalan Ampang, KL');
    await tester.tap(find.text('Confirm owner details'));
    await tester.pumpAndSettle();
    expect(repo.orders['o1']!['ownerFullName'], 'Aina Binti Ali');
    await _next(tester);

    // Plate.
    await tester.tap(find.text('No, issue new'));
    await tester.pumpAndSettle();
    expect(repo.orders['o1']!['plateTransfer'], 'no');
    await _next(tester);

    // Financing: cash, with the balance confirmed (not paid).
    await tester.tap(find.text('Cash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full Cash'));
    await tester.pumpAndSettle();
    expect(find.text('Balance to pay: RM 79,950'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(repo.orders['o1']!['cashBalanceConfirmed'], isTrue);
    expect(repo.orders['o1']!['cashBalancePaid'], isNot(true));
    expect(repo.orders['o1']!['balanceDueAmount'], 79950);
    await _next(tester);

    // Advisor: waiting, until a DA code links one.
    expect(find.textContaining('Awaiting assignment'), findsOneWidget);
    expect(tester.widget<FilledButton>(next).onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Their DA code'), 'da-0001');
    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();
    expect(repo.orders['o1']!['advisorName'], 'Siti');
    expect(repo.orders['o1']!['status'], 'assigned');
    await _next(tester);

    // Schedule.
    await tester.tap(find.byType(ChoiceChip).first);
    await tester.pumpAndSettle();
    expect(repo.orders['o1']!['deliveryDate'], isNotEmpty);
    await _next(tester);

    // Delivery: the advisor has not submitted the checklist yet.
    expect(find.text('Keys handed over'), findsOneWidget);
    expect(find.textContaining('Still to pay TEKSI: Order fee RM 3,000, Cash balance RM 79,950'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Accept delivery')).onPressed, isNull);
  });

  testWidgets('an unfinished order is resumed where it stopped, and a submitted checklist can be accepted',
      (tester) async {
    final repo = _FakeRepo(stored: [
      (
        id: 'old',
        values: <String, dynamic>{
          'vehicle': 'JUNEYAO JY AIR',
          'status': 'ready_for_delivery',
          'depositAmount': 3000,
          'depositPaid': true,
          'deliveryDate': '2026-10-20',
          'checklistSubmitted': true,
          'checklistResults': jsonEncode([
            {'name': 'Keys handed over', 'done': true, 'note': ''},
          ]),
        },
        createdAt: DateTime(2026, 9),
      ),
    ]);
    await _pump(tester, repo: repo);
    expect(find.text('Step 9 of 9'), findsOneWidget);
    expect(find.textContaining('completed the handover checklist'), findsOneWidget);
    await tester.tap(find.text('Accept delivery'));
    await tester.pumpAndSettle();
    expect(repo.orders['old']!['status'], 'delivered');
    expect(repo.orders['old']!['checklistAccepted'], isTrue);
    expect(repo.active, isNull, reason: 'a finished order is no longer resumed');
    expect(find.text('Delivery accepted'), findsWidgets);
  });
}
