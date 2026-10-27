// Partner registration rules checked by the server (0305, docs/KIV.md M6):
// Citizens only, Business registration and Driver permit refuse a Submit
// (CITIZENS_ONLY, BUSINESS_REGISTRATION_REQUIRED, DRIVER_PERMIT_REQUIRED) and
// an approval (PARTNER_RULES_NOT_MET, unless the admin overrides with a
// reason); a vehicle permit or an age limit only pauses that service.
//
// Pure, so it is tested without a database: what the server's problems say
// (RuleProblem), the driver's modal for a refused Submit, the "Before you
// submit" checklist worked out with the same rules the server applies, and
// the admin's review banner and rules card.
library;

import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../admin/screens/people/people_logic.dart';
import 'date_order.dart';
import 'document_text.dart';
import 'partner_onboarding.dart' show OnboardingStep;
import 'partner_registration.dart';
import 'partner_type_rules.dart';

// ---- What the server says ------------------------------------------------------------------------

/// The codes a Submit is refused with, one per rule.
const citizensOnlyCode = 'CITIZENS_ONLY';
const businessRegistrationCode = 'BUSINESS_REGISTRATION_REQUIRED';
const driverPermitCode = 'DRIVER_PERMIT_REQUIRED';

/// An approval refused while rules fail.
const partnerRulesNotMetCode = 'PARTNER_RULES_NOT_MET';

const registrationRuleCodes = {citizensOnlyCode, businessRegistrationCode, driverPermitCode, partnerRulesNotMetCode};

/// The rules, by the server's key.
enum RegRule {
  citizensOnly('citizens_only', 'Citizens only'),
  businessRegistration('business_registration', 'Business registration'),
  driverPermit('driver_permit', 'Driver permit'),
  vehiclePermit('vehicle_permit', 'Vehicle permit'),
  vehicleAge('vehicle_age', 'Age-limit covers');

  const RegRule(this.key, this.label);
  final String key;
  final String label;

  static RegRule? parse(Object? v) => values.where((r) => r.key == '$v').firstOrNull;

  static RegRule? ofCode(String code) => switch (code) {
        citizensOnlyCode => citizensOnly,
        businessRegistrationCode => businessRegistration,
        driverPermitCode => driverPermit,
        _ => null,
      };
}

String _s(Object? v) => v == null ? '' : '$v'.trim();

/// One rule for one Partner Service type, as `partner_registration_checks`
/// (and a refusal's detail) gives it.
class RuleProblem {
  const RuleProblem({
    required this.rule,
    this.status = 'failed',
    this.type = '',
    this.place = '',
    this.message = '',
    this.permit = '',
    this.idType,
    this.idNumber = '',
    this.missing = const [],
    this.permitState = '',
    this.validUntil = '',
  });

  factory RuleProblem.fromJson(Map raw) => RuleProblem(
        rule: RegRule.parse(raw['rule']) ?? RegRule.driverPermit,
        status: _s(raw['status']).isEmpty ? 'failed' : _s(raw['status']),
        type: _s(raw['type']),
        place: _s(raw['place']),
        message: _s(raw['message']),
        permit: _s(raw['permit']),
        idType: IdDocType.parse(raw['id_type']),
        idNumber: _s(raw['id_number']),
        missing: [for (final m in (raw['missing'] is List ? raw['missing'] as List : const [])) _s(m)],
        permitState: _s(raw['state']),
        validUntil: _s(raw['valid_until']),
      );

  final RegRule rule;

  /// failed, passed or paused.
  final String status;
  final String type;
  final String place;

  /// The server's words.
  final String message;

  /// The permit's name (driver or vehicle permit).
  final String permit;
  final IdDocType? idType;
  final String idNumber;

  /// What a business registration lacks: "company number", "registration document".
  final List<String> missing;

  /// A driver permit: ok, missing, expired or no_expiry.
  final String permitState;
  final String validUntil;

  bool get failed => status == 'failed';
  bool get paused => status == 'paused';
}

/// The rows of a JSON list (the checks, a refusal's detail); none when it
/// can't be read.
List<RuleProblem> ruleProblemsFromJson(Object? raw) {
  Object? v = raw;
  if (v is String) {
    try {
      v = jsonDecode(v);
    } catch (_) {
      return const [];
    }
  }
  if (v is! List) return const [];
  return [for (final r in v) if (r is Map) RuleProblem.fromJson(r)];
}

