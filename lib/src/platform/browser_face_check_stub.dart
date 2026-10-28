/// No in-browser face check outside a browser.
const browserFaceCheckSupported = false;

/// Never called here: [browserFaceCheckSupported] is false.
Future<({String state, double? score})?> browserFaceCompare(String selfieUrl, String cardUrl) async => null;
