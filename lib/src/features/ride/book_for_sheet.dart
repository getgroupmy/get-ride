import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/book_for.dart';
import '../../widgets/busy.dart';
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
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('book-for-name'),
                      controller: _name,
                      autofocus: widget.name.isEmpty,
                      maxLength: 80,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: "Passenger's name", counterText: ''),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (pick != null)
                    BusyIconButton(
                      key: const ValueKey('book-for-contact'),
                      tooltip: 'Contacts',
                      icon: const Icon(Icons.contacts_outlined),
                      onPressed: () async {
                        try {
                          final c = await pick();
                          if (c == null || !mounted) return;
                          setState(() {
                            if (c.name != null) _name.text = c.name!;
                            if (c.phone != null) _phone.text = c.phone!;
                          });
                        } catch (_) {}
                      },
                    ),
                ],
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

/// On the confirm sheet once "Someone else" is filled in: who, and a pen
/// that reopens [showBookForSheet]. Nothing is typed on the sheet itself.
class BookForSummary extends StatelessWidget {
  const BookForSummary({super.key, required this.name, required this.phone, required this.onEdit});
  final String name, phone;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Material(
      key: const ValueKey('book-for-summary'),
      color: t.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
          child: Row(
            children: [
              Icon(Icons.person_outline, color: muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
                    Text(phone, style: t.textTheme.bodySmall?.copyWith(color: muted)),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('book-for-edit'),
                tooltip: "Edit passenger's details",
                icon: Icon(Icons.edit_outlined, size: 18, color: muted),
                onPressed: onEdit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
