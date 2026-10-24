// Rider sharing and small rider fixes: wallet QR share/save, the referral
// invite and card, Scan & Pay's torch and help, the emergency contact dial
// code and delete confirmation, the sign-out confirmation and the 404 page.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/get_coin.dart';
import 'package:get_ride/src/app.dart' show appTheme, routerProvider;
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/contact_phone.dart';
import 'package:get_ride/src/core/image_share.dart';
import 'package:get_ride/src/core/referral.dart';
import 'package:get_ride/src/core/wallet_qr.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/referral_repository.dart';
import 'package:get_ride/src/features/auth/passkey_sign_in_button.dart';
import 'package:get_ride/src/features/auth/welcome_screen.dart';
import 'package:get_ride/src/features/profile/emergency_contacts_screen.dart';
import 'package:get_ride/src/features/profile/referral_screen.dart';
import 'package:get_ride/src/features/shell/not_found_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_qr_screens.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/image_share.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthClientOptions, SupabaseClient;
import 'notice.dart';

const _me = '11111111-1111-1111-1111-111111111111';
final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);

class _FakeTrade implements CoinTradeRepository {
  @override
  Future<CoinTradeQuote> quote() async => const CoinTradeQuote(
    walletBalance: 10,
    coinBalance: 300,
    settings: GetCoinSettings(coinsPerCurrency: 100),
    stats: CoinMarketStats(),
  );

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeReferrals implements ReferralRepository {
  @override
  Future<MyReferrer?> myReferrer() async => null;

  @override
  Future<int?> myReferralCount() async => 2;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeAccount implements AccountRepository {
  _FakeAccount([List<EmergencyContact>? contacts]) : contacts = contacts ?? [];
  final List<EmergencyContact> contacts;
  final saved = <String>[];
  final deleted = <String>[];

  @override
  Future<List<EmergencyContact>> emergencyContacts() async => List.of(contacts);

  @override
  Future<void> saveEmergencyContact({String? id, required String name, required String phone}) async =>
      saved.add('${id ?? 'new'}|$name|$phone');

  @override
  Future<void> deleteEmergencyContact(String id) async {
    deleted.add(id);
    contacts.removeWhere((c) => c.id == id);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Records what the share / save seams were handed.
class _Seams {
  final shared = <ShareableImage>[];
  final saved = <ShareableImage>[];
  final texts = <String>[];

  /// The text sharer's answer: true when it fell back to the clipboard (a
  /// desktop browser without Web Share).
  var textCopied = false;
  final qrs = <({String data, Color color, String? caption})>[];
  var torches = 0;

  /// False: a browser with no Web Share for files.
  var fileShare = true;

  /// The image share fails for a passing reason.
  var shareFails = false;

  /// The download fails.
  var saveFails = false;

  List<Override> get overrides => [
    fileSharingAvailableProvider.overrideWithValue(fileShare),
    imageSharerProvider.overrideWithValue((i) async {
      if (shareFails) throw Exception('busy');
      shared.add(i);
      return false;
    }),
    imageSaverProvider.overrideWithValue((i) async {
      saved.add(i);
      return ImageSaveResult(saveFails ? ImageSaveOutcome.failed : ImageSaveOutcome.downloaded);
    }),
    textSharerProvider.overrideWithValue((t, {subject, origin}) async {
      texts.add(t);
      return textCopied;
    }),
    qrPngRendererProvider.overrideWithValue((data, {color = Colors.black, caption}) async {
      qrs.add((data: data, color: color, caption: caption));
      return _png;
    }),
    boundaryPngProvider.overrideWithValue((key, {pixelRatio = 3}) async => _png),
    scannerTorchProvider.overrideWithValue((_) async => torches++),
  ];
}

Widget _app(Widget home, _Seams seams, {Brightness brightness = Brightness.light, List<Override> more = const []}) =>
    ProviderScope(
      overrides: [
        currentUserIdProvider.overrideWithValue(_me),
        profileProvider.overrideWith((ref) async => Profile({'id': _me, 'name': 'Aina Hassan'})),
        coinTradeRepositoryProvider.overrideWithValue(_FakeTrade()),
        coinSettingsProvider.overrideWith(
          (ref) async => const GetCoinSettings(referralReferrerCoins: 50, referralReferredCoins: 20),
        ),
        walletBalancesProvider.overrideWith((ref) async => const []),
        walletTxProvider.overrideWith((ref) async => const []),
        ...seams.overrides,
        ...more,
      ],
      child: MaterialApp(theme: appTheme(brightness), home: home),
    );

void _tall(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 2400);
  addTearDown(tester.view.reset);
}

void main() {
  group('rules', () {
    test('image file names are safe everywhere', () {
      expect(pngFileName('My Code!.png'), 'my-code.png');
      expect(pngFileName('  '), 'getride.png');
      expect(walletQrFileName(coin: false), 'getride-wallet-qr.png');
      expect(walletQrFileName(coin: true), 'getride-coin-qr.png');
      expect(walletQrFileName(coin: false, amount: 12.5), 'getride-wallet-qr-12-50.png');
      expect(referralCardFileName('a1b2-c3d4'), 'getride-invite-a1b2c3d4.png');
    });

    test('what a save tells the rider', () {
      expect(imageSaveMessage(const ImageSaveResult(ImageSaveOutcome.downloaded)), 'Image saved to your downloads');
      expect(
        imageSaveMessage(const ImageSaveResult(ImageSaveOutcome.savedToFile, path: '/d/x.png')),
        contains('/d/x.png'),
      );
      expect(imageSaveMessage(const ImageSaveResult(ImageSaveOutcome.shareSheet)), isNull);
      expect(imageSaveMessage(const ImageSaveResult(ImageSaveOutcome.failed)), contains("Couldn't"));
    });

    test('a shared wallet code says who it pays and for how much', () {
      final text = walletQrShareText(coin: false, userId: _me, name: 'Aina', amountLabel: 'RM12.50');
      expect(text, contains('pay Aina'));
      expect(text, contains('RM12.50'));
      expect(text, contains(walletAccountNumber(_me)));
      // GET.coin codes name the same account number as GET.wallet ones,
      // never the internal user id.
      final coin = walletQrShareText(coin: true, userId: _me);
      expect(coin, contains('Account no. ${walletAccountNumber(_me)}'));
      expect(coin, isNot(contains(_me)));
      expect(walletQrCaption(coin: false, userId: _me, name: 'aina'), startsWith('AINA\nAccount no.'));
      expect(walletQrCaption(coin: true, userId: _me), 'Account no. ${walletAccountNumber(_me)}');
    });

    test('the invite card names the inviter when there is one', () {
      expect(referralCardHeadline('Aina'), 'Aina is inviting you to ride');
      expect(referralCardHeadline('  '), "You're invited to ride");
    });

    test('a stored number splits onto its dial code and joins back', () {
      var s = splitContactPhone('+60123456789', defaultDialCode: '+60');
      expect((s.country.dialCode, s.local), ('+60', '123456789'));
      s = splitContactPhone('+6591234567', defaultDialCode: '+60');
      expect((s.country.code, s.local), ('SG', '91234567'));
      // +971 beats a shorter code that also matches nothing longer.
      s = splitContactPhone('+971501234567', defaultDialCode: '+60');
      expect((s.country.code, s.local), ('AE', '501234567'));
      s = splitContactPhone('+12025550123', defaultDialCode: '+60');
      expect((s.country.dialCode, s.local), ('+1', '2025550123'));
      // An older contact saved without a code stays on the default.
      s = splitContactPhone('012-345 6789', defaultDialCode: '+60');
      expect((s.country.dialCode, s.local), ('+60', '12-345 6789'));
      // An unlisted country stays whole in the field.
      s = splitContactPhone('+998901234567', defaultDialCode: '+60');
      expect((s.country.dialCode, s.local), ('+60', '+998901234567'));

      expect(composeContactPhone('+65', '9123 4567'), '+6591234567');
      expect(composeContactPhone('+60', '012 345 6789'), '+60123456789');
      expect(composeContactPhone('+60', '+998 90 123 4567'), '+998901234567');
      expect(composeContactPhone('+60', '  '), '');
    });

    test('the torch button only gives up once a running camera has none', () {
      expect(scannerTorchAvailable(const MobileScannerState.uninitialized()), isTrue);
      const running = MobileScannerState(
        availableCameras: 1,
        cameraDirection: CameraFacing.back,
        cameraLensType: CameraLensType.any,
        isInitialized: true,
        isStarting: false,
        isRunning: true,
        size: Size(100, 100),
        torchState: TorchState.unavailable,
        zoomScale: 1,
        deviceOrientation: DeviceOrientation.portraitUp,
      );
      expect(scannerTorchAvailable(running), isFalse);
      expect(scannerTorchAvailable(running.copyWith(torchState: TorchState.off)), isTrue);
    });

    testWidgets('a wallet code renders as a PNG on white with a quiet zone', (tester) async {
      final png = await tester.runAsync(
        () => renderQrPng(walletQrPayload(_me), color: const Color(0xFFED2E67), size: 400, caption: 'AINA'),
      );
      final decoded = img.decodePng(png!)!;
      expect(decoded.width, 400);
      expect(decoded.height, greaterThan(400));
      // The corners are the white quiet zone, not the code.
      for (final (x, y) in [(2, 2), (397, 2), (2, 397)]) {
        final p = decoded.getPixel(x, y);
        expect((p.r, p.g, p.b), (255, 255, 255));
      }
    });
  });

  group('wallet QR', () {
    for (final brightness in Brightness.values) {
      testWidgets('the receive code shares and saves as an image (${brightness.name})', (tester) async {
        _tall(tester);
        final seams = _Seams();
        await tester.pumpWidget(_app(const ReceiveQrScreen(), seams, brightness: brightness));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('wallet-qr-share')));
        await tester.pumpAndSettle();
        final shared = seams.shared.single;
        expect(shared.png, _png);
        expect(shared.fileName, 'getride-wallet-qr.png');
        expect(shared.text, contains('Aina Hassan'));
        expect(seams.qrs.single.data, walletQrPayload(_me));
        expect(seams.qrs.single.caption, contains(walletAccountNumber(_me)));

        await tester.tap(find.byKey(const ValueKey('wallet-qr-save')));
        await tester.pumpAndSettle();
        expect(seams.saved.single.fileName, 'getride-wallet-qr.png');
        expect(find.text('Image saved to your downloads'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final brightness in Brightness.values) {
      for (final coin in [false, true]) {
        testWidgets('${coin ? 'GET.coin' : 'Receive'}: a browser that cannot share images copies the account number '
            '(${brightness.name})', (tester) async {
          _tall(tester);
          final copied = <String>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
            return null;
          });
          addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
          final seams = _Seams()..fileShare = false;
          await tester.pumpWidget(_app(ReceiveQrScreen(coin: coin), seams, brightness: brightness));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('wallet-qr-share')));
          await tester.pumpAndSettle();
          expect(seams.shared, isEmpty, reason: 'no image share is tried where it can never work');
          expect(copied.single, contains('Account no. ${walletAccountNumber(_me)}'));
          expect(find.text(copiedForPasting), findsOneWidget);
          expect(find.textContaining('Please try again'), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('a passing share failure still says try again', (tester) async {
      _tall(tester);
      final seams = _Seams()..shareFails = true;
      await tester.pumpWidget(_app(const ReceiveQrScreen(), seams));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wallet-qr-share')));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't share the image. Please try again."), findsOneWidget);
    });

    testWidgets('an amount code shares with its amount, and not once it has expired', (tester) async {
      _tall(tester);
      final seams = _Seams();
      await tester.pumpWidget(_app(const ReceiveQrScreen(), seams));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('qr-amount')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '12.5');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('wallet-qr-share')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(seams.shared.single.fileName, 'getride-wallet-qr-12-50.png');
      expect(seams.shared.single.text, contains('RM'));
      expect(seams.qrs.single.data, walletQrPayload(_me, amount: 12.5));

      await tester.pump(const Duration(seconds: 61));
      expect(find.text('QR code expired'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wallet-qr-share')), warnIfMissed: false);
      await tester.pump();
      expect(seams.shared, hasLength(1));
    });

    testWidgets('the GET.coin code shares in black with the account number', (tester) async {
      _tall(tester);
      final seams = _Seams();
      await tester.pumpWidget(_app(const ReceiveQrScreen(coin: true), seams, brightness: Brightness.dark));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wallet-qr-share')));
      await tester.pumpAndSettle();
      expect(seams.shared.single.fileName, 'getride-coin-qr.png');
      expect(seams.qrs.single.color, Colors.black);
      expect(seams.shared.single.text, contains('Account no. ${walletAccountNumber(_me)}'));
      expect(seams.shared.single.text, isNot(contains(_me)));
      expect(seams.qrs.single.data, walletQrPayload(_me), reason: 'the code itself still carries the user id');
      expect(tester.takeException(), isNull);
    });
  });

  group('referral', () {
    for (final brightness in Brightness.values) {
      testWidgets('the invite shares as text and as a card (${brightness.name})', (tester) async {
        _tall(tester);
        final seams = _Seams();
        await tester.pumpWidget(
          _app(
            const ReferralScreen(),
            seams,
            brightness: brightness,
            more: [referralRepositoryProvider.overrideWithValue(_FakeReferrals())],
          ),
        );
        await tester.pumpAndSettle();
        final code = referralCodeFor(userId: _me);
        final link = referralLink(code);

        // The card carries the code, the inviter and each side's bonus.
        expect(find.byKey(const ValueKey('referral-poster')), findsOneWidget);
        expect(find.byKey(const ValueKey('referral-poster-qr')), findsOneWidget);
        expect(find.text('Aina Hassan is inviting you to ride'), findsOneWidget);
        expect(find.text('for Aina Hassan'), findsOneWidget);
        expect(find.text('for you'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('referral-share-invite')));
        await tester.pump();
        expect(seams.texts.single, referralMessage(code, link));
        expect(seams.texts.single, contains('https://getride.my/?ref=$code'));

        await tester.ensureVisible(find.byKey(const ValueKey('referral-card-share')));
        await tester.tap(find.byKey(const ValueKey('referral-card-share')));
        await tester.pumpAndSettle();
        expect(seams.shared.single.png, _png);
        expect(seams.shared.single.fileName, referralCardFileName(code));
        expect(seams.shared.single.text, referralMessage(code, link));

        await tester.tap(find.byKey(const ValueKey('referral-card-save')));
        await tester.pumpAndSettle();
        expect(seams.saved.single.fileName, referralCardFileName(code));
        expect(tester.takeException(), isNull);
      });
    }

    for (final brightness in Brightness.values) {
      testWidgets('web: Share card copies the invite where images cannot be shared; Download says it saved '
          '(${brightness.name})', (tester) async {
        _tall(tester);
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
        final seams = _Seams()..fileShare = false;
        await tester.pumpWidget(
          _app(
            const ReferralScreen(),
            seams,
            brightness: brightness,
            more: [referralRepositoryProvider.overrideWithValue(_FakeReferrals())],
          ),
        );
        await tester.pumpAndSettle();
        final code = referralCodeFor(userId: _me);
        await tester.ensureVisible(find.byKey(const ValueKey('referral-card-share')));
        await tester.tap(find.byKey(const ValueKey('referral-card-share')));
        await tester.pumpAndSettle();
        expect(seams.shared, isEmpty);
        expect(copied.single, referralMessage(code, referralLink(code)));
        expect(find.text(copiedForPasting), findsOneWidget);

        await closeAnyNotice(tester);
        await tester.tap(find.byKey(const ValueKey('referral-card-save')));
        await tester.pumpAndSettle();
        expect(seams.saved.single.fileName, referralCardFileName(code));
        expect(find.text('Image saved to your downloads'), findsOneWidget);

        // A download that fails says so.
        await closeAnyNotice(tester);
        seams.saveFails = true;
        await tester.pumpWidget(
          _app(
            const ReferralScreen(),
            seams,
            brightness: brightness,
            more: [referralRepositoryProvider.overrideWithValue(_FakeReferrals())],
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('referral-card-save')));
        await tester.tap(find.byKey(const ValueKey('referral-card-save')));
        await tester.pumpAndSettle();
        expect(find.text("Couldn't save the image. Try Share instead."), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a card that could not be drawn says so instead of nothing', (tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ShareSaveImageButtons(keyPrefix: 'x', image: (_) async => null),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('x-share')));
      await tester.pumpAndSettle();
      expect(find.text(imageNotReadyMessage), findsOneWidget);
    });

    testWidgets('with no share sheet the invite is copied, and it says so', (tester) async {
      _tall(tester);
      final seams = _Seams()..textCopied = true;
      await tester.pumpWidget(
        _app(const ReferralScreen(), seams, more: [referralRepositoryProvider.overrideWithValue(_FakeReferrals())]),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('referral-share-invite')));
      await tester.pump();
      expect(seams.texts, hasLength(1));
      await pumpNotice(tester);
      expect(find.text('Invite copied, paste it to a friend'), findsOneWidget);
    });
  });

  group('scan & pay', () {
    testWidgets('the torch toggles and the help sheet explains how to pay (dark)', (tester) async {
      _tall(tester);
      final seams = _Seams();
      await tester.pumpWidget(_app(const ScanPayScreen(), seams, brightness: Brightness.dark));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.byKey(const ValueKey('scan-torch')));
      await tester.pump();
      expect(seams.torches, 1);

      await tester.tap(find.byKey(const ValueKey('scan-help')));
      await tester.pumpAndSettle();
      expect(find.text('How to pay'), findsWidgets);
      for (final step in scanPayHowToSteps) {
        expect(find.text(step), findsOneWidget);
      }
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scan-help-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final brightness in Brightness.values) {
      testWidgets('with no camera the aiming hint goes, the panel says why ($brightness)', (tester) async {
        _tall(tester);
        final scanner = MobileScannerController(autoStart: false);
        addTearDown(scanner.dispose);
        await tester.pumpWidget(_app(ScanPayScreen(scanner: scanner), _Seams(), brightness: brightness));
        await tester.pump();
        expect(find.byKey(const ValueKey('scan-hint')), findsOneWidget, reason: 'a camera to aim: the hint shows');

        // Web or desktop with no camera: the scanner reports an error.
        scanner.value = scanner.value.copyWith(
          error: const MobileScannerException(errorCode: MobileScannerErrorCode.unsupported),
        );
        await tester.pump();
        expect(find.text('Point the camera at a GET.ride QR code.'), findsNothing);
        expect(find.byKey(const ValueKey('scan-hint-none')), findsOneWidget);
        expect(find.byKey(const ValueKey('scan-manual')), findsOneWidget, reason: 'the code can still be pasted');
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('emergency contacts', () {
    Future<_FakeAccount> pump(WidgetTester tester, {List<EmergencyContact>? contacts, Brightness? brightness}) async {
      _tall(tester);
      final account = _FakeAccount(contacts);
      await tester.pumpWidget(
        _app(
          const EmergencyContactsScreen(),
          _Seams(),
          brightness: brightness ?? Brightness.light,
          more: [accountRepositoryProvider.overrideWithValue(account), contactPickerProvider.overrideWithValue(null)],
        ),
      );
      await tester.pumpAndSettle();
      return account;
    }

    testWidgets('a contact is added on the dial code picked for it (dark)', (tester) async {
      final account = await pump(tester, brightness: Brightness.dark);
      await tester.tap(find.text('Add contact'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('contact-dial-country')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('country-search')), 'singa');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('country-SG')));
      await tester.pumpAndSettle();
      expect(find.text('+65'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Mei');
      await tester.enterText(find.byKey(const ValueKey('contact-phone')), '9123 4567');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(account.saved, ['new|Mei|+6591234567']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing shows a stored number on its own dial code', (tester) async {
      final account = await pump(
        tester,
        contacts: [EmergencyContact(id: 'c1', name: 'Mei', phone: '+6591234567')],
      );
      await tester.tap(find.text('Mei'));
      // The row spins behind the form until it is answered.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('+65'), findsOneWidget);
      expect(find.widgetWithText(TextField, '91234567'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(account.saved, ['c1|Mei|+6591234567']);
    });

    testWidgets('deleting asks first', (tester) async {
      final account = await pump(
        tester,
        contacts: [EmergencyContact(id: 'c1', name: 'Mei', phone: '+6591234567')],
      );
      await tester.tap(find.byKey(const ValueKey('contact-delete-c1')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Delete contact?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(account.deleted, isEmpty);
      expect(find.text('Mei'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('contact-delete-c1')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('contact-delete-confirm')));
      await tester.pumpAndSettle();
      expect(account.deleted, ['c1']);
      expect(find.text('Mei'), findsNothing);
    });
  });

  group('page not found', () {
    GoRouter router() => GoRouter(
      initialLocation: '/',
      errorBuilder: notFoundPage,
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('home')),
        GoRoute(path: '/share/:token', builder: (_, s) => Text('share ${s.pathParameters['token']}')),
        GoRoute(path: '/install/:platform', builder: (_, s) => Text('install ${s.pathParameters['platform']}')),
      ],
    );

    for (final brightness in Brightness.values) {
      testWidgets('an unknown address gets a way home (${brightness.name})', (tester) async {
        final r = router();
        await tester.pumpWidget(MaterialApp.router(theme: appTheme(brightness), routerConfig: r));
        r.go('/no/such/page');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('not-found')), findsOneWidget);
        expect(find.text('/no/such/page'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('not-found-home')));
        await tester.pumpAndSettle();
        expect(find.text('home'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the public share and install links still open their pages', (tester) async {
      final r = router();
      await tester.pumpWidget(MaterialApp.router(routerConfig: r));
      r.go('/share/abc');
      await tester.pumpAndSettle();
      expect(find.text('share abc'), findsOneWidget);
      r.go('/install/android');
      await tester.pumpAndSettle();
      expect(find.text('install android'), findsOneWidget);
      expect(find.byType(NotFoundScreen), findsNothing);
    });

    testWidgets("the app's router still sends a signed-out unknown address to sign-in", (tester) async {
      final db = SupabaseClient(
        'http://localhost',
        'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final container = ProviderContainer(
        overrides: [
          supabaseProvider.overrideWithValue(db),
          deviceBlockedProvider.overrideWith((ref) async => false),
          appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
          passkeyOfferedHereProvider.overrideWith((ref) async => false),
        ],
      );
      addTearDown(container.dispose);
      final r = container.read(routerProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: r),
        ),
      );
      r.go('/no/such/page');
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(NotFoundScreen), findsNothing);
    });
  });
}
