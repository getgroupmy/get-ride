import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_contact_picker/flutter_native_contact_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/picked_contact.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_host.dart';

final emergencyContactsProvider = FutureProvider.autoDispose<List<EmergencyContact>>(
  (ref) => ref.watch(accountRepositoryProvider).emergencyContacts(),
);

typedef PickedContact = ({String? name, String? phone});

/// Opens the phone's own contact picker and returns the person chosen, or
/// null when they backed out. The system picker hands back only that one
/// contact, so no address-book permission is asked for. Null on the web and
/// desktop, which have no picker (the button is not shown there); overridden
/// in tests.
final contactPickerProvider = Provider<Future<PickedContact?> Function()?>((ref) {
  if (kIsWeb || !(defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
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
    final name = TextEditingController(text: c?.name);
    final phone = TextEditingController(text: c?.phone);
    final pick = ref.read(contactPickerProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
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
                      phone.text = p.phone!;
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
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 12),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty || phone.text.trim().isEmpty) return;
    try {
      await ref
          .read(accountRepositoryProvider)
          .saveEmergencyContact(id: c?.id, name: name.text.trim(), phone: phone.text.trim());
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
                              icon: const Icon(Icons.call_outlined),
                              onPressed: () => launchUrl(Uri(scheme: 'tel', path: c.phone)),
                            ),
                            BusyIconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await ref.read(accountRepositoryProvider).deleteEmergencyContact(c.id);
                                ref.invalidate(emergencyContactsProvider);
                              },
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
