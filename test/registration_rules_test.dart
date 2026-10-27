// Partner registration rules checked by the server (0305, docs/KIV.md M6):
// what a refusal says, the driver's modal per rule, the "Before you submit"
// checklist, the admin's banner words and rules card, and the Partner
// Service type's "Partners affected now" list, in light and dark. Made-up
// people only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/catalogue/partner_rule_failures.dart';
import 'package:get_ride/src/core/date_order.dart';
import 'package:get_ride/src/core/document_text.dart' show IdDocType;
import 'package:get_ride/src/core/partner_onboarding.dart' show OnboardingStep;
import 'package:get_ride/src/core/registration_rules.dart';
import 'package:get_ride/src/features/partner/registration_rules_parts.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'partner_registration_fixture.dart';

Map<String, dynamic> _partner([Map<String, dynamic> extra = const {}]) => {
      'id': 'p1',
      'partner_types': ['eHailing', 'Teksi'],
      'service_countries': ['Malaysia'],
      'service_states': ['Malaysia|Selangor'],
      'service_cities': ['Malaysia|Selangor|Ampang'],
      ...extra,
    };

const _myKad = {'id_type': 'mykad', 'ic': '900101-14-5566', 'nationality': 'Malaysian'};

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  group('what the server says', () {
    test('a refusal names its rules from the detail, else its hint', () {
      const e = PostgrestException(
        message: 'BUSINESS_REGISTRATION_REQUIRED',
        code: '42501',
        hint: 'Dealer in Malaysia needs a company number.',
        details: '[{"rule":"business_registration","status":"failed","type":"Dealer","place":"Malaysia",'
            '"missing":["registration document"],"message":"Dealer in Malaysia needs a company number."}]',
      );
      final p = ruleProblemsFromError(e).single;
      expect((p.rule, p.type, p.place), (RegRule.businessRegistration, 'Dealer', 'Malaysia'));
      expect(p.missing, ['registration document']);
      final bare = ruleProblemsFromError(const PostgrestException(message: 'DRIVER_PERMIT_REQUIRED', hint: 'Upload it.'));
      expect((bare.single.rule, bare.single.message), (RegRule.driverPermit, 'Upload it.'));
      expect(ruleProblemsFromError(const PostgrestException(message: 'PARTNER_TYPES_LOCKED', hint: 'x')), isEmpty);
      expect(ruleProblemsFromError(Exception('CITIZENS_ONLY')), isEmpty);
    });

    test('the modal per rule, in the mockup words', () {
      final citizen = submitRefusal(
        const RuleProblem(rule: RegRule.citizensOnly, type: 'eHailing', place: 'Malaysia'),
        idType: IdDocType.passport,
        idNumber: 'P-48210771',
      );
      expect(citizen.title, 'eHailing is for Malaysian citizens');
      expect(citizen.body,
          'eHailing in Malaysia takes partners with a MyKad only. Your ID is a passport (P-48210771). Choose another '
          'Partner Service type, or sign up with a MyKad.');
      expect((citizen.action, citizen.step), ('Change type', OnboardingStep.partnerType));

      final company = submitRefusal(const RuleProblem(rule: RegRule.businessRegistration, type: 'Dealer', place: 'Malaysia'));
      expect(company.title, 'Add your company registration');
      expect(company.body,
          'Dealer in Malaysia needs a company number and the registration document (SSM). Add them, then submit again.');
      expect(company.note, 'Missing: company number, registration document.');
      expect((company.action, company.step), ('Add company', OnboardingStep.company));

      final permit = submitRefusal(
          const RuleProblem(rule: RegRule.driverPermit, type: 'Teksi', place: 'Malaysia', permit: 'PSV', permitState: 'missing'));
      expect(permit.title, 'Upload your driver permit (PSV)');
      expect(permit.body,
          'Teksi in Malaysia needs a PSV. Upload a photo of the front, with the expiry date showing, then submit again.');
      expect(permit.note, 'The rest of your sign-up is saved.');
      expect((permit.action, permit.step), ('Upload', OnboardingStep.driverPermit));

      final sg = submitRefusal(const RuleProblem(rule: RegRule.citizensOnly, type: 'Hail', place: 'Singapore'),
          idType: IdDocType.mypr);
      expect(sg.title, 'Hail is for citizens of Singapore');
    });

    test("the admin's banner and rules card", () {
      const failed = [
        RuleProblem(rule: RegRule.businessRegistration, type: 'Dealer', place: 'Malaysia', message: 'No company.'),
      ];
      expect(approveBlockedTitle(failed), "Can't approve: Business registration missing (Dealer needs it in Malaysia)");
      final rows = reviewRuleRows([
        ...failed,
        const RuleProblem(rule: RegRule.vehiclePermit, status: 'paused', type: 'eHailing', message: 'Waiting.'),
      ]);
      expect([for (final r in rows) r.chip], ['Not set', 'Failed', 'Not set', 'Paused', 'Not set']);
      expect(reviewRuleRows(failed, overridden: true)[1].chip, 'Overridden');
      expect(askLineFor(failed.single)!.key, 'company.document');
      expect(askLineFor(const RuleProblem(rule: RegRule.citizensOnly))!.key, 'services');
      expect(askLineFor(const RuleProblem(rule: RegRule.driverPermit, permitState: 'expired'))!.key, 'permit.valid_until');
      expect(askLineFor(const RuleProblem(rule: RegRule.vehicleAge)), isNull);
      expect(
        ruleFailureWhy((
          partnerId: 'p9',
          name: 'Test Driver Alpha',
          status: 'unapproved',
          problems: const [RuleProblem(rule: RegRule.citizensOnly, idType: IdDocType.passport)],
        )),
        'Citizens only: passport, not a citizen ID',
      );
    });
  });

  group('Before you submit', () {
    final now = DateTime(2026, 10, 27);

    test('Done, Needed, Later and Not needed, from the same rules as the server', () {
      final rows = submitChecklist(
        profile: _myKad,
        partner: _partner(),
        entries: regEntries,
        vehicle: const {'plate': 'WXY 1234', 'year': '2021'},
        now: now,
        order: DateOrder.dmy,
      );
      expect([for (final r in rows) (r.name, r.state)], [
        ('Citizens only', CheckState.done),
        ('Company registration', CheckState.needed),
        ('Driver permit (Kad Pemandu)', CheckState.needed),
        ('Driver permit expiry', CheckState.needed),
        ('Vehicle permit (EVP)', CheckState.later),
        ('Vehicle age', CheckState.done),
      ]);
      expect(rows.first.detail, 'eHailing, Teksi: MyKad 900101-14-5566');
      expect(rows[2].detail, 'Teksi: upload Kad Pemandu');
      expect(rows[3].detail, 'Type the expiry date');
      expect(rows[4].detail, 'eHailing, also Teksi: paused until uploaded');
      expect(rows[5].detail, 'WXY 1234, 2021: within 20 years (Teksi covers eHailing)');
      expect(rows[1].step, OnboardingStep.company);
      expect(checklistLead(_partner()), 'You chose eHailing and Teksi in Malaysia. These are the rules the server checks when you submit.');
    });

    test('a passport on a citizens-only type, an expired permit, an old vehicle', () {
      final rows = submitChecklist(
        profile: const {'id_type': 'passport', 'ic': 'P1', 'nationality': 'Indonesian'},
        partner: _partner({
          'company_reg_no': '201901012345',
          'company_document_url': 'https://x/ssm.pdf',
          'driver_permit_card_no': 'KP1',
          'driver_permit_front_url': 'https://x/kp.jpg',
          'driver_permit_valid_until': '2026-09-03',
        }),
        entries: regEntries,
        vehicle: const {'plate': 'WXY 1234', 'year': '2001'},
        now: now,
        order: DateOrder.dmy,
      );
      final byName = {for (final r in rows) r.name: r};
      expect(byName['Citizens only']!.state, CheckState.needed);
      expect(byName['Citizens only']!.step, OnboardingStep.partnerType);
      expect(byName['Company registration']!.state, CheckState.done);
      expect(byName['Driver permit (Kad Pemandu)']!.state, CheckState.done);
      expect(byName['Driver permit expiry']!.detail, 'Expired 03/09/2026: upload the new one');
      expect(byName['Vehicle age']!.state, CheckState.later, reason: 'over the limit pauses, never refuses');
    });

    test('a type with no rules: nothing needed', () {
      final rows = submitChecklist(profile: _myKad, partner: _partner({'partner_types': ['Delivery']}), entries: regEntries);
      expect(rows.every((r) => r.state == CheckState.notNeeded), isTrue);
    });
  });

  for (final b in Brightness.values) {
    group('screens (${b.name})', () {
      Future<void> phone(WidgetTester tester, Widget child) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(
          child: MaterialApp(theme: ThemeData(brightness: b), home: Scaffold(body: child)),
        ));
        await _settle(tester);
      }

      for (final (problem, title, action, step) in [
        (
          const RuleProblem(rule: RegRule.citizensOnly, type: 'eHailing', place: 'Malaysia'),
          'eHailing is for Malaysian citizens',
          'Change type',
          OnboardingStep.partnerType,
        ),
        (
          const RuleProblem(rule: RegRule.businessRegistration, type: 'Dealer', place: 'Malaysia'),
          'Add your company registration',
          'Add company',
          OnboardingStep.company,
        ),
        (
          const RuleProblem(rule: RegRule.driverPermit, type: 'Teksi', place: 'Malaysia', permit: 'PSV'),
          'Upload your driver permit (PSV)',
          'Upload',
          OnboardingStep.driverPermit,
        ),
      ]) {
        testWidgets('the refused-Submit modal: $title', (tester) async {
          OnboardingStep? got;
          var closed = false;
          await phone(
            tester,
            Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () async {
                    got = await showSubmitRefused(context, problem, idType: IdDocType.passport, idNumber: 'P-1');
                    closed = true;
                  },
                  child: const Text('Submit'),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Submit'));
          await _settle(tester);
          expect(find.text(title), findsOneWidget);
          expect(find.text('Not submitted'), findsOneWidget);
          expect(find.text('OK'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(action));
          await _settle(tester);
          expect((closed, got), (true, step));
        });
      }

      testWidgets('the checklist: Needed rows, Fix the first one and Submit anyway', (tester) async {
        final fixed = <OnboardingStep>[];
        var anyway = 0;
        await phone(
          tester,
          SingleChildScrollView(
            child: SubmitChecklist(
              lead: checklistLead(_partner()),
              rows: submitChecklist(
                profile: _myKad,
                partner: _partner(),
                entries: regEntries,
                vehicle: const {'plate': 'WXY 1234', 'year': '2021'},
                now: DateTime(2026, 10, 27),
              ),
              submit: const Text('Submit for review'),
              onFix: fixed.add,
              onSubmitAnyway: () => anyway++,
            ),
          ),
        );
        expect(find.text('Before you submit'), findsOneWidget);
        expect(find.text('3 needed before you can submit'), findsOneWidget);
        expect(find.text('Submit for review'), findsNothing);
        expect(find.text('Later'), findsOneWidget);
        expect(find.text('"Needed" items stop the submission. "Later" items only pause that service until you add them.'),
            findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('checklist-fix')));
        await tester.tap(find.byKey(const ValueKey('checklist-fix')));
        await tester.tap(find.byKey(const ValueKey('checklist-submit-anyway')));
        expect(fixed, [OnboardingStep.company]);
        expect(anyway, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Partner registration: checked by the server, and who would fail now', (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            partnerRuleFailuresProvider.overrideWith((ref, type) async => [
                  (
                    partnerId: 'p1',
                    name: 'Test Driver Alpha',
                    status: 'unapproved',
                    problems: const [RuleProblem(rule: RegRule.citizensOnly, idType: IdDocType.passport)],
                  ),
                  (
                    partnerId: 'p2',
                    name: 'Test Driver Bravo',
                    status: 'approved',
                    problems: const [RuleProblem(rule: RegRule.driverPermit, permitState: 'missing')],
                  ),
                ]),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: b),
            home: const Scaffold(body: ServerCheckedNote(type: 'eHailing')),
          ),
        ));
        await _settle(tester);
        expect(find.text('Checked by the server on submit and approval'), findsOneWidget);
        expect(find.text('Partners affected now: 2 would fail'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('pst-rule-failures')));
        await _settle(tester);
        expect(find.text('Would fail now (2)'), findsOneWidget);
        expect(find.text('Test Driver Alpha'), findsOneWidget);
        expect(find.text('Pending'), findsOneWidget);
        expect(find.text('Approved'), findsOneWidget);
        expect(find.text('Citizens only: passport, not a citizen ID'), findsOneWidget);
        expect(find.text('Driver permit: none uploaded'), findsOneWidget);
        expect(find.text('Open review'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a new type: the server line, no list', (tester) async {
        await phone(tester, const ServerCheckedNote());
        expect(find.text('Checked by the server on submit and approval'), findsOneWidget);
        expect(find.byKey(const ValueKey('pst-rule-failures')), findsNothing);
      });
    });
  }
}
