import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

final emergencyContactsProvider = FutureProvider.autoDispose<List<EmergencyContact>>(
  (ref) => ref.watch(accountRepositoryProvider).emergencyContacts(),
);

class EmergencyContactsScreen extends ConsumerWidget {
  const EmergencyContactsScreen({super.key});

  static const maxContacts = 5;

  Future<void> _edit(BuildContext context, WidgetRef ref, [EmergencyContact? c]) async {
    final name = TextEditingController(text: c?.name);
    final phone = TextEditingController(text: c?.phone);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c == null ? 'Add contact' : 'Edit contact'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
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
      appBar: AppBar(title: const Text('Emergency contacts')),
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
                        ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                          title: Text(c.name),
                          subtitle: Text(c.phone),
                          onTap: () => _edit(context, ref, c),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              icon: const Icon(Icons.call_outlined),
                              onPressed: () => launchUrl(Uri(scheme: 'tel', path: c.phone)),
                            ),
                            IconButton(
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
