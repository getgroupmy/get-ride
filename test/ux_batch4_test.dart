// Tester findings, round 4: Offer your fare's cents, finger-sized targets on
// the route sheet and the meter, the contrast still short of 4.5:1 (checked
// against what each line actually sits on, with an admin's light secondary
// grey as well as the app's own), the session key dialog, flags on the web,
// and pages on a phone on its side with the keyboard up (iPhone 15,
// 852x393, safe area 59/59/21, keyboard 200).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/catalogue/catalogue_data.dart' show vehicleMakeModelsProvider;
import 'package:get_ride/src/admin/screens/catalogue/make_model_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/models.dart' show Profile, SupportMessage, SupportTicket;
import 'package:get_ride/src/data/photo_picker.dart' show photoCameraAvailableProvider;
import 'package:get_ride/src/features/support/support_chat_screen.dart';
import 'package:get_ride/src/features/support/support_screen.dart' show ticketsProvider;
import 'package:get_ride/src/providers.dart' show accountRepositoryProvider, profileProvider;
import 'package:get_ride/src/widgets/loading_skeleton.dart';
import 'package:get_ride/src/core/dial_countries.dart';
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/core/landscape_stage.dart';
import 'package:get_ride/src/core/ride_confirm.dart' show RideOptions;
import 'package:get_ride/src/data/app_display_repository.dart' show recentPlacesProvider;
import 'package:get_ride/src/data/device_access.dart' show deviceBlockedProvider;
import 'package:get_ride/src/data/geo_service.dart' show Place;
import 'package:get_ride/src/features/auth/otp_screen.dart';
import 'package:get_ride/src/features/auth/phone_screen.dart';
import 'package:get_ride/src/features/auth/welcome_screen.dart';
import 'package:get_ride/src/features/meter/meter_screen.dart' show meterCaption, meterPanel;
import 'package:get_ride/src/features/my_ride/my_ride_screen.dart' show showAddFavouriteSheet;
import 'package:get_ride/src/features/ride/confirm_parts.dart' show showRideOptionsSheet;
import 'package:get_ride/src/features/ride/home_parts.dart' show VehicleTypeBar;
import 'package:get_ride/src/features/ride/offer_fare_screen.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/widgets/common.dart' show contrastRatio, dialogFill, mutedTextColor;
import 'package:get_ride/src/widgets/dial_country_picker.dart';
import 'package:get_ride/src/widgets/map_credit.dart' show MapBrand, mapBrandFill, mapBrandInk;
import 'package:latlong2/latlong.dart' show LatLng;

import 'ux_batch3_test.dart' show expectOnScreen, iphone15, iphone15Side, onPhone, sheetHost;

/// The keyboard the tester had up on its side.
const _keyboard = 200.0;

/// The app's theme, and the same with an admin's light secondary grey (the
/// tester's palette read 2.5:1 on white with it: #9CA3AF by day, #6B7280 by
/// night).
final _themes = <String, ThemeData>{
  for (final b in Brightness.values) ...{
    'app ${b.name}': appTheme(b),
    'admin grey ${b.name}': appTheme(b, colors: {'textSecondary': b == Brightness.light ? '#9CA3AF' : '#6B7280'}),
  },
};

/// [over] laid on [under]: what a translucent fill comes to.
Color _over(Color over, Color under) => Color.alphaBlend(over, under);

/// What [f]'s words are painted on, worked out up the tree: each Material,
/// ColoredBox or decorated box's fill laid over the ones under it, down to
/// the first opaque one; and the opacity of any Opacity on the way, which
/// fades the words into that ground.
({Color ink, Color ground}) _paint(WidgetTester tester, Finder f) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: f, matching: find.byType(RichText), matchRoot: true).first,
  );
  var ink = paragraph.text.style?.color ?? const Color(0xFF000000);
  final fills = <Color>[];
  var opacity = 1.0;
  final theme = Theme.of(tester.element(f));
  tester.element(f).visitAncestorElements((e) {
    final w = e.widget;
    Color? c;
    if (w is Material && w.type != MaterialType.transparency) {
      c = w.color ?? (w.type == MaterialType.canvas ? theme.canvasColor : theme.cardColor);
    } else if (w is ColoredBox) {
      c = w.color;
    } else if (w is DecoratedBox && w.decoration is BoxDecoration) {
      c = (w.decoration as BoxDecoration).color;
    } else if (w is Opacity) {
      opacity *= w.opacity;
    }
    if (c != null && c.a > 0) fills.add(c);
    return !(c != null && c.a >= 1);
  });
  var ground = fills.isNotEmpty && fills.last.a >= 1 ? fills.last : const Color(0xFFFFFFFF);
  for (final c in fills.reversed.skip(fills.isNotEmpty && fills.last.a >= 1 ? 1 : 0)) {
    ground = _over(c, ground);
  }
  if (ink.a < 1) ink = _over(ink, ground);
  if (opacity < 1) ink = Color.lerp(ground, ink, opacity)!;
  return (ink: ink, ground: ground);
}

