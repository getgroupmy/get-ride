// My QR (migration 0161): an account's personal QR codes.
//
//   GET.Referral  any account: scanning it opens sign-up with the owner's
//                 referral code.
//   GET.me        drivers: scanning it adds the driver as a My Ride favourite.
//   GET.now       drivers: scanning it books that driver directly — the
//                 request goes to them alone, with no automatic fallback.
//
// Each code is a random token; one is active per kind at a time. The owner
// can expire it, make a new one, or bring back one of their last ten (the
// same token works again), choosing an optional auto-expiry each time.
//
// The QR encodes `https://qr.getride.my/<ref|me|now>/<token>`. That host is
// an app link (Android App Links, iOS universal links — see
// docs/store-release.md), so a phone camera opens the installed app straight
// on the code, and a phone without the app lands on the web app, which serves
// the same paths. Codes printed before it encode
// `https://getride.my/q/<kind>/<token>`; that and
// `getride://<ref|me|now>/<token>` are still accepted. [parseGetQr] also
// recognises My Ride codes and wallet codes, so one scanner can route every
// GET code.
//
// Pure: the repository is lib/src/data/my_qr_repository.dart.
import 'my_ride.dart';
import 'referral.dart';
import 'wallet_qr.dart';

/// The host a QR's link is on: an app link on Android and iOS, and the web
/// app everywhere else.
const myQrHost = 'qr.getride.my';

/// Where a QR's web form lives: `https://qr.getride.my/<kind>/<token>`.
const myQrWebBase = 'https://$myQrHost/';

/// Where codes made before [myQrHost] point (`/q/<kind>/<token>` on the main
/// site). Still read when scanned, and still a route in the app.
const myQrLegacyWebBase = 'https://getride.my/q/';

/// The app-scheme form, accepted when scanned.
const myQrScheme = 'getride://';

final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{20,64}$');

/// Whether [s] can be a personal QR token (22 base64url characters as the
/// server makes them; 20–64 accepted).
bool isQrToken(String s) => _tokenPattern.hasMatch(s);

/// The three kinds of personal code.
enum QrKind {
  referral('referral', 'GET.Referral', 'ref'),
  me('me', 'GET.me', 'me'),
  now('now', 'GET.now', 'now');

  const QrKind(this.wire, this.label, this.pathSegment);

  /// As the database stores it.
  final String wire;

  /// As the app names it.
  final String label;

  /// Its segment in a payload (`qr.getride.my/<segment>/<token>`) and in the
  /// app's paths (`/<segment>/<token>`, `/q/<segment>/<token>`).
  final String pathSegment;

  /// GET.me and GET.now are for drivers only.
  bool get driverOnly => this != QrKind.referral;

  /// What scanning it does, for the My QR page.
  String get description => switch (this) {
    QrKind.referral => 'Friends who scan it sign up with your referral code.',
    QrKind.me => 'Passengers who scan it add you to their My Ride drivers.',
    QrKind.now => 'Passengers who scan it book you directly. The request comes to you only.',
  };

  /// From the database value or a payload segment; null for anything else.
  static QrKind? parse(Object? v) {
    final s = '${v ?? ''}'.trim().toLowerCase();
    for (final k in QrKind.values) {
      if (s == k.wire || s == k.pathSegment) return k;
    }
    return null;
  }
}

/// The kinds an account may hold: drivers all three, everyone else referral.
List<QrKind> qrKindsFor({required bool isPartner}) => isPartner ? QrKind.values : const [QrKind.referral];

/// What a code encodes. The web form by default, so a camera without the
/// app opens the web app.
String qrPayload(QrKind kind, String token, {bool web = true}) =>
    web ? '$myQrWebBase${kind.pathSegment}/$token' : '$myQrScheme${kind.pathSegment}/$token';

/// Where a code stands.
enum QrStatus {
  active,

  /// Ran out on its own (auto-expiry).
  expired,

  /// Expired by the owner, or replaced by a newer code.
  revoked;

  static QrStatus parse(Object? v) => switch (v) {
    'active' => QrStatus.active,
    'revoked' => QrStatus.revoked,
    _ => QrStatus.expired,
  };

  String get label => switch (this) {
    QrStatus.active => 'Active',
    QrStatus.expired => 'Expired',
    QrStatus.revoked => 'Turned off',
  };
}

