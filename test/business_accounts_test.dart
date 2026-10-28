// Business accounts (migration 0313): the settings resolution (the server's
// business_rule_settings, on the cases of
// supabase/tests/business_accounts_0313.sql), the payment, the invoice CSV
// and PDF, and the pages: Account › Business (the list, one account's
// Overview, Members, Rules and Invoices, applying) and Admin › People ›
// Business accounts (the list, one account, the defaults), in light and
// dark, wide and on a phone.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/business/business_accounts_screen.dart';
import 'package:get_ride/src/admin/screens/business/business_defaults_screen.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/business_accounts.dart';
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/ride_payment.dart';
import 'package:get_ride/src/data/business_repository.dart';
import 'package:get_ride/src/features/business/business_apply_screen.dart';
import 'package:get_ride/src/features/business/business_booking.dart';
import 'package:get_ride/src/features/business/business_invoice_files.dart';
import 'package:get_ride/src/features/business/business_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _default = BusinessRegionRule(
  id: 'd',
  values: BusinessValues(
    creditLimit: 10000,
    dueDays: 30,
    overdueDays: 14,
    discountPct: 5,
    commissionPct: 15,
    memberLimit: 500,
    terms: BusinessTerms.invoice,
    services: {...BusinessService.values},
  ),
);

final _rules = [
  _default,
  const BusinessRegionRule(id: 'c', country: 'Bizland 313', values: BusinessValues(creditLimit: 2500), position: 1),
  const BusinessRegionRule(
    id: 's',
    country: 'Bizland 313',
    state: 'North 313',
    values: BusinessValues(dueDays: 14, terms: BusinessTerms.wallet),
    position: 1,
  ),
  const BusinessRegionRule(
    id: 'p',
    country: 'Bizland 313',
    state: 'North 313',
    city: 'Port 313',
    values: BusinessValues(creditLimit: 9000),
    position: 1,
  ),
  const BusinessRegionRule(id: 'off', country: 'Bizland 313', state: 'South 313', values: BusinessValues(discountPct: 40), active: false),
];

const _detail = {
  'id': 'acc',
  'name': 'Contoh Trading',
  'regNo': '202301031300',
  'status': 'active',
  'role': 'admin',
  'memberId': 'm1',
  'isAdmin': true,
  'settings': {
    'creditLimit': 10000, 'dueDays': 30, 'overdueDays': 14, 'discountPct': 5, 'commissionPct': 15,
    'memberLimit': 500, 'terms': 'invoice', 'services': ['ride', 'scheduled', 'freight', 'courier'],
  },
  'monthSpend': 4812.4,
  'monthTrips': 63,
  'monthDeliveries': 41,
  'mySpend': 120,
  'myLimit': 0,
  'nextInvoice': '2026-11-01',
  'walletBalance': 0,
  'rules': {'hoursOn': true, 'hoursFrom': 7, 'hoursUntil': 22, 'noteRequired': true, 'approvalOn': true,
            'approvalOver': 50, 'capOn': true, 'monthlyCap': 8000, 'bookersFreight': true},
  'members': [
    {'id': 'm1', 'name': 'Aisyah K.', 'phone': '+60100313101', 'role': 'admin', 'team': 'Finance', 'monthlyLimit': null, 'status': 'active', 'spend': 0},
    {'id': 'm2', 'name': 'Ravi M.', 'phone': '+60100313102', 'role': 'booker', 'team': 'Logistics', 'monthlyLimit': 3000, 'status': 'active', 'spend': 210},
    {'id': 'm3', 'name': 'Daniel T.', 'phone': '+60100313103', 'role': 'rider', 'team': 'Sales', 'monthlyLimit': 0, 'status': 'invited', 'spend': 0},
  ],
  'invoices': [
    {'id': 'i1', 'invoice_no': 'GR2610-ABC123', 'terms': 'invoice', 'period_start': '2026-10-01', 'period_end': '2026-10-31',
     'status': 'open', 'amount': 4812.4, 'trips': 104},
    {'id': 'i2', 'invoice_no': 'GR2609-ABC123', 'terms': 'invoice', 'period_start': '2026-09-01', 'period_end': '2026-09-30',
     'status': 'paid', 'amount': 6120, 'trips': 130, 'paid_at': '2026-09-28T04:00:00Z'},
  ],
  'approvals': [
    {'id': 'a1', 'member': 'Ravi M.', 'amount': 82, 'service': 'Car', 'pickup': 'Office', 'dropoff': 'KLIA', 'note': 'Client', 'status': 'pending'},
  ],
};

