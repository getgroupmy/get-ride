import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/driver_permit.dart';
import 'package:get_ride/src/features/partner/driver_permit_screen.dart';

final _required = [
  (id: 'doc-licence', values: <String, dynamic>{'name': 'Driving licence'}),
  (id: 'doc-permit', values: <String, dynamic>{'name': 'Taxi permit', 'isTaxiPermit': true}),
];

Map<String, dynamic> upload(String docId, {Map<String, dynamic>? taxiPermit, String status = 'Approved'}) => {
  'id': 'u-$docId',
  'doc_id': docId,
  'doc_name': docId == 'doc-permit' ? 'Taxi permit' : 'Driving licence',
  'status': status,
  'file_url': 'https://x/$docId.jpg',
  'document_number': 'DOC-1',
  'expiry_date': '2027-01-31',
  'ai_verification': {
    'extracted': {'documentNumber': 'AI-1', 'taxiPermit': ?taxiPermit},
  },
};

const _tp = {
  'name': 'ali bin abu',
  'idNumber': '900101-14-5678',
  'licenceReferenceNumber': 'LPKP-778',
  'vehicleNumber': 'wxy 1234',
  'companyName': 'Teksi Maju',
  'validityFrom': '2025-02-01',
  'validityTo': '2026-10-20',
  'photoUrl': 'https://x/face.jpg',
};

void main() {
  group('picking the permit upload', () {
    test('the tagged required document wins', () {
      final docs = [upload('doc-licence', taxiPermit: _tp), upload('doc-permit')];
      expect(pickPermitDocument(_required, docs)!['doc_id'], 'doc-permit');
    });

    test('else an upload the AI read as a permit; never an unrelated one', () {
      expect(pickPermitDocument(const [], [upload('x'), upload('y', taxiPermit: _tp)])!['doc_id'], 'y');
      expect(pickPermitDocument(const [], [upload('x')]), isNull);
    });
  });

  test('fields come from the permit, then the row, then the partner and profile', () {
    final p = resolveDriverPermit(
      profile: {'name': 'Profile Name', 'ic': '900101145678', 'avatar_url': 'https://x/me.jpg'},
      partner: {'name': 'Partner Name', 'address': 'Jalan 1'},
      document: upload('doc-permit', taxiPermit: _tp),
    );
    expect(p.name, 'ALI BIN ABU');
    expect(p.permitNumber, 'LPKP-778');
    expect(p.vehiclePlate, 'WXY 1234');
    expect(p.company, 'TEKSI MAJU');
    expect(p.expiryDate, DateTime(2026, 10, 20));
    expect(p.photoUrl, 'https://x/face.jpg');
    expect(p.address, 'Jalan 1');
    expect(p.hasDocument, isTrue);

    final bare = resolveDriverPermit(profile: {'name': 'Aina', 'ic': '1'}, partner: const {});
    expect(bare.name, 'AINA');
    expect(bare.hasDocument, isFalse);
    expect(bare.photoUrl, isNull, reason: 'no stock portrait of a stranger');
    expect(bare.company, 'TEKSI');
  });

  group('start checks', () {
    final today = DateTime(2026, 10, 5);
    DriverPermit permit({String? ic, String? to}) => resolveDriverPermit(
      profile: {'ic': ic ?? '900101145678'},
      document: upload('doc-permit', taxiPermit: {..._tp, 'validityTo': ?to}),
    );

    test('IC compared ignoring punctuation and case', () {
      expect(permitStartBlock(permit(), today: today), isNull);
      expect(permitStartBlock(permit(ic: '800101-01-0000'), today: today), PermitBlock.icMismatch);
    });

    test('expiry and days left', () {
      expect(daysToExpiry(permit(), today), 15);
      expect(permitStartBlock(permit(to: '2026-10-04'), today: today), PermitBlock.expired);
      expect(permitStartBlock(permit(to: '2026-10-05'), today: today), isNull);
    });

    test('vehicle must match the permit when both are known', () {
      expect(permitStartBlock(permit(), today: today, vehiclePlate: 'WXY1234'), isNull);
      expect(permitStartBlock(permit(), today: today, vehiclePlate: 'ABC 1'), PermitBlock.plateMismatch);
      expect(permitStartBlock(permit(), today: today), isNull);
      expect(permitBlockMessage(PermitBlock.plateMismatch, permit(), vehiclePlate: 'ABC 1'), contains('ABC 1'));
    });
  });

  testWidgets('the card shows the permit, its expiry and a blocked meter', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = resolveDriverPermit(
      profile: {'ic': '900101145678'},
      document: upload('doc-permit', taxiPermit: {..._tp, 'photoUrl': null}, status: 'Pending Review'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driverPermitProvider.overrideWith((ref) async => p),
          currentPlateProvider.overrideWith((ref) async => 'ABC 1'),
        ],
        child: MaterialApp(home: DriverPermitScreen(today: DateTime(2026, 10, 5))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ALI BIN ABU'), findsOneWidget);
    expect(find.text('TAXI DRIVER PERMIT · TEKSI MAJU'), findsOneWidget);
    expect(find.text('Review: Pending Review'), findsOneWidget);
    expect(find.text('Expires in 15 days'), findsOneWidget);
    expect(find.textContaining('is not the one on your permit'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('permit-open-meter')));
    await tester.pumpAndSettle();
    expect(find.text('Vehicle mismatch'), findsOneWidget);
  });
}