/// The failed rules a refused Submit or approval names; empty for any other
/// error. A refusal without a readable detail still gives its rule, with the
/// hint as the message.
List<RuleProblem> ruleProblemsFromError(Object e) {
  if (e is! PostgrestException || !registrationRuleCodes.contains(e.message)) return const [];
  final list = [for (final p in ruleProblemsFromJson(e.details)) if (p.failed) p];
  if (list.isNotEmpty) return list;
  final rule = RegRule.ofCode(e.message);
  return rule == null ? const [] : [RuleProblem(rule: rule, message: _s(e.hint))];
}

// ---- The driver's modal --------------------------------------------------------------------------------

/// The modal for a Submit the server refused: what to say and where its
/// action goes.
typedef SubmitRefusal = ({
  String title,
  String body,
  String note,
  String action,
  OnboardingStep step,
  RegRule rule,
});

bool _malaysia(String place) => const {'malaysia', 'my', 'mys', ''}.contains(place.trim().toLowerCase());

/// "Malaysian citizens", or "citizens of Singapore".
String citizensOf(String country) => _malaysia(country) ? 'Malaysian citizens' : 'citizens of ${country.trim()}';

String _idSays(IdDocType? type, String number) {
  final n = number.trim().isEmpty ? '' : ' (${number.trim()})';
  return switch (type) {
    IdDocType.passport => 'Your ID is a passport$n.',
    IdDocType.mypr => 'Your ID is a MyPR$n: permanent residents are not citizens.',
    IdDocType.mykad => 'Your ID shows you are not a citizen.',
    null => 'Add your National ID first.',
  };
}

/// The modal for [p], with [idType] and [idNumber] from the driver's
/// profile when the server didn't send them.
SubmitRefusal submitRefusal(RuleProblem p, {IdDocType? idType, String idNumber = ''}) {
  final type = p.type.isEmpty ? 'This service' : p.type;
  final place = p.place.isEmpty ? 'your area' : p.place;
  switch (p.rule) {
    case RegRule.citizensOnly:
      final id = p.idType ?? idType;
      final number = p.idNumber.isNotEmpty ? p.idNumber : idNumber;
      final my = _malaysia(p.place);
      return (
        title: '$type is for ${citizensOf(p.place)}',
        body: my
            ? '$type in $place takes partners with a MyKad only. ${_idSays(id, number)} Choose another Partner '
                'Service type, or sign up with a MyKad.'
            : '$type in $place takes citizens only. ${_idSays(id, number)} Choose another Partner Service type, '
                'or sign up with a citizen ID.',
        note: 'Sent back by the server, so it applies to every app version. Your answers are kept.',
        action: 'Change type',
        step: OnboardingStep.partnerType,
        rule: p.rule,
      );
    case RegRule.businessRegistration:
      final missing = p.missing.isEmpty ? const ['company number', 'registration document'] : p.missing;
      return (
        title: 'Add your company registration',
        body: '$type in $place needs a company number and the registration document'
            '${_malaysia(p.place) ? ' (SSM)' : ''}. Add them, then submit again.',
        note: 'Missing: ${missing.join(', ')}.',
        action: 'Add company',
        step: OnboardingStep.company,
        rule: p.rule,
      );
    case RegRule.driverPermit:
    case RegRule.vehiclePermit:
    case RegRule.vehicleAge:
      final permit = p.permit.isEmpty || p.permit == 'permit' ? 'driver permit' : p.permit;
      final title = p.permit.isEmpty || p.permit == 'permit'
          ? 'Upload your driver permit'
          : 'Upload your driver permit ($permit)';
      final body = switch (p.permitState) {
        'expired' => 'Your $permit expired${p.validUntil.isEmpty ? '' : ' on ${formatStoredDateForUser(p.validUntil)}'}: '
            'an expired permit counts as missing. Upload the new one, with the expiry date showing, then submit again.',
        'no_expiry' => 'Type the expiry date of your $permit as it is on the card, then submit again.',
        _ => '$type in $place needs a $permit. Upload a photo of the front, with the expiry date showing, then '
            'submit again.',
      };
      return (
        title: title,
        body: body,
        note: 'The rest of your sign-up is saved.',
        action: 'Upload',
        step: OnboardingStep.driverPermit,
        rule: RegRule.driverPermit,
      );
  }
}