double _ratio(WidgetTester tester, Finder f) {
  final p = _paint(tester, f);
  return contrastRatio(p.ink, p.ground);
}

Widget _app(ThemeData theme, Widget home, {List overrides = const []}) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(theme: theme, home: home),
);

void main() {
  _offerFare();
  _targets();
  _contrast();
  _webFlags();
  _landscapeKeyboard();
}

// ---- 1. Offer your fare --------------------------------------------------------

Widget _offerPage({required double recommended, int decimals = 2, ValueChanged<OfferFareResult>? onChanged}) =>
    MaterialApp(
      home: OfferFareScreen(
        recommended: recommended,
        current: recommended,
        currencyLabel: 'RM',
        money: (v) => 'RM${v.toStringAsFixed(decimals)}',
        fareDecimals: decimals,
        payment: 'cash',
        autoAccept: false,
        entrance: '',
        pickupName: 'KLCC',
        routeLabel: 'KL Sentral',
        onChanged: onChanged,
      ),
    );

void _offerFare() {
  test('the field holds the fare as the region books it', () {
    expect(offerFareFieldText(68.05, 2), '68.05');
    expect(offerFareFieldText(68.0, 2), '68');
    expect(offerFareFieldText(68.5, 2), '68.50');
    expect(offerFareFieldText(70.05000000001, 2), '70.05', reason: 'a sum with float noise');
    expect(offerFareFieldText(69.0, 0), '69');
  });

  testWidgets('Offer your fare opens on the exact recommended fare: field, note and auto-accept agree', (tester) async {
    OfferFareResult? latest;
    await tester.pumpWidget(_offerPage(recommended: 68.05, onChanged: (r) => latest = r));
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const ValueKey('offer-fare-field')));
    expect(field.controller!.text, '68.05', reason: 'not "68", the cents dropped');
    expect(tester.widget<Text>(find.byKey(const ValueKey('offer-fare-note'))).data, 'Recommended fare: RM68.05');
    expect(find.text('Automatically accept the nearest driver for RM68.05'), findsOneWidget);
    // Left untouched, the page hands back the recommended fare, not 68.
    await tester.tap(find.byKey(const ValueKey('offer-fare-auto-accept')));
    await tester.pump();
    expect(latest!.fare, 68.05);

    // Cents can be typed where the region has them, two at most.
    await tester.enterText(find.byKey(const ValueKey('offer-fare-field')), '70.5');
    await tester.pump();
    expect(find.text('Automatically accept the nearest driver for RM70.50'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('offer-fare-field')), '70.555');
    await tester.pump();
    expect(field.controller!.text, '70.5', reason: 'a third decimal is not taken');
  });

  testWidgets('where fares are whole the field is too', (tester) async {
    await tester.pumpWidget(_offerPage(recommended: 69, decimals: 0));
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const ValueKey('offer-fare-field')));
    expect(field.controller!.text, '69');
    expect(tester.widget<Text>(find.byKey(const ValueKey('offer-fare-note'))).data, 'Recommended fare: RM69');
    expect(find.text('Automatically accept the nearest driver for RM69'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('offer-fare-field')), '70.5');
    await tester.pump();
    expect(field.controller!.text, '69', reason: 'no point where fares are whole');
  });
}

// ---- 2. Touch targets ----------------------------------------------------------

/// Every node a finger can tap, with its size on the screen.
List<(Size, String)> _tapTargets(WidgetTester tester) {
  final out = <(Size, String)>[];
  void walk(SemanticsNode n, Matrix4 m) {
    final mm = n.transform == null ? m : (m.clone()..multiply(n.transform!));
    final d = n.getSemanticsData();
    if (d.hasAction(SemanticsAction.tap) && !d.flagsCollection.isHidden) {
      out.add((MatrixUtils.transformRect(mm, n.rect).size, d.label));
    }
    n.visitChildren((c) {
      walk(c, mm);
      return true;
    });
  }

  walk(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!, Matrix4.identity());
  return out;
}

