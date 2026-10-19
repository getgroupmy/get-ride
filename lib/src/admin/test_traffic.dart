// Test traffic (migration 0241): the tester accounts the Claude test sessions
// sign in with, and the switch that brings their calls back into an admin
// figure.
//
// The list lives in `public.test_accounts` so the server can read it: the
// edge functions mark a tester's calls as test traffic from the verified
// caller id (fare AI response log, map usage). The label never changes how a
// call is limited, charged or answered.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';
import 'admin_repository.dart';
import 'profile_search.dart';

/// One listed tester, with what the people search knows of them.
@immutable
class TestAccount {
  const TestAccount({required this.id, this.profile = const {}, this.note});

  final String id;
  final Map<String, dynamic> profile;
  final String? note;

  factory TestAccount.fromRow(Map<String, dynamic> r) {
    final p = r['profile'];
    return TestAccount(
      id: '${r['profile_id']}',
      profile: p is Map ? Map<String, dynamic>.from(p) : const {},
      note: r['note'] as String?,
    );
  }

  /// The name (or phone, email, account id) the admin knows them by.
  String get label => personLabel({...profile, 'id': id});

  /// How else they are known; the profile id when nothing else is.
  String get details {
    final d = personDetails(profile);
    return d.isEmpty ? id : d;
  }
}

/// Reads and writes the tester list. Only admins read it; EDIT on Display
/// Settings (or a full admin) writes it (RLS in 0241).
class TestAccountsRepository {
  TestAccountsRepository(this._db);
  final SupabaseClient _db;

  Future<List<TestAccount>> list() async => [
        for (final r in await _db
            .from('test_accounts')
            .select('profile_id, note, created_at, profile:profiles(id, name, phone, email, display_id)')
            .order('created_at'))
          TestAccount.fromRow(r),
      ];

  /// Lists [profileId]; already listed is fine.
  Future<void> add(String profileId) async {
    try {
      await _db.from('test_accounts').insert({'profile_id': profileId});
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow;
    }
  }

  Future<void> remove(String profileId) => _db.from('test_accounts').delete().eq('profile_id', profileId);

  /// The admin's usual people search (name, phone, email, account id or id).
  Future<List<Map<String, dynamic>>> searchPeople(String query) => AdminRepository(_db).searchPeople(query);
}

final testAccountsRepositoryProvider = Provider((ref) => TestAccountsRepository(ref.watch(supabaseProvider)));

final testAccountsProvider = FutureProvider.autoDispose<List<TestAccount>>(
  (ref) => ref.watch(testAccountsRepositoryProvider).list(),
);

/// Whether an admin figure counts test traffic too. Off (real users only)
/// each time the app starts.
class IncludeTestTraffic extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// Admin → Fare AI → Response log.
final fareAiLogIncludeTestProvider = NotifierProvider<IncludeTestTraffic, bool>(IncludeTestTraffic.new);

/// Admin → Maps → Usage.
final mapUsageIncludeTestProvider = NotifierProvider<IncludeTestTraffic, bool>(IncludeTestTraffic.new);

/// The "Include test traffic" switch above a figure.
class IncludeTestTrafficSwitch extends ConsumerWidget {
  const IncludeTestTrafficSwitch({super.key, required this.provider, this.hidden});

  final NotifierProvider<IncludeTestTraffic, bool> provider;

  /// What is left out while it is off ("12 test calls hidden"), if known.
  final String? hidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(provider);
    final t = Theme.of(context);
    return SwitchListTile(
      key: const ValueKey('include-test-traffic'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      secondary: Icon(Icons.science_outlined, color: t.colorScheme.onSurfaceVariant),
      title: const Text('Include test traffic'),
      subtitle: Text(
        on
            ? 'Showing every call, the tester accounts\' too.'
            : 'Real users only: calls from the tester accounts are left out${hidden == null ? '' : ' ($hidden)'}.',
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
      value: on,
      onChanged: (v) => ref.read(provider.notifier).set(v),
    );
  }
}
