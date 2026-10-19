// Partner statements and the Earnings page (migration 0201): the server's
// totals, the statements list, the PDF from the `partner-statement`
// function (kept on the device so a statement opens offline), the payout
// account, and Admin → Settings → Partner statements.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/driver_earnings.dart' show EarningsPeriod;
import '../core/partner_statement.dart';
import '../core/statement_layout.dart';
import '../providers.dart';
import 'live_tables.dart';

/// A refusal, as one sentence.
class StatementError implements Exception {
  const StatementError(this.message);
  final String message;

  static Object wrap(Object e) {
    if (e is StatementError) return e;
    if (e is FunctionException) {
      final d = e.details;
      return StatementError(statementErrorMessage(d is Map ? d['hint'] : null, status: e.status));
    }
    if (e is PostgrestException) {
      if (e.code == '42501') return StatementError(statementErrorMessage(null, status: 403));
      if ((e.hint ?? '').trim().isNotEmpty) return StatementError(e.hint!.trim());
    }
    return e;
  }

  @override
  String toString() => message;
}

/// Who adds an incentive or adjustment, and what it was for.
class StatementEntry {
  const StatementEntry({
    required this.id,
    required this.kind,
    required this.partnerName,
    required this.partnerId,
    required this.amount,
    required this.label,
    required this.at,
    required this.byName,
  });

  factory StatementEntry.fromRow(Map<String, dynamic> r) => StatementEntry(
    id: '${r['id']}',
    kind: '${r['kind']}',
    partnerName: '${r['partner_name'] ?? ''}',
    partnerId: '${r['partner_display_id'] ?? ''}',
    amount: r['amount'] is num ? (r['amount'] as num).toDouble() : double.tryParse('${r['amount']}') ?? 0,
    label: '${r['label'] ?? ''}',
    at: DateTime.tryParse('${r['at'] ?? ''}')?.toLocal(),
    byName: '${r['created_by_name'] ?? ''}',
  );

  final String id;

  /// incentive | adjustment
  final String kind;
  final String partnerName;
  final String partnerId;
  final double amount;
  final String label;
  final DateTime? at;
  final String byName;
}

class PayoutAccount {
  const PayoutAccount({required this.bank, required this.account, required this.holder});
  final String bank;
  final String account;
  final String holder;
}

