// Admin > Reports (migration 0280): the page's reads and writes. What the
// admin may see is the server's (ai_report_catalogue, ai_report_run check
// the caller's grants and region); this only asks.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ai_report.dart';
import '../providers.dart';

/// Whether the AI service and the email are set up (the ai-report function's GET).
class ReportServices {
  const ReportServices({this.aiReady = false, this.emailReady = false, this.emailKeySet = false, this.emailFrom, this.senderOk = false});

  factory ReportServices.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final ai = m['ai'] is Map ? m['ai'] as Map : const {};
    final email = m['email'] is Map ? m['email'] as Map : const {};
    return ReportServices(
      aiReady: ai['ready'] == true,
      emailReady: email['ready'] == true,
      emailKeySet: email['key_set'] == true,
      emailFrom: email['from'] as String?,
      senderOk: email['sender_ok'] == true,
    );
  }

  final bool aiReady;
  final bool emailReady;
  final bool emailKeySet;
  final String? emailFrom;
  final bool senderOk;
}

/// The AI's answer: a checked plan, or why there is none.
typedef AskAnswer = ({ReportPlan? plan, String? reason});

/// An admin a schedule can send to.
typedef ReportAdmin = ({String id, String name, String email});

/// One logged email of a schedule.
typedef ReportSend = ({DateTime at, int? rows, int recipients, bool ok, bool skipped, String? error, String? reason});

Object? _json(Object? v) => v is String ? jsonDecode(v) : v;

/// A database refusal in the page's words ("Reports: " dropped).
String reportErrorText(Object e) {
  final s = e is PostgrestException ? e.message : '$e';
  return s.replaceFirst(RegExp(r'^Reports:\s*'), '');
}

class AiReportRepository {
  AiReportRepository(this._db);
  final SupabaseClient? _db;

  Future<ReportCatalogue> catalogue() async => ReportCatalogue.fromJson(await _db!.rpc('ai_report_catalogue'));

  Future<ReportServices> services() async {
    try {
      final res = await _db!.functions.invoke('ai-report', method: HttpMethod.get);
      return ReportServices.fromJson(_json(res.data));
    } catch (_) {
      return const ReportServices();
    }
  }

  Future<AskAnswer> ask(String request) async {
    try {
      final res = await _db!.functions.invoke('ai-report', body: {'request': request});
      final m = _json(res.data);
      if (m is Map && m['ok'] == true) return (plan: ReportPlan.fromJson(m['plan']), reason: null);
      return (plan: null, reason: m is Map ? '${m['reason'] ?? "The AI couldn't make a report of that."}' : null);
    } on FunctionException catch (e) {
      final m = _json(e.details);
      final reason = m is Map ? (m['reason'] ?? m['error']) : null;
      return (
        plan: null,
        reason: reason == 'admin_only'
            ? 'Your admin access does not include Reports.'
            : '${reason ?? "The AI service didn't answer. Try again in a moment."}',
      );
    }
  }

  Future<ReportResult> run(ReportPlan plan) async =>
      ReportResult.fromJson(await _db!.rpc('ai_report_run', params: {'p_plan': plan.toJson()}));

  Future<List<SavedReport>> saved() async {
    final rows = await _db!.from('ai_reports_saved').select().order('updated_at', ascending: false);
    return [for (final r in rows) SavedReport.fromJson(r)];
  }

  Future<SavedReport> save({required String name, required ReportPlan plan, String? request}) async =>
      SavedReport.fromJson(await _db!
          .from('ai_reports_saved')
          .insert({'name': name.trim(), 'plan': plan.toJson(), 'request': ?request})
          .select()
          .single());

  Future<void> deleteSaved(String id) => _db!.from('ai_reports_saved').delete().eq('id', id);

  Future<List<ReportSchedule>> schedules() async {
    final rows = await _db!.from('ai_report_schedules').select().order('created_at', ascending: true);
    return [for (final r in rows) ReportSchedule.fromJson(r)];
  }

  Future<void> saveSchedule(ReportSchedule s, {bool isNew = false}) async {
    if (isNew) {
      await _db!.from('ai_report_schedules').insert(s.toRow());
    } else {
      await _db!.from('ai_report_schedules').update(s.toRow()).eq('id', s.id);
    }
  }

  Future<void> setPaused(String id, bool paused) => _db!.from('ai_report_schedules').update({'paused': paused}).eq('id', id);

  Future<void> deleteSchedule(String id) => _db!.from('ai_report_schedules').delete().eq('id', id);

  /// "Send now": false when it was sent in the last minute.
  Future<bool> sendNow(String id) async {
    final res = _json(await _db!.rpc('ai_report_schedule_send_now', params: {'p_id': id}));
    return res is Map && res['posted'] == true;
  }

  Future<List<ReportSend>> sends(String scheduleId) async {
    final rows = await _db!
        .from('ai_report_sends')
        .select()
        .eq('schedule_id', scheduleId)
        .order('at', ascending: false)
        .limit(10);
    return [
      for (final r in rows)
        (
          at: DateTime.parse('${r['at']}'),
          rows: (r['rows'] as num?)?.toInt(),
          recipients: (r['recipients'] as num?)?.toInt() ?? 0,
          ok: r['ok'] == true,
          skipped: r['skipped'] == true,
          error: r['error'] as String?,
          reason: r['reason'] as String?,
        ),
    ];
  }

  Future<List<ReportAdmin>> admins() async {
    final rows = await _db!.rpc('ai_report_admins');
    return [
      for (final r in rows is List ? rows : const [])
        if (r is Map) (id: '${r['id']}', name: '${r['name'] ?? ''}', email: '${r['email'] ?? ''}'),
    ];
  }

  Future<String?> emailFrom() async =>
      (await _db!.from('ai_report_settings').select('email_from').maybeSingle())?['email_from'] as String?;

  Future<void> setEmailFrom(String from) => _db!.from('ai_report_settings').update({'email_from': from.trim()}).eq('id', true);
}

final aiReportRepositoryProvider = Provider<AiReportRepository>((ref) => AiReportRepository(ref.watch(supabaseProvider)));

final reportCatalogueProvider = FutureProvider.autoDispose<ReportCatalogue>(
  (ref) => ref.watch(aiReportRepositoryProvider).catalogue(),
);

final reportServicesProvider = FutureProvider.autoDispose<ReportServices>(
  (ref) => ref.watch(aiReportRepositoryProvider).services(),
);

final savedReportsProvider = FutureProvider.autoDispose<List<SavedReport>>(
  (ref) => ref.watch(aiReportRepositoryProvider).saved(),
);

final reportSchedulesProvider = FutureProvider.autoDispose<List<ReportSchedule>>(
  (ref) => ref.watch(aiReportRepositoryProvider).schedules(),
);

/// The Reports page's clock (for tests).
final reportClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