/// The auto-expiry choices offered when a code is made or brought back.
enum QrTtl {
  hour(3600, '1 hour'),
  day(86400, '24 hours'),
  week(604800, '7 days'),
  never(null, 'Never');

  const QrTtl(this.seconds, this.label);

  /// What the server takes (`p_ttl_seconds`); null = never.
  final int? seconds;
  final String label;
}

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

/// One of the account's codes (`my_qr_codes()`, or the `qr` of a reply).
class PersonalQr {
  const PersonalQr({
    required this.id,
    required this.kind,
    required this.token,
    required this.status,
    this.createdAt,
    this.expiresAt,
    this.revokedAt,
    this.lastActivatedAt,
    this.reactivatable = false,
  });

  final String id;
  final QrKind kind;
  final String token;
  final QrStatus status;
  final DateTime? createdAt;

  /// When it runs out on its own; null = never.
  final DateTime? expiresAt;
  final DateTime? revokedAt;

  /// When it was last made or brought back.
  final DateTime? lastActivatedAt;

  /// Whether it can be brought back (not active, among the last ten).
  final bool reactivatable;

  /// Active as the server last said, and not run out since.
  bool isActiveAt(DateTime now) => status == QrStatus.active && (expiresAt == null || expiresAt!.isAfter(now));

  /// What the QR encodes.
  String get payload => qrPayload(kind, token);

  /// Null for a row that isn't one (unknown kind, no id or token).
  static PersonalQr? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = QrKind.parse(json['kind']);
    final id = _s(json['id']);
    final token = _s(json['token']);
    if (kind == null || id == null || token == null) return null;
    return PersonalQr(
      id: id,
      kind: kind,
      token: token,
      status: QrStatus.parse(json['status']),
      createdAt: _date(json['created_at']),
      expiresAt: _date(json['expires_at']),
      revokedAt: _date(json['revoked_at']),
      lastActivatedAt: _date(json['last_activated_at']),
      reactivatable: json['reactivatable'] == true,
    );
  }
}

/// The active code of [kind] in [codes] at [now], if any.
PersonalQr? activeQr(Iterable<PersonalQr> codes, QrKind kind, DateTime now) {
  for (final c in codes) {
    if (c.kind == kind && c.isActiveAt(now)) return c;
  }
  return null;
}

/// Earlier codes of [kind] (not active at [now]), newest first.
List<PersonalQr> qrHistory(Iterable<PersonalQr> codes, QrKind kind, DateTime now) {
  final list = [
    for (final c in codes)
      if (c.kind == kind && !c.isActiveAt(now)) c,
  ];
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  list.sort((a, b) => (b.lastActivatedAt ?? b.createdAt ?? epoch).compareTo(a.lastActivatedAt ?? a.createdAt ?? epoch));
  return list;
}

/// "Never expires" / "Expires in 45 min" / "Expires in 3 h" / "Expires in
/// 2 days" / "Expired".
String qrExpiryText(DateTime? expiresAt, DateTime now) {
  if (expiresAt == null) return 'Never expires';
  final left = expiresAt.difference(now);
  if (left <= Duration.zero) return 'Expired';
  if (left < const Duration(hours: 1)) {
    final m = (left.inSeconds / 60).ceil();
    return 'Expires in $m min';
  }
  if (left < const Duration(hours: 48)) {
    final h = (left.inMinutes / 60).ceil();
    return 'Expires in $h h';
  }
  final d = (left.inHours / 24).ceil();
  return 'Expires in $d days';
}

/// The status line under a code: "Active · Expires in 3 h", "Expired",
/// "Turned off".
String qrStatusText(PersonalQr qr, DateTime now) {
  if (qr.isActiveAt(now)) return '${QrStatus.active.label} · ${qrExpiryText(qr.expiresAt, now)}';
  return qr.status == QrStatus.revoked ? QrStatus.revoked.label : QrStatus.expired.label;
}

// ---- Scanning ----------------------------------------------------------------------

/// What a scanned GET code is.
sealed class GetQrScan {
  const GetQrScan();
}

/// A personal code (GET.Referral / GET.me / GET.now): resolve it with
/// `resolve_qr` before acting on it.
class PersonalQrScan extends GetQrScan {
  const PersonalQrScan(this.kind, this.token);
  final QrKind kind;
  final String token;
}

