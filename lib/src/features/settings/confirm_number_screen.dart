import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';

/// The link in a number change's text (migration 0282): what it would do,
/// and the confirm.
class NumberChangeLinkRepository {
  NumberChangeLinkRepository(this._db);
  final SupabaseClient? _db;

  /// {status: waiting | confirmed | expired | cancelled | unknown, phone_masked}.
  Future<Map<String, dynamic>> lookup(String token) async {
    final res = await _db!.rpc('phone_change_lookup', params: {'p_token': token});
    return res is Map ? Map<String, dynamic>.from(res) : const {'status': 'unknown'};
  }

  Future<Map<String, dynamic>> confirm(String token) async {
    final res = await _db!.rpc('phone_change_confirm', params: {'p_token': token});
    return res is Map ? Map<String, dynamic>.from(res) : const {'status': 'unknown'};
  }
}

final numberChangeLinkRepositoryProvider = Provider((ref) => NumberChangeLinkRepository(ref.watch(supabaseProvider)));

/// The link support's number change texts to the new number (Admin → God
/// View's pencil by Phone): what it would do, and Confirm. Works signed out;
/// the sign-in number moves only once it is confirmed.
class ConfirmNumberScreen extends ConsumerStatefulWidget {
  const ConfirmNumberScreen({super.key, required this.token});
  final String token;

  @override
  ConsumerState<ConfirmNumberScreen> createState() => _ConfirmNumberScreenState();
}

class _ConfirmNumberScreenState extends ConsumerState<ConfirmNumberScreen> {
  Map<String, dynamic>? _link;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  Future<void> _lookup() async {
    try {
      final r = await ref.read(numberChangeLinkRepositoryProvider).lookup(widget.token);
      if (mounted) setState(() => _link = r);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(numberChangeLinkRepositoryProvider).confirm(widget.token);
      if (mounted) setState(() => _link = {...?_link, ...r});
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final link = _link;
    final status = link?['status'] as String?;
    final phone = (link?['phone_masked'] as String?) ?? 'the new number';
    final (IconData icon, String title, String body) = switch (status) {
      'waiting' => (
        Icons.phone_iphone,
        'Confirm your new number',
        'Support is moving your get.ride account to $phone. Once you confirm, you sign in with it, '
            'and the old number no longer works. Your PIN stays the same.',
      ),
      'confirmed' => (
        Icons.check_circle_outline,
        'Number confirmed',
        'Your get.ride account now signs in with $phone.',
      ),
      'expired' || 'cancelled' => (
        Icons.timer_off_outlined,
        'This link has expired',
        'Ask support to send a new one.',
      ),
      _ => (Icons.link_off, 'This link is not valid', 'Check the text you got, or ask support to send a new one.'),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('New phone number')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 480,
            child: link == null && _error == null
                ? const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (link != null) ...[
                      Icon(icon, size: 48, color: t.colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(title, key: const ValueKey('confirm-number-title'), style: t.textTheme.titleLarge, textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      Text(body, style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, key: const ValueKey('confirm-number-error'), style: TextStyle(color: t.colorScheme.error)),
                    ],
                    const SizedBox(height: 20),
                    if (status == 'waiting')
                      BusyButton.filled(
                        key: const ValueKey('confirm-number-go'),
                        onPressed: _busy ? null : _confirm,
                        child: _busy
                            ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Confirm new number'),
                      )
                    else
                      OutlinedButton(onPressed: () => context.go('/'), child: const Text('Open get.ride')),
                  ]),
          ),
        ],
      ),
    );
  }
}
