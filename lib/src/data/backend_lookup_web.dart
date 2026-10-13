/// The browser resolves hosts itself and does not say; always true.
Future<bool> hostResolves(String host, Duration timeout) async => true;
