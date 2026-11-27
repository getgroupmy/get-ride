// GET.eKYC (migration 0439): the admin's switches, starting a check on the
// server (ekyc-start, which holds the API key) and waiting for its result
// (ekyc-webhook writes it; the person may read their own session).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ekyc.dart';
import '../providers.dart';

/// The switches, re-read when invalidated. Off on any error, so the usual
/// photo-and-selfie flow is used.
final ekycConfigProvider = FutureProvider<EkycConfig>((ref) async {
  try {
    return EkycConfig.fromJson(await ref.watch(supabaseProvider).rpc('ekyc_config'));
  } catch (_) {
    return EkycConfig.off;
  }
});

final ekycRepositoryProvider = Provider<EkycRepository>((ref) => EkycRepository(ref));

class EkycRepository {
  EkycRepository(this._ref);
  final Ref _ref;

  /// A one-time page for the signed-in person. Throws with the function's
  /// error code when refused.
  Future<({String url, String sessionId})> start(String purpose) async {
    final res = await _ref.read(supabaseProvider).functions.invoke('ekyc-start', body: {'purpose': purpose});
    final started = parseEkycStart(res.data);
    if (started == null) throw StateError('ekyc-start: ${res.data}');
    return started;
  }

  /// Waits (up to [timeout]) for the webhook to record the result. Returns
  /// the session's state: 'completed', 'failed' or still 'started'.
  Future<String> waitForResult(String sessionId, {Duration timeout = const Duration(seconds: 20)}) async {
    final db = _ref.read(supabaseProvider);
    final until = DateTime.now().add(timeout);
    var state = 'started';
    while (DateTime.now().isBefore(until)) {
      try {
        final row = await db.from('ekyc_sessions').select('state').eq('id', sessionId).maybeSingle();
        state = (row?['state'] as String?) ?? state;
        if (state != 'started') return state;
      } catch (_) {
        // a blip: try again
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return state;
  }

  Future<EkycConfig> setConfig(EkycConfig c) async =>
      EkycConfig.fromJson(await _ref.read(supabaseProvider).rpc('set_ekyc_config', params: {'p': c.toJson()}));
}
