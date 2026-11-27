import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A call to GET.eKYC failed.
class EkycApiException implements Exception {
  EkycApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'GET.eKYC ($statusCode): $message';
}

/// What the server says this verification needs. Everything the SDK shows
/// comes from here, so new steps and wording arrive without an app update.
class EkycSessionInfo {
  EkycSessionInfo(this.json);
  final Map<String, dynamic> json;

  String get verificationId => json['verification_id'] as String;
  String? get client => json['client'] as String?;
  String get state => json['state'] as String;
  bool get test => json['test'] == true;
  String? get documentName => json['document_name'] as String?;
  /// null: depends on the document (detected after the front photo).
  bool? get needsSelfie => json['needs_selfie'] as bool?;
  List<String> get livenessChallenge =>
      ((json['liveness_challenge'] as List?) ?? const []).cast<String>();
  bool get consentNeeded => json['consent_needed'] == true;
  String consentText(String lang) {
    final t = (json['consent_text'] as Map?)?.cast<String, dynamic>() ?? const {};
    return (t[lang] ?? t['en'] ?? '') as String;
  }
}

/// What the server recognised on the front of the document (no personal data).
class EkycDocument {
  EkycDocument(this.json);
  final Map<String, dynamic> json;
  String? get name => json['name'] as String?;
  bool? get needsSelfie => json['needs_selfie'] as bool?;
  bool get needsBack => json['needs_back'] == true;
  /// false: the photo could not be read clearly; suggest a retake.
  bool? get readable => json['readable'] as bool?;
}

class EkycStatus {
  EkycStatus(this.state, this.finished);
  final String state;
  final bool finished;
}

/// The hosted-session API. Authenticated by the one-time link only: the app
/// never holds the API key.
class EkycApi {
  EkycApi(String hostedUrl, {http.Client? client})
      : _http = client ?? http.Client(),
        _base = _parse(hostedUrl);

  final http.Client _http;
  final Uri _base;

  static Uri _parse(String hostedUrl) {
    final u = Uri.parse(hostedUrl.trim());
    final i = u.pathSegments.indexOf('v');
    if (!u.hasScheme || i < 0 || i + 1 >= u.pathSegments.length || u.pathSegments[i + 1].isEmpty) {
      throw ArgumentError('not a GET.eKYC hosted_url: $hostedUrl');
    }
    final prefix = u.pathSegments.sublist(0, i);
    return u.replace(pathSegments: [...prefix, 'v1', 'hosted', u.pathSegments[i + 1]], query: null, fragment: null);
  }

  /// The server's origin (scheme, host, port).
  String get origin => _base.origin;

  Uri _u([String path = '']) => _base.replace(path: _base.path + path);

  Future<Map<String, dynamic>> _send(http.BaseRequest req) async {
    final res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 90)));
    Map<String, dynamic> body = const {};
    try {
      body = (jsonDecode(utf8.decode(res.bodyBytes)) as Map).cast<String, dynamic>();
    } catch (_) {}
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final d = body['detail'];
      final msg = d is String ? d : (d is Map ? '${d['message'] ?? d}' : (res.reasonPhrase ?? 'error'));
      throw EkycApiException(res.statusCode, msg);
    }
    return body;
  }

  Future<EkycSessionInfo> info() async => EkycSessionInfo(await _send(http.Request('GET', _u())));

  Future<void> consent(String lang) async {
    final r = http.Request('POST', _u('/consent'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'accepted': true, 'lang': lang});
    await _send(r);
  }

  /// Uploads one JPEG. For the document front, returns what was recognised.
  Future<EkycDocument?> upload(String kind, Uint8List jpeg) async {
    final r = http.MultipartRequest('PUT', _u('/media/$kind'))
      ..files.add(http.MultipartFile.fromBytes('file', jpeg, filename: '$kind.jpg'));
    final out = await _send(r);
    final doc = out['document'];
    return doc is Map ? EkycDocument(doc.cast<String, dynamic>()) : null;
  }

  Future<void> submit() async {
    try {
      await _send(http.Request('POST', _u('/submit')));
    } on EkycApiException catch (e) {
      if (e.statusCode != 409) rethrow; // already submitted: fine
    }
  }

  Future<EkycStatus> status() async {
    final s = await _send(http.Request('GET', _u('/status')));
    return EkycStatus(s['state'] as String, s['finished'] == true);
  }

  void close() => _http.close();
}
