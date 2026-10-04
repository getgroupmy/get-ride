import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_categories.g.dart';
import 'package:get_ride/src/admin/admin_filters.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/admin_shell.dart';
import 'package:get_ride/src/admin/screens/commission_screen.dart';
import 'package:get_ride/src/admin/screens/documents_screen.dart';
import 'package:get_ride/src/admin/screens/settings_screens.dart';

void main() {
  group('AdminAccess', () {
    test('no grants means no admin', () {
      expect(AdminAccess.none.isAdmin, isFalse);
      expect(AdminAccess.none.canRead(['admin-users']), isFalse);
    });

    test('wildcard edit grants everything', () {
      const a = AdminAccess([AdminGrant(page: '*', edit: true)]);
      expect(a.isFullAdmin, isTrue);
      expect(a.canEdit(['admin-anything']), isTrue);
    });

    test('wildcard read is view-only everywhere', () {
      const a = AdminAccess([AdminGrant(page: '*', edit: false)]);
      expect(a.isFullAdmin, isFalse);
      expect(a.levelFor(['admin-users']), AccessLevel.read);
    });

    test('per-page grants cover only their module', () {
      const a = AdminAccess([
        AdminGrant(page: 'admin-users-blocked', edit: true),
        AdminGrant(page: 'admin-support', edit: false),
      ]);
      expect(a.levelFor(adminModules['users']!.pages), AccessLevel.edit);
      expect(a.levelFor(adminModules['support']!.pages), AccessLevel.read);
      expect(a.levelFor(adminModules['partners']!.pages), AccessLevel.none);
    });

    test('edit on one page beats read on another in the same module', () {
      const a = AdminAccess([
        AdminGrant(page: 'admin-partners', edit: false),
        AdminGrant(page: 'admin-partners-approved', edit: true),
      ]);
      expect(a.levelFor(adminModules['partners']!.pages), AccessLevel.edit);
    });
  });

  group('list filters', () {
    test('userStatus prefers profile_status', () {
      expect(userStatus({'profile_status': 'Un-Approved', 'status': 'approved'}), 'unapproved');
      expect(userStatus({'profile_status': 'Deleted', 'status': 'blocked'}), 'deleted');
      expect(userStatus({'status': 'blocked'}), 'blocked');
      expect(userStatus({}), 'unapproved');
    });

    test('user and partner filters', () {
      expect(userMatches({'id_verified': 'Failed'}, 'unapproved-docs'), isTrue);
      expect(partnerMatches({'permit': 'pending', 'status': 'approved'}, 'permit-pending'), isTrue);
      expect(partnerMatches({'documents_ok': false}, 'unapproved-docs'), isTrue);
      expect(partnerMatches({'status': 'blocked'}, 'approved'), isFalse);
    });

    test('rowSearch is case-insensitive over chosen columns', () {
      final row = {'name': 'Aisyah Rahman', 'phone': '+60123', 'secret': 'x'};
      expect(rowSearch(row, 'aisyah', ['name']), isTrue);
      expect(rowSearch(row, '0123', ['name', 'phone']), isTrue);
      expect(rowSearch(row, 'x', ['name']), isFalse);
      expect(rowSearch(row, '  ', ['name']), isTrue);
    });
  });

  group('settings editor', () {
    const fields = [
      SettingsField('code', 'Code', FieldKind.text, required: true),
      SettingsField('discount', 'Discount', FieldKind.number, required: true),
      SettingsField('maxUses', 'Max Uses', FieldKind.number),
      SettingsField('active', 'Active', FieldKind.boolean),
    ];

    test('coerceValues stores real JSON types', () {
      final r = coerceValues(fields, {'code': ' NEW10 ', 'discount': '10.5', 'maxUses': '', 'active': true});
      expect(r.error, isNull);
      expect(r.values, {'code': 'NEW10', 'discount': 10.5, 'active': true});
    });

    test('coerceValues validates required and numeric input', () {
      expect(coerceValues(fields, {'code': '', 'discount': '1'}).error, 'Code is required.');
      expect(coerceValues(fields, {'code': 'A', 'discount': 'ten'}).error, 'Discount must be a number.');
    });

    test('scope and ordering', () {
      final a = SettingEntry(id: 'a', values: {'providerId': 'p1', 'displayPriority': 2}, position: 0);
      final b = SettingEntry(id: 'b', values: {'providerId': 'p1', 'displayPriority': 1}, position: 1);
      final c = SettingEntry(id: 'c', values: {'providerId': 'p2'}, position: 2);
      expect([a, b, c].where((e) => matchesScope(e, {'providerId': 'p1'})).map((e) => e.id), ['a', 'b']);
      expect(sortEntries([a, b, c], 'displayPriority').map((e) => e.id), ['b', 'a', 'c']);
      expect(sortEntries([c, b, a], null).map((e) => e.id), ['a', 'b', 'c']);
    });

    test('generated catalogue is consistent', () {
      expect(crudCategories, hasLength(23));
      expect(crudCategories.map((c) => c.key).toSet(), hasLength(23));
      for (final c in crudCategories) {
        expect(c.fields, isNotEmpty, reason: c.key);
        if (c.childCategory != null) {
          final child = crudCategories.firstWhere((x) => x.key == c.childCategory);
          expect(child.nested, isTrue);
          expect(c.childScopeKey, isNotNull);
        }
      }
      expect(categoryFor('promocode-list').table, 'settings_entries');
      expect(categoryFor('insurance-providers').table, 'insurance_providers');
    });

    test('unknown categories fall back to the raw editor', () {
      final c = categoryFor('partner-type');
      expect(c.isRaw, isTrue);
      expect(c.title, 'Partner Type');
      expect(c.usesCategoryColumn, isTrue);
    });
  });

  test('document expiry overrides pending/approved but not rejected', () {
    final now = DateTime(2026, 6, 1);
    expect(documentDisplayStatus({'status': 'Approved', 'expiry_date': '2026-01-01'}, now: now), 'Expired');
    expect(documentDisplayStatus({'status': 'Rejected', 'expiry_date': '2026-01-01'}, now: now), 'Rejected');
    expect(documentDisplayStatus({'status': 'Approved', 'expiry_date': '2027-01-01'}, now: now), 'Approved');
    expect(documentDisplayStatus({}, now: now), 'Pending Review');
  });

  test('commission scope requirements', () {
    expect(requiredScope('master'), isEmpty);
    expect(requiredScope('city'), ['country', 'state', 'city']);
    expect(requiredScope('user'), ['user_id']);
    expect(commissionScopeLabel({'level': 'city', 'city': 'Ipoh', 'state': 'Perak', 'country': 'Malaysia'}),
        'Ipoh, Perak, Malaysia');
  });

  testWidgets('non-admins see the access gate, not the panel', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [adminAccessProvider.overrideWith((_) async => AdminAccess.none)],
      child: const MaterialApp(home: AdminShell(location: '/admin/dashboard', child: Text('PANEL'))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No admin access'), findsOneWidget);
    expect(find.text('PANEL'), findsNothing);
  });

  testWidgets('read-only admins see only granted modules', (tester) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        adminAccessProvider.overrideWith(
          (_) async => const AdminAccess([AdminGrant(page: 'admin-support', edit: false)]),
        ),
      ],
      child: const MaterialApp(home: AdminShell(location: '/admin/support', child: Text('PANEL'))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('PANEL'), findsOneWidget);
    expect(find.text('Support'), findsOneWidget);
    expect(find.text('Users'), findsNothing);
    expect(find.text('Sub-admins'), findsNothing);
  });
}