class PartnerStatementRepository {
  PartnerStatementRepository(this._db, {http.Client? client}) : _http = client ?? http.Client();
  final SupabaseClient _db;
  final http.Client _http;

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw StatementError.wrap(e);
    }
  }

  Future<StatementSettings> settings() async => StatementSettings.fromJson(await _db.rpc('partner_statement_config'));

  Future<StatementTotals> earnings(DateTime from, DateTime to) => _call(
    () async => StatementTotals.fromJson(
      await _db.rpc(
        'my_earnings',
        params: {'p_from': from.toUtc().toIso8601String(), 'p_to': to.toUtc().toIso8601String()},
      ),
    ),
  );

  /// [bucket]: day | week | month.
  Future<List<EarningsBucket>> series(DateTime from, DateTime to, String bucket) => _call(
    () async => [
      for (final r in await _db.rpc(
        'my_earnings_series',
        params: {'p_from': from.toUtc().toIso8601String(), 'p_to': to.toUtc().toIso8601String(), 'p_bucket': bucket},
      ) as List)
        EarningsBucket.fromRow(Map<String, dynamic>.from(r as Map)),
    ],
  );

  /// Newest first; [before] pages back from a period's first day.
  Future<List<StatementPeriod>> periods(StatementType type, {int limit = 12, DateTime? before}) => _call(
    () async => [
      for (final r in await _db.rpc(
        'my_statement_periods',
        params: {'p_type': type.name, 'p_limit': limit, 'p_before': before == null ? null : isoDate(before)},
      ) as List)
        StatementPeriod.fromRow(type, Map<String, dynamic>.from(r as Map)),
    ],
  );

  /// Has the statement made (or handed back), then fetches the PDF.
  Future<({StatementDownload info, Uint8List bytes})> download(StatementPeriod p, StatementLang lang) =>
      _call(() async {
        final res = await _db.functions.invoke(
          'partner-statement',
          body: {'type': p.type.name, 'start': isoDate(p.start), 'lang': lang.name},
        );
        final info = StatementDownload.fromJson(Map<String, dynamic>.from(res.data as Map));
        final pdf = await _http.get(Uri.parse(info.url)).timeout(const Duration(seconds: 30));
        if (pdf.statusCode != 200) throw StatementError(statementErrorMessage(null));
        await _cachePut(p.cacheName(lang), pdf.bodyBytes);
        return (info: info, bytes: pdf.bodyBytes);
      });

  // ---- Offline copies (not on the website: the browser keeps its downloads) ----
  static Future<Directory?> _cacheDir() async {
    if (kIsWeb) return null;
    try {
      final d = Directory('${(await getApplicationSupportDirectory()).path}/statements');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cachePut(String name, Uint8List bytes) async {
    try {
      final d = await _cacheDir();
      if (d != null) await File('${d.path}/$name').writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  /// The copy last downloaded on this device, or null.
  Future<Uint8List?> cached(StatementPeriod p, StatementLang lang) async {
    try {
      final d = await _cacheDir();
      final f = d == null ? null : File('${d.path}/${p.cacheName(lang)}');
      return f != null && await f.exists() ? await f.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  // ---- The statement language, remembered on the device ----
  static const _langKey = 'partner_statement_lang';

  Future<StatementLang> savedLang() async {
    try {
      return StatementLang.parse((await SharedPreferences.getInstance()).getString(_langKey));
    } catch (_) {
      return StatementLang.en;
    }
  }

  Future<void> saveLang(StatementLang lang) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_langKey, lang.name);
    } catch (_) {}
  }

  // ---- Payout account (on the statement only when the admin turns the bank line on) ----
  Future<PayoutAccount?> payoutAccount() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    final r = await _db.from('partner_payout_accounts').select().eq('profile_id', uid).maybeSingle();
    return r == null
        ? null
        : PayoutAccount(bank: '${r['bank_name']}', account: '${r['account_no']}', holder: '${r['holder_name']}');
  }

  Future<void> savePayoutAccount(String bank, String account, String holder) =>
      _call(() => _db.rpc('set_my_payout_account', params: {'p_bank': bank, 'p_account': account, 'p_holder': holder}));

  /// The public verification page: what a statement's QR code proves.
  Future<StatementVerification?> verify(String token) async =>
      StatementVerification.fromJson(await _db.rpc('statement_verify', params: {'p_token': token}));

  // ---- Admin ----
  Future<StatementSettings> saveSettings(StatementSettings s) => _call(
    () async =>
        StatementSettings.fromJson(await _db.rpc('set_partner_statement_config', params: {'p_config': s.toJson()})),
  );

  /// Surcharge names on trips over the last year, with how many trips had each.
  Future<List<({String name, int trips})>> surchargeNames() async => [
    for (final r in await _db.rpc('statement_surcharge_names') as List)
      (name: '${(r as Map)['name']}', trips: (r['trips'] as num?)?.toInt() ?? 0),
  ];

  /// [partner]: partner ID, phone, or account id.
  Future<void> creditIncentive(String partner, double amount, String label) => _call(
    () => _db.rpc(
      'admin_credit_incentive',
      params: {'p_partner': partner.trim(), 'p_amount': amount, 'p_label': label.trim()},
    ),
  );

  Future<void> postAdjustment(String partner, double amount, String reason, DateTime? effective) => _call(
    () => _db.rpc(
      'admin_post_adjustment',
      params: {
        'p_partner': partner.trim(),
        'p_amount': amount,
        'p_reason': reason.trim(),
        'p_effective': effective == null ? null : isoDate(effective),
      },
    ),
  );

  /// [kind]: incentive | adjustment | all.
  Future<List<StatementEntry>> entries(String kind, {int limit = 100}) async => [
    for (final r in await _db.rpc('admin_statement_entries', params: {'p_kind': kind, 'p_limit': limit}) as List)
      StatementEntry.fromRow(Map<String, dynamic>.from(r as Map)),
  ];

  Future<bool> canEdit() async => await _db.rpc('caller_can_edit_statements') == true;

  // ---- Layout (0217) ----
  Future<StatementLayout> layout() async => StatementLayout.fromJson(await _db.rpc('partner_statement_layout'));

  Future<StatementLayout> saveLayout(StatementLayout l) => _call(
    () async =>
        StatementLayout.fromJson(await _db.rpc('set_partner_statement_layout', params: {'p_layout': l.toJson()})),
  );

  /// Uploads a PNG or JPEG logo to the public `app-branding` bucket; answers its file name there.
  Future<String> uploadLogo(Uint8List bytes, String ext) => _call(() async {
    final png = ext != 'jpg';
    final path = 'statement-logo-${DateTime.now().millisecondsSinceEpoch}.${png ? 'png' : 'jpg'}';
    await _db.storage.from(statementLogoBucket).uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(upsert: true, contentType: png ? 'image/png' : 'image/jpeg'),
    );
    return path;
  });

  String logoUrl(String path) => _db.storage.from(statementLogoBucket).getPublicUrl(path);

  /// A made-up statement drawn in [l], which need not be saved yet.
  Future<({Uint8List bytes, String fileName})> sample(StatementLayout l, StatementType type, StatementLang lang) =>
      _call(() async {
        final res = await _db.functions.invoke(
          'partner-statement',
          body: {'preview': true, 'type': type.name, 'lang': lang.name, 'layout': l.toJson()},
        );
        final m = Map<String, dynamic>.from(res.data as Map);
        return (bytes: base64Decode('${m['pdf']}'), fileName: '${m['fileName']}');
      });
}

