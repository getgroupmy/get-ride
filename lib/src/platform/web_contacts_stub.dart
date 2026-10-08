/// Not a browser: no web contact picker.
bool webContactsSupported() => false;

/// Never called off the web.
Future<({String? name, List<String> numbers})?> pickWebContact() async => null;
