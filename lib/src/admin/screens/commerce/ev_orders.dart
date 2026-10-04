/// TEKSI EV order domain logic — a pure port of Expo `utils/evOrders.ts`.
///
/// The customer wizard and the admin back office read and write the same
/// `ev_orders.values` shape, so the status vocabulary, checklist JSON and
/// wizard-step derivation must match the Expo app exactly.
library;

import 'dart:convert';

typedef EvOrderValues = Map<String, dynamic>;

// ---------------------------------------------------------------------------
// Status vocabulary
// ---------------------------------------------------------------------------

/// Stored spellings, in lifecycle order (drives the filter row).
const evOrderStatuses = ['pending', 'assigned', 'in-progress', 'ready_for_delivery', 'delivered', 'cancelled'];

const evOrderStatusLabels = {
  'pending': 'Pending DA',
  'assigned': 'DA assigned',
  'in-progress': 'In progress',
  'ready_for_delivery': 'Ready for delivery',
  'delivered': 'Delivered',
  'cancelled': 'Cancelled',
};

const _rank = {
  'pending': 0,
  'assigned': 1,
  'in-progress': 2,
  'ready_for_delivery': 3,
  'delivered': 4,
  'cancelled': 4,
};

enum EvOrderStatusTone { warning, info, accent, success, error }

const _tones = {
  'pending': EvOrderStatusTone.warning,
  'assigned': EvOrderStatusTone.info,
  'in-progress': EvOrderStatusTone.accent,
  'ready_for_delivery': EvOrderStatusTone.accent,
  'delivered': EvOrderStatusTone.success,
  'cancelled': EvOrderStatusTone.error,
};

String _str(Object? raw) => (raw ?? '').toString().trim();

/// Coerces any stored status into a known one (tolerating `ready-for-delivery`,
/// `Delivered`, `canceled`, …); unknown values become `pending`.
String normalizeEvOrderStatus(Object? raw) {
  final s = _str(raw).toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
  switch (s) {
    case 'assigned':
    case 'da_assigned':
      return 'assigned';
    case 'in_progress':
    case 'inprogress':
      return 'in-progress';
    case 'ready_for_delivery':
    case 'readyfordelivery':
    case 'ready':
      return 'ready_for_delivery';
    case 'delivered':
    case 'completed':
      return 'delivered';
    case 'cancelled':
    case 'canceled':
      return 'cancelled';
    default:
      return 'pending';
  }
}

String evOrderStatusLabel(Object? raw) => evOrderStatusLabels[normalizeEvOrderStatus(raw)]!;

EvOrderStatusTone evOrderStatusTone(Object? raw) => _tones[normalizeEvOrderStatus(raw)]!;

/// True when the status is at or past [at] in the lifecycle.
bool evOrderStatusAtLeast(Object? raw, String at) {
  final s = normalizeEvOrderStatus(raw);
  if (s == 'cancelled') return at == 'cancelled';
  return _rank[s]! >= (_rank[at] ?? 0);
}

// ---------------------------------------------------------------------------
// Loose value coercion
// ---------------------------------------------------------------------------

