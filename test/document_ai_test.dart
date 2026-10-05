import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/core/document_ai.dart';

DocumentAiResult _result({
  bool matches = true,
  String? number = 'D1234567',
  List<String> numbers = const ['D1234567', 'REF-9'],
  String? start = '2024-01-31',
  String? expiry = '2029-01-31',
  String? insurer = 'Etiqa General Takaful',
  bool? pwd = false,
}) => DocumentAiResult({
  'isReal': true,
  'isRelevant': matches,
  'matchesTitle': matches,
  'detectedTitle': 'Malaysian Driving Licence',
  'confidence': 0.87,
  'reason': 'Looks genuine.',
  'extracted': {
    'documentNumber': number,
    'documentNumbers': numbers,
    'startDate': start,
    'expiryDate': expiry,
    'insuranceProviderName': insurer,
    'isPwd': pwd,
    'issuanceCountry': 'Malaysia',
    'documentName': null,
  },
  'rawText': '{}',
  'verifiedAt': '2026-10-05T03:00:00.000Z',
});

void main() {
  test('reads the function answer', () {
    final ok = parseDocAiResponse({'ok': true, 'result': _result().raw});
    expect(ok.result!.matchesTitle, isTrue);
    expect(ok.result!.confidence, 0.87);
    expect(ok.result!.candidateNumbers, ['D1234567', 'REF-9']);
    expect(ok.result!.detectedDocumentName, 'Malaysian Driving Licence', reason: 'falls back to the AI label');
    expect(ok.result!.issuanceCountry, 'Malaysia');

    final none = parseDocAiResponse(jsonEncode({'ok': true, 'result': null, 'reason': 'no_keys'}));
    expect(none.result, isNull);
    expect(none.reason, 'no_keys');
    expect(parseDocAiResponse('garbage').reason, 'bad_response');
    expect(parseDocAiResponse({'ok': false, 'error': 'front: image is too large'}).reason, 'front: image is too large');
  });

  test('request body: data URLs and only the prompt fields', () {
    expect(imageMimeFor('ID.JPG'), 'image/jpeg');
    expect(imageMimeFor('scan.heic'), isNull);
    final url = imageDataUrl(Uint8List.fromList([1, 2, 3]), 'image/png');
    expect(url, 'data:image/png;base64,AQID');
    final body = docAiRequestBody(
      frontDataUrl: url,
      docName: 'Driving Licence',
      documentNumber: '  ',
      expiryDate: '2029-01-31',
    );
    expect(body.containsKey('back'), isFalse);
    expect(body['context'], {
      'docName': 'Driving Licence',
      'documentNumber': null,
      'insuranceProviderName': null,
      'isPwd': false,
      'startDate': null,
      'expiryDate': '2029-01-31',
    });
  });

  test('auto-fill only what is asked for and still blank', () {
    const insurers = [(id: 'i1', name: 'Allianz'), (id: 'i2', name: 'Etiqa General Takaful')];
    final fill = docAiAutofill(
      _result(pwd: true),
      requireDocumentNumber: true,
      requireStartDate: false,
      requireExpiryDate: true,
      requireInsuranceProvider: true,
      pwdFlag: true,
      documentNumber: '',
      startDate: '',
      expiryDate: '2030-12-31',
      insurerId: null,
      isPwd: false,
      insurers: insurers,
    );
    expect(fill.documentNumber, 'D1234567');
    expect(fill.startDate, isNull, reason: 'not required');
    expect(fill.expiryDate, isNull, reason: 'never overwrites a typed value');
    expect(fill.insurerId, 'i2');
    expect(fill.isPwd, isTrue);
    expect(fill.filled, ['Document number (multiple found)', 'Insurance provider', 'PWD flag']);

    final none = docAiAutofill(
      _result(insurer: 'Unknown Mutual'),
      requireDocumentNumber: true,
      requireStartDate: true,
      requireExpiryDate: true,
      requireInsuranceProvider: true,
      pwdFlag: false,
      documentNumber: 'TYPED',
      startDate: '2020-01-01',
      expiryDate: '2030-01-01',
      insurerId: null,
      isPwd: false,
      insurers: const [(id: 'i1', name: 'Allianz')],
    );
    expect(none.filled, isEmpty);
  });

  test('the stored row carries the verdict like Expo', () {
    Map<String, dynamic> payload({Map<String, dynamic>? ai}) => providerDocPayload(
      partnerId: 'p1',
      authUserId: 'u1',
      docId: 'd1',
      docName: 'Driving Licence',
      flags: const DocFlags(requireDocumentNumber: true),
      documentNumber: 'D1',
      insuranceProviderId: null,
      insuranceProviderName: null,
      isPwd: false,
      startDate: '',
      expiryDate: '',
      fileUrl: 'https://x/front.jpg',
      fileUrlBack: null,
      uploadedAt: '2026-10-05T00:00:00Z',
      aiVerification: ai,
      issuanceCountry: ai == null ? null : 'Malaysia',
      detectedDocumentName: ai == null ? null : 'Driving Licence',
    );
    final without = payload();
    expect(without['ai_verification'], isNull);
    expect(without['ai_verified'], isNull);
    final flagged = payload(ai: _result(matches: false).raw);
    expect(flagged['ai_verified'], isFalse);
    expect(flagged['issuance_country'], 'Malaysia');
    expect(flagged['status'], 'Pending Review', reason: 'a verdict never approves anything');
  });

  test('unavailable reasons read plainly', () {
    expect(docAiUnavailableText('no_keys'), contains('not set up'));
    expect(docAiUnavailableText('not_deployed'), contains('not available yet'));
    expect(docAiUnavailableText(null), contains('admin will review'));
  });
}