/// A driver's My Ride code (`getride://myride/<CODE>`, or a bare code).
class MyRideCodeScan extends GetQrScan {
  const MyRideCodeScan(this.code);
  final String code;
}

/// A GET account's wallet code (`getpay://u/<id>`).
class WalletCodeScan extends GetQrScan {
  const WalletCodeScan(this.account);
  final GetAccountQr account;
}

/// An invite link (`https://getride.my/?ref=CODE`).
class ReferralLinkScan extends GetQrScan {
  const ReferralLinkScan(this.code);
  final String code;
}

/// Anything else (a merchant's code, a web link, text).
class OtherQrScan extends GetQrScan {
  const OtherQrScan(this.text);
  final String text;
}

bool _isGetRideHost(String host) {
  final h = host.toLowerCase();
  return h == 'getride.my' || h == 'www.getride.my';
}

/// The personal code in [raw], or null. Accepts
/// `https://qr.getride.my/<kind>/<token>`, the older
/// `https://getride.my/q/<kind>/<token>` (http and www too) and
/// `getride://<kind>/<token>`, with or without a trailing slash or query.
/// A bare token is not one: it doesn't say which kind of code it is.
PersonalQrScan? parsePersonalQr(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  final web = scheme == 'https' || scheme == 'http';
  List<String> segs;
  if (scheme == 'getride') {
    // getride://now/<token>: the kind is the host.
    segs = [uri.host, ...uri.pathSegments];
  } else if (web && uri.host.toLowerCase() == myQrHost) {
    segs = uri.pathSegments;
  } else if (web && _isGetRideHost(uri.host)) {
    final p = uri.pathSegments;
    if (p.isEmpty || p.first.toLowerCase() != 'q') return null;
    segs = p.sublist(1);
  } else {
    return null;
  }
  segs = [
    for (final s in segs)
      if (s.isNotEmpty) s,
  ];
  if (segs.length != 2) return null;
  final kind = QrKind.parse(segs[0]);
  final token = segs[1];
  if (kind == null || !isQrToken(token)) return null;
  return PersonalQrScan(kind, token);
}

/// Whether [location] (an app path) is a personal code's link page:
/// `/q/<kind>/<token>`, or `/<kind>/<token>` as an app link on
/// [myQrHost] arrives. These open signed out too.
bool isQrLinkLocation(String location) {
  if (location.startsWith('/q/')) return true;
  final segs = location.split('?').first.split('/').where((s) => s.isNotEmpty).toList();
  return segs.length == 2 && QrKind.values.any((k) => k.pathSegment == segs.first);
}