/// Where the statement logo is kept (with the splash and app icon).
const statementLogoBucket = 'app-branding';

final partnerStatementRepositoryProvider = Provider((ref) => PartnerStatementRepository(ref.watch(supabaseProvider)));

final statementSettingsProvider = FutureProvider.autoDispose<StatementSettings>((ref) {
  ref.watchLive('app_settings');
  return ref.watch(partnerStatementRepositoryProvider).settings();
});

final statementLayoutProvider = FutureProvider.autoDispose<StatementLayout>((ref) {
  ref.watchLive('app_settings');
  return ref.watch(partnerStatementRepositoryProvider).layout();
});

/// The Earnings page's totals for a period, and the same per day (days with trips only, newest first).
/// The Earnings page's clock: the totals, the chart, the trips, the CSV and
/// the day names all read it, so they share one "now" (pinned in tests).
final earningsClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final earningsTotalsProvider = FutureProvider.autoDispose
    .family<({StatementTotals totals, List<EarningsBucket> days}), EarningsPeriod>((ref, period) async {
      ref.watchLive('wallets');
      final settings = await ref.watch(statementSettingsProvider.future);
      final repo = ref.watch(partnerStatementRepositoryProvider);
      final r = earningsRange(period, ref.watch(earningsClockProvider)(), sunday: settings.weekStartsSunday);
      final results = await Future.wait([repo.earnings(r.from, r.to), repo.series(r.from, r.to, 'day')]);
      final days = (results[1] as List<EarningsBucket>).where((d) => d.totals.trips > 0).toList()
        ..sort((a, b) => b.start.compareTo(a.start));
      return (totals: results[0] as StatementTotals, days: days);
    });

/// The chart's last eight weeks, oldest first.
final earningsWeeksProvider = FutureProvider.autoDispose<List<EarningsBucket>>((ref) async {
  ref.watchLive('wallets');
  final settings = await ref.watch(statementSettingsProvider.future);
  final r = earningsWeeksRange(ref.watch(earningsClockProvider)(), sunday: settings.weekStartsSunday);
  return ref.watch(partnerStatementRepositoryProvider).series(r.from, r.to, 'week');
});
