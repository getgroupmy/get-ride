import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_contact_picker/flutter_native_contact_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../core/contact_phone.dart';
import '../../core/picked_contact.dart';
import '../../platform/web_contacts.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/dial_country_picker.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/page_style_host.dart';

final emergencyContactsProvider = FutureProvider.autoDispose<List<EmergencyContact>>(
  (ref) => ref.watch(accountRepositoryProvider).emergencyContacts(),
);

typedef PickedContact = ({String? name, String? phone});

/// Opens the phone's own contact picker and returns the person chosen, or
/// null when they backed out. The system picker hands back only that one
/// contact, so no address-book permission is asked for. On the web it is the
/// browser's Contact Picker where there is one (Chrome on Android); null on a
/// browser without it (Safari on iPhone) and on desktop, where the button is
/// not shown. Overridden in tests.
final contactPickerProvider = Provider<Future<PickedContact?> Function()?>((ref) {
  if (kIsWeb) {
    if (!webContactsSupported()) return null;
    return () async {
      final c = await pickWebContact();
      if (c == null) return null;
      return pickedContact(fullName: c.name, numbers: c.numbers);
    };
  }
  if (!(defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
    return null;
  }
  return () async {
    final c = await FlutterNativeContactPicker().selectPhoneNumber();
    if (c == null) return null;
    return pickedContact(fullName: c.fullName, selected: c.selectedPhoneNumber, numbers: c.phoneNumbers);
  };
});

class EmergencyContactsScreen extends ConsumerWidget {
  const EmergencyContactsScreen({super.key});

  static const maxContacts = 5;

  Future<void> _edit(BuildContext context, WidgetRef ref, [EmergencyContact? c]) async {
    final split = splitContactPhone(c?.phone, defaultDialCode: AppConfig.defaultDialCode);
    var country = split.country;
    final name = TextEditingController(text: c?.name);
    final phone = TextEditingController(text: split.local);
    final pick = ref.read(contactPickerProvider);
    final ok = await showAppDialog<bool>(id: 'emergency-contacts.edit',
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          // Scrolls under a keyboard on a small phone or at large text,
          // with Cancel and Save kept in view.
          scrollable: true,
          title: Text(c == null ? 'Add contact' : 'Edit contact'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (pick != null)
              Align(
                alignment: Alignment.centerRight,
                child: BusyButton.text(
                  key: const ValueKey('contact-pick'),
                  icon: const Icon(Icons.contacts_outlined),
                  child: const Text('Contacts'),
                  onPressed: () async {
                    try {
                      final p = await pick();
                      if (p == null) return;
                      if (p.name != null) name.text = p.name!;
                      if (p.phone != null) {
                        final picked = splitContactPhone(p.phone, defaultDialCode: country.dialCode);
                        setDialog(() => country = picked.country);
                        phone.text = picked.local;
                      } else if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('The selected contact has no phone number.')),
                        );
                      }
                    } catch (_) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text("Couldn't open your contacts. Please try again.")),
                        );
                      }
                    }
                  },
                ),
              ),
            TextField(
              controller: name,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DialCountryButton(
                key: const ValueKey('contact-dial-country'),
                country: country,
                height: 56,
                onPressed: () async {
                  final picked = await showDialCountryPicker(ctx, selected: country);
                  if (picked != null) setDialog(() => country = picked);
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey('contact-phone'),
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\s+()-]'))],
                  decoration: const InputDecoration(labelText: 'Phone'),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
              ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    final number = composeContactPhone(country.dialCode, phone.text);
    if (ok != true || name.text.trim().isEmpty || number.isEmpty) return;
    try {
      await ref.read(accountRepositoryProvider).saveEmergencyContact(id: c?.id, name: name.text.trim(), phone: number);
      ref.invalidate(emergencyContactsProvider);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, EmergencyContact c) async {
    final ok = await showAppDialog<bool>(id: 'emergency-contacts.delete',
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete contact?'),
        content: Text('${c.name} will no longer be told about your trips in an emergency.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('contact-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(accountRepositoryProvider).deleteEmergencyContact(c.id);
      ref.invalidate(emergencyContactsProvider);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(emergencyContactsProvider);
    final count = contacts.value?.length ?? 0;
    return Scaffold(
      appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Emergency contacts')),
      floatingActionButton: count >= maxContacts
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add contact'),
            ),
      body: AsyncView(
        value: contacts,
        onRetry: () => ref.invalidate(emergencyContactsProvider),
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.contact_emergency_outlined,
                title: 'No emergency contacts',
                message: 'Add people we can share your trip with in an emergency.',
              )
            : ListView(children: [
                ResponsiveCenter(
                  child: Card(
                    child: Column(children: [
                      for (final c in list)
                        BusyListTile(
                          leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                          title: Text(c.name),
                          subtitle: Text(c.phone),
                          onTap: () => _edit(context, ref, c),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              tooltip: 'Call ${c.name}',
                              icon: const Icon(Icons.call_outlined),
                              onPressed: () => launchUrl(Uri(scheme: 'tel', path: c.phone)),
                            ),
                            BusyIconButton(
                              key: ValueKey('contact-delete-${c.id}'),
                              tooltip: 'Delete ${c.name}',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(context, ref, c),
                            ),
                          ]),
                        ),
                    ]),
                  ),
                ),
              ]),
      ),
    );
  }
}
