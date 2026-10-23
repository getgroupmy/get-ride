// "When they sign in" (migration 0281): what a dispatch ID must do before
// their role opens. The PIN is always theirs to set (only when the account
// has none); a live selfie and their ID are the admin's switches, with an
// optional "finish within X days". In Dispatch → Accounts (Create an ID and
// each account) and Users → Edit User.
import 'package:flutter/material.dart';

import '../../../core/signin_checks.dart';
import '../../../widgets/page_style_host.dart';

class SignInChecksFields extends StatefulWidget {
  const SignInChecksFields({super.key, required this.value, required this.onChanged, this.enabled = true, this.onDaysBad});

  final SignInAsks value;
  final ValueChanged<SignInAsks> onChanged;
  final bool enabled;

  /// Whether the typed number of days can't be used (1 to 365, or blank).
  final ValueChanged<bool>? onDaysBad;

  @override
  State<SignInChecksFields> createState() => _SignInChecksFieldsState();
}

class _SignInChecksFieldsState extends State<SignInChecksFields> {
  late final _days = TextEditingController(text: widget.value.days?.toString() ?? '');
  bool _bad = false;

  @override
  void didUpdateWidget(SignInChecksFields old) {
    super.didUpdateWidget(old);
    // Cleared from outside (the form was sent).
    final typed = parseDeadlineDays(_days.text);
    if (!typed.bad && typed.days != widget.value.days) _days.text = widget.value.days?.toString() ?? '';
  }

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  void _typed(String s) {
    final d = parseDeadlineDays(s);
    if (d.bad != _bad) {
      setState(() => _bad = d.bad);
      widget.onDaysBad?.call(d.bad);
    }
    if (!d.bad) widget.onChanged(widget.value.copyWith(days: () => d.days));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final v = widget.value;
    final on = widget.enabled;
    return Column(
      key: const ValueKey('signin-checks'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('When they sign in', style: t.textTheme.titleSmall),
        SwitchListTile(
          key: const ValueKey('ask-pin'),
          contentPadding: EdgeInsets.zero,
          value: true,
          onChanged: null,
          secondary: const Icon(Icons.lock_outline),
          title: const Text('Set their own PIN'),
          subtitle: const Text("Only a new account, or one with no PIN yet. Someone who has a PIN isn't asked."),
        ),
        SwitchListTile(
          key: const ValueKey('ask-selfie'),
          contentPadding: EdgeInsets.zero,
          value: v.selfie,
          onChanged: on ? (x) => widget.onChanged(v.copyWith(selfie: x)) : null,
          secondary: const Icon(Icons.face_outlined),
          title: const Text('Take a selfie'),
          subtitle: const Text('A live selfie with the front camera, when they have no approved photo or it was rejected.'),
        ),
        SwitchListTile(
          key: const ValueKey('ask-id'),
          contentPadding: EdgeInsets.zero,
          value: v.id,
          onChanged: on ? (x) => widget.onChanged(v.copyWith(id: x)) : null,
          secondary: const Icon(Icons.badge_outlined),
          title: const Text('Upload their ID'),
          subtitle: const Text(
            'MyKad or passport, front and back, when none is on record, it was rejected or it ran out. '
            'The role opens once the ID is approved.',
          ),
        ),
        if (v.any) ...[
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('ask-days'),
            controller: _days,
            enabled: on,
            keyboardType: TextInputType.number,
            onChanged: _typed,
            decoration: InputDecoration(
              labelText: 'Finish within (days)',
              helperText: 'Blank: no deadline. After it, the role pauses until they finish.',
              errorText: _bad ? 'Give 1 to 365 days, or leave it blank.' : null,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Text("These can't be skipped and apply on any phone. User mode keeps working.", style: muted),
      ],
    );
  }
}

/// The account's switches, changed afterwards; the new ones, or null.
Future<SignInAsks?> editSignInChecks(BuildContext context, {required String name, required SignInAsks current}) {
  var asks = current;
  var bad = false;
  return showAppDialog<SignInAsks>(
    id: 'admin-dispatch.account-checks',
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        key: const ValueKey('account-checks-dialog'),
        title: Text(name.isEmpty ? 'Sign-in checks' : 'Sign-in checks: $name'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: SignInChecksFields(
              value: asks,
              onChanged: (a) => set(() => asks = a),
              onDaysBad: (b) => set(() => bad = b),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('account-checks-save'),
            onPressed: bad ? null : () => Navigator.pop(ctx, asks),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
