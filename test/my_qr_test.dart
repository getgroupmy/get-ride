// My QR — personal QR codes (migration 0161): lib/src/core/my_qr.dart,
// lib/src/data/my_qr_repository.dart and the RideRequest getters.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/my_qr.dart';
import 'package:get_ride/src/core/my_ride.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/my_qr_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _token = 'iUzYnXt4Sn-bpU1vUXy2hg';
const _id = '7c9e6679-7425-40de-944b-e07fc1f90ae7';

void main() {
  group('QrKind', () {
    test('labels and segments', () {
      expect([for (final k in QrKind.values) k.label], ['GET.Referral', 'GET.me', 'GET.now']);
      expect([for (final k in QrKind.values) k.pathSegment], ['ref', 'me', 'now']);
      expect(QrKind.referral.driverOnly, isFalse);
      expect(QrKind.me.driverOnly && QrKind.now.driverOnly, isTrue);
    });

    test('parse takes the stored value and the segment, any case', () {
      expect(QrKind.parse('referral'), QrKind.referral);
      expect(QrKind.parse('REF'), QrKind.referral);
      expect(QrKind.parse('Now'), QrKind.now);
      expect(QrKind.parse('myride'), isNull);
      expect(QrKind.parse(null), isNull);
    });

    test('drivers get all three kinds, everyone else referral', () {
      expect(qrKindsFor(isPartner: true), QrKind.values);
      expect(qrKindsFor(isPartner: false), [QrKind.referral]);
    });
  });

  group('payloads', () {
    test('the web form by default, the app scheme on request', () {
      expect(qrPayload(QrKind.now, _token), 'https://qr.getride.my/now/$_token');
      expect(qrPayload(QrKind.referral, _token, web: false), 'getride://ref/$_token');
    });

    test('every form parses back, the token case kept', () {
      for (final k in QrKind.values) {
        for (final web in [true, false]) {
          final s = parsePersonalQr(qrPayload(k, _token, web: web));
          expect(s?.kind, k);
          expect(s?.token, _token);
        }
      }
      expect(parsePersonalQr('  HTTPS://WWW.GETRIDE.MY/q/ME/$_token/?utm=x ')?.token, _token);
      expect(parsePersonalQr('http://getride.my/q/now/$_token#frag')?.kind, QrKind.now);
      expect(parsePersonalQr('getride://referral/$_token/')?.kind, QrKind.referral);
    });

    test('codes printed before qr.getride.my still read', () {
      for (final k in QrKind.values) {
        final s = parsePersonalQr('https://getride.my/q/${k.pathSegment}/$_token');
        expect(s?.kind, k);
        expect(s?.token, _token);
      }
      expect(parsePersonalQr('http://www.getride.my/q/ref/$_token')?.kind, QrKind.referral);
      expect(parsePersonalQr('getride://now/$_token')?.kind, QrKind.now);
    });

    test('the qr host takes the short form only', () {
      expect(parsePersonalQr('HTTPS://QR.GETRIDE.MY/ME/$_token?x=1')?.kind, QrKind.me);
      expect(parsePersonalQr('http://qr.getride.my/now/$_token/')?.token, _token);
      expect(parsePersonalQr('https://qr.getride.my/q/now/$_token'), isNull);
      expect(parsePersonalQr('https://qr.getride.my/now'), isNull);
      expect(parsePersonalQr('https://qr.getride.my/vip/$_token'), isNull);
      expect(parsePersonalQr('https://getride.my/now/$_token'), isNull, reason: 'the short form is the qr host only');
      expect(parsePersonalQr('https://evil.qr.getride.my.example.com/now/$_token'), isNull);
    });

    test('anything else is not a personal code', () {
      expect(parsePersonalQr('https://example.com/q/now/$_token'), isNull);
      expect(parsePersonalQr('https://getride.my/share/$_token'), isNull);
      expect(parsePersonalQr('https://getride.my/q/vip/$_token'), isNull);
      expect(parsePersonalQr('https://getride.my/q/now/short'), isNull);
      expect(parsePersonalQr('https://getride.my/q/now/$_token/extra'), isNull);
      expect(parsePersonalQr('getride://myride/AB2C3D4E'), isNull);
      expect(parsePersonalQr(_token), isNull);
      expect(isQrToken(_token), isTrue);
      expect(isQrToken('has space in it 12345678'), isFalse);
    });
  });

  group('app links', () {
    test('the link pages open signed out', () {
      for (final loc in [
        '/q/now/$_token',
        '/q/zz/short',
        '/ref/$_token',
        '/me/$_token',
        '/now/$_token',
        '/now/short',
        '/now/$_token?utm=x',
      ]) {
        expect(isQrLinkLocation(loc), isTrue, reason: loc);
      }
      for (final loc in ['/', '/login', '/now', '/me', '/referral/$_token', '/now/$_token/extra', '/account/my-qr']) {
        expect(isQrLinkLocation(loc), isFalse, reason: loc);
      }
    });

    test('getride:// links go to /q/, the kind taken from the host', () {
      expect(qrSchemeLinkLocation(Uri.parse('getride://now/$_token')), '/q/now/$_token');
      expect(qrSchemeLinkLocation(Uri.parse('getride://referral/$_token/')), '/q/ref/$_token');
      expect(qrSchemeLinkLocation(Uri.parse('GETRIDE://Me/$_token?x=1')), '/q/me/$_token');
      // The link page says a broken token isn't a code.
      expect(qrSchemeLinkLocation(Uri.parse('getride://now/short')), '/q/now/short');
      expect(qrSchemeLinkLocation(Uri.parse('getride://myride/AB2C3D4E')), isNull);
      expect(qrSchemeLinkLocation(Uri.parse('getride://now')), isNull);
      expect(qrSchemeLinkLocation(Uri.parse('getride://now/$_token/extra')), isNull);
      expect(qrSchemeLinkLocation(Uri.parse('https://qr.getride.my/now/$_token')), isNull);
      expect(qrSchemeLinkLocation(Uri.parse('/now/$_token')), isNull);
    });
  });

  group('parseGetQr routes every GET code', () {
    test('personal codes', () {
      final s = parseGetQr(qrPayload(QrKind.now, _token));
      expect(s, isA<PersonalQrScan>().having((s) => s.kind, 'kind', QrKind.now));
    });

    test('My Ride codes', () {
      expect(parseGetQr('getride://myride/ab2c3d4e'), isA<MyRideCodeScan>().having((s) => s.code, 'code', 'AB2C3D4E'));
      expect(parseGetQr('AB2C3D4E'), isA<MyRideCodeScan>());
    });

    test('wallet codes', () {
      final s = parseGetQr('getpay://u/$_id?amt=5');
      expect(s, isA<WalletCodeScan>());
      expect((s as WalletCodeScan).account.userId, _id);
      expect(s.account.amount, 5);
    });

    test('invite links', () {
      expect(
        parseGetQr('https://getride.my/?ref=amin22'),
        isA<ReferralLinkScan>().having((s) => s.code, 'code', 'AMIN22'),
      );
    });

    test('anything else, and empty', () {
      expect(parseGetQr('https://example.com/?ref=AMIN22'), isA<OtherQrScan>());
      expect(parseGetQr('getpay://u/not-a-uuid'), isA<OtherQrScan>());
      expect(parseGetQr('000201010211'), isA<OtherQrScan>());
      expect(parseGetQr('   '), isNull);
    });
  });

  group('PersonalQr', () {
    final now = DateTime.utc(2026, 10, 12, 12);
    Map<String, dynamic> row({String status = 'active', DateTime? expires, String kind = 'now', DateTime? at}) => {
      'id': _id,
      'kind': kind,
      'token': _token,
      'status': status,
      'created_at': '2026-10-01T00:00:00Z',
      'expires_at': expires?.toIso8601String(),
      'revoked_at': null,
      'last_activated_at': (at ?? DateTime.utc(2026, 10, 1)).toIso8601String(),
      'reactivatable': status != 'active',
    };

    test('fromJson', () {
      final q = PersonalQr.fromJson(row(expires: now.add(const Duration(hours: 3))))!;
      expect(q.kind, QrKind.now);
      expect(q.status, QrStatus.active);
      expect(q.payload, 'https://qr.getride.my/now/$_token');
      expect(q.isActiveAt(now), isTrue);
      expect(q.isActiveAt(now.add(const Duration(hours: 4))), isFalse, reason: 'ran out since it was read');
      expect(PersonalQr.fromJson({'id': _id, 'kind': 'vip', 'token': _token}), isNull);
      expect(PersonalQr.fromJson('nope'), isNull);
    });

    test('active and history', () {
      final codes = [
        PersonalQr.fromJson(row(status: 'revoked', at: DateTime.utc(2026, 10, 2)))!,
        PersonalQr.fromJson(row(status: 'active'))!,
        PersonalQr.fromJson(row(status: 'expired', at: DateTime.utc(2026, 10, 5)))!,
        PersonalQr.fromJson(row(status: 'active', kind: 'me'))!,
      ];
      expect(activeQr(codes, QrKind.now, now), same(codes[1]));
      expect(activeQr(codes, QrKind.referral, now), isNull);
      expect(qrHistory(codes, QrKind.now, now), [codes[2], codes[0]]);
    });

    test('expiry and status text', () {
      expect(qrExpiryText(null, now), 'Never expires');
      expect(qrExpiryText(now.add(const Duration(minutes: 44, seconds: 10)), now), 'Expires in 45 min');
      expect(qrExpiryText(now.add(const Duration(hours: 23, minutes: 59)), now), 'Expires in 24 h');
      expect(qrExpiryText(now.add(const Duration(days: 7)), now), 'Expires in 7 days');
      expect(qrExpiryText(now, now), 'Expired');
      expect(qrStatusText(PersonalQr.fromJson(row())!, now), 'Active · Never expires');
      expect(qrStatusText(PersonalQr.fromJson(row(status: 'revoked'))!, now), 'Turned off');
      expect(
        qrStatusText(PersonalQr.fromJson(row(expires: now.subtract(const Duration(seconds: 1))))!, now),
        'Expired',
      );
    });

    test('ttl choices', () {
      expect([for (final t in QrTtl.values) t.seconds], [3600, 86400, 604800, null]);
      expect([for (final t in QrTtl.values) t.label], ['1 hour', '24 hours', '7 days', 'Never']);
    });
  });

  group('replies', () {
    test('MyQrResult', () {
      final ok = MyQrResult.fromJson({
        'ok': true,
        'qr': {'id': _id, 'kind': 'me', 'token': _token, 'status': 'active'},
      });
      expect(ok, isA<MyQrDone>().having((r) => r.qr.kind, 'kind', QrKind.me));
      final no = MyQrResult.fromJson({'ok': false, 'error': 'rate_limited', 'retry_after': 30});
      expect(no, isA<MyQrRefused>());
      expect((no as MyQrRefused).error, MyQrError.rateLimited);
      expect(no.retryAfter, const Duration(seconds: 30));
      expect((MyQrResult.fromJson({'ok': false, 'error': 'not_a_driver'}) as MyQrRefused).error, MyQrError.notADriver);
      expect((MyQrResult.fromJson(null) as MyQrRefused).error, MyQrError.unknown);
      for (final e in MyQrError.values) {
        expect(e.message, isNotEmpty);
      }
    });

    test('QrResolution', () {
      final ref = QrResolution.fromJson({
        'status': 'active',
        'kind': 'referral',
        'referral_code': 'AMIN22',
        'owner_name': 'Aminah A.',
        'own': false,
      });
      expect(ref, isA<QrActive>().having((r) => r.referralCode, 'code', 'AMIN22'));
      final now = QrResolution.fromJson({
        'status': 'active',
        'kind': 'now',
        'driver': {'driver_id': 'd1', 'name': 'Dan', 'plate': 'WXY 1610'},
        'available': true,
        'online': true,
        'own': false,
      }) as QrActive;
      expect(now.kind, QrKind.now);
      expect(now.driver?.name, 'Dan');
      expect(now.driver?.available, isTrue);
      expect(now.online, isTrue);
      final me = QrResolution.fromJson({
        'status': 'active',
        'kind': 'me',
        'driver': {'driver_id': 'd1', 'name': 'Dan'},
        'available': false,
        'already_favourite': true,
      }) as QrActive;
      expect(me.available, isFalse);
      expect(me.driver?.available, isFalse);
      expect(me.alreadyFavourite, isTrue);
      expect(QrResolution.fromJson({'status': 'sign_in_required', 'kind': 'now'}), isA<QrSignInRequired>());
      expect(QrResolution.fromJson({'status': 'expired'}), isA<QrExpired>());
      expect(QrResolution.fromJson({'status': 'unknown'}), isA<QrUnknown>());
      expect(QrResolution.fromJson({'status': 'active'}), isA<QrUnknown>(), reason: 'no kind');
      expect(
        QrResolution.fromJson({'status': 'rate_limited', 'retry_after': 90}),
        isA<QrRateLimited>().having((r) => r.retryAfter, 'wait', const Duration(seconds: 90)),
      );
      expect(qrResolutionMessage(const QrExpired()), contains('expired'));
      expect(qrResolutionMessage(const QrSignInRequired(QrKind.now)), contains('book'));
    });

    test('adding by GET.me code reuses My Ride outcomes', () {
      final r = AddFavouriteResult.fromJson({'ok': false, 'error': 'expired'});
      expect((r as FavouriteNotAdded).error, AddFavouriteError.expiredCode);
      expect(
        (AddFavouriteResult.fromJson({'ok': false, 'error': 'wrong_kind'}) as FavouriteNotAdded).error,
        AddFavouriteError.wrongCode,
      );
    });
  });

  group('GET.now booking', () {
    test('QrBookingError.parse', () {
      expect(QrBookingError.parse('QR_EXPIRED')?.reason, QrBookingFailure.expired);
      expect(QrBookingError.parse('QR_SELF_BOOKING')?.reason, QrBookingFailure.selfBooking);
      expect(QrBookingError.parse('QR_DRIVER_UNAVAILABLE')?.reason, QrBookingFailure.driverUnavailable);
      expect(QrBookingError.parse('RIDE_REQUEST_DUPLICATE'), isNull);
      expect(QrBookingError.parse(null), isNull);
      for (final f in QrBookingFailure.values) {
        expect(QrBookingError(f).toString(), isNotEmpty);
      }
    });

    test('RideRequest getters', () {
      final direct = RideRequest({
        'id': 'x',
        'status': 'open',
        'direct_driver_id': 'd1',
        'direct_qr_id': _id,
        'target_driver_ids': ['d1'],
      });
      expect(direct.isDirectBooking, isTrue);
      expect(direct.directDriverId, 'd1');
      expect(direct.directQrId, _id);
      expect(RideRequest({'id': 'y', 'status': 'open'}).isDirectBooking, isFalse);
    });
  });

  test('isMissingMyQr', () {
    expect(isMissingMyQr(const PostgrestException(message: 'x', code: 'PGRST202')), isTrue);
    expect(isMissingMyQr(const PostgrestException(message: 'x', code: '42883')), isTrue);
    expect(isMissingMyQr(const PostgrestException(message: 'Could not find the function public.resolve_qr')), isTrue);
    expect(isMissingMyQr(const PostgrestException(message: 'not_authorized', code: '42501')), isFalse);
  });
}
