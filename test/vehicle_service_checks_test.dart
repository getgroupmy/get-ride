// The vehicle's service at registration and on the review (docs/KIV.md M1),
// and the per-service checks the server works out for every vehicle (M9,
// migration 0301): the pure pieces, and the Vehicle service field in light
// and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart' show ServiceArea;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/partner_registration.dart';
import 'package:get_ride/src/core/partner_review.dart';
import 'package:get_ride/src/core/vehicle_onboarding.dart';
import 'package:get_ride/src/features/partner/vehicle_service_parts.dart';

const _options = <VehicleServiceOption>[(id: 'ride', name: 'Ride'), (id: 'comfort', name: 'Comfort')];

void main() {
  group('the vehicle service (M1)', () {
    test('the services a driver picks from: switched on, by display priority, then in order', () {
      final options = vehicleServiceOptions([
        (id: 'premium', values: <String, dynamic>{'name': 'Premium', 'displayPriority': 3}),
        (id: 'ride', values: <String, dynamic>{'name': 'Ride', 'displayPriority': 1}),
        (id: 'old', values: <String, dynamic>{'name': 'Old', 'status': false}),
        (id: 'nameless', values: <String, dynamic>{}),
        (id: 'comfort', values: <String, dynamic>{'name': 'Comfort'}),
      ]);
      expect(options.map((o) => o.id), ['ride', 'premium', 'comfort']);
      expect(vehicleServiceName(options, 'premium'), 'Premium');
      expect(vehicleServiceName(options, 'old'), isNull);
      expect(vehicleServiceName(options, ''), isNull);
    });

    test('the make & model sets it, else the driver chooses; nothing to choose asks for nothing', () {
      expect(vehicleServiceChoice(mapped: 'ride', chosen: 'comfort').serviceId, 'ride');
      expect(vehicleServiceChoice(mapped: '', chosen: 'comfort').serviceId, 'comfort');
      final missing = vehicleServiceChoice(mapped: '', chosen: '');
      expect((missing.serviceId, missing.problem), (null, vehicleServiceMissing));
      final none = vehicleServiceChoice(mapped: '', chosen: '', canChoose: false);
      expect((none.serviceId, none.problem), (null, null));
    });

    test('the make & model list sets a service by the longest model at the start of the grant', () {
      final rows = [
        {'make': 'PERODUA', 'model': 'BEZZA', 'service_id': 'ride'},
        {'make': 'PERODUA', 'model': 'BEZZA 1.3', 'service_id': 'comfort'},
        {'make': 'PERODUA', 'model': 'AXIA'},
      ];
      expect(makeModelService(rows, 'Perodua', 'Bezza 1.3 AV'), 'comfort');
      expect(makeModelService(rows, 'PERODUA', 'BEZZA'), 'ride');
      expect(makeModelService(rows, 'PERODUA', 'AXIA'), '', reason: 'the list sets none');
      expect(makeModelService(rows, 'PROTON', 'SAGA'), '');
    });

    test('the review line: approved, else asked for, and where it came from', () {
      const names = {'ride': 'Ride', 'comfort': 'Comfort'};
      expect(vehicleServiceReviewText(requested: 'ride', approved: '', mapped: '', names: names),
          "Ride · driver's choice (make & model sets none)");
      expect(vehicleServiceReviewText(requested: 'ride', approved: '', mapped: 'ride', names: names), 'Ride');
      expect(vehicleServiceReviewText(requested: 'ride', approved: 'comfort', mapped: 'ride', names: names),
          'Comfort · approved · driver asked for Ride');
      expect(vehicleServiceReviewText(requested: 'comfort', approved: '', mapped: 'ride', names: names),
          'Comfort · make & model sets Ride');
      expect(vehicleServiceReviewText(requested: '', approved: '', mapped: '', names: names), 'Not chosen');
      expect(vehicleServiceReviewText(requested: 'gone', approved: '', mapped: 'gone'), 'gone', reason: 'an id with no name');
    });

    test('the review line sits after Model, is the admin\'s to change and never blocks approval', () {
      final lines = applicationReviewLines(
        profile: const {'id': 'u1', 'name': 'TEST DRIVER'},
        partner: const {'id': 'p1', 'partner_types': ['EHAILING']},
        vehicle: const {'id': 'v1', 'plate': 'TST 1', 'make': 'PROTON', 'model': 'SAGA', 'service_id': 'ride'},
        serviceNames: const {'ride': 'Ride'},
      );
      final keys = lines.map((l) => l.key).toList();
      expect(keys.indexOf(vehicleServiceKey), keys.indexOf('vehicle.model') + 1);
      final line = lines.firstWhere((l) => l.key == vehicleServiceKey);
      expect((line.label, line.value, line.editValue, line.optional),
          ('Vehicle service', "Ride · driver's choice (make & model sets none)", 'ride', true));
      expect(reviewEditFor(vehicleServiceKey), ReviewEdit.service);
      expect(reviewCanReject(vehicleServiceKey), isFalse);

      // An application decided line by line before the line existed: it is
      // approved as before.
      final before = {
        for (final l in lines)
          if (l.key != vehicleServiceKey)
            l.key: ReviewItem(key: l.key, group: l.group, label: l.label, state: ReviewState.approved),
      };
      final t = reviewTally(lines, before);
      expect((t.canApprove, t.open), (true, 0));
      // Decided, it counts like any other line.
      final decided = {
        ...before,
        vehicleServiceKey: const ReviewItem(
            key: vehicleServiceKey, group: ReviewGroup.vehicle, label: 'Vehicle service', state: ReviewState.approved),
      };
      expect(reviewTally(lines, decided).approved, t.approved + 1);
      expect(reviewTally(lines, const {}).open, lines.length - 1);
    });
  });

  group('the per-service checks (M9)', () {
    test('a row in words', () {
      expect(vehicleServiceCheckText({'service': 'eHailing', 'status': 'paused_age', 'max_age_years': 15}),
          'eHailing: paused: over the 15-year limit');
      expect(vehicleServiceCheckText({'service': 'eHailing', 'status': 'waiting_permit', 'permit_name': 'EVP'}),
          'eHailing: waiting for EVP');
      expect(vehicleServiceCheckText({'service': 'Teksi', 'status': 'active', 'set_by_admin': true}),
          'Teksi: active · set by an admin');
    });

    test('what applying would do', () {
      expect(vehicleServicePreviewText({'service': 'eHailing', 'current_status': null, 'would_status': 'paused_age',
        'checks_status': 'paused_age', 'max_age_years': 15, 'changes': true}),
          'eHailing: would be added, paused: over the 15-year limit');
      expect(vehicleServicePreviewText({'service': 'eHailing', 'current_status': 'active', 'would_status': 'waiting_permit',
        'checks_status': 'waiting_permit', 'permit_name': 'EVP', 'changes': true}),
          'eHailing: active now, would be waiting for EVP');
      expect(vehicleServicePreviewText({'service': 'Old', 'current_status': 'active', 'would_status': null,
        'changes': true}), contains('would be removed'));
      expect(vehicleServicePreviewText({'service': 'Teksi', 'current_status': 'active', 'would_status': 'active',
        'checks_status': 'paused_age', 'set_by_admin': true, 'changes': false}),
          'Teksi: set by an admin, kept as active (the checks say paused: over the ?-year limit)');
      expect(vehicleServicePreviewText({'service': 'Teksi', 'current_status': 'active', 'would_status': 'active',
        'checks_status': 'active', 'changes': false}), 'Teksi: no change');
    });

    test('the same statuses the server works out: the type over its limit paused, the others not', () {
      final entries = [
        {'name': 'Ride', 'vehicleRequired': true, 'rules': {'vehicleAge': {'required': true, 'rules': [{'maxYears': 10}]}}},
        {'name': 'Cab', 'vehicleRequired': true, 'rules': {'vehicleAge': {'required': true, 'rules': [{'maxYears': 20}]}},
          'vehiclePermit': {'required': true, 'rules': [{'name': 'EVP', 'permitType': 'evp'}]}},
        {'name': 'Walk', 'vehicleRequired': false},
      ];
      final st = vehicleServiceStatuses(
        services: vehicleServicesOf(['Ride', 'Cab', 'Walk'], entries),
        entries: entries,
        area: const ServiceArea(countries: ['Malaysia']),
        registered: DateTime(2011, 1, 1),
        now: DateTime(2026, 10, 27),
      );
      expect([for (final s in st) (s.service, s.state)], [
        ('Ride', VehicleServiceState.pausedAge),
        ('Cab', VehicleServiceState.waitingPermit),
      ]);
      expect(st.last.toRow('v1')['permit_type'], 'evp');
    });
  });

  group('the Vehicle service field', () {
    Future<void> pump(WidgetTester tester, Widget field, Brightness b) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [vehicleServiceOptionsProvider.overrideWith((_) async => _options)],
        child: MaterialApp(theme: appTheme(b), home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: field))),
      ));
      await tester.pump();
      await tester.pump();
    }

    for (final b in Brightness.values) {
      testWidgets('filled in from the make & model, read-only (${b.name})', (tester) async {
        var changed = false;
        await pump(tester, VehicleServiceField(mapped: 'ride', value: '', onChanged: (_) => changed = true), b);
        expect(find.text(VehicleServiceField.label), findsOneWidget);
        expect(find.text(VehicleServiceField.helper), findsOneWidget);
        expect(find.text('Ride · from make & model'), findsOneWidget);
        expect(find.byType(DropdownButtonFormField<String>), findsNothing);
        await tester.tap(find.byKey(const ValueKey('vehicle-service-mapped')));
        await tester.pump();
        expect(changed, isFalse);
        expect(tester.takeException(), isNull);
      });

      testWidgets('else the driver chooses, with the error when missing (${b.name})', (tester) async {
        var picked = '';
        await pump(
          tester,
          StatefulBuilder(
            builder: (context, setState) => VehicleServiceField(
              mapped: '',
              value: picked,
              errorText: picked.isEmpty ? vehicleServiceMissing : null,
              onChanged: (v) => setState(() => picked = v),
            ),
          ),
          b,
        );
        expect(find.text(vehicleServiceMissing), findsOneWidget);
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Comfort').last);
        await tester.pumpAndSettle();
        expect(picked, 'comfort');
        expect(find.text(vehicleServiceMissing), findsNothing);
        expect(find.text('Comfort'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
