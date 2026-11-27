import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/rider_id_gate.dart';

void main() {
  group('RiderIdGateRule', () {
    test('defaults and clamps', () {
      const s = RiderIdGateRule.standard;
      expect([s.require, s.idType, s.nthBooking, s.selfie, s.allowPhoto, s.autoVerifyScore],
          [false, 'either', 1, true, true, 85]);
      final r = RiderIdGateRule.fromJson({'require': true, 'idType': 'x', 'nthBooking': 999, 'autoVerifyScore': 10});
      expect([r.require, r.idType, r.nthBooking, r.autoVerifyScore], [true, 'either', 50, 60]);
      expect(RiderIdGateRule.fromJson(r.toJson()), r);
      // A driving licence is an accepted ID type (not coerced to 'either').
      expect(RiderIdGateRule.fromJson({'idType': 'licence'}).idType, 'licence');
    });
  });

  group('RiderIdGateConfig.ruleFor', () {
    final cfg = RiderIdGateConfig.fromJson({
      'master': {'require': true, 'nthBooking': 3},
      'Malaysia': {'require': true, 'nthBooking': 1},
    });

    test('country rule wins, else master', () {
      expect(cfg.ruleFor('Malaysia')?.nthBooking, 1);
      expect(cfg.ruleFor('Singapore')?.nthBooking, 3); // master
      expect(cfg.ruleFor(null)?.nthBooking, 3); // master
    });

    test('no rules at all', () {
      expect(RiderIdGateConfig.empty.ruleFor('Malaysia'), isNull);
    });
  });

  group('riderIdGateBlocks', () {
    final cfg = RiderIdGateConfig.fromJson({
      'Malaysia': {'require': true, 'nthBooking': 1},
      'Thailand': {'require': true, 'nthBooking': 3},
      'Laos': {'require': false},
    });

    test('nth=1 blocks an unverified rider before their first booking', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Malaysia', priorBookings: 0, verified: false), isTrue);
    });

    test('a verified rider is never blocked', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Malaysia', priorBookings: 0, verified: true), isFalse);
    });

    test('nth=3 lets the first two through, blocks the third', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Thailand', priorBookings: 1, verified: false), isFalse);
      expect(riderIdGateBlocks(config: cfg, country: 'Thailand', priorBookings: 2, verified: false), isTrue);
    });

    test('require=off never blocks', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Laos', priorBookings: 99, verified: false), isFalse);
    });

    test('no rule for the country and no master never blocks', () {
      expect(riderIdGateBlocks(config: cfg, country: 'Nowhere', priorBookings: 99, verified: false), isFalse);
    });
  });

  group('RiderIdGateConfig.ruleForRider (matches the server order)', () {
    final cfg = RiderIdGateConfig.fromJson({
      'master': {'require': false},
      'Malaysia': {'require': true, 'nthBooking': 1},
    });

    test('where the rider is now wins over nationality', () {
      expect(cfg.ruleForRider(currentCountry: 'Malaysia', nationality: 'Singapore')?.require, isTrue);
    });

    test('falls back to nationality, then master', () {
      expect(cfg.ruleForRider(nationality: 'Malaysia')?.require, isTrue);
      expect(cfg.ruleForRider(currentCountry: 'Nowhere', nationality: 'Nowhere')?.require, isFalse); // master
    });

    test('a blank current country is ignored', () {
      expect(cfg.ruleForRider(currentCountry: '  ', nationality: 'Malaysia')?.require, isTrue);
    });
  });

  group('riderIdGateBlocks uses current country first', () {
    final cfg = RiderIdGateConfig.fromJson({
      'master': {'require': false},
      'Malaysia': {'require': true, 'nthBooking': 1},
    });

    test('a rider in Malaysia is gated even when their nationality differs', () {
      expect(
        riderIdGateBlocks(
            config: cfg, currentCountry: 'Malaysia', country: 'Singapore', priorBookings: 0, verified: false),
        isTrue,
      );
    });

    test('nationality still gates when the current country is unknown', () {
      expect(
        riderIdGateBlocks(config: cfg, country: 'Malaysia', priorBookings: 0, verified: false),
        isTrue,
      );
    });

    test('a verified rider in Malaysia is never gated', () {
      expect(
        riderIdGateBlocks(
            config: cfg, currentCountry: 'Malaysia', country: 'Singapore', priorBookings: 0, verified: true),
        isFalse,
      );
    });
  });

  group('RiderVerifyMethod (combines the eKYC and live-selfie gates)', () {
    test('derives from the two gates', () {
      expect(RiderVerifyMethod.of(idRequired: false, selfieRequired: false), RiderVerifyMethod.none);
      expect(RiderVerifyMethod.of(idRequired: true, selfieRequired: false), RiderVerifyMethod.ekyc);
      expect(RiderVerifyMethod.of(idRequired: false, selfieRequired: true), RiderVerifyMethod.liveSelfie);
      expect(RiderVerifyMethod.of(idRequired: true, selfieRequired: true), RiderVerifyMethod.both);
    });

    test('maps back to the two gate requirements', () {
      expect([RiderVerifyMethod.none.idRequired, RiderVerifyMethod.none.selfieRequired], [false, false]);
      expect([RiderVerifyMethod.ekyc.idRequired, RiderVerifyMethod.ekyc.selfieRequired], [true, false]);
      expect([RiderVerifyMethod.liveSelfie.idRequired, RiderVerifyMethod.liveSelfie.selfieRequired], [false, true]);
      expect([RiderVerifyMethod.both.idRequired, RiderVerifyMethod.both.selfieRequired], [true, true]);
    });

    test('round-trips through the two flags', () {
      for (final m in RiderVerifyMethod.values) {
        expect(RiderVerifyMethod.of(idRequired: m.idRequired, selfieRequired: m.selfieRequired), m);
      }
    });
  });
}
