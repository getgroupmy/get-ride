// The browser's Contact Picker API (`navigator.contacts.select`), where the
// browser has it: Chrome and Edge on Android. Safari on iPhone does not offer
// it to web pages (only behind an experimental setting), so there
// [webContactsSupported] is false and the app's own iOS build picks instead.
export 'web_contacts_stub.dart' if (dart.library.js_interop) 'web_contacts_web.dart';
