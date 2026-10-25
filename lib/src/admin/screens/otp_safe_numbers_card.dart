// Admin › SMS / WhatsApp › Test and staff numbers (migration 0292): numbers
// that skip every country phone rule and daily code limit, so testing and
// support never get locked out. Each code sent to one is logged.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth_utils.dart' show normalizeE164;
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

String _when(Object? at) {
  final d = DateTime.tryParse('${at ?? ''}');
  return d == null ? '' : DateFormat('d MMM y, h:mm a').format(d.toLocal());
}

final otpSafeNumbersProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => [
      for (final r in await ref.watch(supabaseProvider).from('otp_safe_numbers').select().order('created_at', ascending: true))
        Map<String, dynamic>.from(r),
    ]);

class OtpSafeNumbersCard extends ConsumerStatefulWidget {
  const OtpSafeNumbersCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<OtpSafeNumbersCard> createState() => _OtpSafeNumbersCardState();
}

class _OtpSafeNumbersCardState extends ConsumerState<OtpSafeNumbersCard> {
  final _phone = TextEditingController(), _note = TextEditingController();

  @override
  void dispose() {
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _set(String phone, bool add) async {
    final ok = await runAdminAction(context, () async {
      await ref.read(supabaseProvider).rpc('admin_otp_safe_set', params: {
        'p_phone': phone,
        'p_add': add,
        'p_note': add ? _note.text.trim() : null,
      });
    });
    if (!ok || !mounted) return;
    if (add) {
      _phone.clear();
      _note.clear();
    }
    ref.invalidate(otpSafeNumbersProvider);
  }

  void _add() {
    final p = normalizeE164(_phone.text.trim());
    if (!RegExp(r'^\+\d{6,17}$').hasMatch(p)) {
      showInfo(context, 'Enter the number with its country code, e.g. +60 12 345 6789.');
      return;
    }
    _set(p, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final list = ref.watch(otpSafeNumbersProvider);
    return Card(
      key: const ValueKey('otp-safe-numbers-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Test and staff numbers', style: t.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'These numbers skip every country phone rule and the daily code limits '
            '(Admin › Country / States / Cities › a country › Phone numbers), so testing and support never get '
            'locked out. Each code sent to one is logged.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          list.when(
            loading: () => const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
            error: (e, _) => Text('$e'),
            data: (rows) => rows.isEmpty
                ? const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('None yet'))
                : Column(children: [
                    for (final r in rows)
                      ListTile(
                        key: ValueKey('otp-safe-${r['phone']}'),
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.verified_user_outlined),
                        title: Text('${r['phone']}'),
                        subtitle: Text([
                          if ('${r['note'] ?? ''}'.isNotEmpty) '${r['note']}',
                          r['last_used_at'] == null ? 'Not used yet' : 'Last code ${_when(r['last_used_at'])}',
                        ].join(' · ')),
                        trailing: widget.canEdit
                            ? BusyIconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _set('${r['phone']}', false),
                              )
                            : null,
                      ),
                  ]),
          ),
          if (widget.canEdit) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 220,
                child: TextField(
                  key: const ValueKey('otp-safe-phone'),
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Number', hintText: '+60 12 345 6789'),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  key: const ValueKey('otp-safe-note'),
                  controller: _note,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: 'Note (optional)', counterText: ''),
                ),
              ),
              BusyButton.tonal(key: const ValueKey('otp-safe-add'), onPressed: _add, child: const Text('Add number')),
            ]),
          ],
        ]),
      ),
    );
  }
}
