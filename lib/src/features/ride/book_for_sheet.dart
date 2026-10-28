import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/book_for.dart';
import '../../core/family.dart' show FamilyPassenger, FamilyPick;
import '../../data/family_repository.dart' show familyPassengersProvider;
import '../../providers.dart' show profileProvider;
import '../../widgets/app_notice.dart';
import '../profile/emergency_contacts_screen.dart' show contactPickerProvider;
import '../../widgets/page_style_host.dart';

/// "Someone else": the passenger's name and phone, typed (or picked from
/// the contacts) in a modal rather than on the confirm sheet. Null when it
/// is closed without Done.
///
/// With [familyModule] (Family, 0317) a host also picks a member or a child
/// of their family the module allows; [onFamily] hears who (null: someone
/// else) before the sheet closes with Done.
Future<BookedFor?> showBookForSheet(
  BuildContext context, {
  String name = '',
  String phone = '',
  String? familyModule,
  FamilyPick? family,
  ValueChanged<FamilyPick?>? onFamily,
}) =>
    showAppSheet<BookedFor>(id: 'book-for.show-book-for-sheet',
      context: context,
      // Scrolls, above the keyboard, when it does not fit (landscape).
      fitContent: true,
      builder: (_) => _BookForSheet(
        name: name,
        phone: phone,
        familyModule: familyModule,
        family: family,
        onFamily: onFamily,
      ),
    );

class _BookForSheet extends ConsumerStatefulWidget {
  const _BookForSheet({required this.name, required this.phone, this.familyModule, this.family, this.onFamily});
  final String name, phone;
  final String? familyModule;
  final FamilyPick? family;
  final ValueChanged<FamilyPick?>? onFamily;

  @override
  ConsumerState<_BookForSheet> createState() => _BookForSheetState();
}

class _BookForSheetState extends ConsumerState<_BookForSheet> {
  late final _name = TextEditingController(text: widget.name);
  late final _phone = TextEditingController(text: widget.phone);
  late String? _familyId = widget.family?.id;
  late bool _withAdult = widget.family?.withAdult ?? false;

  void _done(BookedFor ready, FamilyPassenger? picked) {
    widget.onFamily?.call(picked == null ? null : (id: picked.id, withAdult: _withAdult));
    Navigator.pop(context, ready);
  }

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
    final family = widget.familyModule == null
        ? const <FamilyPassenger>[]
        : [for (final p in ref.watch(familyPassengersProvider(widget.familyModule!)).value ?? const <FamilyPassenger>[])
            if (p.allowed) p];
    final picked = family.where((p) => p.id == _familyId).firstOrNull;
    final myPhone = ref.watch(profileProvider).value?.phone ?? '';
    // A child too young to ride alone goes only with an adult.
    final needsAdult = picked != null && picked.needsAdult && !_withAdult;
    final ready = needsAdult ? null : bookedFor(_name.text, _phone.text);
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
              // Family (0317): the members and children this service allows.
              if (family.isNotEmpty) ...[
                Text('Your family', style: t.textTheme.titleSmall),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final p in family)
                    ChoiceChip(
                      key: ValueKey('book-for-family-${p.id}'),
                      label: Text(p.label),
                      selected: p.id == _familyId,
                      onSelected: (on) => setState(() {
                        _familyId = on ? p.id : null;
                        _withAdult = false;
                        if (on) {
                          _name.text = p.name;
                          _phone.text = p.phone ?? myPhone;
                        }
                      }),
                    ),
                ]),
                if (picked != null && picked.isChild) ...[
                  SwitchListTile(
                    key: const ValueKey('book-for-family-adult'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('An adult rides with them'),
                    subtitle: Text(picked.needsAdult
                        ? '${picked.name.split(' ').first} is too young to ride alone.'
                        : 'The driver checks a 4-digit pickup code you get in the app.'),
                    value: _withAdult,
                    onChanged: (v) => setState(() => _withAdult = v),
                  ),
                ],
                const SizedBox(height: 12),
              ],
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
                        unawaited(showAppNotice(
                          id: 'notice.book-for',
                          context: context,
                          message: 'That contact has no phone number.',
                        ));
                      }
                    } catch (_) {
                      if (context.mounted) {
                        unawaited(showAppNotice(
                          id: 'notice.book-for',
                          context: context,
                          message: "Couldn't open your contacts. Please try again.",
                          kind: NoticeKind.error,
                        ));
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
                onChanged: (_) => setState(() => _familyId = null),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('book-for-phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: "Passenger's phone"),
                onChanged: (_) => setState(() => _familyId = null),
                onSubmitted: (_) {
                  if (ready != null) _done(ready, picked);
                },
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('book-for-done'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: ready == null ? null : () => _done(ready, picked),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