void _targets() {
  for (final b in Brightness.values) {
    testWidgets('the route sheet (Add a stop): every row and tab is 44 or more (${b.name})', (tester) async {
      await onPhone(tester, iphone15);
      final semantics = tester.ensureSemantics();
      const klcc = Place(name: 'KLCC', address: 'Kuala Lumpur City Centre', point: LatLng(3.1579, 101.7123));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [recentPlacesProvider.overrideWith((ref) async => const [klcc])],
          child: MaterialApp(
            theme: appTheme(b),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showPlaceSearch(context, title: 'Add a stop', from: klcc, current: klcc),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final small = [
        for (final (size, label) in _tapTargets(tester))
          if (size.height < 44 || size.width < 44) '$label ${size.width.round()}x${size.height.round()}',
      ];
      expect(small, isEmpty, reason: 'the search field was 257x24, the tabs 34 high');
      // The field's box keeps its height (58): the field fills it.
      expect(tester.getSize(find.byKey(const ValueKey('place-search-field'))).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(find.byKey(const ValueKey('place-tab-suggested'))).height, 44);
      semantics.dispose();
    });
  }

  test("the meter's SET is 44 on the screen however the console is scaled", () {
    // The console is held on its side: the space it is given is wide.
    for (final size in const [Size(852 - 118 - 80, 393 - 21), Size(1600, 900), Size(500, 300), Size(1024, 700)]) {
      final layout = meterConsoleLayout(size);
      final scale = meterConsoleScale(size, layout);
      final onScreen = meterTargetSize(scale) * scale;
      expect(onScreen, greaterThanOrEqualTo(44 - 1e-9), reason: '$size');
    }
    // As the tester measured it: scaled to 0.886, a 44 layout button was 39.
    expect(44 * 0.886, lessThan(44));
    expect(meterTargetSize(0.886) * 0.886, closeTo(44, 1e-9));
    // Scaled right down, the button stops at twice its size in the layout.
    expect(meterTargetSize(0.2), 88);
  });
}

// ---- 3. Contrast ---------------------------------------------------------------

void _contrast() {
  group('contrast (4.5:1) on what each line sits on', () {
    test('the map credit chip, opaque over dark, light and satellite tiles', () {
      for (final tile in const [Color(0xFF000000), Color(0xFF1B1F23), Color(0xFF7A8B6E), Color(0xFFFFFFFF)]) {
        expect(contrastRatio(mapBrandInk, _over(mapBrandFill, tile)), greaterThanOrEqualTo(4.5), reason: '$tile');
      }
    });

    testWidgets('the map credit chip is not drawn at half opacity', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Center(child: MapBrand('OpenStreetMap')))),
      );
      final brand = find.byKey(const ValueKey('map-brand'));
      var faded = false;
      tester.element(brand).visitAncestorElements((e) {
        if (e.widget is Opacity && (e.widget as Opacity).opacity < 1) faded = true;
        return true;
      });
      expect(faded, isFalse);
      expect(_ratio(tester, find.text('OpenStreetMap')), greaterThanOrEqualTo(4.5));
    });

    test("the meter's TIME and WAITING captions", () {
      expect(contrastRatio(meterCaption, meterPanel), greaterThanOrEqualTo(7));
    });

    for (final MapEntry(key: name, value: theme) in _themes.entries) {
      testWidgets('"Your ride, your way." and the terms on the welcome page ($name)', (tester) async {
        await onPhone(tester, iphone15);
        await tester.pumpWidget(_app(theme, const WelcomeScreen()));
        await tester.pump();
        expect(_ratio(tester, find.text('Your ride, your way.')), greaterThanOrEqualTo(4.5));
        expect(_ratio(tester, find.byKey(const ValueKey('welcome-terms'))), greaterThanOrEqualTo(4.5));
      });

      testWidgets('the vehicle bar: "City", its seats, chosen or not ($name)', (tester) async {
        const city = RideService('City', '', 1, 4);
        const comfort = RideService('Comfort', '', 1.3, 4);
        await tester.pumpWidget(
          _app(
            theme,
            Scaffold(
              body: VehicleTypeBar(services: const [city, comfort], selected: city, onSelect: (_) {}),
            ),
          ),
        );
        await tester.pump();
        for (final word in ['City', 'Comfort']) {
          final box = find.byKey(ValueKey('vehicle-type-$word'));
          expect(_ratio(tester, find.descendant(of: box, matching: find.text(word))), greaterThanOrEqualTo(4.5));
          expect(_ratio(tester, find.descendant(of: box, matching: find.text('4'))), greaterThanOrEqualTo(4.5));
        }
      });

      testWidgets('Offer your fare: the grey words on its card ($name)', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: OfferFareScreen(
              recommended: 20,
              current: 20,
              currencyLabel: 'RM',
              money: (v) => 'RM$v',
              payment: 'cash',
              autoAccept: false,
              entrance: '',
              pickupName: 'KLCC',
              routeLabel: 'KL Sentral',
            ),
          ),
        );
        await tester.pump();
        expect(_ratio(tester, find.text('You can change the recommended fare')), greaterThanOrEqualTo(4.5));
      });

      testWidgets('the route sheet: To and From captions ($name)', (tester) async {
        const klcc = Place(name: 'KLCC', address: 'Kuala Lumpur City Centre', point: LatLng(3.1579, 101.7123));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [recentPlacesProvider.overrideWith((ref) async => const <Place>[])],
            child: MaterialApp(
              theme: theme,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showPlaceSearch(context, title: 'Enter your route', from: klcc, routeEnds: true),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(_ratio(tester, find.text('To')), greaterThanOrEqualTo(4.5));
        expect(_ratio(tester, find.text('From')), greaterThanOrEqualTo(4.5));
      });

      test('the session key note on its dialog ($name)', () {
        expect(contrastRatio(mutedTextColor(theme, background: dialogFill(theme)), dialogFill(theme)), greaterThanOrEqualTo(4.5));
      });
    }

    for (final b in Brightness.values) {
      test('the session key note under an admin modal colour (${b.name})', () {
        final base = appTheme(b, colors: {'textSecondary': b == Brightness.light ? '#9CA3AF' : '#6B7280'});
        for (final fill in const [Color(0xFFE5E7EB), Color(0xFF374151), Color(0xFF2DABE2)]) {
          final t = base.copyWith(dialogTheme: base.dialogTheme.copyWith(backgroundColor: fill));
          expect(contrastRatio(mutedTextColor(t, background: dialogFill(t)), fill), greaterThanOrEqualTo(4.5));
        }
      });
    }
  });
}

