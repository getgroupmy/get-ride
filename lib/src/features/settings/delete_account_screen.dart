// Settings → Delete account (migration 0194): what happens, then the PIN
// (or an SMS code to the account's own number), then gone.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/account_deletion.dart';
import '../../data/account_deletion_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

final accountDeletionCheckProvider = FutureProvider.autoDispose<AccountDeletionCheck>(
  (ref) => ref.watch(accountDeletionRepositoryProvider).check(),
);

enum _Step { review, pin, code }

class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  var _step = _Step.review;
  final _code = TextEditingController();
  final _reason = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _go(_Step step) => setState(() {
    _step = step;
    _error = null;
    _code.clear();
  });

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
      _code.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    var hasPin = true;
    try {
      hasPin = await ref.read(authRepositoryProvider).hasPinSet();
    } catch (_) {}
    if (!mounted) return;
    if (hasPin) {
      _go(_Step.pin);
    } else {
      await _sendCode();
    }
  }

  Future<void> _sendCode() => _run(() async {
    final auth = ref.read(authRepositoryProvider);
    final phone = auth.currentPhone;
    if (phone == null) throw StateError('Sign in again to delete your account.');
    await auth.sendOtp(phone, createUser: false);
    if (mounted) _go(_Step.code);
  });

  Future<void> _completed(String code) => _run(() async {
    final repo = ref.read(accountDeletionRepositoryProvider);
    final reason = _reason.text.trim().isEmpty ? null : _reason.text.trim();
    String? problem;
    if (_step == _Step.pin) {
      problem = await repo.delete(pin: code, reason: reason);
    } else {
      final auth = ref.read(authRepositoryProvider);
      await auth.verifyOtp(auth.currentPhone ?? '', code);
      problem = await repo.delete(reason: reason);
    }
    if (!mounted) return;
    if (problem != null) {
      _code.clear();
      setState(() => _error = problem);
      return;
    }
    await showAppDialog<void>(id: 'delete-account.run',
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        key: const ValueKey('account-deleted'),
        title: const Text('Your account has been deleted'),
        content: const Text('Thank you for riding with GET.ride. You can sign up again with your number at any time.'),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
    await repo.signOutHere();
    if (mounted) context.go('/');
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return PopScope(
      canPop: _step == _Step.review && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _go(_Step.review);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Delete account'),
          leading: BackButton(
            onPressed: _busy ? null : () => _step == _Step.review ? context.pop() : _go(_Step.review),
          ),
        ),
        body: SingleChildScrollView(
          child: ResponsiveCenter(
            maxWidth: 480,
            padding: const EdgeInsets.all(24),
            child: _step == _Step.review ? _review(t) : _confirm(t),
          ),
        ),
      ),
    );
  }

  Widget _review(ThemeData t) {
    final check = ref.watch(accountDeletionCheckProvider);
    return check.when(
      skipLoadingOnReload: true,
      loading: () => const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Column(
        children: [
          Text(errorText(e), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: () => ref.invalidate(accountDeletionCheckProvider), child: const Text('Try again')),
        ],
      ),
      data: (c) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.person_remove_outlined, size: 48, color: t.colorScheme.error),
          const SizedBox(height: 12),
          Text('Delete your GET.ride account?', textAlign: TextAlign.center, style: t.textTheme.headlineSmall),
          const SizedBox(height: 16),
          for (final line in accountDeletionEffects(c))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 10),
                    child: Icon(Icons.circle, size: 8, color: t.colorScheme.onSurfaceVariant),
                  ),
                  Expanded(child: Text(line, style: t.textTheme.bodyMedium)),
                ],
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('delete-reason'),
            controller: _reason,
            maxLength: 300,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Why are you leaving? (optional)'),
          ),
          const SizedBox(height: 8),
          if (c.activeRide)
            Card(
              key: const ValueKey('delete-active-ride'),
              color: t.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'You have a ride under way. You can delete your account once it ends.',
                  style: TextStyle(color: t.colorScheme.onErrorContainer),
                ),
              ),
            ),
          if (_error != null) Text(_error!, style: TextStyle(color: t.colorScheme.error)),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('delete-continue'),
            style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError),
            onPressed: c.activeRide || _busy ? null : _start,
            child: const Text('Delete my account'),
          ),
          TextButton(onPressed: _busy ? null : () => context.pop(), child: const Text('Keep my account')),
        ],
      ),
    );
  }

  Widget _confirm(ThemeData t) {
    final pin = _step == _Step.pin;
    final phone = ref.read(authRepositoryProvider).currentPhone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          pin ? 'Enter your PIN' : 'Enter the code we sent',
          key: const ValueKey('delete-step-title'),
          textAlign: TextAlign.center,
          style: t.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          pin
              ? 'Confirm it\'s you to delete your account. This can\'t be undone.'
              : 'We texted a 6-digit code to ${phone ?? 'your number'}. Enter it to delete your account.',
          textAlign: TextAlign.center,
          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 32),
        CodeField(
          key: ValueKey('delete-code-${_step.name}'),
          controller: _code,
          length: 6,
          obscure: pin,
          onCompleted: _completed,
        ),
        const SizedBox(height: 16),
        if (_busy)
          const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('delete-error'),
            textAlign: TextAlign.center,
            style: TextStyle(color: t.colorScheme.error),
          ),
        TextButton(
          key: const ValueKey('delete-use-sms'),
          onPressed: _busy ? null : _sendCode,
          child: Text(pin ? 'Use an SMS code instead' : 'Resend code'),
        ),
      ],
    );
  }
}
