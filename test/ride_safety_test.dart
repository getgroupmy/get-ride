// City ride safety (migration 0311): the pure logic in
// lib/src/core/ride_safety.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/date_order.dart';
import 'package:get_ride/src/core/ride_safety.dart';

typedef _Req = ({String id, double? fare, double? away, bool mine});

void main() {
  group('settings', () {
    test('defaults, from a row, problems', () {
      const d = RideSafetySettings();
      expect([d.reportWindowDays, d.maxBlocksPerRider, d.blockFlagRiders], [30, 20, 3]);
      expect(d.limitsLine, 'Limits: minimum fare filter up to RM30; pickup distance 1 to 10 km.');
      final s = RideSafetySettings.fromRow({
        'report_window_days': 14, 'max_blocks_per_rider': 5, 'block_flag_riders': 2, 'filter_min_fare_on': false,
        'filter_min_fare_cap': '40', 'filter_distance_min_km': 0.5, 'filter_distance_max_km': 8, 'show_driver_permit': false,
      });
      expect([s.reportWindowDays, s.maxBlocksPerRider, s.blockFlagRiders], [14, 5, 2]);
      expect([s.minFareOn, s.minFareCap, s.distanceMinKm, s.distanceMaxKm, s.showDriverPermit], [false, 40, 0.5, 8, false]);
      expect(s.toRow()['filter_min_fare_cap'], 40);
      expect(d.problem, isNull);
      expect(d.copyWith(distanceMinKm: 12).problem, contains('shortest pickup distance'));
      expect(d.copyWith(reportWindowDays: 0).problem, isNotNull);
    });
  });

  group('categories', () {
    test('names are unique among the active ones', () {
      const others = [TripReportCategory(label: 'Safety'), TripReportCategory(label: 'Fare', active: false)];
      expect(categoryLabelProblem('  ', others), 'Give the category a name.');
      expect(categoryLabelProblem('safety', others), contains('already'));
      expect(categoryLabelProblem('Fare', others), isNull, reason: 'a removed one frees its name');
      expect(categoryLabelProblem('x' * 41, others), 'Up to 40 characters.');
    });
  });

  group('the receipt', () {
    final info = TripSafetyInfo.fromJson({
      'trip': {'ref': 'GR-80412ABC', 'driver_id': 'd1', 'driver_name': 'Hafiz R.', 'completed': true},
      'can_report': true,
      'report_until': '2027-05-30T10:00:00Z',
      'report_window_days': 30,
      'categories': [
        {'id': 'c1', 'label': 'Safety', 'urgent': true, 'sos_reminder': true},
        {'id': 'c2', 'label': 'Fare'},
      ],
      'blocked': false,
      'cover': {
        'shown': true, 'insurer': 'Contoh Takaful', 'policy_no': 'PA-2026-0001', 'cover_amount': 50000,
        'currency': 'MYR', 'claim_days': 30, 'hotline': '1-300-00-0000',
      },
      'permits': [
        {'name': 'E-hailing vehicle permit (eVP)', 'issuer': 'APAD', 'valid_until': '2027-06-30'},
      ],
    })!;

    test('reads the server, words the cover and the permit', () {
      expect(info.canReport, isTrue);
      expect(info.categories.first.sosReminder, isTrue);
      expect(info.trip.driverLabel, 'Hafiz R.');
      expect(info.coverTitle, 'You were covered on this trip');
      expect(
        info.coverText(order: DateOrder.dmy),
        'Passenger personal accident cover by Contoh Takaful, policy PA-2026-0001, up to RM50,000. '
        'Driver licensed by APAD: E-hailing vehicle permit (eVP) valid to 30/06/2027.',
      );
      expect(info.cover!.claimLine,
          'To claim: report the trip below or call 1-300-00-0000 within 30 days. Cover details are set by the admin per region.');
    });

    test('a permit date follows the user\'s country', () {
      expect(info.permits.single.line(order: DateOrder.mdy), contains('valid to 06/30/2027'));
    });

    test('no cover without real details, or when off', () {
      expect(PassengerCover.fromJson({'shown': false, 'insurer': 'A', 'policy_no': 'P', 'cover_amount': 1}), isNull);
      expect(PassengerCover.fromJson({'shown': true, 'insurer': 'A', 'policy_no': '', 'cover_amount': 1}), isNull);
      expect(PassengerCover.fromJson({'shown': true, 'insurer': 'A', 'policy_no': 'P', 'cover_amount': 0}), isNull);
      expect(TripSafetyInfo.fromJson(null), isNull, reason: 'not the trip\'s rider');
      final permitOnly = TripSafetyInfo.fromJson({
        'trip': {'ref': 'GR-1'},
        'permits': [{'name': 'EVP'}],
      })!;
      expect([permitOnly.showsCoverCard, permitOnly.coverTitle], [true, 'Your driver\'s permit']);
      expect(TripSafetyInfo.fromJson({'trip': {'ref': 'GR-1'}})!.showsCoverCard, isFalse);
    });

    test('the report result in words', () {
      final r = TripReportResult.fromJson({
        'ticket_id': 't1', 'ticket_number': 10233, 'category': 'Safety', 'urgent': true, 'blocked': true,
      });
      expect(r.message('Hafiz R.'),
          'Report sent: ticket #10233 (Safety). Support replies in Help › My tickets. Hafiz R. is blocked.');
      expect(TripReportResult.fromJson({'ticket_id': 't', 'block_error': 'You can block up to 1 drivers.'}).message('X'),
          contains('We couldn\'t block X'));
      expect(blockSheetText('Hafiz R.'), contains('They aren\'t told'));
      expect(blockSheetText('Hafiz R.'), isNot(contains('→')));
    });
  });

  group('request filters', () {
    final list = <_Req>[
      (id: 'a', fare: 14, away: 1.2, mine: false),
      (id: 'b', fare: 22, away: 3.8, mine: false),
      (id: 'c', fare: 9, away: 0.6, mine: false),
      (id: 'd', fare: 85, away: 6.5, mine: false),
      (id: 'e', fare: 12, away: 8.9, mine: false),
      (id: 'f', fare: 5, away: 20, mine: true),
      (id: 'g', fare: null, away: null, mine: false),
    ];
    List<String> ids(RequestFilters f) =>
        applyRequestFilters(list, f, fare: (r) => r.fare, awayKm: (r) => r.away, exempt: (r) => r.mine)
            .shown
            .map((r) => r.id)
            .toList();

    test('none keeps everything, nearest first; newest keeps the order given', () {
      expect(ids(RequestFilters.none), ['c', 'a', 'b', 'd', 'e', 'f', 'g']);
      expect(ids(const RequestFilters(sort: RequestSort.newest)), ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
      expect(RequestFilters.none.summary('MYR'), 'All requests near you, nearest first');
    });

    test('minimum fare and distance hide; exempt and unknown stay; counted', () {
      const f = RequestFilters(minFare: 10, maxKm: 5, sort: RequestSort.newest);
      expect(ids(f), ['a', 'b', 'f', 'g']);
      expect(applyRequestFilters(list, f, fare: (r) => r.fare, awayKm: (r) => r.away, exempt: (r) => r.mine).hidden, 3);
      expect(f.summary('MYR'), 'From RM10 · within 5 km · newest first');
      expect(hiddenRequestsLine(1), '1 request hidden by your filters');
    });

    test('sorts by price or distance', () {
      expect(ids(const RequestFilters(sort: RequestSort.price)), ['d', 'b', 'a', 'e', 'c', 'f', 'g']);
      expect(ids(const RequestFilters(sort: RequestSort.distance)), ['c', 'a', 'b', 'd', 'e', 'f', 'g']);
      expect(const RequestFilters(sort: RequestSort.price).summary('MYR'), 'highest fare first');
    });

    test('within the admin\'s limits; a switched-off filter is none', () {
      const f = RequestFilters(minFare: 80, maxKm: 0.2, sort: RequestSort.price);
      final w = f.within(const RideSafetySettings());
      expect([w.minFare, w.maxKm, w.sort], [30, 1, RequestSort.price]);
      final off = f.within(const RideSafetySettings(minFareOn: false, distanceOn: false, sortOn: false));
      expect(off, RequestFilters.none);
      expect(off.active, isFalse);
    });

    test('saved and read back', () {
      const f = RequestFilters(minFare: 15, maxKm: 4, sort: RequestSort.newest);
      expect(RequestFilters.fromJson(f.toJson()), f);
      expect(RequestFilters.fromJson({'sort': 'nonsense'}).sort, RequestSort.distance);
    });

    test('the queue order: nearest first by default, toward the destination first always', () {
      final items = ['near', 'far', 'toward'];
      final away = {'near': 1.0, 'far': 9.0, 'toward': 5.0};
      expect(requestQueueOrder(items, RequestSort.distance, toward: (x) => x == 'toward', awayKm: (x) => away[x]),
          ['toward', 'near', 'far']);
      expect(requestQueueOrder(['far', 'near', 'toward'], RequestSort.price, toward: (x) => x == 'toward', awayKm: (x) => away[x]),
          ['toward', 'far', 'near']);
    });
  });

  group('admin', () {
    test('the Partners list line', () {
      final flags = driverSafetyFlagsByPartner([
        {'partner_id': 'd1', 'reports': 3, 'urgent': 1, 'blocks': 4, 'blocks_since_review': 4, 'flagged': true},
        {'partner_id': 'd2', 'reports': 0, 'blocks': 1},
        {'partner_id': ''},
      ]);
      expect(flags.keys, ['d1', 'd2']);
      expect(flags['d1']!.line, 'Reports: 3 (1 urgent) · Blocked by 4 riders, review');
      expect(flags['d2']!.line, 'Blocked by 1 rider');
      expect(const DriverSafetyFlag().line, isNull);
    });

    test('one driver\'s reports and blocks', () {
      final d = AdminDriverSafety.fromJson({
        'flag_riders': 2, 'blocks_since_review': 2,
        'reports': [{'ticket_id': 't1', 'ticket_number': 5, 'category': 'Safety', 'urgent': true, 'status': 'open'}],
        'blocks': [{'rider_name': 'Rider A', 'blocked_at': '2027-01-01T00:00:00Z', 'source': 'report'}],
      });
      expect([d.flagged, d.reports.single.number, d.blocks.single.source], [true, 5, 'report']);
    });

    test('cover rules: the most specific wins, even one that is off', () {
      const rules = [
        CoverRule(insurer: 'Default Co', policyNo: 'D-1', coverAmount: 1000),
        CoverRule(country: 'Malaysia', insurer: 'Contoh Takaful', policyNo: 'PA-1', coverAmount: 50000),
        CoverRule(country: 'Malaysia', state: 'Sabah', enabled: false),
      ];
      expect(coverRuleFor(rules, country: 'malaysia', state: 'Selangor')!.insurer, 'Contoh Takaful');
      expect(coverRuleFor(rules, country: 'Malaysia', state: 'Sabah')!.shown, isFalse);
      expect(coverRuleFor(rules, country: 'Thailand')!.insurer, 'Default Co');
      expect(rules[1].summary, 'Insurer: Contoh Takaful · Policy: PA-1 · Cover: RM50,000');
      expect(rules[2].summary, 'Off: no cover shown here');
      expect(const CoverRule(country: 'Malaysia').summary, contains('riders see nothing'));
      expect(const CoverRule(termsUrl: 'ftp://x').problem, contains('https://'));
      expect(const CoverRule(state: 'Sabah').problem, isNotNull);
      expect(rules[0].placeLabel, 'Default (everywhere else)');
    });

    test('support: urgent open reports first, chips', () {
      final tickets = [
        {'id': '1', 'status': 'open'},
        {'id': '2', 'status': 'open', 'priority': 'urgent', 'report_category': 'Safety', 'reported_at': 'x'},
        {'id': '3', 'status': 'closed', 'priority': 'urgent', 'report_category': 'Safety', 'reported_at': 'x'},
        {'id': '4', 'status': 'open', 'priority': 'normal', 'report_category': 'Fare', 'reported_at': 'x'},
      ];
      expect(urgentTicketsFirst(tickets).map((t) => t['id']), ['2', '1', '3', '4']);
      expect(ticketReportChip(tickets[1]), 'Urgent · Safety');
      expect(ticketReportChip(tickets[3]), 'Report · Fare');
      expect(ticketReportChip(tickets[0]), isNull);
    });
  });
}