/// Booleans may be stored as `true`, `"true"`, `"1"` or `"yes"`.
bool evFlag(Object? raw) {
  if (raw is bool) return raw;
  final s = _str(raw).toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

// ---------------------------------------------------------------------------
// Delivery checklist
// ---------------------------------------------------------------------------

class EvChecklistResult {
  const EvChecklistResult({required this.name, required this.done, this.note = ''});
  final String name;
  final bool done;
  final String note;

  EvChecklistResult copyWith({bool? done, String? note}) =>
      EvChecklistResult(name: name, done: done ?? this.done, note: note ?? this.note);

  @override
  bool operator ==(Object other) =>
      other is EvChecklistResult && other.name == name && other.done == done && other.note == note;

  @override
  int get hashCode => Object.hash(name, done, note);

  @override
  String toString() => 'EvChecklistResult($name, $done, $note)';
}

/// Parses the `checklistResults` JSON string. Never throws.
List<EvChecklistResult> parseChecklistResults(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return const [];
  try {
    final parsed = jsonDecode(raw);
    if (parsed is! List) return const [];
    return parsed
        .map((x) {
          final row = x is Map ? x : const {};
          return EvChecklistResult(name: _str(row['name']), done: row['done'] != false, note: _str(row['note']));
        })
        .where((x) => x.name.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

String serializeChecklistResults(List<EvChecklistResult> items) =>
    jsonEncode([for (final x in items) {'name': x.name, 'done': x.done, 'note': x.note}]);

bool isChecklistSubmitted(EvOrderValues values) => evFlag(values['checklistSubmitted']);

bool isChecklistAccepted(EvOrderValues values) => evFlag(values['checklistAccepted']);

/// Template items merged with what was already submitted, so re-opening the
/// sheet resumes; submitted items no longer in the template are kept.
List<EvChecklistResult> buildChecklistDraft(List<String> templateNames, EvOrderValues values) {
  final saved = parseChecklistResults(values['checklistResults']);
  final byName = {for (final x in saved) x.name: x};
  final draft = templateNames
      .map((n) => n.trim())
      .where((n) => n.isNotEmpty)
      .map((n) => byName[n] ?? EvChecklistResult(name: n, done: false))
      .toList();
  final templateSet = draft.map((x) => x.name).toSet();
  for (final x in saved) {
    if (!templateSet.contains(x.name)) draft.add(x);
  }
  return draft;
}

// ---------------------------------------------------------------------------
// Wizard progress
// ---------------------------------------------------------------------------

const evStepKeys = [
  'model',
  'specification',
  'deposit',
  'ownership',
  'plate',
  'financing',
  'advisor',
  'schedule',
  'delivery',
];

/// Maps an admin finance-type label onto `cash` / `hp` / `leasing` / `rental`.
String? mapAdminTypeToFinanceType(Object? raw) {
  final t = _str(raw).toLowerCase();
  if (t.isEmpty) return null;
  if (t == 'cash') return 'cash';
  if (t == 'leasing' || t.startsWith('leas')) return 'leasing';
  if (t == 'hire purchase' || t == 'hp' || t.contains('hire')) return 'hp';
  if (t == 'rental' || t.contains('rent')) return 'rental';
  return null;
}

bool isEvOwnershipConfirmed(EvOrderValues v) =>
    _str(v['ownerFullName']).isNotEmpty && _str(v['ownerIdNumber']).isNotEmpty && _str(v['ownerAddress']).isNotEmpty;

bool isEvPlateAnswered(EvOrderValues v) {
  final t = _str(v['plateTransfer']).toLowerCase();
  if (t == 'no') return true;
  return t == 'yes' && _str(v['plateNumber']).isNotEmpty;
}

bool isEvFinancingComplete(EvOrderValues v) {
  final type = mapAdminTypeToFinanceType(v['financeType']);
  if (type == null) return false;
  if (_str(v['financeChoice']).isEmpty) return false;
  // A sum the customer has confirmed they owe completes the step as surely
  // as one already received: the back office records the money itself.
  if (type == 'cash') return evFlag(v['cashBalancePaid']) || evFlag(v['cashBalanceConfirmed']);
  if (type == 'leasing') {
    final addon = _str(v['leasingAddonRequired']).toLowerCase();
    if (addon == 'no') return true;
    return addon == 'yes' && (evFlag(v['leasingAddonPaid']) || evFlag(v['leasingAddonConfirmed']));
  }
  return true;
}

/// Furthest wizard step the customer has satisfied (floor: ownership).
String deriveEvOrderStep(EvOrderValues v) {
  if (isChecklistAccepted(v) || _str(v['deliveryDate']).isNotEmpty) return 'delivery';
  if (isEvFinancingComplete(v)) return _str(v['advisorId']).isNotEmpty ? 'schedule' : 'advisor';
  if (isEvPlateAnswered(v)) return 'financing';
  if (isEvOwnershipConfirmed(v)) return 'plate';
  return 'ownership';
}

// ---------------------------------------------------------------------------
// Admin back-office helpers (from app/admin-orders.tsx)
// ---------------------------------------------------------------------------

/// Patch written when a Delivery Advisor is assigned.
Map<String, dynamic> advisorAssignmentPatch(String advisorId, Map<String, dynamic> a, DateTime now) => {
      'advisorId': advisorId,
      'advisorName': _s(a['name']),
      'advisorContact': _s(a['contact']),
      'advisorEmail': _s(a['email']),
      'advisorDealership': _s(a['dealership']),
      'advisorDaNumber': _s(a['daNumber'] ?? advisorId),
      'advisorCountry': _s(a['country']),
      'advisorState': _s(a['state']),
      'advisorCity': _s(a['city']),
      'status': 'assigned',
      'assignedAt': now.toUtc().toIso8601String(),
    };

/// Patch written when the handover checklist is submitted. Submitting makes
/// an order ready for delivery; only the customer's acceptance delivers it.
Map<String, dynamic> checklistSubmissionPatch(
  List<EvChecklistResult> draft,
  Object? currentStatus,
  DateTime now,
) =>
    {
      'checklistResults': serializeChecklistResults(draft),
      'checklistSubmitted': true,
      'checklistSubmittedAt': now.toUtc().toIso8601String(),
      'status': normalizeEvOrderStatus(currentStatus) == 'delivered' ? 'delivered' : 'ready_for_delivery',
    };

/// Filter key: `all`, `refit` (wheels swapped) or a status.
bool evOrderMatches(EvOrderValues v, String id, String filter, String query) {
  if (filter == 'refit') {
    if (!_truthy(v['wheelsSwapped'])) return false;
  } else if (filter != 'all' && normalizeEvOrderStatus(v['status']) != filter) {
    return false;
  }
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final blob = '${_s(v['customerName'])} ${_s(v['customerPhone'])} ${_s(v['vehicle'])} $id ${_s(v['advisorName'])}'
      .toLowerCase();
  return blob.contains(q);
}

/// Counts per status plus `total` and `refit`.
Map<String, int> evOrderStats(Iterable<EvOrderValues> orders) {
  final counts = <String, int>{'total': 0, 'refit': 0, for (final s in evOrderStatuses) s: 0};
  for (final v in orders) {
    counts['total'] = counts['total']! + 1;
    final s = normalizeEvOrderStatus(v['status']);
    counts[s] = counts[s]! + 1;
    if (_truthy(v['wheelsSwapped'])) counts['refit'] = counts['refit']! + 1;
  }
  return counts;
}

/// JS truthiness for a stored value (Expo checks `!!o.values.wheelsSwapped`).
bool _truthy(Object? v) => v != null && v != false && v != '' && v != 0;

String _s(Object? v) => v == null ? '' : '$v';

/// Last six characters of the id, upper-cased (the "Order #" label).
String shortOrderId(String id) => (id.length <= 6 ? id : id.substring(id.length - 6)).toUpperCase();

/// Parses a JSON string array (gallery images); never throws.
List<String> parseStringList(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final v = jsonDecode(raw);
    return v is List ? v.map((x) => '$x').where((s) => s.isNotEmpty).toList() : const [];
  } catch (_) {
    return const [];
  }
}
