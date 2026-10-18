// Tester findings, round 3: sheets and pages that ran off a phone on its
// side (iPhone 15, 852x393 with its notch and home bar), on a small phone
// at large text (iPhone SE, 375x667 at 1.3) and under the keyboard, and the
// iOS, accessibility and contrast fixes that came with them.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/data/device_access.dart' show deviceBlockedProvider;
import 'package:get_ride/src/features/auth/otp_screen.dart';
import 'package:get_ride/src/features/auth/phone_screen.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/models.dart' show EmergencyContact;
import 'package:get_ride/src/features/my_ride/my_ride_screen.dart' show showAddFavouriteSheet;
import 'package:get_ride/src/features/partner/partner_screen.dart' show floatingRequestsBeside;
import 'package:get_ride/src/features/profile/emergency_contacts_screen.dart';
import 'package:get_ride/src/providers.dart' show accountRepositoryProvider;
import 'package:get_ride/src/features/ride/book_for_sheet.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart';
import 'package:get_ride/src/features/ride/location_share_button.dart';
import 'package:get_ride/src/features/ride/pickup_time_sheet.dart';
import 'package:get_ride/src/features/ride/searching_parts.dart';
import 'package:get_ride/src/widgets/common.dart' show EmptyState, contrastRatio;
import 'package:get_ride/src/features/safety/ride_sos.dart' show RideSosFab;
import 'package:get_ride/src/widgets/map_sheet_layout.dart';
import 'package:get_ride/src/widgets/search_select.dart';

/// A phone the testers used.
class Phone {
  const Phone(this.name, this.size, {this.padding = EdgeInsets.zero, this.scale = 1.0});
  final String name;
  final Size size;
  final EdgeInsets padding;
  final double scale;

  @override
  String toString() => name;
}

const iphone15 = Phone('iPhone 15', Size(393, 852), padding: EdgeInsets.only(top: 59, bottom: 34));
const iphone15Side = Phone(
  'iPhone 15 landscape',
  Size(852, 393),
  padding: EdgeInsets.only(left: 59, right: 59, bottom: 21),
);
const iphoneSe = Phone('iPhone SE @1.3', Size(375, 667), padding: EdgeInsets.only(top: 20), scale: 1.3);

/// Sets the screen up as [phone], with a keyboard [keyboard] high.
Future<void> onPhone(WidgetTester tester, Phone phone, {double keyboard = 0}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = phone.size;
  final p = phone.padding;
  tester.view.padding = FakeViewPadding(left: p.left, top: p.top, right: p.right, bottom: p.bottom);
  tester.view.viewPadding = FakeViewPadding(left: p.left, top: p.top, right: p.right, bottom: p.bottom);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
}

/// A page to open sheets from, at [phone]'s text size; [ready] gets its context.
Widget sheetHost(Phone phone, Brightness b, void Function(BuildContext) ready, {List overrides = const []}) =>
    ProviderScope(
      overrides: [...overrides],
      child: MaterialApp(
        theme: ThemeData(brightness: b),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(phone.scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ready(c);
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

/// Whether [f] is wholly on the screen, clear of the keyboard.
void expectOnScreen(WidgetTester tester, Finder f, {double keyboard = 0}) {
  final r = tester.getRect(f);
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  expect(r.top, greaterThanOrEqualTo(0));
  expect(r.bottom, lessThanOrEqualTo(screen.height - keyboard + 0.01));
}

void main() {
  _sheets();
  _keyboardPages();
  _mapSheets();
}

/// A ride sheet as the trip screens build it: a title, the driver card
/// whose last row must show at rest, more below, and a pinned footer.
Widget _rideSheet(Phone phone, Brightness b, {bool sos = false}) => MaterialApp(
  theme: ThemeData(brightness: b),
  builder: (c, child) => MediaQuery(
    data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(phone.scale)),
    child: child!,
  ),
  home: Scaffold(
    appBar: AppBar(title: const Text('Your ride')),
    body: MapSheetLayout(
      map: Stack(children: [
        const Positioned.fill(child: ColoredBox(color: Colors.blueGrey)),
        if (sos) Positioned.fill(child: RideSosFab(onPressed: () {})),
      ]),
      sheet: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Driver on the way', key: ValueKey('sheet-title'), style: TextStyle(fontSize: 24)),
            const SizedBox(height: 16),
            const Card(child: ListTile(title: Text('Ahmad'), subtitle: Text('Proton Saga · WXY 1234'))),
            const Card(child: ListTile(title: Text('Trip code'), trailing: Text('4821'))),
            MapSheetRestLine(
              child: OverflowBar(
                key: const ValueKey('call-row'),
                children: [
                  TextButton(onPressed: () {}, child: const Text('Call')),
                  TextButton(onPressed: () {}, child: const Text('Message')),
                ],
              ),
            ),
            for (var i = 0; i < 6; i++) ListTile(title: Text('Detail $i')),
          ],
        ),
      ),
      footer: Material(
        key: const ValueKey('ride-footer'),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(onPressed: () {}, child: const Text('Cancel ride')),
          ),
        ),
      ),
    ),
  ),
);