// ---- Before you submit ---------------------------------------------------------------------------------

/// A checklist row: Done, Needed (the server refuses the Submit), Later
/// (that service is paused until it is added) or Not needed.
enum CheckState {
  done('Done'),
  needed('Needed'),
  later('Later'),
  notNeeded('Not needed');

  const CheckState(this.label);
  final String label;
}

typedef ChecklistRow = ({String name, String detail, CheckState state, OnboardingStep? step});

/// "Before you submit": the rules the server checks on Submit, worked out
/// from the driver's [profile], [partner] row (types, area, company, driver
/// permit) and the Partner Service type settings [entries]; the vehicle rows
/// from [vehicle] (its plate, year and registration date). [order] is the
/// date order (tests).
List<ChecklistRow> submitChecklist({
  required Map<String, dynamic>? profile,
  required Map<String, dynamic> partner,
  required Iterable<Map<String, dynamic>> entries,
  Map<String, dynamic>? vehicle,
  DateTime? now,
  DateOrder? order,
}) {
  final today = now ?? DateTime.now();
  final types = parseStringList(partner['partner_types']);
  final area = ServiceArea.fromRow(partner);
  final rows = <ChecklistRow>[];

  // Citizens only.
  final only = citizensOnlyTypes(types, entries, area);
  final idType = IdDocType.parse(profile?['id_type']);
  final ic = _s(profile?['ic']);
  if (only.isEmpty) {
    rows.add((name: 'Citizens only', detail: 'Not needed for these types', state: CheckState.notNeeded, step: null));
  } else if (idShowsNonCitizen(idType, _s(profile?['nationality']))) {
    rows.add((
      name: 'Citizens only',
      detail: '${only.join(', ')}: ${idType?.label ?? 'your ID'} is not a citizen ID',
      state: CheckState.needed,
      step: OnboardingStep.partnerType,
    ));
  } else {
    rows.add((
      name: 'Citizens only',
      detail: '${only.join(', ')}: ${[idType?.label ?? 'ID', if (ic.isNotEmpty) ic].join(' ')}',
      state: CheckState.done,
      step: null,
    ));
  }

  // Company registration.
  final business = businessRegistrationTypes(types, entries, area);
  if (business.isEmpty) {
    rows.add((name: 'Company registration', detail: 'Not needed for these types', state: CheckState.notNeeded, step: null));
  } else {
    final missing = [
      if (_s(partner['company_reg_no']).isEmpty) 'company number',
      if (_s(partner['company_document_url']).isEmpty) 'registration document',
    ];
    rows.add(missing.isEmpty
        ? (
            name: 'Company registration',
            detail: '${business.join(', ')}: ${_s(partner['company_reg_no'])}',
            state: CheckState.done,
            step: null,
          )
        : (
            name: 'Company registration',
            detail: '${business.join(', ')}: add the ${missing.join(' and ')}',
            state: CheckState.needed,
            step: OnboardingStep.company,
          ));
  }

  // Driver permit, and its expiry date.
  final permit = driverPermitFor(types, entries, area).firstOrNull;
  if (permit == null) {
    rows.add((name: 'Driver permit', detail: 'Not needed for these types', state: CheckState.notNeeded, step: null));
  } else {
    final name = permit.name.isEmpty ? 'driver permit' : permit.name;
    final title = permit.name.isEmpty ? 'Driver permit' : 'Driver permit ($name)';
    final uploaded = _s(partner['driver_permit_card_no']).isNotEmpty && _s(partner['driver_permit_front_url']).isNotEmpty;
    rows.add(uploaded
        ? (name: title, detail: '${permit.type}: ${_s(partner['driver_permit_card_no'])}', state: CheckState.done, step: null)
        : (name: title, detail: '${permit.type}: upload $name', state: CheckState.needed, step: OnboardingStep.driverPermit));
    final until = DateTime.tryParse(_s(partner['driver_permit_valid_until']));
    final day = DateTime(today.year, today.month, today.day);
    rows.add(until == null
        ? (name: 'Driver permit expiry', detail: 'Type the expiry date', state: CheckState.needed, step: OnboardingStep.driverPermit)
        : until.isBefore(day)
            ? (
                name: 'Driver permit expiry',
                detail: 'Expired ${formatDateForUser(until, order: order)}: upload the new one',
                state: CheckState.needed,
                step: OnboardingStep.driverPermit,
              )
            : (
                name: 'Driver permit expiry',
                detail: 'Valid until ${formatDateForUser(until, order: order)}',
                state: CheckState.done,
                step: null,
              ));
  }

  // The vehicle: a permit or an age limit pauses that service only.
  final services = vehicleServicesOf(types, entries);
  final permits = <String, List<String>>{};
  for (final s in services) {
    final need = vehiclePermitFor(s, services, entries, area);
    if (need == null) continue;
    final also = EffectiveTypeRules.of(s, entries).settings.vehiclePermitAlsoFor;
    final label = need.name.isEmpty ? 'Vehicle permit' : 'Vehicle permit (${need.name})';
    permits.putIfAbsent(label, () => []).add(also.isEmpty ? need.type : '${need.type}, also ${also.join(', ')}');
  }
  if (permits.isEmpty) {
    rows.add((name: 'Vehicle permit', detail: 'Not needed for these types', state: CheckState.notNeeded, step: null));
  } else {
    for (final e in permits.entries) {
      rows.add((name: e.key, detail: '${e.value.join('; ')}: paused until uploaded', state: CheckState.later, step: null));
    }
  }

  final registered = _registered(vehicle);
  final statuses = services.isEmpty
      ? const <VehicleServiceStatus>[]
      : vehicleServiceStatuses(services: services, entries: entries, area: area, registered: registered, now: today);
  final limited = [for (final s in statuses) if (s.limit != null) s];
  final plate = _s(vehicle?['plate']);
  final year = registered == null ? '' : '${registered.year}';
  final which = [if (plate.isNotEmpty) plate, if (year.isNotEmpty) year].join(', ');
  if (limited.isEmpty || registered == null) {
    rows.add((
      name: 'Vehicle age',
      detail: limited.isEmpty ? 'No age limit for these types' : 'Register your vehicle first',
      state: CheckState.notNeeded,
      step: null,
    ));
  } else {
    final over = [for (final s in limited) if (s.state == VehicleServiceState.pausedAge) s];
    if (over.isNotEmpty) {
      rows.add((
        name: 'Vehicle age',
        detail: '$which: over ${over.map((s) => '${s.limit!.maxYears} years for ${s.service}').join(', ')}: paused',
        state: CheckState.later,
        step: null,
      ));
    } else {
      final s = limited.first;
      final cover = s.coveredBy == null ? '' : ' (${s.coveredBy} covers ${s.service})';
      rows.add((
        name: 'Vehicle age',
        detail: '$which: within ${s.limit!.maxYears} years$cover',
        state: CheckState.done,
        step: null,
      ));
    }
  }
  return rows;
}

