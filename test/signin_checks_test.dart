// The sign-in checks of a dispatch ID (migration 0281), without a screen:
// reading dispatch_my_checks, the step shown, the waiting lines, the
// admin's words and switches, the rejection reasons, reading a MyKad or a
// passport, and the live selfie's blink and head turn.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/liveness.dart';
import 'package:get_ride/src/core/signin_checks.dart';

DispatchChecks _checks(Map<String, dynamic> m) =>
    DispatchChecks.fromJson({'holds': true, 'kinds': ['stand_admin'], 'asks_selfie': true, 'asks_id': true, ...m});

void main() {
  group("what's needed", () {
    test('no role, or nothing left: no step, the role open', () {
      expect(DispatchChecks.fromJson({'holds': false, 'needs': []}).step, SignInStep.done);
      expect(DispatchChecks.fromJson(null).blocked, isFalse);
      expect(_checks({'needs': []}).blocked, isFalse);
      expect(_checks({'needs': ['nonsense']}).needs, isEmpty, reason: 'an unknown need is ignored');
    });

    test('one step at a time: PIN, selfie, ID, then waiting', () {
      expect(_checks({'needs': ['pin', 'selfie', 'id']}).step, SignInStep.pin);
      expect(_checks({'needs': ['selfie', 'id']}).step, SignInStep.selfie);
      expect(_checks({'needs': ['recheck', 'pending']}).step, SignInStep.selfie);
      expect(_checks({'needs': ['id']}).step, SignInStep.id);
      expect(_checks({'needs': ['pending']}).step, SignInStep.pending);
      expect(_checks({'needs': ['pending']}).blocked, isTrue);
    });

    test('a new phone alone asks a re-check selfie', () {
      expect(_checks({'needs': ['recheck']}).recheckOnly, isTrue);
      expect(_checks({'needs': ['selfie', 'recheck']}).recheckOnly, isFalse);
    });

    test('the rejection reason comes with the state', () {
      final c = _checks({
        'needs': ['id'],
        'id': {'state': 'rejected', 'reason': 'name_mismatch', 'note': 'Use your own MyKad'},
        'selfie': {'state': 'rejected', 'reason': 'blurry'},
      });
      expect(c.id.state, RecordState.rejected);
      expect(c.id.rejection, "Name doesn't match: Use your own MyKad");
      expect(c.selfie.rejection, 'Photo blurry');
    });

    test('an ID running out is asked for again without shutting the role', () {
      final c = _checks({
        'needs': [],
        'id': {'state': 'renew', 'expiry': '2026-11-20'},
      });
      expect(c.renewDue, isTrue);
      expect(c.blocked, isFalse);
      expect(c.id.expiry, DateTime(2026, 11, 20));
      expect(_checks({'asks_id': false, 'id': {'state': 'renew'}}).renewDue, isFalse);
    });

    test('days left to the deadline', () {
      final now = DateTime.utc(2026, 10, 24, 9);
      expect(_checks({'deadline': '2026-10-27T09:00:00Z'}).daysLeft(now), 3);
      expect(_checks({'deadline': '2026-10-24T10:00:00Z'}).daysLeft(now), 1);
      expect(_checks({'deadline': '2026-10-23T09:00:00Z'}).daysLeft(now), isNull);
      expect(_checks({}).daysLeft(now), isNull);
    });

    test('the waiting page lines', () {
      final c = _checks({
        'needs': ['pending'],
        'id': {'state': 'pending'},
        'selfie': {'state': 'received'},
      });
      expect(waitingLines(c).map((l) => '${l.label}: ${l.state}'), ['ID: Waiting for review', 'Photo: Received']);
      expect(
        waitingLines(_checks({'asks_selfie': false, 'id': {'state': 'ok'}})).map((l) => l.state),
        ['Approved'],
      );
    });

    test('the role in words', () {
      expect(roleWord(['staff', 'stand_admin']), 'stand admin');
      expect(roleWord(['fleet_owner']), 'fleet owner');
      expect(roleWord(['staff']), 'stand staff');
    });
  });

  group("the admin's side", () {
    test('the switches as dispatch_grant reads them; a deadline only with something asked', () {
      expect(const SignInAsks(selfie: true, days: 7).toJson(), {'verify_selfie': true, 'verify_id': false, 'verify_days': 7});
      expect(const SignInAsks(days: 7).toJson()['verify_days'], isNull);
      expect(SignInAsks.fromJson({'selfie': true, 'id': true, 'days': 3}), const SignInAsks(selfie: true, id: true, days: 3));
      expect(const SignInAsks(id: true, days: 3).copyWith(days: () => null).days, isNull);
    });

    test('finish within: blank, a number of days, or not one', () {
      expect(parseDeadlineDays(''), (days: null, bad: false));
      expect(parseDeadlineDays(' 14 '), (days: 14, bad: false));
      expect(parseDeadlineDays('0').bad, isTrue);
      expect(parseDeadlineDays('400').bad, isTrue);
      expect(parseDeadlineDays('a week').bad, isTrue);
    });

    test("an account's state in words", () {
      expect(verifyStatus({'needs': ['selfie', 'id'], 'paused': true}), 'Paused: not verified');
      expect(verifyStatus({'needs': ['pending']}), 'Waiting for approval');
      expect(verifyStatus({'needs': ['pin', 'recheck', 'id']}), 'To do: PIN, selfie (new phone), ID');
      expect(verifyStatus({'needs': []}), isNull);
      expect(asksText(const SignInAsks(selfie: true, id: true, days: 7)), 'Asks for a selfie and ID, within 7 days');
      expect(asksText(const SignInAsks()), isNull);
    });

    test('rejection reasons from the list; Other needs a note', () {
      expect(rejectReasons.values, [
        'Photo blurry',
        'Face not clear',
        "Name doesn't match",
        'Expired',
        'Wrong document',
        'Other',
      ]);
      expect(rejectChoiceProblem(null, ''), 'Pick why.');
      expect(rejectChoiceProblem('other', ' '), isNotNull);
      expect(rejectChoiceProblem('other', 'Glare on the card'), isNull);
      expect(rejectChoiceProblem('expired', ''), isNull);
      expect(rejectNotes('blurry', ' Try daylight '), 'Photo blurry: Try daylight');
      expect(rejectNotes('other', 'Glare on the card'), 'Glare on the card');
      expect(rejectReasonText(null, null), isNull);
    });

    test('face match, live check and mismatch words', () {
      expect(faceMatchText('match', 97.4), 'Same person likely (97%)');
      expect(faceMatchText('no_match', 12), 'Faces differ (12%)');
      expect(faceMatchText(null, null), 'Not checked');
      expect(livenessText('passed', 'blink'), 'Live: blinked');
      expect(livenessText('not_checked'), 'Live check: not checked');
      expect(mismatchWarning(['name', 'ic']), "The name and IC number read from the card doesn't match the profile.");
      expect(mismatchWarning(const []), isNull);
    });
  });

  group('reading the card', () {
    test('a MyKad: the IC number and the name under it', () {
      final r = readCard('KAD PENGENALAN\nMyKad\nMALAYSIA\n880202-10-1234\nAINA BINTI AHMAD\nNO 12 JALAN SS2/24\n'
          '47300 PETALING JAYA\nSELANGOR\nWARGANEGARA\nISLAM PEREMPUAN');
      expect(r.ic, '880202-10-1234');
      expect(r.name, 'AINA BINTI AHMAD');
      expect(r.expiry, isNull);
    });

    test('an IC read with spaces or without dashes', () {
      expect(readCard('880202 10 1234\nSITI NURHALIZA').ic, '880202-10-1234');
      expect(readCard('880202101234').ic, '880202-10-1234');
      expect(readCard('nothing here').ic, isNull);
    });

    test("a passport's machine lines: name, expiry and a Malaysian IC", () {
      final r = readCard('PASPORT MALAYSIA\nP<MYSAHMAD<<AINA<BINTI<<<<<<<<<<<<<<<<<<<<<<<\n'
          'A123456786MYS8802021F3105147880202101234<<26');
      expect(r.name, 'AINA BINTI AHMAD');
      expect(r.expiry, DateTime(2031, 5, 14));
      expect(r.ic, '880202-10-1234');
    });

    test('what was read against the profile, as the server checks it', () {
      const read = (name: 'AINA BINTI AHMAD', ic: '880202-10-1234', expiry: null);
      expect(cardMismatch(read, profileName: 'Aina binti Ahmad', profileIc: '880202101234'), isEmpty);
      expect(cardMismatch(read, profileName: 'Aina', profileIc: null), isEmpty, reason: 'a short name is part of it');
      expect(cardMismatch(read, profileName: 'Siti Nurhaliza', profileIc: '900101-14-5678'), ['name', 'ic']);
      expect(cardMismatch((name: null, ic: null, expiry: null), profileName: 'X', profileIc: '1'), isEmpty);
    });
  });

  group('the live selfie', () {
    const open = FaceSample(leftEyeOpen: 0.95, rightEyeOpen: 0.9, yaw: 2);
    const shut = FaceSample(leftEyeOpen: 0.05, rightEyeOpen: 0.1, yaw: 2);

    test('a blink is open, shut, open', () {
      final t = LivenessTracker(LiveChallenge.blink);
      expect(t.feed(open), isFalse);
      expect(t.text, 'Blink slowly');
      expect(t.feed(open), isFalse);
      expect(t.feed(shut), isFalse);
      expect(t.feed(open), isTrue);
      expect(t.passed, isTrue);
    });

    test('a photo held up never blinks', () {
      final t = LivenessTracker(LiveChallenge.blink);
      for (var i = 0; i < 20; i++) {
        expect(t.feed(open), isFalse);
      }
    });

    test('a head turn is straight, then turned', () {
      final t = LivenessTracker(LiveChallenge.turn);
      expect(t.feed(const FaceSample(yaw: 30)), isFalse, reason: 'not straight first');
      expect(t.text, 'Look straight at the camera');
      expect(t.feed(const FaceSample(yaw: 3)), isFalse);
      expect(t.feed(const FaceSample(yaw: -15)), isFalse);
      expect(t.feed(const FaceSample(yaw: -31)), isTrue);
    });

    test('no face, two faces or too far start again', () {
      final t = LivenessTracker(LiveChallenge.blink);
      t.feed(open);
      t.feed(shut);
      t.feed(const FaceSample(faces: 2));
      expect(t.text, 'Only you in the picture, please');
      expect(t.feed(open), isFalse, reason: 'the shut eyes before do not count after a second face');
      t.feed(const FaceSample(faces: 0));
      expect(t.text, 'Put your face in the circle');
      t.feed(const FaceSample(width: 0.1, leftEyeOpen: 1, rightEyeOpen: 1));
      expect(t.text, 'Come a little closer');
    });

    test('the challenge kept with the selfie', () {
      expect(LiveChallenge.blink.detail, 'blink');
      expect(LiveChallenge.turn.detail, 'turn');
    });
  });
}