/// Where the app should go for a `getride://<kind>/<token>` link opened from
/// outside (the router gets the whole URI; its path alone would lose the
/// kind, which is the URI's host): `/q/<kind>/<token>`, which the link page
/// then checks. Null for anything else, including the https links, whose
/// path already is a route.
String? qrSchemeLinkLocation(Uri uri) {
  if (uri.scheme.toLowerCase() != 'getride') return null;
  final kind = QrKind.parse(uri.host);
  final rest = [
    for (final s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  if (kind == null || rest.length != 1) return null;
  return '/q/${kind.pathSegment}/${Uri.encodeComponent(rest.single)}';
}

/// Reads any scanned GET code; null for an empty one.
GetQrScan? parseGetQr(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final personal = parsePersonalQr(text);
  if (personal != null) return personal;
  final myRide = parseMyRideCode(text);
  if (myRide != null) return MyRideCodeScan(myRide);
  if (text.toLowerCase().startsWith(walletQrScheme)) {
    final wallet = parseWalletQr(text);
    if (wallet is GetAccountQr) return WalletCodeScan(wallet);
  }
  final uri = Uri.tryParse(text);
  if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && _isGetRideHost(uri.host)) {
    final code = referralCodeFromUri(uri);
    if (code != null) return ReferralLinkScan(code);
  }
  return OtherQrScan(text);
}

// ---- What a code resolves to (`resolve_qr`) -------------------------------------------

sealed class QrResolution {
  const QrResolution();

  factory QrResolution.fromJson(Object? json) {
    final m = json is Map ? Map<String, dynamic>.from(json) : const <String, dynamic>{};
    final kind = QrKind.parse(m['kind']);
    switch (m['status']) {
      case 'active' when kind != null:
        final d = m['driver'];
        return QrActive(
          kind: kind,
          referralCode: _s(m['referral_code']),
          ownerName: _s(m['owner_name']),
          driver: d is Map
              ? FavouriteDriver.fromRow({
                  ...Map<String, dynamic>.from(d),
                  'available': m['available'] == true,
                  'online': m['online'] == true,
                })
              : null,
          own: m['own'] == true,
          available: m['available'] != false,
          online: m['online'] == true,
          alreadyFavourite: m['already_favourite'] == true,
        );
      case 'sign_in_required' when kind != null:
        return QrSignInRequired(kind);
      case 'expired':
        return const QrExpired();
      case 'rate_limited':
        final wait = m['retry_after'];
        final secs = wait is num ? wait.toInt() : int.tryParse('$wait');
        return QrRateLimited(secs != null && secs > 0 ? Duration(seconds: secs) : null);
      default:
        return const QrUnknown();
    }
  }
}

/// A live code. [referralCode] / [ownerName] for GET.Referral (the name
/// masked, "Ahmad A."; absent for a caller who isn't signed in); [driver]
/// for GET.me / GET.now (what a rider sees of a driver — never a phone).
class QrActive extends QrResolution {
  const QrActive({
    required this.kind,
    this.referralCode,
    this.ownerName,
    this.driver,
    this.own = false,
    this.available = true,
    this.online = false,
    this.alreadyFavourite = false,
  });

  final QrKind kind;
  final String? referralCode;
  final String? ownerName;
  final FavouriteDriver? driver;

  /// The caller's own code.
  final bool own;

  /// GET.me / GET.now: false when the driver can't take rides (or hid the
  /// caller); the two read alike on purpose.
  final bool available;

  /// GET.now: the driver is online now.
  final bool online;

  /// GET.me: the driver is already one of the caller's favourites.
  final bool alreadyFavourite;
}

/// A driver's code scanned by someone who isn't signed in.
class QrSignInRequired extends QrResolution {
  const QrSignInRequired(this.kind);
  final QrKind kind;
}

/// Expired, turned off or replaced. Nothing about its owner is told.
class QrExpired extends QrResolution {
  const QrExpired();
}

/// No such code.
class QrUnknown extends QrResolution {
  const QrUnknown();
}

/// Too many unknown codes tried.
class QrRateLimited extends QrResolution {
  const QrRateLimited(this.retryAfter);
  final Duration? retryAfter;
}

/// The database doesn't have My QR yet (migration 0161 not applied).
class QrNotAvailable extends QrResolution {
  const QrNotAvailable();
}

/// What to tell someone about a code that isn't live.
String qrResolutionMessage(QrResolution r) => switch (r) {
  QrActive() => '',
  QrSignInRequired(:final kind) =>
    kind == QrKind.now ? 'Sign in to book this driver.' : 'Sign in to add this driver to My Ride.',
  QrExpired() => 'This code has expired. Ask for a new one.',
  QrUnknown() => "This code isn't a GET.ride code.",
  QrRateLimited() => 'Too many codes tried. Please wait a while and try again.',
  QrNotAvailable() => "This code can't be read yet. Please try again later.",
};

// ---- Making, expiring and reviving codes -----------------------------------------------

/// Why a code was not made, expired or revived.
enum MyQrError {
  invalidKind,
  invalidTtl,
  notADriver,
  driverUnavailable,
  noProfile,
  notFound,
  notReactivatable,
  rateLimited,
  unknown;

  static MyQrError parse(Object? v) => switch (v) {
    'invalid_kind' => MyQrError.invalidKind,
    'invalid_ttl' => MyQrError.invalidTtl,
    'not_a_driver' => MyQrError.notADriver,
    'driver_unavailable' => MyQrError.driverUnavailable,
    'no_profile' => MyQrError.noProfile,
    'not_found' => MyQrError.notFound,
    'not_reactivatable' => MyQrError.notReactivatable,
    'rate_limited' => MyQrError.rateLimited,
    _ => MyQrError.unknown,
  };

  String get message => switch (this) {
    MyQrError.invalidKind || MyQrError.unknown => "Couldn't update the code. Please try again.",
    MyQrError.invalidTtl => 'Pick when the code should expire.',
    MyQrError.notADriver => 'GET.me and GET.now codes are for drivers.',
    MyQrError.driverUnavailable => "Your driver account can't use this code right now.",
    MyQrError.noProfile => 'Finish setting up your account first.',
    MyQrError.notFound => 'That code was not found.',
    MyQrError.notReactivatable => 'Only your last 10 codes can be used again. Make a new one instead.',
    MyQrError.rateLimited => 'Too many changes. Please wait a while and try again.',
  };
}

/// What making / expiring / reviving a code came to.
sealed class MyQrResult {
  const MyQrResult();

  factory MyQrResult.fromJson(Object? json) {
    final m = json is Map ? Map<String, dynamic>.from(json) : const <String, dynamic>{};
    final qr = PersonalQr.fromJson(m['qr']);
    if (m['ok'] == true && qr != null) return MyQrDone(qr);
    final wait = m['retry_after'];
    final secs = wait is num ? wait.toInt() : int.tryParse('$wait');
    return MyQrRefused(
      MyQrError.parse(m['error']),
      retryAfter: secs != null && secs > 0 ? Duration(seconds: secs) : null,
    );
  }
}

class MyQrDone extends MyQrResult {
  const MyQrDone(this.qr);
  final PersonalQr qr;
}

class MyQrRefused extends MyQrResult {
  const MyQrRefused(this.error, {this.retryAfter});
  final MyQrError error;
  final Duration? retryAfter;
}

/// The database doesn't have My QR yet.
class MyQrNotAvailable extends MyQrResult {
  const MyQrNotAvailable();
}

// ---- Booking with a GET.now code ---------------------------------------------------------

/// Why a GET.now booking was refused. Nothing was stored and no driver told.
enum QrBookingFailure {
  /// The code has expired (or isn't a live GET.now code): `QR_EXPIRED`.
  expired,

  /// The rider scanned their own code: `QR_SELF_BOOKING`.
  selfBooking,

  /// The driver can't take rides right now: `QR_DRIVER_UNAVAILABLE`.
  driverUnavailable,

  /// The database can't book by code yet (migration 0161 not applied).
  notAvailable,
}

/// A GET.now booking the database refused.
class QrBookingError implements Exception {
  const QrBookingError(this.reason);
  final QrBookingFailure reason;

  /// The refusal in a database error message, or null for any other error.
  static QrBookingError? parse(String? message) {
    final m = message ?? '';
    if (m.contains('QR_EXPIRED')) return const QrBookingError(QrBookingFailure.expired);
    if (m.contains('QR_SELF_BOOKING')) return const QrBookingError(QrBookingFailure.selfBooking);
    if (m.contains('QR_DRIVER_UNAVAILABLE')) return const QrBookingError(QrBookingFailure.driverUnavailable);
    return null;
  }

  @override
  String toString() => switch (reason) {
    QrBookingFailure.expired => 'This GET.now code has expired. Ask the driver for their current code.',
    QrBookingFailure.selfBooking => "You can't book yourself with your own GET.now code.",
    QrBookingFailure.driverUnavailable => "This driver can't take rides right now.",
    QrBookingFailure.notAvailable => "Booking a driver by QR isn't available yet. Please try again later.",
  };
}

/// The codes shown under a QR on My QR, to read out, type or paste: the
/// QR's own code (what it carries, accepted wherever a scan is), and the
/// short code people type for the same thing: the referral code under
/// GET.Referral, the My Ride code under GET.me.
List<({String id, String label, String value})> myQrCodeRows(
  PersonalQr qr, {
  String? referralCode,
  String? myRideCode,
}) {
  final rows = <({String id, String label, String value})>[];
  final ref = referralCode?.trim() ?? '';
  final ride = myRideCode?.trim() ?? '';
  if (qr.kind == QrKind.referral && ref.isNotEmpty) rows.add((id: 'referral', label: 'Referral code', value: ref));
  if (qr.kind == QrKind.me && ride.isNotEmpty) {
    rows.add((id: 'my-ride', label: 'My Ride code', value: formatMyRideCode(ride)));
  }
  rows.add((id: 'qr', label: '${qr.kind.label} code', value: qr.token));
  return rows;
}