class _Repo extends BusinessRepository {
  _Repo() : super(_db);

  List<BusinessMembership> mine = [
    const BusinessMembership(accountId: 'acc', name: 'Contoh Trading', role: BusinessRole.admin),
    const BusinessMembership(accountId: 'inv', name: 'Syarikat Lain', role: BusinessRole.rider, memberStatus: 'invited'),
  ];
  final calls = <String>[];
  BusinessRules? savedRules;
  BusinessRegionRule? savedRule;
  BusinessValues? savedOverrides;
  final limits = <(String, double?)>[];

  @override
  Future<List<BusinessMembership>> myAccounts() async => mine;
  @override
  Future<BusinessAccountDetail> detail(String accountId) async => BusinessAccountDetail.fromJson(_detail);
  @override
  Future<void> join(String accountId) async => calls.add('join $accountId');
  @override
  Future<void> leave(String accountId) async => calls.add('leave $accountId');
  @override
  Future<void> setRules(String accountId, BusinessRules rules) async => savedRules = rules;
  @override
  Future<void> decideApproval(String approvalId, bool approve) async => calls.add('decide $approvalId $approve');
  @override
  Future<void> updateMember(String memberId, {BusinessRole? role, String? team, double? limit, bool defaultLimit = false}) async =>
      limits.add((memberId, limit));
  @override
  Future<void> invite(String accountId, {required String phone, String? name, required BusinessRole role, String? team, double? limit}) async =>
      calls.add('invite $phone ${role.name}');
  @override
  Future<List<AdminBusinessAccount>> adminAccounts() async => [
    AdminBusinessAccount(const {
      'id': 'acc', 'name': 'Contoh Trading', 'reg_no': '202301031300', 'status': 'pending', 'country': 'Malaysia',
      'state': 'Selangor', 'city': '', 'document_url': 'https://x.supabase.co/storage/v1/object/business-documents/u/ssm.png',
      'wallet_balance': 0, 'hours_on': false, 'hours_from': 7, 'hours_until': 22, 'approval_over': 50, 'monthly_cap': 8000,
      'bookers_freight': true, 'discount_pct': 8, 'profiles': {'name': 'Aisyah', 'phone': '+60100313101'},
    }, members: 3),
    AdminBusinessAccount(const {'id': 'b', 'name': 'Active Sdn Bhd', 'reg_no': '1', 'status': 'active', 'country': 'Malaysia', 'state': 'Sabah'}),
  ];
  @override
  Future<List<BusinessInvoice>> adminInvoices(String accountId) async => [
    BusinessInvoice.fromJson(const {
      'id': 'i3', 'invoice_no': 'GR2609-ABC123', 'terms': 'invoice', 'period_start': '2026-09-01', 'status': 'issued',
      'amount': 6120, 'trips': 130, 'due_date': '2026-10-31',
    }),
  ];
  @override
  Future<List<Map<String, dynamic>>> adminWallet(String accountId) async => const [];
  @override
  Future<List<BusinessMember>> adminMembers(String accountId) async =>
      [const BusinessMember(id: 'm1', phone: '+60100313101', name: 'Aisyah K.', role: BusinessRole.admin)];
  @override
  Future<void> setStatus(String accountId, String status, {String? note}) async => calls.add('status $status');
  @override
  Future<void> saveAccount(String accountId, {Map<String, dynamic> details = const {}, BusinessValues? overrides}) async =>
      savedOverrides = overrides;
  @override
  Future<void> markPaid(String invoiceId, {String? note}) async => calls.add('paid $invoiceId');
  @override
  Future<List<BusinessRegionRule>> regionRules() async => _rules;
  @override
  Future<void> saveRegionRule(BusinessRegionRule r) async => savedRule = r;
}

Future<_Repo> _pump(WidgetTester tester, Widget home, {Brightness b = Brightness.light, Size size = const Size(1300, 2400), bool canEdit = true}) async {
  final repo = _Repo();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        ...quietLiveOverrides,
        pageAccessProvider.overrideWith((ref, page) => canEdit ? AccessLevel.edit : AccessLevel.read),
        businessRepositoryProvider.overrideWithValue(repo),
        currentUserIdProvider.overrideWithValue('u1'),
      ],
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await closeAnyNotice(tester);
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

