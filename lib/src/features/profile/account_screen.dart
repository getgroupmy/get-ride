import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/admin_providers.dart';
import '../../core/referral.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final profile = ref.watch(profileProvider);
    final isAdmin = ref.watch(adminAccessProvider).value?.isAdmin ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(children: [
        ResponsiveCenter(
          maxWidth: 760,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AsyncView(
              value: profile,
              onRetry: () => ref.invalidate(profileProvider),
              data: (p) => Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: CircleAvatar(
                    radius: 28,
                    backgroundImage: p?.avatarUrl != null ? NetworkImage(p!.avatarUrl!) : null,
                    child: p?.avatarUrl == null ? const Icon(Icons.person, size: 28) : null,
                  ),
                  title: Text(p?.name ?? 'Add your name', style: t.textTheme.titleLarge),
                  subtitle: Text([p?.phone, p?.displayId].whereType<String>().join(' · ')),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => context.go('/account/edit'),
                ),
              ),
            ),
            if (profile.value != null)
              Card(
                child: ListTile(
                  key: const ValueKey('account-referral'),
                  leading: const Icon(Icons.card_giftcard),
                  title: const Text('Invite friends'),
                  subtitle: Text(
                    'Your code ${referralCodeFor(userId: profile.value!.id, explicitCode: profile.value!.referralCode)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/account/referral'),
                ),
              ),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.electric_car_outlined),
                  title: const Text('Book TEKSI EV'),
                  subtitle: const Text('Order an electric car, or follow your order'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/ev'),
                ),
                ListTile(
                  leading: const Icon(Icons.contact_emergency_outlined),
                  title: const Text('Emergency contacts'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/account/emergency'),
                ),
                ListTile(
                  leading: const Icon(Icons.support_agent),
                  title: const Text('Help & support'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/account/support'),
                ),
                if (isAdmin)
                  ListTile(
                    leading: const Icon(Icons.admin_panel_settings_outlined),
                    title: const Text('Admin panel'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.go('/admin'),
                  ),
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Settings'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/account/settings'),
                ),
              ]),
            ),
            Card(
              child: ListTile(
                leading: Icon(Icons.logout, color: t.colorScheme.error),
                title: Text('Sign out', style: TextStyle(color: t.colorScheme.error)),
                onTap: () => ref.read(authRepositoryProvider).signOut(),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
