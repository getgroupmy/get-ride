import 'dart:io';

/// Whether [host] resolves within [timeout].
Future<bool> hostResolves(String host, Duration timeout) async {
  try {
    final found = await InternetAddress.lookup(host).timeout(timeout);
    return found.isNotEmpty;
  } catch (_) {
    return false;
  }
}
