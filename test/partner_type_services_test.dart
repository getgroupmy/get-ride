// Partner type services (0257, 0259): the rule the admin page's "Who sees
// this request?" works out, matching partner_type_allows_service and
// caller_partner_service_ok in the database.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/partner_type_services.dart';

const _teksi = PartnerTypeServiceRule(
  typeKey: 'teksi',
  typeName: 'Teksi',
  allServices: false,
  services: ['Teksi', 'Ride', 'Comfort', '6-seater'],
);
const _phailing = PartnerTypeServiceRule(
  typeKey: 'phailing',
  typeName: 'pHailing',
  allServices: false,
  services: ['Delivery', 'Food', 'Mart'],
);
const _fleet = PartnerTypeServiceRule(typeKey: 'fleet', typeName: 'Fleet');
const _none = PartnerTypeServiceRule(typeKey: 'blocked', typeName: 'Blocked', allServices: false);

final _rules = rulesByKey([_teksi, _phailing, _fleet, _none]);

void main() {
  test('keys are ptr_key: no case, spaces, dashes or underscores', () {
    expect(partnerServiceKey(' E-Hailing '), 'ehailing');
    expect(partnerServiceKey('Service_Provider'), 'serviceprovider');
    expect(partnerServiceKey('6 - Seater'), '6seater');
  });

  test('a type with a rule sees its services only, compared without case or spaces', () {
    expect(partnerTypeAllowsService(_rules, 'Teksi', 'Ride'), isTrue);
    expect(partnerTypeAllowsService(_rules, ' TEKSI ', 'ride'), isTrue);
    expect(partnerTypeAllowsService(_rules, 'te-ksi', '6 Seater'), isTrue);
    expect(partnerTypeAllowsService(_rules, 'Teksi', 'Delivery'), isFalse);
    expect(partnerTypeAllowsService(_rules, 'Blocked', 'Ride'), isFalse, reason: 'no services ticked');
  });

  test('All services sees every service, new ones too', () {
    expect(partnerTypeAllowsService(_rules, 'Fleet', 'Ride'), isTrue);
    expect(partnerTypeAllowsService(_rules, 'Fleet', 'Something added later'), isTrue);
  });

  test('a type without a rule sees every service', () {
    expect(partnerTypeAllowsService(_rules, 'Dealer', 'Delivery'), isTrue);
    expect(partnerTypeAllowsService(const {}, 'Teksi', 'Delivery'), isTrue);
  });

  test('a partner sees what any of their types allows', () {
    expect(partnerSeesService(_rules, ['Teksi'], 'Delivery'), isFalse);
    expect(partnerSeesService(_rules, ['Teksi', 'pHailing'], 'Delivery'), isTrue);
    expect(partnerSeesService(_rules, ['Teksi', 'pHailing'], 'Ride'), isTrue);
    expect(partnerSeesService(_rules, ['Blocked', 'Unlisted'], 'Delivery'), isTrue, reason: 'Unlisted has no rule');
    expect(partnerSeesService(_rules, ['Blocked'], 'Delivery'), isFalse);
  });

  test('no types, blank types or a blank service: sees it', () {
    expect(partnerSeesService(_rules, const [], 'Delivery'), isTrue);
    expect(partnerSeesService(_rules, const [' ', ''], 'Delivery'), isTrue);
    expect(partnerSeesService(_rules, ['Teksi'], '  '), isTrue);
  });

  test('labels: All or N of M, and the summary', () {
    expect(ruleCountLabel(_fleet, 8), 'All');
    expect(ruleCountLabel(_teksi, 8), '4 of 8');
    expect(ruleSummary(_fleet), 'All services');
    expect(ruleSummary(_teksi), 'Teksi, Ride, Comfort, 6-seater');
    expect(ruleSummary(_none), 'No services');
  });

  test('service choices: the catalogue, then services only a rule names, once per key', () {
    expect(serviceChoices(['Ride', 'Comfort', 'Delivery'], [_teksi, _phailing]),
        ['Ride', 'Comfort', 'Delivery', 'Teksi', '6-seater', 'Food', 'Mart']);
    expect(serviceChoices([' ride ', 'RIDE'], const []), ['ride']);
  });

  test('types to add: the partner types without a rule, once per key', () {
    expect(typesWithoutRule(['TEKSI', 'eHailing', 'e-hailing', 'Dealer', ' '], [_teksi]), ['eHailing', 'Dealer']);
  });

  test('a row reads and writes as the table holds it', () {
    final r = PartnerTypeServiceRule.fromRow({
      'type_key': 'teksi',
      'type_name': 'Teksi',
      'all_services': false,
      'services': ['Ride', ' ', null],
      'note': ' Licensed taxi ',
      'updated_at': '2026-10-21T03:15:00Z',
    });
    expect(r.services, ['Ride']);
    expect(r.note, 'Licensed taxi');
    expect(r.updatedAt, DateTime.utc(2026, 10, 21, 3, 15));
    expect(r.toRow(), {
      'type_key': 'teksi',
      'type_name': 'Teksi',
      'all_services': false,
      'services': ['Ride'],
      'note': 'Licensed taxi',
    });
    expect(PartnerTypeServiceRule.fromRow({'type_key': 'x'}).allServices, isTrue, reason: 'the column default');
  });

  test('search matches the name, key, note or a service', () {
    expect(ruleMatches(_teksi, ''), isTrue);
    expect(ruleMatches(_teksi, 'tek'), isTrue);
    expect(ruleMatches(_teksi, 'comf'), isTrue);
    expect(ruleMatches(_teksi, 'food'), isFalse);
    expect(ruleMatches(_teksi, '6-se'), isTrue);
    expect(ruleMatches(_teksi, 'zzz'), isFalse);
  });
}
