// Account → Profile (Expo `app/profile.tsx`): who the account is, read-only,
// with Edit for the editor, the sign-in security shortcuts and sign out. The
// side menus' profile header opens this page rather than the editor.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/net_image.dart';
import '../../widgets/side_menu_host.dart';
import '../settings/change_pin_screen.dart' show pinSetProvider;
import 'account_screen.dart' show confirmSignOut;
import 'referral_screen.dart' show myReferrerProvider;

/// An ID or passport number with all but its last four characters hidden:
/// the page is often open in a car with a passenger beside the phone.
/// Pure.
String maskIdNumber(String raw) {
  final s = raw.replaceAll(RegExp(r'\s'), '');
  if (s.length <= 4) return s;
  return '${'•' * (s.length - 4)}${s.substring(s.length - 4)}';
}

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        leading: sideMenuLeading(context),
        // One way to edit: the "Edit profile" button under the details.
        title: const Text('Profile'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(profileProvider.future),
        child: AsyncView(
          value: ref.watch(profileProvider),
          onRetry: () => ref.invalidate(profileProvider),
          data: (p) => ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [ResponsiveCenter(maxWidth: 760, child: _ProfileBody(profile: p))],
          ),
        ),
      ),
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({required this.profile});

  final Profile? profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final p = profile;
    final referrer = ref.watch(myReferrerProvider).value;
    final pinSet = ref.watch(pinSetProvider).value;
    String shown(String? v) => (v ?? '').trim().isEmpty ? 'Not set' : v!.trim();

    Widget section(String title, List<Widget> rows) => Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(title, style: t.textTheme.titleSmall),
          ),
          ...rows,
        ],
      ),
    );
    Widget row(IconData icon, String label, String value, {Key? key}) => ListTile(
      key: key,
      dense: true,
      leading: Icon(icon, color: muted),
      title: Text(label, style: TextStyle(color: muted)),
      subtitle: Text(value, style: t.textTheme.bodyLarge),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Center(
          child: NetAvatar(url: p?.avatarUrl, radius: 44, fallback: const Icon(Icons.person, size: 44)),
        ),
        const SizedBox(height: 10),
        Text(
          shown(p?.name) == 'Not set' ? 'Add your name' : p!.name!.trim(),
          key: const ValueKey('profile-name'),
          textAlign: TextAlign.center,
          style: t.textTheme.headlineSmall,
        ),
        if (p?.displayId case final id?)
          Text(
            'Account $id',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
        if (referrer != null) ...[
          const SizedBox(height: 8),
          Center(
            child: Chip(
              key: const ValueKey('profile-referred'),
              avatar: const Icon(Icons.card_giftcard, size: 18),
              label: Text(referrer.name == null ? 'Referred' : 'Referred by ${referrer.name}'),
            ),
          ),
        ],
        if (p != null && p.totalRides > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${p.totalRides} ride${p.totalRides == 1 ? '' : 's'}',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
          ),
        const SizedBox(height: 12),
        section('Account', [
          row(Icons.phone_iphone, 'Phone number', shown(p?.phone)),
          row(Icons.mail_outline, 'Email', shown(p?.email)),
        ]),
        section('Identity', [
          row(Icons.flag_outlined, 'Country', shown(p?.nationality)),
          row(
            Icons.badge_outlined,
            'ID / passport no.',
            (p?.idNumber ?? '').trim().isEmpty ? 'Not set' : maskIdNumber(p!.idNumber!),
            key: const ValueKey('profile-id'),
          ),
          row(Icons.home_outlined, 'Address', shown(p?.address)),
        ]),
        section('Security', [
          ListTile(
            key: const ValueKey('profile-pin'),
            leading: Icon(Icons.password, color: muted),
            title: Text(pinSet == false ? 'Set sign-in PIN' : 'Change sign-in PIN'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/account/settings/pin'),
          ),
          ListTile(
            leading: Icon(Icons.phone_forwarded_outlined, color: muted),
            title: const Text('Change phone number'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/account/settings/phone'),
          ),
        ]),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          key: const ValueKey('profile-edit-button'),
          onPressed: () => context.push('/account/edit'),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Edit profile'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const ValueKey('profile-sign-out'),
          style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
          onPressed: () async {
            if (await confirmSignOut(context)) await ref.read(authRepositoryProvider).signOut();
          },
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}
