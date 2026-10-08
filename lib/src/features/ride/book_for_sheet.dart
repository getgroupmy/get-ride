import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/book_for.dart';
import '../profile/emergency_contacts_screen.dart' show contactPickerProvider;

/// "Someone else": the passenger's name and phone, typed (or picked from
/// the contacts) in a modal rather than on the confirm sheet. Null when it
/// is closed without Done.
Future<BookedFor?> showBookForSheet(BuildContext context, {String name = '', String phone = ''}) =>
    showModalBottomSheet<BookedFor>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BookForSheet(name: name, phone: phone),
    );

class _BookForSheet extends ConsumerStatefulWidget {
  const _BookForSheet({required this.name, required this.phone});
  final String name, phone;

  @override
  ConsumerState<_BookForSheet> createState() => _BookForSheetState();
}

class _BookForSheetState extends ConsumerState<_BookForSheet> {
  late final _name = TextEditingController(text: widget.name);
  late final _phone = TextEditingController(text: widget.phone);

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pick = ref.watch(contactPickerProvider);
    final ready = bookedFor(_name.text, _phone.text);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            key: const ValueKey('book-for-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text("Who's riding?", style: t.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'The driver will meet and call them. You can follow the ride here.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              // From the address book: the phone's own picker, or the
              // browser's where it has one.
              if (pick != null) ...[
                OutlinedButton.icon(
                  key: const ValueKey('book-for-contact'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.contacts_outlined),
                  label: const Text('Choose from contacts'),
                  onPressed: () async {
                    try {
                      final c = await pick();
                      if (c == null || !mounted) return;
                      setState(() {
                        if (c.name != null) _name.text = c.name!;
                        if (c.phone != null) _phone.text = c.phone!;
                      });
                      if (c.phone == null && context.mounted) {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          const SnackBar(content: Text('That contact has no phone number.')),
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          const SnackBar(content: Text("Couldn't open your contacts. Please try again.")),
                        );
                      }
                    }
                  },
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const ValueKey('book-for-name'),
                controller: _name,
                autofocus: widget.name.isEmpty && pick == null,
                maxLength: 80,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: "Passenger's name", counterText: ''),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('book-for-phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: "Passenger's phone"),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (ready != null) Navigator.pop(context, ready);
                },
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('book-for-done'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: ready == null ? null : () => Navigator.pop(context, ready),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