void _mapSheets() {
  for (final b in Brightness.values) {
    for (final phone in const [iphone15, iphone15Side, iphoneSe]) {
      final at = '$phone ${b.name}';

      testWidgets('ride sheet at rest shows Call and Message above the footer ($at)', (tester) async {
        await onPhone(tester, phone);
        await tester.pumpWidget(_rideSheet(phone, b));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // Fully down by hand, it still rests no lower than that row (or,
        // where the row can't fit above the footer, all the way up, the
        // title and driver in view rather than a handle and a clipped title).
        await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, 600));
        await tester.pumpAndSettle();
        final row = tester.getRect(find.byKey(const ValueKey('call-row')));
        final footer = tester.getRect(find.byKey(const ValueKey('ride-footer')));
        final body = tester.getRect(find.byType(MapSheetLayout));
        final handle = tester.getRect(find.byKey(const ValueKey('map-sheet-handle')));
        final atMax = handle.top <= body.top + body.height * (1 - 0.92) + 10;
        if (!atMax) expect(row.bottom, lessThanOrEqualTo(footer.top + 0.5), reason: 'above "Cancel ride"');
        final title = tester.getRect(find.byKey(const ValueKey('sheet-title')));
        expect(title.bottom, lessThanOrEqualTo(footer.top), reason: 'the title whole above the footer');
        // Clear of the notch on its side.
        expect(title.left, greaterThanOrEqualTo(phone.padding.left));
      });
    }

    testWidgets('SOS and the map buttons stand clear of the notch (${b.name})', (tester) async {
      await onPhone(tester, iphone15Side);
      await tester.pumpWidget(_rideSheet(iphone15Side, b, sos: true));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const ValueKey('ride-sos'))).left, greaterThanOrEqualTo(59));
    });
  }
}

void _keyboardPages() {
  for (final b in Brightness.values) {
    for (final (phone, keyboard) in const [(iphone15Side, 170.0), (iphoneSe, 260.0), (iphone15, 336.0)]) {
      final at = '$phone, keyboard up, ${b.name}';

      testWidgets('sign-in phone: no overflow and Next reachable ($at)', (tester) async {
        await onPhone(tester, phone, keyboard: keyboard);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [deviceBlockedProvider.overrideWith((ref) async => false)],
            child: MaterialApp(
              theme: ThemeData(brightness: b),
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(phone.scale)),
                child: child!,
              ),
              home: const PhoneScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final next = find.byKey(const ValueKey('phone-next'));
        await tester.ensureVisible(next);
        await tester.pumpAndSettle();
        expectOnScreen(tester, next, keyboard: keyboard);
        // The number field is a full tap target.
        expect(tester.getSize(find.byKey(const ValueKey('phone-number'))).height, greaterThanOrEqualTo(48));
      });

      testWidgets('code page: no overflow and Verify reachable ($at)', (tester) async {
        await onPhone(tester, phone, keyboard: keyboard);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: ThemeData(brightness: b),
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(phone.scale)),
                child: child!,
              ),
              home: const OtpScreen(phone: '+60123456789', next: 'pin'),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final verify = find.byKey(const ValueKey('otp-verify'));
        await tester.ensureVisible(verify);
        await tester.pump(const Duration(milliseconds: 500));
        expectOnScreen(tester, verify, keyboard: keyboard);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('Add a driver: Add reachable over the keyboard ($at)', (tester) async {
        await onPhone(tester, phone, keyboard: keyboard);
        late BuildContext ctx;
        await tester.pumpWidget(sheetHost(phone, b, (c) => ctx = c));
        showAddFavouriteSheet(ctx);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final add = find.byKey(const ValueKey('favourite-code-add'));
        await tester.ensureVisible(add);
        await tester.pumpAndSettle();
        expectOnScreen(tester, add, keyboard: keyboard);
      });

      testWidgets('Add contact: Save reachable over the keyboard ($at)', (tester) async {
        await onPhone(tester, phone, keyboard: keyboard);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              accountRepositoryProvider.overrideWithValue(_NoContacts()),
              contactPickerProvider.overrideWithValue(null),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: b),
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(phone.scale)),
                child: child!,
              ),
              home: const EmergencyContactsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'the list page');
        await tester.tap(find.text('Add contact').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final save = find.byKey(const ValueKey('contact-save'));
        expectOnScreen(tester, save, keyboard: keyboard);
        // Short over the keyboard: the fields, not the title.
        expect(find.text('Add contact'), phone == iphone15Side ? findsOneWidget : findsNWidgets(2));
      });
    }
  }
}

