import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/document_text.dart' show IdDocType;
import 'package:get_ride/src/core/partner_id_gate.dart';

void main() {
  group('PartnerIdGateConfig', () {
    test('reads {country: {require}} and bare bools, with a master default', () {
      const cfg = PartnerIdGateConfig({'master': false, 'Malaysia': true});
      expect(cfg.requiredIn('Malaysia'), isTrue);
      expect(cfg.requiredIn('Thailand'), isFalse, reason: 'falls back to master');
      expect(cfg.requiredIn(null), isFalse);

      final parsed = PartnerIdGateConfig.fromJson({
        'master': {'require': false},
        'Malaysia': {'require': true},
        'Singapore': true,
      });
      expect(parsed.requiredIn('Malaysia'), isTrue);
      expect(parsed.requiredIn('Singapore'), isTrue);
      expect(parsed.requiredIn('Indonesia'), isFalse);
      // Unusable JSON reads as empty (off everywhere).
      expect(PartnerIdGateConfig.fromJson(null).requiredIn('Malaysia'), isFalse);
      expect(PartnerIdGateConfig.empty.requiredIn('Malaysia'), isFalse);
    });

    test('no master means off by default', () {
      const cfg = PartnerIdGateConfig({'Malaysia': true});
      expect(cfg.requiredIn('Thailand'), isFalse);
    });
  });

  group('idProvesCitizenship', () {
    test('only a citizen MyKad proves citizenship', () {
      expect(idProvesCitizenship(IdDocType.mykad, null), isTrue);
      expect(idProvesCitizenship(IdDocType.mykad, 'Malaysian'), isTrue);
      // A passport, a permanent resident card and a driving licence do not.
      expect(idProvesCitizenship(IdDocType.passport, 'Malaysian'), isFalse);
      expect(idProvesCitizenship(IdDocType.mypr, null), isFalse);
      expect(idProvesCitizenship(IdDocType.licence, null), isFalse);
      expect(idProvesCitizenship(null, null), isFalse);
      // A MyKad whose read says non-citizen is not proof either.
      expect(idProvesCitizenship(IdDocType.mykad, 'Indonesian'), isFalse);
    });
  });

  group('partnerIdGateBlocks', () {
    const on = PartnerIdGateConfig({'Malaysia': true, 'master': false});

    test('an unverified partner is gated only where the admin turned it on', () {
      expect(
        partnerIdGateBlocks(config: on, country: 'Malaysia', verified: false),
        isTrue,
      );
      expect(
        partnerIdGateBlocks(config: on, country: 'Thailand', verified: false),
        isFalse,
        reason: 'gate off there',
      );
    });

    test('a verified partner skips the gate', () {
      expect(partnerIdGateBlocks(config: on, country: 'Malaysia', verified: true), isFalse);
    });

    test('a citizens-only pick forces verification when the ID is not citizen proof', () {
      // Verified on a passport, but a citizens-only service is picked → must
      // re-verify with a citizen ID, even where the gate is off.
      expect(
        partnerIdGateBlocks(
          config: on,
          country: 'Thailand',
          verified: true,
          pickedCitizensOnly: true,
          idType: IdDocType.passport,
          nationality: 'Malaysian',
        ),
        isTrue,
      );
      // A licence is not citizen proof either.
      expect(
        partnerIdGateBlocks(
          config: on,
          country: 'Thailand',
          verified: true,
          pickedCitizensOnly: true,
          idType: IdDocType.licence,
        ),
        isTrue,
      );
    });

    test('a citizen MyKad satisfies a citizens-only pick', () {
      expect(
        partnerIdGateBlocks(
          config: on,
          country: 'Malaysia',
          verified: true,
          pickedCitizensOnly: true,
          idType: IdDocType.mykad,
          nationality: 'Malaysian',
        ),
        isFalse,
      );
    });

    test('the citizen rule applies only to an already-verified partner', () {
      // Unverified: the general per-country gate decides. A citizens-only pick
      // does not independently force verification where the gate is off — the
      // services step still filters a service a non-citizen cannot take.
      expect(
        partnerIdGateBlocks(
          config: on,
          country: 'Thailand',
          verified: false,
          pickedCitizensOnly: true,
        ),
        isFalse,
      );
      // But where the gate is on, an unverified partner is gated regardless.
      expect(
        partnerIdGateBlocks(
          config: on,
          country: 'Malaysia',
          verified: false,
          pickedCitizensOnly: true,
        ),
        isTrue,
      );
    });
  });
}
