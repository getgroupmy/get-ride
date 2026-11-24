import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ekyc/get_ekyc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const url = 'https://ekyc.example.my/v/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc';

void main() {
  group('EkycApi', () {
    test('talks to the hosted API of the link, never with an API key', () async {
      final seen = <String>[];
      final api = EkycApi(url, client: MockClient((req) async {
        seen.add('${req.method} ${req.url.path}');
        expect(req.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-api-key')));
        if (req.url.path.endsWith('/media/document_front')) {
          return http.Response(jsonEncode({'document': {'name': 'MyKad', 'needs_back': true, 'needs_selfie': true, 'readable': true}}), 200);
        }
        if (req.url.path.endsWith('/status')) return http.Response(jsonEncode({'state': 'approved', 'finished': true}), 200);
        if (req.url.path.endsWith('/submit')) return http.Response(jsonEncode({'detail': 'already sent'}), 409);
        return http.Response(jsonEncode({
          'verification_id': 'ver_1', 'client': 'GET-Ride', 'state': 'created', 'needs_selfie': null,
          'liveness_challenge': ['left', 'center', 'right'], 'consent_needed': true,
          'consent_text': {'en': 'EN text', 'ms': 'BM text'},
        }), 200);
      }));
      expect(api.origin, 'https://ekyc.example.my');
      final info = await api.info();
      expect(info.verificationId, 'ver_1');
      expect(info.livenessChallenge, ['left', 'center', 'right']);
      expect(info.consentText('ms'), 'BM text');
      final doc = await api.upload('document_front', Uint8List.fromList([1, 2, 3]));
      expect(doc!.name, 'MyKad');
      expect(doc.needsBack, isTrue);
      await api.submit(); // 409 = already submitted, not an error
      expect((await api.status()).state, 'approved');
      expect(seen.first, 'GET /v1/hosted/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc');
    });

    test('server errors carry the message', () async {
      final api = EkycApi(url, client: MockClient((_) async => http.Response(jsonEncode({'detail': 'this link has expired'}), 410)));
      expect(() => api.info(), throwsA(isA<EkycApiException>().having((e) => e.statusCode, 'status', 410)));
    });

    test('rejects something that is not a hosted link', () {
      expect(() => EkycApi('https://ekyc.example.my/admin'), throwsArgumentError);
    });
  });

  group('EkycResult', () {
    test('reads the return link and the page bridge', () {
      final r = EkycResult.fromReturnUri(Uri.parse('getride://ekyc-done?verification_id=ver_9&status=review&external_ref=d1'))!;
      expect(r.outcome, EkycOutcome.review);
      expect(r.verificationId, 'ver_9');
      expect(r.sent, isTrue);
      expect(EkycResult.fromReturnUri(Uri.parse('getride://ekyc-done')), isNull);
      final b = EkycResult.fromBridge({'event': 'ekyc.finished', 'verification_id': 'ver_9', 'status': 'cancelled'})!;
      expect(b.outcome, EkycOutcome.cancelled);
      expect(b.sent, isFalse);
      expect(EkycResult.outcomeOf('processing'), EkycOutcome.submitted);
    });
  });

  group('PoseSteps', () {
    final t0 = DateTime(2026);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('captures each cue once the pose is held', () {
      final p = PoseSteps(['selfie', 'left', 'center', 'right']);
      expect(p.feed(null, at(0)), isFalse); // no face
      expect(p.feed(2, at(0)), isFalse);
      expect(p.feed(3, at(500)), isTrue); // straight, held
      p.captured(3);
      expect(p.cue, 'left');
      expect(p.feed(12, at(600)), isFalse); // not far enough
      expect(p.feed(-30, at(700)), isFalse);
      expect(p.feed(-31, at(1200)), isTrue); // a clear turn, either way
      p.captured(-31);
      expect(p.feed(1, at(1300)), isFalse);
      expect(p.feed(1, at(1800)), isTrue);
      p.captured(1);
      expect(p.feed(-35, at(1900)), isFalse); // the same way again does not count
      expect(p.feed(-35, at(2600)), isFalse);
      expect(p.feed(33, at(2700)), isFalse);
      expect(p.feed(33, at(3200)), isTrue); // the other way
      p.captured(33);
      expect(p.done, isTrue);
    });

    test('moving out of the pose restarts the hold', () {
      final p = PoseSteps(['center']);
      expect(p.feed(0, at(0)), isFalse);
      expect(p.feed(20, at(300)), isFalse);
      expect(p.feed(0, at(400)), isFalse);
      expect(p.feed(0, at(800)), isFalse);
      expect(p.feed(0, at(900)), isTrue);
    });
  });
}
