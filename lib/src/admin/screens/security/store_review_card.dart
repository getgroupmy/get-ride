// Admin › Settings › App Settings › Store review login (migration 0333):
// the number Google Play and App Store reviewers sign in with (no SMS code,
// no PIN) into the one sealed demo account, on or off, and every sign-in.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';

/// What the card shows, from `admin_store_review_state()`.
class StoreReviewState {
  const StoreReviewState({
    required this.enabled,
    required this.phone,
    required this.accountReady,
    required this.signIns,
    required this.allowedLast30Days,
  });

  final bool enabled;
  final String phone;
  final bool accountReady;
  final List<Map<String, dynamic>> signIns;
  final int allowedLast30Days;

  factory StoreReviewState.fromJson(Object? json) {
    final m = json is Map ? Map<String, dynamic>.from(json) : const <String, dynamic>{};
    return StoreReviewState(
      enabled: m['enabled'] == true,
      phone: (m['phone'] as String?) ?? '60608080',
      accountReady: m['accountReady'] == true,
      signIns: [
        for (final r in (m['signIns'] is List ? m['signIns'] as List : const [])) if (r is Map) Map<String, dynamic>.from(r),
      ],
      allowedLast30Days: (m['allowedLast30Days'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A sign-in row's outcome in words.
String storeReviewOutcomeLabel(String? outcome) => switch (outcome) {
  'allowed' => 'Signed in',
  'off' => 'Refused: switched off',
  'wrong_number' => 'Refused: another number',
  'rate_limited' => 'Refused: too many tries',
  'no_account' => 'Refused: no demo account',
  _ => outcome ?? '',
};

final storeReviewStateProvider = FutureProvider.autoDispose<StoreReviewState>(
  (ref) async => StoreReviewState.fromJson(await ref.watch(supabaseProvider).rpc('admin_store_review_state')),
);

class StoreReviewCard extends ConsumerStatefulWidget {
  const StoreReviewCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<StoreReviewCard> createState() => _StoreReviewCardState();
}

class _StoreReviewCardState extends ConsumerState<StoreReviewCard> {
  final _phone = TextEditingController();
  bool? _enabled;
  StoreReviewState? _loaded;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  void _load(StoreReviewState s) {
    if (identical(_loaded, s)) return;
    _loaded = s;
    _phone.text = s.phone;
    _enabled = null;
  }

  Future<void> _save(StoreReviewState stored) async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6 || digits.length > 15) {
      showInfo(context, 'Enter 6 to 15 digits, with the country code (60608080).');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(supabaseProvider).rpc('admin_store_review_set', params: {
        'p_enabled': _enabled ?? stored.enabled,
        'p_phone': digits,
      }),
      success: 'Store review login saved',
    );
    if (ok && mounted) ref.invalidate(storeReviewStateProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Card(
      key: const ValueKey('store-review-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(storeReviewStateProvider),
          onRetry: () => ref.invalidate(storeReviewStateProvider),
          data: (stored) {
            _load(stored);
            final on = _enabled ?? stored.enabled;
            final changed = on != stored.enabled || _phone.text.replaceAll(RegExp(r'\D'), '') != stored.phone;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Store review login', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'For Google Play and App Store reviewers. On, this number signs in with no SMS code and no PIN '
                  'into one demo account that only runs simulations: no real rides, riders, drivers, payments, '
                  'chats or calls, and no admin. Off, the number signs in like any other.',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                SwitchListTile(
                  key: const ValueKey('store-review-on'),
                  contentPadding: EdgeInsets.zero,
                  value: on,
                  onChanged: widget.canEdit ? (v) => setState(() => _enabled = v) : null,
                  title: Text(on ? 'On' : 'Off'),
                  subtitle: Text(stored.accountReady ? 'Demo account ready' : 'Demo account missing: apply migration 0333'),
                ),
                TextField(
                  key: const ValueKey('store-review-phone'),
                  controller: _phone,
                  enabled: widget.canEdit,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Reviewer number',
                    helperText: 'Digits with the country code: 60608080 is +60 608080',
                    prefixText: '+',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (widget.canEdit) ...[
                  const SizedBox(height: 12),
                  BusyButton.filled(
                    key: const ValueKey('store-review-save'),
                    onPressed: changed ? () => _save(stored) : null,
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save store review login'),
                  ),
                ],
                const Divider(height: 24),
                Text(
                  'Sign-ins (${stored.allowedLast30Days} in the last 30 days)',
                  style: t.textTheme.titleSmall,
                ),
                if (stored.signIns.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('None yet.', style: t.textTheme.bodySmall?.copyWith(color: muted)),
                  )
                else
                  for (final r in stored.signIns.take(20))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        r['outcome'] == 'allowed' ? Icons.login : Icons.block,
                        color: r['outcome'] == 'allowed' ? t.colorScheme.primary : t.colorScheme.error,
                      ),
                      title: Text(
                        '${formatDateTime(DateTime.tryParse('${r['at']}')?.toLocal())} · '
                        '${storeReviewOutcomeLabel(r['outcome'] as String?)}',
                      ),
                      subtitle: Text([
                        r['platform'],
                        r['device'],
                        if (r['appVersion'] != null) 'v${r['appVersion']}',
                        if (r['ip'] != null) 'IP ${r['ip']}',
                      ].whereType<String>().join(' · ')),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}