// ---- Flags on the web ----------------------------------------------------------

final _emoji = RegExp('[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]', unicode: true);

/// Every string painted on the screen.
Iterable<String> _painted(WidgetTester tester) => tester
    .renderObjectList<RenderParagraph>(find.byType(RichText))
    .map((p) => p.text.toPlainText());

void _webFlags() {
  for (final b in Brightness.values) {
    testWidgets('on the web the sign-in phone page draws no emoji: the flag is "MY" (${b.name})', (tester) async {
      debugFlagsAsCodes = true;
      addTearDown(() => debugFlagsAsCodes = null);
      await onPhone(tester, iphone15);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(appTheme(b), const PhoneScreen(), overrides: [deviceBlockedProvider.overrideWith((ref) async => false)]),
      );
      await tester.pumpAndSettle();
      expect(_painted(tester).where(_emoji.hasMatch), isEmpty);
      expect(find.byKey(const ValueKey('flag-code-MY')), findsOneWidget);
      expect(_ratio(tester, find.text('MY')), greaterThanOrEqualTo(4.5));
      // Still read out as the country, not the code.
      expect(find.bySemanticsLabel(DialCountryButton.semanticsLabelFor(dialCountries.first)), findsOneWidget);

      // And the picker's rows.
      await tester.tap(find.byKey(const ValueKey('dial-country')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('country-SG')), findsOneWidget);
      expect(_painted(tester).where(_emoji.hasMatch), isEmpty);
      semantics.dispose();
    });
  }

  testWidgets('on a phone the flag stays the emoji', (tester) async {
    debugFlagsAsCodes = false;
    addTearDown(() => debugFlagsAsCodes = null);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DialCountryFlag(dialCountries.first))));
    expect(find.text('🇲🇾'), findsOneWidget);
  });
}

// ---- Landscape with the keyboard up --------------------------------------------

