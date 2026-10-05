/// AI check of an uploaded document — the client half of the
/// `document-ai-verify` edge function (getgroupmy/get.ride). The function
/// owns the prompt and the provider; this side builds the request, reads the
/// verdict, and fills in what the partner left blank (Expo
/// `DocumentUploadModal.runAiVerification`). Pure: see test/document_ai_test.dart.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The function refuses images above this (after decoding).
const docAiMaxImageBytes = 4 * 1024 * 1024;

/// What the AI read and decided. [raw] is stored as-is in
/// `ai_verification`, the same shape the Expo app stores.
class DocumentAiResult {
  DocumentAiResult(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> get _ex => (raw['extracted'] as Map?)?.cast<String, dynamic>() ?? const {};
  static String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

  bool get matchesTitle => raw['matchesTitle'] == true;
  bool get isReal => raw['isReal'] == true;
  bool get isRelevant => raw['isRelevant'] == true;
  double get confidence => (raw['confidence'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 0;
  String get reason => _s(raw['reason']) ?? '';
  String get detectedTitle => _s(raw['detectedTitle']) ?? '';
  String? get documentNumber => _s(_ex['documentNumber']);
  List<String> get documentNumbers => [
    for (final v in (_ex['documentNumbers'] as List?) ?? const [])
      if (_s(v) != null) _s(v)!,
  ];
  String? get startDate => _s(_ex['startDate']);
  String? get expiryDate => _s(_ex['expiryDate']);
  String? get insuranceProviderName => _s(_ex['insuranceProviderName']);
  bool? get isPwd => _ex['isPwd'] is bool ? _ex['isPwd'] as bool : null;
  String? get issuanceCountry => _s(_ex['issuanceCountry']);

  /// `detected_document_name`: the name printed on it, else the AI's label.
  String? get detectedDocumentName => _s(_ex['documentName']) ?? _s(raw['detectedTitle']);

  /// Every distinct number it read, the primary one first.
  List<String> get candidateNumbers => {?documentNumber, ...documentNumbers}.toList();
}

/// Reads the function's answer: the result, or null with why there is none.
({DocumentAiResult? result, String? reason}) parseDocAiResponse(Object? data) {
  final m = data is Map ? data : (data is String ? _tryJson(data) : null);
  if (m == null) return (result: null, reason: 'bad_response');
  final r = m['result'];
  if (r is Map) return (result: DocumentAiResult(r.cast<String, dynamic>()), reason: null);
  return (result: null, reason: m['reason'] as String? ?? (m['ok'] == false ? '${m['error']}' : 'no_result'));
}

Map? _tryJson(String s) {
  try {
    final v = jsonDecode(s);
    return v is Map ? v : null;
  } catch (_) {
    return null;
  }
}

String? imageMimeFor(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.webp')) return 'image/webp';
  return null;
}

String imageDataUrl(Uint8List bytes, String mime) => 'data:$mime;base64,${base64Encode(bytes)}';

/// The function's request body (only the fields the prompt uses).
Map<String, dynamic> docAiRequestBody({
  required String frontDataUrl,
  String? backDataUrl,
  required String docName,
  String? documentNumber,
  String? insuranceProviderName,
  bool isPwd = false,
  String? startDate,
  String? expiryDate,
}) {
  String? blank(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
  return {
    'front': frontDataUrl,
    'back': ?backDataUrl,
    'context': {
      'docName': docName,
      'documentNumber': blank(documentNumber),
      'insuranceProviderName': blank(insuranceProviderName),
      'isPwd': isPwd,
      'startDate': blank(startDate),
      'expiryDate': blank(expiryDate),
    },
  };
}

/// What the AI can fill in on the form. Only fields the requirement asks for
/// and the partner has not filled already — a typed value is never replaced.
({String? documentNumber, String? startDate, String? expiryDate, String? insurerId, bool? isPwd, List<String> filled})
docAiAutofill(
  DocumentAiResult r, {
  required bool requireDocumentNumber,
  required bool requireStartDate,
  required bool requireExpiryDate,
  required bool requireInsuranceProvider,
  required bool pwdFlag,
  required String documentNumber,
  required String startDate,
  required String expiryDate,
  required String? insurerId,
  required bool isPwd,
  required List<({String id, String name})> insurers,
}) {
  final filled = <String>[];
  String? number, start, expiry, insurer;
  bool? pwd;
  if (requireDocumentNumber && documentNumber.trim().isEmpty && r.documentNumber != null) {
    number = r.documentNumber;
    filled.add(r.candidateNumbers.length > 1 ? 'Document number (multiple found)' : 'Document number');
  }
  if (requireStartDate && startDate.trim().isEmpty && r.startDate != null) {
    start = r.startDate;
    filled.add('Start date');
  }
  if (requireExpiryDate && expiryDate.trim().isEmpty && r.expiryDate != null) {
    expiry = r.expiryDate;
    filled.add('Expiry date');
  }
  final readInsurer = r.insuranceProviderName?.toLowerCase();
  if (requireInsuranceProvider && insurerId == null && readInsurer != null) {
    for (final p in insurers) {
      final name = p.name.toLowerCase().trim();
      if (name.isEmpty) continue;
      if (name == readInsurer || name.contains(readInsurer) || readInsurer.contains(name)) {
        insurer = p.id;
        filled.add('Insurance provider');
        break;
      }
    }
  }
  if (pwdFlag && !isPwd && r.isPwd == true) {
    pwd = true;
    filled.add('PWD flag');
  }
  return (documentNumber: number, startDate: start, expiryDate: expiry, insurerId: insurer, isPwd: pwd, filled: filled);
}

/// Why there is no verdict, in words for the partner.
String docAiUnavailableText(String? reason) => switch (reason) {
  'disabled' || 'no_keys' || 'provider_no_vision' => 'AI checks are not set up. An admin will review it.',
  'image_too_large' => 'The photo is too large to check automatically. An admin will review it.',
  'not_deployed' => 'AI checks are not available yet. An admin will review it.',
  'signed_out' => 'Sign in again to check documents automatically. An admin will review it.',
  _ => "Couldn't check it automatically. An admin will review it.",
};
