// My QR — personal QR codes (lib/src/core/my_qr.dart; migration 0161).
// Every call goes through the server's functions; on a database without them
// each one answers "not available" (null or a dedicated variant) instead of
// throwing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/my_qr.dart';
import '../core/my_ride.dart';
import '../providers.dart' show supabaseProvider, currentUserIdProvider;

class MyQrRepository {
  MyQrRepository(this._db);
  final SupabaseClient _db;

  /// The signed-in account's codes: active first, then earlier ones newest
  /// first (at most 20 per kind). Null on a database without My QR.
  Future<List<PersonalQr>?> codes() async {
    try {
      final rows = await _db.rpc('my_qr_codes');
      return [for (final r in rows is List ? rows : const []) ?PersonalQr.fromJson(r)];
    } on PostgrestException catch (e) {
      if (isMissingMyQr(e)) return null;
      rethrow;
    }
  }

  /// A new code of [kind], retiring the active one; it runs out after
  /// [ttl] (never by default).
  Future<MyQrResult> generate(QrKind kind, {QrTtl ttl = QrTtl.never}) =>
      _call('generate_my_qr', {'p_kind': kind.wire, 'p_ttl_seconds': ttl.seconds});

  /// Turns a code off now.
  Future<MyQrResult> expire(String id) => _call('expire_my_qr', {'p_id': id});

  /// Brings back an earlier code (one of the last ten of its kind): the same
  /// token works again and the active one of its kind is retired.
  Future<MyQrResult> reactivate(String id, {QrTtl ttl = QrTtl.never}) =>
      _call('reactivate_my_qr', {'p_id': id, 'p_ttl_seconds': ttl.seconds});

  Future<MyQrResult> _call(String fn, Map<String, dynamic> params) async {
    try {
      return MyQrResult.fromJson(await _db.rpc(fn, params: params));
    } on PostgrestException catch (e) {
      if (isMissingMyQr(e)) return const MyQrNotAvailable();
      rethrow;
    }
  }

  /// What a scanned personal code (payload or bare token) is. Works signed
  /// out too, where a GET.Referral code gives its referral code and a
  /// driver's code asks to sign in.
  Future<QrResolution> resolve(String scanned) async {
    try {
      return QrResolution.fromJson(await _db.rpc('resolve_qr', params: {'p_token': scanned.trim()}));
    } on PostgrestException catch (e) {
      if (isMissingMyQr(e)) return const QrNotAvailable();
      rethrow;
    }
  }

  /// Adds the driver whose GET.me code was scanned as a My Ride favourite,
  /// with My Ride's own rules and limits.
  Future<AddFavouriteResult> addFavouriteByQr(String scanned) async {
    try {
      return AddFavouriteResult.fromJson(
        await _db.rpc('add_favourite_driver_by_qr', params: {'p_token': scanned.trim()}),
      );
    } on PostgrestException catch (e) {
      if (isMissingMyQr(e)) return const MyRideNotAvailable();
      rethrow;
    }
  }
}

/// A database without migration 0161: the function (PostgREST schema cache
/// or Postgres), the table or a column isn't there.
bool isMissingMyQr(PostgrestException e) =>
    e.code == 'PGRST202' ||
    e.code == '42883' ||
    e.code == 'PGRST205' ||
    e.code == '42P01' ||
    e.code == '42703' ||
    e.message.contains('Could not find the function');

final myQrRepositoryProvider = Provider((ref) => MyQrRepository(ref.watch(supabaseProvider)));

/// The signed-in account's codes; null when My QR isn't available. Refresh
/// with `ref.invalidate` after making, expiring or reviving one.
final myQrCodesProvider = FutureProvider.autoDispose<List<PersonalQr>?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const [];
  return ref.watch(myQrRepositoryProvider).codes();
});

/// What a scanned code resolves to (keyed by the scanned text); read again
/// when the account signs in or out, as the answer depends on who asks.
final qrResolutionProvider = FutureProvider.autoDispose.family<QrResolution, String>((ref, scanned) {
  ref.watch(currentUserIdProvider);
  return ref.watch(myQrRepositoryProvider).resolve(scanned);
});