DateTime? _registered(Map<String, dynamic>? v) {
  final day = DateTime.tryParse(_s(v?['registration_date']));
  if (day != null) return day;
  final year = int.tryParse(RegExp(r'\d{4}').firstMatch(_s(v?['year']))?.group(0) ?? '');
  return year == null ? null : DateTime(year);
}

/// "You chose eHailing and Teksi in Malaysia."
String checklistLead(Map<String, dynamic> partner) {
  final types = parseStringList(partner['partner_types']);
  final area = ServiceArea.fromRow(partner);
  final names = types.length <= 1
      ? types.join()
      : '${types.sublist(0, types.length - 1).join(', ')} and ${types.last}';
  final where = area.countries.isEmpty ? '' : ' in ${area.countries.join(', ')}';
  return 'You chose $names$where. These are the rules the server checks when you submit.';
}

// ---- The admin's review ----------------------------------------------------------------------------------

/// "Can't approve: Business registration missing (Dealer needs it in Malaysia)".
String approveBlockedTitle(List<RuleProblem> failed) {
  if (failed.isEmpty) return '';
  final p = failed.first;
  final label = p.rule == RegRule.driverPermit && p.permit.isNotEmpty && p.permit != 'permit'
      ? 'Driver permit (${p.permit})'
      : p.rule.label;
  final where = p.place.isEmpty ? '' : ' in ${p.place}';
  return "Can't approve: $label missing (${p.type} needs it$where)";
}

/// One row of the review's "Partner registration rules" card.
typedef ReviewRuleRow = ({RegRule rule, String label, String detail, String chip});