class _NoContacts implements AccountRepository {
  @override
  Future<List<EmergencyContact>> emergencyContacts() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _sheets() {
  const phones = [iphone15, iphone15Side, iphoneSe];
  for (final b in Brightness.values) {
    for (final phone in phones) {
      final at = '$phone ${b.name}';

      testWidgets('Payment method: every method reachable ($at)', (tester) async {
        await onPhone(tester, phone);
        late BuildContext ctx;
        await tester.pumpWidget(sheetHost(phone, b, (c) => ctx = c));
        const many = [
          ...builtInPayments,
          PaymentChoice('Card', 'Card', PaymentKind.card),
          PaymentChoice('Bank', 'Online banking', PaymentKind.other),
          PaymentChoice('Ewallet', 'E-wallet', PaymentKind.wallet),
        ];
        final r = showPaymentSheet(ctx, 'Cash', payments: many);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final last = find.byKey(const ValueKey('payment-Ewallet'));
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expectOnScreen(tester, last);
        await tester.tap(last);
        await tester.pumpAndSettle();
        expect(await r, 'Ewallet');
      });

      testWidgets('Choose date and time: Confirm time on screen ($at)', (tester) async {
        await onPhone(tester, phone);
        late BuildContext ctx;
        await tester.pumpWidget(sheetHost(phone, b, (c) => ctx = c));
        final r = showPickupTimeSheet(
          ctx,
          const ScheduledRidesConfig(enabled: true, minLeadMinutes: 30, maxDaysAhead: 3, lateCancelFee: 5),
          note: 'A RM 2.00 scheduling fee applies.',
          clock: () => DateTime(2026, 10, 15, 16, 52),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final confirm = find.byKey(const ValueKey('pickup-confirm'));
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        expectOnScreen(tester, confirm);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(await r, isNotNull);
      });

      testWidgets("Who's riding: Done reachable over the keyboard ($at)", (tester) async {
        final keyboard = phone == iphone15Side ? 170.0 : 260.0;
        await onPhone(tester, phone, keyboard: keyboard);
        late BuildContext ctx;
        await tester.pumpWidget(
          sheetHost(phone, b, (c) => ctx = c, overrides: [contactPickerProvider.overrideWithValue(null)]),
        );
        final r = showBookForSheet(ctx, name: 'Aminah', phone: '0123456789');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final done = find.byKey(const ValueKey('book-for-done'));
        await tester.ensureVisible(done);
        await tester.pumpAndSettle();
        expectOnScreen(tester, done, keyboard: keyboard);
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(await r, isNotNull);
      });

      testWidgets('cancel reasons: Skip and Cancel request reachable ($at)', (tester) async {
        await onPhone(tester, phone);
        late BuildContext ctx;
        await tester.pumpWidget(sheetHost(phone, b, (c) => ctx = c));
        final r = showSearchCancelSheet(ctx);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final skip = find.byKey(const ValueKey('cancel-skip'));
        await tester.ensureVisible(skip);
        await tester.pumpAndSettle();
        expectOnScreen(tester, skip);
        await tester.tap(skip);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final sure = find.byKey(const ValueKey('cancel-confirm'));
        await tester.ensureVisible(sure);
        await tester.pumpAndSettle();
        expectOnScreen(tester, sure);
        await tester.tap(sure);
        await tester.pumpAndSettle();
        expect((await r)?.cancel, isTrue);
      });

      testWidgets('Location sharing: its last choice reachable ($at)', (tester) async {
        await onPhone(tester, phone);
        late BuildContext ctx;
        await tester.pumpWidget(sheetHost(phone, b, (c) => ctx = c));
        final r = showLocationShareSheet(ctx, on: true);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final buttons = find.descendant(
          of: find.byKey(const ValueKey('location-share-sheet')),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        final last = buttons.last;
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expectOnScreen(tester, last);
        await tester.tap(last);
        await tester.pumpAndSettle();
        expect(await r, isNotNull);
      });

      testWidgets('Set entrance: Done and every key on screen ($at)', (tester) async {
        await onPhone(tester, phone);
        late BuildContext ctx;
        await tester.pumpWidget(sheetHost(phone, b, (c) => ctx = c));
        final r = showEntranceSheet(ctx, '');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final k in ['entrance-key-1', 'entrance-key-0', 'entrance-key-back', 'entrance-done']) {
          expectOnScreen(tester, find.byKey(ValueKey(k)));
        }
        await tester.tap(find.byKey(const ValueKey('entrance-key-4')));
        await tester.tap(find.byKey(const ValueKey('entrance-done')));
        await tester.pumpAndSettle();
        expect(await r, '4');
      });
    }

    testWidgets('pickup helper lines read on the sheet (${b.name})', (tester) async {
      await onPhone(tester, iphone15);
      late BuildContext ctx;
      await tester.pumpWidget(sheetHost(iphone15, b, (c) => ctx = c));
      showPickupTimeSheet(
        ctx,
        const ScheduledRidesConfig(enabled: true, minLeadMinutes: 30, maxDaysAhead: 3),
        clock: () => DateTime(2026, 10, 15, 16, 52),
      );
      await tester.pumpAndSettle();
      final t = Theme.of(tester.element(find.byKey(const ValueKey('pickup-time-sheet'))));
      final helper = tester.widget<Text>(find.textContaining('Book your pickup from'));
      expect(contrastRatio(helper.style!.color!, t.colorScheme.surfaceContainerLow), greaterThanOrEqualTo(4.5));
    });

    testWidgets('a searchable list on its side over the keyboard still shows rows (${b.name})', (tester) async {
      await onPhone(tester, iphone15Side, keyboard: 170);
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: b),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: SearchableDropdownFormField<int>(
                  decoration: const InputDecoration(labelText: 'Country'),
                  items: [for (var i = 0; i < 40; i++) DropdownMenuItem(value: i, child: Text('Place $i'))],
                  onChanged: (v) => picked = '$v',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(SearchableDropdownFormField<int>));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final rows = find.byWidgetPredicate((w) => w is ListTile && w.key.toString().contains('search-select-item'));
      final visible = rows.evaluate().where((e) {
        final r = tester.getRect(find.byWidget(e.widget));
        return r.top >= 0 && r.bottom <= 393 - 170;
      });
      expect(visible.length, greaterThanOrEqualTo(2));
      await tester.tap(find.text('Place 1'));
      await tester.pumpAndSettle();
      expect(picked, '1');
    });
  }

  testWidgets('an empty state scrolls rather than overflow in a short space', (tester) async {
    await onPhone(tester, iphone15Side, keyboard: 170);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmptyState(
            icon: Icons.inbox_outlined,
            title: 'No vehicle types',
            message: 'Add a vehicle type like Car, Bike, Truck, or Pick Up.',
            action: FilledButton(onPressed: () {}, child: const Text('Add Vehicle Type')),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Add Vehicle Type'));
    expectOnScreen(tester, find.text('Add Vehicle Type'), keyboard: 170);
  });

  test('on its side the driver\'s floating requests run beside the map buttons', () {
    expect(floatingRequestsBeside(const Size(852, 393)), isTrue);
    expect(floatingRequestsBeside(const Size(393, 852)), isFalse);
    expect(floatingRequestsBeside(const Size(1280, 800)), isFalse);
  });

  test('the time wheels show fewer rows on a short screen', () {
    expect(pickupWheelRows(852), 5);
    expect(pickupWheelRows(667), 5);
    expect(pickupWheelRows(393), 3);
  });
}