void _landscapeKeyboard() {
  const phone = iphone15Side;
  for (final b in Brightness.values) {
    final at = '$phone, keyboard $_keyboard, ${b.name}';

    testWidgets('sign-in phone: no overflow, the title under no bar ($at)', (tester) async {
      await onPhone(tester, phone, keyboard: _keyboard);
      await tester.pumpWidget(
        _app(appTheme(b), const PhoneScreen(), overrides: [deviceBlockedProvider.overrideWith((ref) async => false)]),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The title beside Back, still in view with the number field.
      // As a focused field is brought into view: just enough to show it.
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('phone-number'))),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
      await tester.pumpAndSettle();
      expectOnScreen(tester, find.byKey(const ValueKey('phone-title')), keyboard: _keyboard);
      expectOnScreen(tester, find.byKey(const ValueKey('phone-number')), keyboard: _keyboard);
      final next = find.byKey(const ValueKey('phone-next'));
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      expectOnScreen(tester, next, keyboard: _keyboard);
    });

    testWidgets('code page: no overflow, the title clear of the back bar ($at)', (tester) async {
      await onPhone(tester, phone, keyboard: _keyboard);
      await tester.pumpWidget(_app(appTheme(b), const OtpScreen(phone: '+60123456789', next: 'pin')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // With the code field brought into view, the title is still there:
      // in the slim back bar, not scrolled away under it.
      await Scrollable.ensureVisible(
        tester.element(find.byType(TextField).first),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
      await tester.pump(const Duration(milliseconds: 500));
      final title = find.byKey(const ValueKey('otp-title'));
      expect(find.descendant(of: find.byType(AppBar), matching: title), findsOneWidget);
      expectOnScreen(tester, title, keyboard: _keyboard);
      expect(tester.getRect(find.byType(AppBar)).height, lessThanOrEqualTo(44 + 0.5));
      final verify = find.byKey(const ValueKey('otp-verify'));
      await tester.ensureVisible(verify);
      await tester.pump(const Duration(milliseconds: 500));
      expectOnScreen(tester, verify, keyboard: _keyboard);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Ride options: no overflow, Close reachable ($at)', (tester) async {
      await onPhone(tester, phone);
      late BuildContext ctx;
      final note = TextEditingController();
      addTearDown(note.dispose);
      await tester.pumpWidget(sheetHost(phone, b, (c) => ctx = c));
      showRideOptionsSheet(ctx, options: const RideOptions(), onChanged: (_) {}, note: note);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final close = find.byKey(const ValueKey('ride-options-close'));
      await tester.ensureVisible(close);
      await tester.pumpAndSettle();
      expectOnScreen(tester, close);
    });

    testWidgets('Add a driver: Add on screen with the field, over the keyboard ($at)', (tester) async {
      await onPhone(tester, phone, keyboard: _keyboard);
      late BuildContext ctx;
      await tester.pumpWidget(sheetHost(phone, b, (c) => ctx = c));
      showAddFavouriteSheet(ctx);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Without scrolling: it stands beside the field.
      expectOnScreen(tester, find.byKey(const ValueKey('favourite-code-add')), keyboard: _keyboard);
      expectOnScreen(tester, find.byKey(const ValueKey('favourite-code')), keyboard: _keyboard);
    });

    testWidgets('Vehicle Types, empty: the caption clear of the pinned Add button (${b.name}, $phone)', (tester) async {
      await onPhone(tester, phone);
      await tester.pumpWidget(
        _app(
          appTheme(b),
          const VehicleMakeModelScreen(),
          overrides: [
            vehicleMakeModelsProvider.overrideWith((ref) async => []),
            pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final fab = tester.getRect(find.byType(FloatingActionButton));
      // The list stops above the button: nothing of it rests under it.
      expect(tester.getRect(find.byKey(const ValueKey('vmm-empty-scroll'))).bottom, lessThanOrEqualTo(fab.top));
      for (final f in [find.text('Add a vehicle type like Car, Bike, Truck, or Pick Up.'), find.text('Add Vehicle Type')]) {
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        expect(tester.getRect(f).overlaps(fab), isFalse);
      }
    });

    testWidgets('support chat with the keyboard up: no overflow while it loads or after (${b.name}, $phone)', (tester) async {
      await onPhone(tester, phone, keyboard: _keyboard);
      await tester.pumpWidget(
        _app(
          appTheme(b),
          const SupportChatScreen(ticketId: 't1'),
          overrides: [
            accountRepositoryProvider.overrideWithValue(_Account()),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me', 'name': 'Ali'})),
            supportMessagesProvider.overrideWith(
              (ref, id) => Stream.fromFuture(
                Future.delayed(const Duration(milliseconds: 300), () => <SupportMessage>[]),
              ),
            ),
            photoCameraAvailableProvider.overrideWithValue(false),
            ticketsProvider.overrideWith(
              (ref) async => [SupportTicket({'id': 't1', 'ticket_number': 1042, 'subject': 'Lost my bag', 'status': 'open'})],
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('loading-skeleton')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'the loading rows in a space under one row high');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the loading rows are cut off, not overflowing, in less than a row', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Column(children: [SizedBox(height: 36, child: LoadingSkeleton())]))),
    );
    expect(tester.takeException(), isNull);
  });
}

class _Account implements AccountRepository {
  @override
  Future<void> markTicketRead(String ticketId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
