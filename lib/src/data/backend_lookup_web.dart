import 'package:http/http.dart' as http;

/// The browser resolves hosts itself and does not say; always true.
Future<bool> hostResolves(String host, Duration timeout) async => true;

/// Not used on the web: the browser does its own lookups.
Future<List<String>> dohLookup(String host, List<String> resolvers, Duration timeout) async => const [];

/// The browser chooses where to connect; a plain client.
http.Client pinnedHttpClient(String host, String ip) => http.Client();
