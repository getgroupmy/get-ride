/// The document check before a partner goes online (Expo
/// `utils/partnerModeDocCheck.ts`): every compulsory document that applies to
/// the service they are switching on — by partner type and service area, the
/// same rules partner onboarding uses — must have an upload that is neither
/// rejected nor expired. Optional documents are reported but never block.
library;

import '../admin/screens/people/people_logic.dart';

enum DocIssueReason {
  missing('not uploaded'),
  rejected('rejected'),
  expired('expired');

  const DocIssueReason(this.label);
  final String label;
}

typedef DocIssue = ({String id, String name, bool compulsory, DocIssueReason reason});

/// Problems with [docs], judged on the newest upload of each document.
/// [uploads] are `provider_documents` rows in any order. Compulsory first,
/// then by name.
List<DocIssue> partnerDocIssues(List<RequiredDoc> docs, Iterable<Map<String, dynamic>> uploads, {DateTime? now}) {
  final latest = <String, Map<String, dynamic>>{};
  for (final u in uploads) {
    final id = '${u['doc_id'] ?? ''}';
    if (id.isEmpty) continue;
    final seen = latest[id];
    if (seen == null || _uploadedAt(u).isAfter(_uploadedAt(seen))) latest[id] = u;
  }
  final issues = <DocIssue>[];
  for (final d in docs) {
    final u = latest[d.id];
    final DocIssueReason? reason;
    if (u == null) {
      reason = DocIssueReason.missing;
    } else {
      reason = switch (docDisplayStatus(u, now: now)) {
        'Rejected' => DocIssueReason.rejected,
        'Expired' => DocIssueReason.expired,
        _ => null,
      };
    }
    if (reason != null) issues.add((id: d.id, name: d.name, compulsory: d.compulsory, reason: reason));
  }
  issues.sort((a, b) {
    if (a.compulsory != b.compulsory) return a.compulsory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return issues;
}

DateTime _uploadedAt(Map<String, dynamic> u) =>
    DateTime.tryParse('${u['uploaded_at'] ?? u['created_at'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0);

/// The issues that keep the partner offline.
List<DocIssue> blockingDocIssues(List<DocIssue> issues) => issues.where((i) => i.compulsory).toList();

/// The partner types a service mode checks documents for: TEKSI for the
/// meter, every other assigned type for e-hailing. A partner who only has the
/// other kind is checked against all their types, so nothing slips through.
List<String> partnerTypesForMode(List<String> assigned, {required bool teksi}) {
  bool isTeksi(String t) => t.trim().toLowerCase() == 'teksi';
  final picked = assigned.where((t) => isTeksi(t) == teksi).toList();
  return picked.isEmpty ? assigned : picked;
}

/// "• Name (reason)" lines, at most four, then "+N more" (Expo
/// `summarizeDocIssues`).
String summarizeDocIssues(List<DocIssue> issues) {
  if (issues.isEmpty) return '';
  final top = issues.take(4).map((i) => '• ${i.name} (${i.reason.label})');
  final more = issues.length > 4 ? ['• +${issues.length - 4} more'] : const <String>[];
  return [...top, ...more].join('\n');
}

/// How long before expiry an approved document can be renewed (Expo
/// `RENEWAL_WINDOW_DAYS`).
const renewalWindowDays = 14;

/// The day an approved document's renewal opens, while it is still shut:
/// [windowDays] before its expiry. Null when it can be replaced now — it is
/// not approved (pending, rejected, expired), has no expiry date, or is
/// already inside the window. Pure.
DateTime? renewalOpensOn(Map<String, dynamic> upload, {required DateTime now, int windowDays = renewalWindowDays}) {
  if (docDisplayStatus(upload, now: now) != 'Approved') return null;
  final expiry = DateTime.tryParse('${upload['expiry_date'] ?? ''}');
  if (expiry == null) return null;
  final day = DateTime(expiry.year, expiry.month, expiry.day);
  final today = DateTime(now.year, now.month, now.day);
  return day.difference(today).inDays > windowDays ? day.subtract(Duration(days: windowDays)) : null;
}
