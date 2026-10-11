// A push that reaches the phone while the app is closed is acknowledged from
// the background handler (reliability Phase C), so the server stops resending
// it and a chat message shows two ticks to its sender as soon as it lands,
// not when the app is next opened (ack_notification, migrations 0144/0146).
//
// It runs in Firebase's background isolate, with nothing of the app started:
// no Supabase client, just the stored session's access token and one REST
// call. An expired token is left alone (the app refreshes it on open, and the
// push is acknowledged then).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../core/push_logic.dart';

Future<void> ackPushInBackground(Map<String, dynamic> data, {http.Client? client}) async {
  final id = pushEventId(data);
  if (id == null) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    // The app may have refreshed the session since this isolate last read it.
    await prefs.reload();
    final token = storedAccessToken(prefs.getString(supabaseSessionKey(AppConfig.supabaseUrl)), DateTime.now());
    if (token == null) return;
    final base = AppConfig.supabaseUrl.trim().replaceFirst(RegExp(r'/$'), '');
    final c = client ?? http.Client();
    try {
      await c
          .post(
            Uri.parse('$base/rest/v1/rpc/ack_notification'),
            headers: {
              'apikey': AppConfig.supabaseAnonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'p_event_id': id, 'p_state': 'delivered'}),
          )
          .timeout(const Duration(seconds: 10));
    } finally {
      if (client == null) c.close();
    }
  } catch (_) {
    // Best effort: the outbox resends once and the app acknowledges on open.
  }
}
