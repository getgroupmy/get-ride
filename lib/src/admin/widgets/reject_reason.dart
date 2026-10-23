// Why a photo or a document is rejected, picked from a list (0281): Photo
// blurry, Face not clear, Name doesn't match, Expired, Wrong document or
// Other, with an optional note (needed for Other). The person sees the
// reason. Admin → Documents (partner, vehicle and sign-in checks) and
// Users → ID documents.
import 'package:flutter/material.dart';

import '../../core/signin_checks.dart';
import '../../widgets/page_style_host.dart';

/// The admin's reason and note, or null when they back out.
Future<RejectChoice?> pickRejectReason(BuildContext context, {String? note}) => showAppDialog<RejectChoice>(
  id: 'admin.reject-reason',
  context: context,
  builder: (_) => _RejectReasonDialog(note: note ?? ''),
);

class _RejectReasonDialog extends StatefulWidget {
  const _RejectReasonDialog({required this.note});
  final String note;

  @override
  State<_RejectReasonDialog> createState() => _RejectReasonDialogState();
}

class _RejectReasonDialogState extends State<_RejectReasonDialog> {
  String? _reason;
  late final _note = TextEditingController(text: widget.note);
  String? _problem;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _send() {
    final p = rejectChoiceProblem(_reason, _note.text);
    if (p != null) return setState(() => _problem = p);
    Navigator.pop(context, (reason: _reason!, note: _note.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('reject-reason-dialog'),
      title: const Text('Why is it rejected?'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in rejectReasons.entries)
                    ChoiceChip(
                      key: ValueKey('reason-${e.key}'),
                      label: Text(e.value),
                      selected: _reason == e.key,
                      onSelected: (_) => setState(() {
                        _reason = e.key;
                        _problem = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('reason-note'),
                controller: _note,
                minLines: 2,
                maxLines: 4,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: _reason == 'other' ? 'Note (needed)' : 'Note (optional)',
                  helperText: 'They see the reason and this note.',
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_problem != null)
                Text(_problem!, key: const ValueKey('reason-problem'), style: TextStyle(color: t.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('reason-reject'), onPressed: _send, child: const Text('Reject')),
      ],
    );
  }
}