/// Each rule once, from every check of the partner: Failed (or Overridden
/// when the approval went past it), Paused, Passed, or Not set for the
/// partner's types.
List<ReviewRuleRow> reviewRuleRows(List<RuleProblem> checks, {bool overridden = false}) => [
      for (final r in RegRule.values)
        () {
          final mine = [for (final c in checks) if (c.rule == r) c];
          final failed = mine.where((c) => c.failed).toList();
          final paused = mine.where((c) => c.paused).toList();
          final label = r == RegRule.driverPermit && mine.isNotEmpty && mine.first.permit.isNotEmpty &&
                  mine.first.permit != 'permit'
              ? 'Driver permit (${mine.first.permit})'
              : r.label;
          if (failed.isNotEmpty) {
            return (rule: r, label: label, detail: failed.map((c) => c.message).join(' '),
                chip: overridden ? 'Overridden' : 'Failed');
          }
          if (paused.isNotEmpty) {
            return (rule: r, label: label, detail: paused.map((c) => c.message).join(' '), chip: 'Paused');
          }
          if (mine.isNotEmpty) {
            return (rule: r, label: label, detail: mine.map((c) => c.message).join('; '), chip: 'Passed');
          }
          return (rule: r, label: label, detail: 'Not set for these types', chip: 'Not set');
        }(),
    ];

/// The review line that asks the partner for what [p] lacks ("Ask partner
/// for documents"): rejected with the server's words, it goes back to the
/// driver with the application and is fixed in that step.
({String key, String group, String label})? askLineFor(RuleProblem p) => switch (p.rule) {
      RegRule.citizensOnly => (key: 'services', group: 'services', label: 'Partner Service types'),
      RegRule.businessRegistration => p.missing.contains('registration document') || p.missing.isEmpty
          ? (key: 'company.document', group: 'company', label: 'Company registration document')
          : (key: 'company.reg_no', group: 'company', label: 'Registration no.'),
      RegRule.driverPermit => p.permitState == 'expired' || p.permitState == 'no_expiry'
          ? (key: 'permit.valid_until', group: 'driver_permit', label: 'Valid until')
          : (key: 'permit.card_no', group: 'driver_permit', label: 'Permit number'),
      _ => null,
    };

/// An approval past failed rules (`partner_rule_overrides`).
class RuleOverride {
  const RuleOverride({required this.reason, required this.rules, this.adminId, this.at});

  factory RuleOverride.fromRow(Map<String, dynamic> r) => RuleOverride(
        reason: _s(r['reason']),
        rules: ruleProblemsFromJson(r['rules']),
        adminId: _s(r['admin_id']).isEmpty ? null : _s(r['admin_id']),
        at: DateTime.tryParse(_s(r['at']))?.toLocal(),
      );

  final String reason;
  final List<RuleProblem> rules;
  final String? adminId;
  final DateTime? at;

  /// "Business registration, Driver permit".
  String get skipped => {for (final r in rules) r.rule.label}.join(', ');
}

/// One partner that would fail a type's rules now (`admin_partner_rule_failures`).
typedef RuleFailure = ({String partnerId, String name, String status, List<RuleProblem> problems});

RuleFailure ruleFailureFromRow(Map<String, dynamic> r) => (
      partnerId: _s(r['partner_id']),
      name: _s(r['name']).isEmpty ? 'Partner' : _s(r['name']),
      status: _s(r['status']),
      problems: ruleProblemsFromJson(r['problems']),
    );

/// "Citizens only: passport, not MyKad" and the like: the first failure, short.
String ruleFailureWhy(RuleFailure f) {
  final p = f.problems.firstOrNull;
  if (p == null) return '';
  final why = switch (p.rule) {
    RegRule.citizensOnly => switch (p.idType) {
        IdDocType.passport => 'passport, not a citizen ID',
        IdDocType.mypr => 'MyPR, not a citizen ID',
        IdDocType.mykad => 'not a citizen there',
        null => 'no ID added',
      },
    RegRule.businessRegistration => 'missing ${p.missing.isEmpty ? 'company number and document' : p.missing.join(' and ')}',
    _ => switch (p.permitState) {
        'expired' => 'expired${p.validUntil.isEmpty ? '' : ' ${formatStoredDateForUser(p.validUntil)}'}',
        'no_expiry' => 'no expiry date',
        _ => 'none uploaded',
      },
  };
  return '${p.rule.label}: $why';
}
