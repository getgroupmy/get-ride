import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/sos.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/profile/emergency_contacts_screen.dart';
import 'package:get_ride/src/features/safety/safety_screen.dart';
import 'package:get_ride/src/providers.dart';

void main() {
  group('rules', () {
    test('phones keep digits and a leading plus', () {
      expect(cleanPhone(' +60 12-345 6789 '), '+60123456789');
      expect(cleanPhone('012 345'), '012345');
    });

    test('the message carries the location and ride when known', () {
      final m = sosMessage(lat: 3.139, lng: 101.6869, driver: 'Ali', plate: 'WXY 1234');
      expect(m, startsWith('EMERGENCY: I need help.'));
      expect(m, contains('https://maps.google.com/?q=3.139000,101.686900'));
      expect(m, contains('driver Ali, car WXY 1234'));
      expect(sosMessage(), isNot(contains('maps.google')));
      expect(sosMessage(), isNot(contains('trip')));
    });

    test('sms links put the body after ? on Android and & on iOS', () {
      final android = sosSmsUri(['+60 12', '013-4'], 'help me', ios: false).toString();
      expect(android, 'sms:+6012,0134?body=help%20me');
      final ios = sosSmsUri(['+6012'], 'help', ios: true).toString();
      expect(ios, 'sms:+6012&body=help');
    });
  });

  group('screen', () {
    Future<List<Uri>> pump(WidgetTester tester, List<EmergencyContact> contacts) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 1200);
      addTearDown(tester.view.reset);
      final launched = <Uri>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emergencyContactsProvider.overrideWith((ref) async => contacts),
            currentUserIdProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            home: SafetyScreen(
              launch: (uri) async {
                launched.add(uri);
                return true;
              },
              locate: () async => (lat: 3.1, lng: 101.7),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return launched;
    }

    testWidgets('with no contacts SOS offers to add one', (tester) async {
      final launched = await pump(tester, []);
      expect(find.text('No contacts yet. Add a trusted contact.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('safety-sos')));
      // The SOS key spins behind the dialog until it is answered.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('No emergency contacts'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(launched, isEmpty);
    });

    testWidgets('SOS opens Messages to every contact with the location', (tester) async {
      final launched = await pump(tester, [
        EmergencyContact(id: '1', name: 'Mum', phone: '+60 12-111'),
        EmergencyContact(id: '2', name: 'Sam', phone: '013 222'),
      ]);
      expect(find.text('2 contacts get an SMS with your location when you send an SOS.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('safety-sos')));
      // The SOS key spins behind the dialog until it is answered.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('(Mum, Sam)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sos-confirm')));
      await tester.pumpAndSettle();
      final uri = launched.single.toString();
      expect(uri, startsWith('sms:+6012111,013222'));
      expect(Uri.decodeComponent(uri), contains('maps.google.com/?q=3.100000,101.700000'));
    });
  });
}
