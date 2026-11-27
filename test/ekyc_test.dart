// GET.eKYC (migration 0439): the admin's switches, the start answer, and the
// words for how a check ended and for GET.eKYC's verdict.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ekyc/get_ekyc.dart' show EkycOutcome;
import 'package:get_ride/src/core/ekyc.dart';
import 'package:get_ride/src/core/signin_checks.dart' show faceProviderText, idDocumentWord, readSourceText;

void main() {
  test('switches: off by default, each use only when the master is on', () {
    expect(EkycConfig.fromJson(null).uses('rider_gate'), isFalse);
    final c = EkycConfig.fromJson({'on': true, 'riderGate': true, 'dispatchId': false});
    expect(c.uses('rider_gate'), isTrue);
    expect(c.uses('first'), isFalse);
    expect(EkycConfig.fromJson({'on': false, 'riderGate': true}).uses('rider_gate'), isFalse);
    expect(c.toJson(), {'on': true, 'riderGate': true, 'dispatchId': false, 'test': false});
  });

  test('the next step after a GET.eKYC check (primary, with a fallback)', () {
    expect(ekycNext(sent: true, verified: true, unavailable: false), EkycNext.accept);
    expect(ekycNext(sent: true, verified: false, unavailable: false), EkycNext.accept,
        reason: 'a submitted check waits for an admin review — it is not a fallback');
    expect(ekycNext(sent: false, verified: false, unavailable: true), EkycNext.fallBack,
        reason: 'GET.eKYC could not start — fall back to the photo-and-selfie face match');
    expect(ekycNext(sent: false, verified: false, unavailable: false), EkycNext.stop,
        reason: 'the person cancelled the check');
  });

  test('admins are told which key is missing', () {
    expect(EkycConfig.fromJson({'serverKey': true, 'webhookKey': true}).missingKeys, isNull);
    expect(EkycConfig.fromJson({'serverKey': false, 'webhookKey': true}).missingKeys, contains('API key'));
    expect(EkycConfig.fromJson({'serverKey': true, 'webhookKey': false}).missingKeys, contains('webhook secret'));
    expect(EkycConfig.fromJson({}).missingKeys, isNull, reason: 'riders are not told about keys');
  });

  test('the start answer must be an https page and a session', () {
    expect(parseEkycStart({'url': 'https://ekyc.getcdn.link/v/abc', 'session_id': 's1'}),
        (url: 'https://ekyc.getcdn.link/v/abc', sessionId: 's1'));
    expect(parseEkycStart({'url': 'http://evil.example/v/abc', 'session_id': 's1'}), isNull);
    expect(parseEkycStart({'error': 'ekyc_off'}), isNull);
    expect(ekycStartError(Exception('{"error":"ekyc_off"}')), contains('not available'));
  });

  test('what the person is told when the page closes', () {
    expect(ekycEndMessage(EkycOutcome.approved, verified: true), 'Identity verified.');
    expect(ekycEndMessage(EkycOutcome.approved, verified: false), contains('being reviewed'));
    expect(ekycEndMessage(EkycOutcome.rejected, verified: false), contains('being reviewed'),
        reason: 'GET.eKYC never rejects anyone by itself; an admin decides');
    expect(ekycEndMessage(EkycOutcome.cancelled, verified: false), isNull);
    expect(ekycEndMessage(EkycOutcome.expired, verified: false), contains('timed out'));
  });

  test("GET.eKYC's verdict for the admin", () {
    expect(ekycVerdictText('approved', []), 'Approved');
    expect(ekycVerdictText('review', ['face_match_uncertain', 'name_mismatch']), 'Needs review: face match uncertain, name mismatch');
    expect(ekycVerdictText(null, null), isNull);
    expect(faceProviderText('ekyc'), 'GET.eKYC');
    expect(readSourceText('ekyc'), 'GET.eKYC');
  });

  test('each identity document is named for the admin (0441)', () {
    expect(idDocumentWord('driving_licence'), 'Driving licence');
    expect(idDocumentWord('ikad'), 'i-Kad');
    expect(idDocumentWord('unhcr'), 'UNHCR card');
    expect(idDocumentWord('mypr'), 'MyPR');
    expect(idDocumentWord('id_card'), 'ID card');
    expect(idDocumentWord(null), 'MyKad', reason: 'checks from before 0441');
  });
}