void main() {
  group('settings', () {
    BusinessValues at(String c, [String s = '', String city = '']) => resolveBusinessValues(_rules, country: c, state: s, city: city);

    test('the Default answers every value everywhere', () {
      expect(at('Nowhere').isComplete, isTrue);
      expect(at('Nowhere').creditLimit, 10000);
    });
    test('a state rule leaves the country\'s credit limit and sets its own', () {
      final v = at('Bizland 313', 'North 313');
      expect([v.creditLimit, v.dueDays, v.terms], [2500, 14, BusinessTerms.wallet]);
    });
    test('the narrowest rule wins, names in any case', () {
      expect(at('bizland 313', 'north 313', 'port 313').creditLimit, 9000);
    });
    test('an inactive rule is skipped', () => expect(at('Bizland 313', 'South 313').discountPct, 5));
    test('the account overrides on top', () {
      final v = resolveBusinessValues(_rules,
          country: 'Bizland 313', state: 'North 313', overrides: const BusinessValues(creditLimit: 100, discountPct: 10));
      expect([v.creditLimit, v.discountPct, v.dueDays], [100, 10, 14]);
    });
    test('what a rule follows comes from the rules above it', () {
      final city = _rules.firstWhere((r) => r.id == 'p');
      expect(businessValuesAbove(_rules, city).creditLimit, 2500);
      expect(businessValuesAbove(_rules, _default).isEmpty, isTrue);
    });
    test('region names as the server compares them', () {
      expect(regionNameNorm('W.P. Kuala Lumpur'), 'w p kuala lumpur');
      expect(regionNameNorm('Wilayah Persekutuan Labuan'), 'labuan');
    });
    test('values read as on the page, and step within bounds', () {
      expect(BusinessField.memberLimit.show(0.0), 'No limit');
      expect(BusinessField.creditLimit.show(20000.0), 'RM 20,000');
      expect(BusinessField.overdueDays.stepped(1, -1), 1);
      expect(BusinessField.discountPct.stepped(5.0, 1), 6.0);
      expect(BusinessField.services.show({BusinessService.ride, BusinessService.courier}), 'City rides, Courier');
    });
  });

  group('the payment', () {
    const accounts = [
      BusinessMembership(accountId: 'a', name: 'Alpha', role: BusinessRole.rider),
      BusinessMembership(accountId: 'b', name: 'Beta', role: BusinessRole.booker, bookersFreight: false),
      BusinessMembership(accountId: 'c', name: 'Gamma', role: BusinessRole.admin, status: 'suspended'),
      BusinessMembership(accountId: 'd', name: 'Delta', role: BusinessRole.admin, memberStatus: 'invited'),
      BusinessMembership(accountId: 'e', name: 'Epsilon', role: BusinessRole.admin, services: {BusinessService.freight}),
    ];
    test('offered where the member may book that kind of trip', () {
      expect([for (final c in businessPaymentChoices(accounts, BusinessService.ride)) c.label], ['Business: Alpha', 'Business: Beta']);
      expect([for (final c in businessPaymentChoices(accounts, BusinessService.freight)) c.label], ['Business: Epsilon']);
      expect(businessPaymentChoices(accounts, BusinessService.ride).first.kind, PaymentKind.business);
    });
    test('its value names the account; the ride stores the label', () {
      final v = businessPaymentValue('a');
      expect(businessAccountIdOf(v), 'a');
      expect(businessAccountIdOf('Cash'), isNull);
      final choices = withBusinessPayments(builtInPayments, accounts, BusinessService.ride);
      expect(bookedPaymentMode(v, choices), 'Business: Alpha');
      expect(bookedPaymentMode('Cash', choices), 'Cash');
      expect(resolvePayment(v, choices), v, reason: 'kept while offered');
      expect(paymentKindOf('Business: Alpha'), PaymentKind.business);
    });
    test('the trip paid by the business', () {
      expect(RidePayMethod.parse('business'), RidePayMethod.business);
      expect(ridePaidSummary(RidePayMethod.business, 'RM 20.00'), 'RM 20.00 charged to the business account');
      expect(
        ridePayOptions(due: 10, walletBalance: 0, coinBalance: 0, coinsPerCurrency: 1, money: (v) => '$v', coins: (v) => '$v',
            others: businessPaymentChoices(accounts, BusinessService.ride)).length,
        2,
        reason: 'never a way to pay a trip after it ends',
      );
    });
  });

  group('invoices as files', () {
    final file = BusinessInvoiceFile.fromJson({
      'invoice': {'id': 'i', 'invoice_no': 'GR2609-ABC', 'terms': 'invoice', 'period_start': '2026-09-01', 'status': 'issued',
                  'amount': 27, 'due_date': '2026-10-31'},
      'account': {'name': 'Contoh Trading', 'regNo': '2023', 'address': 'Lot 1', 'state': 'Selangor', 'country': 'Malaysia'},
      'lines': [
        {'at': '2026-09-03T02:05:00Z', 'member': 'Ravi', 'team': 'Logistics', 'service': 'Car', 'pickup': 'Office, Level 3',
         'dropoff': 'Client "A"', 'note': 'Visit', 'gross': 20, 'discount': 2, 'charged': 18},
        {'at': '2026-09-04T02:05:00Z', 'member': 'Siti', 'service': 'Van', 'pickup': 'A', 'dropoff': 'B', 'gross': 10, 'discount': 1, 'charged': 9},
      ],
    });
    test('CSV: a header, a row a trip, the total; commas and quotes kept', () {
      final csv = businessInvoiceCsv(file).split('\r\n');
      expect(csv.first, startsWith('Date,Member,Team'));
      expect(csv[1], contains('"Office, Level 3","Client ""A"""'));
      expect(csv[3], 'Total,,,,,,,,30.00,3.00,27.00');
    });
    test('PDF builds', () async {
      final Uint8List bytes = await buildBusinessInvoicePdf(file, today: DateTime(2026, 10, 2));
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });
    test('status words', () {
      final i = file.invoice;
      expect(i.statusLabel(DateTime(2026, 10, 2)), 'Due 31 Oct');
      expect(i.statusLabel(DateTime(2026, 11, 2)), 'Overdue since 31 Oct');
      expect(i.monthLabel, 'September 2026');
      expect(businessMoneyCents(4812.4), 'RM 4,812.40');
    });
  });

  test('listed under People, grantable', () {
    final list = allAdminEntries.firstWhere((e) => e.path == businessAccountsPath);
    expect(list.section, 'People');
    expect(list.pages, [businessAccountsPage]);
    expect(allAdminEntries.any((e) => e.path == businessDefaultsPath), isTrue);
    expect(grantablePages, contains(businessAccountsPage));
  });

  for (final b in Brightness.values) {
    testWidgets('Account › Business: accounts and an invitation (${b.name})', (tester) async {
      final repo = await _pump(tester, const BusinessHomeScreen(), b: b, size: const Size(400, 900));
      expect(tester.takeException(), isNull);
      expect(find.text('Contoh Trading'), findsOneWidget);
      expect(find.text('You were invited as Rider'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('business-join-inv')));
      expect(repo.calls, ['join inv']);
      await closeAnyNotice(tester);
      expect(find.byKey(const ValueKey('business-apply')), findsOneWidget);
    });

    testWidgets('one account: overview, members, rules, invoices (${b.name})', (tester) async {
      final repo = await _pump(tester, const BusinessAccountScreen(id: 'acc'), b: b, size: const Size(400, 1600));
      expect(tester.takeException(), isNull);
      expect(find.text('RM 4,812.40'), findsOneWidget);
      expect(find.text('63 trips · 41 deliveries'), findsOneWidget);
      expect(find.text('RM 10,000'), findsOneWidget);
      expect(find.text('Due in 30 days'), findsOneWidget);
      expect(find.textContaining('"Business: Contoh Trading"'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('business-approve-a1')));
      expect(repo.calls, ['decide a1 true']);

      await _tap(tester, find.byKey(const ValueKey('business-tab-Members')));
      expect(find.text('Ravi M.'), findsOneWidget);
      expect(find.text('RM 3,000'), findsOneWidget);
      expect(find.text('RM 500'), findsOneWidget, reason: "the Admin follows the account's default");
      await _tap(tester, find.byTooltip('Raise Monthly limit').at(1));
      expect(repo.limits, [('m2', 3100.0)]);

      await _tap(tester, find.byKey(const ValueKey('business-tab-Rules')));
      expect(find.text('07:00'), findsOneWidget);
      await _tap(tester, find.byTooltip('Raise Above'));
      expect(find.text('RM 60'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('business-rule-note')));
      await _tap(tester, find.byKey(const ValueKey('business-rules-save')));
      expect([repo.savedRules?.approvalOver, repo.savedRules?.noteRequired], [60, false]);

      await _tap(tester, find.byKey(const ValueKey('business-tab-Invoices')));
      expect(find.text('October 2026'), findsOneWidget);
      expect(find.text('RM 4,812.40 (so far)'), findsOneWidget);
      expect(find.byKey(const ValueKey('business-invoice-pdf-i1')), findsOneWidget);
      expect(find.byKey(const ValueKey('business-invoice-csv-i2')), findsOneWidget);
    });
  }

  testWidgets('invite by phone', (tester) async {
    final repo = await _pump(tester, const BusinessAccountScreen(id: 'acc'), size: const Size(400, 1600));
    await _tap(tester, find.byKey(const ValueKey('business-tab-Members')));
    await _tap(tester, find.byKey(const ValueKey('business-invite')));
    await tester.enterText(find.byKey(const ValueKey('business-invite-phone')), '+60 12 345 6789');
    await _tap(tester, find.text('Booker'));
    await _tap(tester, find.byKey(const ValueKey('business-invite-send')));
    expect(repo.calls, ['invite +60 12 345 6789 booker']);
  });

  testWidgets('applying: the document, then the details', (tester) async {
    await _pump(tester, const BusinessApplyScreen(), size: const Size(400, 1600));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('business-doc-photo')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('business-apply-send')));
    expect(find.text('Enter the company name and its SSM number.'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('admin: the list and one account (${b.name})', (tester) async {
      final repo = await _pump(tester, const BusinessAccountsAdminScreen(), b: b);
      expect(find.text('Contoh Trading'), findsOneWidget);
      expect(find.text('Active Sdn Bhd'), findsNothing, reason: 'waiting ones first');
      await _tap(tester, find.byKey(const ValueKey('biz-filter-all')));
      expect(find.text('Active Sdn Bhd'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      final r2 = await _pump(tester, const BusinessAccountAdminScreen(id: 'acc'), b: b);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('biz-open-document')), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('biz-approve')));
      await _tap(tester, find.byKey(const ValueKey('biz-status-confirm')));
      expect(r2.calls, ['status active']);
      // The discount is set for this account (8%); the credit limit follows the defaults.
      expect(find.text('8%'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('biz-set-creditLimit')));
      await _tap(tester, find.byTooltip('Raise Starting credit limit'));
      await _tap(tester, find.byKey(const ValueKey('biz-overrides-save')));
      expect([r2.savedOverrides?.creditLimit, r2.savedOverrides?.discountPct], [11000, 8]);
      await _tap(tester, find.byKey(const ValueKey('biz-invoice-paid-i3')));
      await _tap(tester, find.text('Mark paid').last);
      expect(r2.calls, ['status active', 'paid i3']);
      expect(repo.calls, isEmpty);
    });

    testWidgets('admin: the defaults per region (${b.name})', (tester) async {
      final repo = await _pump(tester, const BusinessDefaultsScreen(), b: b, size: const Size(400, 2600));
      expect(tester.takeException(), isNull);
      expect(find.text('RM 10,000'), findsOneWidget);
      await _tap(tester, find.byTooltip('Raise Business discount'));
      await _tap(tester, find.byKey(const ValueKey('biz-region-save')));
      expect(repo.savedRule?.values.discountPct, 6);
      await _tap(tester, find.byKey(const ValueKey('biz-region-North 313, Bizland 313')));
      expect(find.textContaining('Follows the rule above: RM 2,500'), findsOneWidget);
      expect(find.text('14 days'), findsWidgets);
    });
  }

  testWidgets('admin, read-only', (tester) async {
    await _pump(tester, const BusinessAccountAdminScreen(id: 'acc'), canEdit: false, size: const Size(400, 2600));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('biz-approve')), findsNothing);
    expect(find.byKey(const ValueKey('biz-overrides-save')), findsNothing);
  });
}
