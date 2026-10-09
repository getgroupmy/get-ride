import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/pin_change.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

/// Whether the signed-in account has a PIN yet. When it can't be told the
/// answer is yes: the screen then asks for the current PIN, and "Forgot
/// PIN?" is still there for an account that has none.
final pinSetProvider = FutureProvider.autoDispose<bool>((ref) async {
  try {
    return await ref.watch(authRepositoryProvider).hasPinSet();
  } catch (_) {
    return true;
  }
});

/// Change (or first set) the sign-in PIN from Settings (Expo
/// `change-pin.tsx`): the current PIN — or, forgotten, an SMS code to the
/// account's own number — then the new PIN twice. Its own page, so leaving
/// it never touches the sign-in flow.
class ChangePinScreen extends ConsumerWidget {
  const ChangePinScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPin = ref.watch(pinSetProvider);
    return hasPin.when(
      data: (v) => _ChangePinFlow(hasPin: v),
      loading: () => Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => const _ChangePinFlow(hasPin: true),
    );
  }
}

class _ChangePinFlow extends ConsumerStatefulWidget {
  const _ChangePinFlow({required this.hasPin});
  final bool hasPin;

  @override
  ConsumerState<_ChangePinFlow> createState() => _ChangePinFlowState();
}

class _ChangePinFlowState extends ConsumerState<_ChangePinFlow> {
  late PinChangeStep _step = firstPinChangeStep(hasPin: widget.hasPin);
  final _code = TextEditingController();
  String? _current, _new, _error;

  /// Set once the new PIN is saved: whether the sign-in password kept up.
  bool? _synced;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _go(PinChangeStep step, {String? error}) => setState(() {
    _step = step;
    _error = error;
    _code.clear();
  });

  void _back() {
    final prev = previousPinChangeStep(_step, hasPin: widget.hasPin);
    if (prev == null) {
      context.pop();
    } else {
      _go(prev);
    }
  }

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

  Future<void> _completed(String code) async {
    await _submit(code);
    // The popup comes up once the spinner has stopped.
    final synced = _synced;
    if (synced != null && mounted) await _done(synced);
  }

  Future<void> _submit(String code) => _run(() async {
    final auth = ref.read(authRepositoryProvider);
    switch (_step) {
      case PinChangeStep.verify:
        final problem = await auth.checkCurrentPin(code);
        if (!mounted) return;
        if (problem != null) {
          _code.clear();
          setState(() => _error = problem);
          return;
        }
        _current = code;
        _go(PinChangeStep.create);
      case PinChangeStep.code:
        await auth.verifyOtp(auth.currentPhone ?? '', code);
        if (!mounted) return;
        _current = null;
        _go(PinChangeStep.create);
      case PinChangeStep.create:
        _new = code;
        _go(PinChangeStep.confirm);
      case PinChangeStep.confirm:
        final problem = newPinProblem(_new ?? '', code, current: _current);
        if (problem != null) {
          // Expo: a mismatch is typed again; a PIN that isn't new is chosen again.
          _go(problem.startsWith('PINs do not match') ? PinChangeStep.confirm : PinChangeStep.create, error: problem);
          return;
        }
        _synced = await auth.changePin(code);
        ref.invalidate(pinSetProvider);
    }
  });

  Future<void> _forgot() => _run(() async {
    final auth = ref.read(authRepositoryProvider);
    final phone = auth.currentPhone;
    if (phone == null) throw StateError('Sign in again to reset your PIN.');
    await auth.sendOtp(phone, createUser: false);
    if (mounted) _go(PinChangeStep.code);
  });

  Future<void> _resend() => _run(() async {
    final auth = ref.read(authRepositoryProvider);
    await auth.sendOtp(auth.currentPhone ?? '', createUser: false);
    if (mounted) showInfo(context, 'Code sent');
  });

  Future<void> _done(bool synced) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) {
        final t = Theme.of(c);
        return AlertDialog(
          key: const ValueKey('pin-updated'),
          icon: Icon(Icons.check_circle, color: t.colorScheme.primary, size: 48),
          title: Text(widget.hasPin ? 'New PIN Has Been Updated' : 'Your PIN Has Been Set'),
          content: Text(
            synced
                ? 'Use it the next time you sign in.'
                : 'Use it the next time you sign in. We may text you a code once to confirm it\'s you.',
            textAlign: TextAlign.center,
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        );
      },
    );
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final copy = pinChangeCopy(_step, hasPin: widget.hasPin, phone: ref.read(authRepositoryProvider).currentPhone);
    // Three dots: who you are, the new PIN, the new PIN again.
    final dot = switch (_step) {
      PinChangeStep.verify || PinChangeStep.code => 0,
      PinChangeStep.create => 1,
      PinChangeStep.confirm => 2,
    };
    final dots = widget.hasPin ? 3 : 2;
    final shown = widget.hasPin ? dot : dot - 1;
    return PopScope(
      canPop: previousPinChangeStep(_step, hasPin: widget.hasPin) == null && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.hasPin ? 'Change PIN' : 'Set PIN'),
          leading: BackButton(onPressed: _busy ? null : _back),
        ),
        body: SingleChildScrollView(
          child: ResponsiveCenter(
            maxWidth: 440,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < dots; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: i == shown ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: i <= shown ? t.colorScheme.primary : t.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 32),
                Text(
                  copy.title,
                  key: const ValueKey('pin-step-title'),
                  textAlign: TextAlign.center,
                  style: t.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  copy.subtitle,
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 32),
                CodeField(
                  key: ValueKey('pin-field-${_step.name}'),
                  controller: _code,
                  length: 6,
                  obscure: _step != PinChangeStep.code,
                  onCompleted: _completed,
                ),
                const SizedBox(height: 16),
                if (_busy)
                  const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))),
                if (_error != null)
                  Text(
                    _error!,
                    key: const ValueKey('pin-error'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.colorScheme.error),
                  ),
                if (_step == PinChangeStep.verify)
                  TextButton(
                    key: const ValueKey('pin-forgot'),
                    onPressed: _busy ? null : _forgot,
                    child: const Text('Forgot PIN?'),
                  ),
                if (_step == PinChangeStep.code)
                  TextButton(onPressed: _busy ? null : _resend, child: const Text('Resend code')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
