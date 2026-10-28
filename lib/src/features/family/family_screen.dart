// Family (rider side menu, migration 0317). The host sees their members and
// children, what each gets and has agreed to, where those who share are
// now, and adds, changes or removes them. A member sees what is shared, who
// can see them, the admin looks at their family, and leaves at any time.
// An invitee reads plain terms before Join or Not now.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/booking_modules.dart' show bookingModule;
import '../../core/date_order.dart' show formatDateForUser;
import '../../core/family.dart';
import '../../core/format.dart' show formatMoney;
import '../../data/family_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import 'family_forms.dart';
import 'family_trip_parts.dart';

String _m(num v) => formatMoney(v);

/// The clock the page reads (a fixed one in tests).
final familyClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

class FamilyScreen extends ConsumerStatefulWidget {
  const FamilyScreen({super.key});

  @override
  ConsumerState<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends ConsumerState<FamilyScreen> {
  String? _selected;

  void _reload() {
    ref.invalidate(familyMineProvider);
    ref.invalidate(familyInvitesProvider);
    ref.invalidate(familyLiveProvider);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(familyMineProvider);
    final invites = ref.watch(familyInvitesProvider).value ?? const <FamilyInvite>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Family')),
      body: AsyncView(
        value: async,
        onRetry: _reload,
        data: (view) => RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              ResponsiveCenter(
                maxWidth: 640,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final i in invites) _InviteCard(invite: i, onDone: _reload),
                  switch (view.role) {
                    FamilyRole.host => _HostView(
                      view: view,
                      selected: _selected,
                      onSelect: (id) => setState(() => _selected = id),
                      onChanged: _reload,
                    ),
                    FamilyRole.member => _MemberView(view: view, onChanged: _reload),
                    FamilyRole.none => _NoFamily(view: view, onChanged: _reload),
                  },
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoFamily extends StatelessWidget {
  const _NoFamily({required this.view, required this.onChanged});
  final FamilyView view;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (!view.settings.enabled) {
      return const EmptyState(icon: Icons.family_restroom, title: 'Family isn\'t available in your area yet');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 12),
      Icon(Icons.family_restroom, size: 56, color: t.colorScheme.primary),
      const SizedBox(height: 12),
      Text('Ride as a family', textAlign: TextAlign.center, style: t.textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(
        'Invite up to ${view.settings.maxMembers} people with their phone number, or add a child without a phone. '
        'They pay with your GET.wallet within the limits you set. Nobody is ever watched without knowing: '
        'members see what is shared and who can see them, and can leave at any time.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 20),
      FilledButton(
        key: const ValueKey('family-add'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: () async {
          if (await openAddFamilyMember(context, view)) onChanged();
        },
        child: const Text('Add a member'),
      ),
    ]);
  }
}

class _HostView extends ConsumerWidget {
  const _HostView({required this.view, required this.selected, required this.onSelect, required this.onChanged});
  final FamilyView view;
  final String? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final now = ref.watch(familyClockProvider)();
    final active = [for (final m in view.members) if (m.isActive && !m.isChild) m];
    final limits = active.fold<double>(0, (a, m) => a + m.limit);
    final current = view.members.where((m) => m.id == selected).firstOrNull ?? view.members.firstOrNull;
    final live = ref.watch(familyLiveProvider).value ?? const <FamilyLiveItem>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
        '${view.count} of ${view.cap} members · spent this month ${_m(view.spent)}'
        '${limits > 0 ? ' of ${_m(limits)}' : ''}',
        key: const ValueKey('family-summary'),
        style: TextStyle(color: muted),
      ),
      const SizedBox(height: 10),
      for (final m in view.members)
        _MemberTile(member: m, selected: current?.id == m.id, now: now, onTap: () => onSelect(m.id)),
      if (current != null) _MemberCard(view: view, member: current, onChanged: onChanged),
      if (live.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Shared with you now', style: t.textTheme.titleSmall),
        for (final l in live)
          ListTile(
            key: ValueKey('family-live-${l.memberId}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.location_on_outlined),
            title: Text(l.name),
            subtitle: Text([l.line, if (l.driver != null) '${l.driver}${l.plate == null ? '' : ' · ${l.plate}'}'].join('\n')),
          ),
      ],
      const SizedBox(height: 16),
      if (view.capRequest?.status == 'pending')
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('You asked for ${view.capRequest!.wanted} members. An admin decides.',
              key: const ValueKey('family-cap-pending'), style: TextStyle(color: muted)),
        ),
      FilledButton(
        key: const ValueKey('family-add'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: () async {
          if (await openAddFamilyMember(context, view)) onChanged();
        },
        child: Text(view.full ? 'Ask for more members' : 'Add a member'),
      ),
      const SizedBox(height: 4),
      const _ViewLogButton(),
    ]);
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member, required this.selected, required this.now, required this.onTap});
  final FamilyMember member;
  final bool selected;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final dark = t.brightness == Brightness.dark;
    final kidBg = dark ? const Color(0xFF3A2A12) : const Color(0xFFFDF2E3);
    final kidFg = dark ? const Color(0xFFFFCF8F) : const Color(0xFF8A4B00);
    final (pill, pillBg, pillFg) = member.onTrip && !member.isChild
        ? ('Live', c.errorContainer, c.onErrorContainer)
        : member.isChild
            ? ('Child', kidBg, kidFg)
            : member.isInvited
                ? ('Invited', c.surfaceContainerHighest, c.onSurfaceVariant)
                : ('Member', c.surfaceContainerHighest, c.onSurfaceVariant);
    final title = [
      member.name,
      if (member.relation != null || (member.isChild && member.birthDate != null))
        '(${[?member.relation, if (member.isChild && member.birthDate != null) '${childAge(member.birthDate!, now)}'].join(', ')})',
      if (member.isChild) '· no phone',
    ].join(' ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? c.primary : c.outlineVariant, width: selected ? 2 : 1),
        ),
        child: InkWell(
          key: ValueKey('family-member-${member.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: member.isChild ? kidBg : c.primaryContainer,
                  foregroundColor: member.isChild ? kidFg : c.onPrimaryContainer,
                  child: Text(member.initials, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: t.textTheme.titleSmall),
                    Text(familyMemberLine(member, _m, now),
                        style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                  ]),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: pillBg, borderRadius: BorderRadius.circular(10)),
                  child: Text(pill, style: TextStyle(color: pillFg, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

String _servicesLine(FamilyView view, List<String>? keys) {
  final mods = view.payModules;
  if (keys == null) return mods.isEmpty ? 'None in your area yet' : familyList([for (final m in mods) m.name]);
  final names = [
    for (final k in keys) mods.where((m) => m.key == k).firstOrNull?.name ?? bookingModule(k)?.name ?? k,
  ];
  return names.isEmpty ? 'None' : familyList(names);
}

/// What one member gets and has agreed to (the host's view).
class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.view, required this.member, required this.onChanged});
  final FamilyView view;
  final FamilyMember member;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = member;
    final first = m.name.split(' ').first;
    final s = view.settings;
    final rows = <(IconData, String, String)>[
      if (m.isChild) ...[
        (Icons.payments_outlined, 'Pays with', 'My GET.wallet only'),
        (Icons.apps, 'Services', _servicesLine(view, m.services)),
        (Icons.pin_outlined, 'Pickup code', 'New 4 digits every ride'),
        if (s.womenDriversForChildren) (Icons.woman_outlined, 'Driver', 'Women drivers (admin rule)'),
        (Icons.directions_walk, 'Rides alone', 'From ${s.aloneAge}; younger with an adult'),
      ] else ...[
        (
          Icons.payments_outlined,
          m.isInvited ? 'Will pay with my GET.wallet' : 'Pays with my GET.wallet',
          m.monthlyLimit == null
              ? 'Up to ${_m(m.limit)} a month${m.isActive ? ' · ${_m(m.left)} left' : ''}'
              : '${_m(m.monthlyLimit!)} a month${m.isActive ? ' · ${_m(m.left)} left' : ''}',
        ),
        if (m.perRideLimit != null) (Icons.receipt_long_outlined, 'Per trip', 'Up to ${_m(m.perRideLimit!)}'),
        (Icons.apps, 'Services $first can use', _servicesLine(view, m.services)),
        (
          Icons.location_on_outlined,
          'Location I can see',
          m.isInvited
              ? (m.location == FamilyLocationRule.never ? 'Never' : 'Only once they join')
              : m.locationNow.label +
                  (m.locationPending != null ? ' (asked: ${m.locationPending!.label.toLowerCase()})' : ''),
        ),
        (Icons.visibility_outlined, 'Who can see $first', 'Me (they see this list)'),
      ],
    ];
    final note = m.isChild
        ? 'Rides alone from ${s.aloneAge} (admin rule); younger rides with an adult.'
        : m.isInvited
            ? '$first reads all of this before accepting.'
            : '$first saw these rules when joining and gets a notice when they change. They can leave any time.';
    return Card(
      key: const ValueKey('family-member-card'),
      margin: const EdgeInsets.only(top: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(m.name, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          for (final (icon, k, v) in rows)
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Row(children: [
                Icon(icon, size: 20, color: t.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(k, style: TextStyle(color: t.colorScheme.onSurfaceVariant))),
                const SizedBox(width: 8),
                Flexible(child: Text(v, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
            ),
          const SizedBox(height: 4),
          Text(note, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
              key: const ValueKey('family-member-remove'),
              onPressed: () async {
                if (await confirmRemoveFamilyMember(context, m)) onChanged();
              },
              child: Text(m.isInvited ? 'Cancel invite' : 'Remove'),
            ),
            if (!m.isInvited || !m.isChild)
              TextButton(
                key: const ValueKey('family-member-change'),
                onPressed: () async {
                  if (await openEditFamilyMember(context, view, m)) onChanged();
                },
                child: const Text('Change'),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// The member's own view: what is covered, what is shared and with whom,
/// a raise to accept or refuse, Share with family, the admin log, Leave.
class _MemberView extends ConsumerWidget {
  const _MemberView({required this.view, required this.onChanged});
  final FamilyView view;
  final VoidCallback onChanged;

  Future<void> _consent(BuildContext context, WidgetRef ref, {bool? acceptRaise, bool? shareAlways}) async {
    try {
      await ref.read(familyRepositoryProvider).consent(acceptRaise: acceptRaise, shareAlways: shareAlways);
      onChanged();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final me = view.me!;
    final host = view.hostName ?? 'Your host';
    final first = host.split(' ').first;
    final sharedNow = me.locationNow == FamilyLocationRule.always;
    final canAlways = me.location == FamilyLocationRule.always;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('You\'re in ${possessive(host)} family', style: t.textTheme.titleLarge),
      const SizedBox(height: 8),
      if (sharedNow)
        Align(alignment: Alignment.centerLeft, child: SharedWithFamilyChip(onTap: () {}, open: true)),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('What the family covers', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '${familyPayLabel(host)}: ${_m(me.left)} left of ${_m(me.limit)} this month'
              '${me.perRideLimit == null ? '' : ', up to ${_m(me.perRideLimit!)} a trip'}.',
              key: const ValueKey('family-me-covers'),
            ),
            Text('Services: ${_servicesLine(view, me.services)}.'),
            const SizedBox(height: 4),
            Text(
              'Tips, waiting, luggage, add-ons, cancel fees and owed fees on a family trip go to $first too, '
              'inside your limit.',
              style: t.textTheme.bodySmall,
            ),
          ]),
        ),
      ),
      Card(
        key: const ValueKey('family-me-who'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Who can see you', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(switch (me.locationNow) {
              FamilyLocationRule.never => '$first (family host): not your location. $first sees the trips the family pays for.',
              FamilyLocationRule.ride => '$first (family host): your location while you are on a ride the family covers.',
              FamilyLocationRule.always => '$first (family host): your location, while Share with family is on.',
            }),
            const SizedBox(height: 4),
            const Text('GET.ride safety team: only when they open it for a report or SOS; every look is logged.'),
            if (canAlways)
              SwitchListTile(
                key: const ValueKey('family-share-always'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Share with family'),
                subtitle: Text('Let $first see where you are, also when you are not on a ride.'),
                value: me.shareAlways,
                onChanged: (v) => _consent(context, ref, shareAlways: v),
              ),
          ]),
        ),
      ),
      if (me.locationPending != null)
        Card(
          key: const ValueKey('family-raise'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('$first asks to see more', style: t.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(me.locationPending!.memberLine),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('family-raise-keep'),
                    onPressed: () => _consent(context, ref, acceptRaise: false),
                    child: const Text('Keep as it is'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('family-raise-accept'),
                    onPressed: () => _consent(context, ref, acceptRaise: true),
                    child: const Text('Accept'),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      const SizedBox(height: 8),
      const _ViewLogButton(),
      const SizedBox(height: 8),
      OutlinedButton(
        key: const ValueKey('family-leave'),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
        onPressed: () async {
          final ok = await showAppDialog<bool>(
            id: 'family.leave',
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Leave the family?'),
              content: Text('Sharing stops at once and $first no longer pays for your trips.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
                FilledButton(key: const ValueKey('family-leave-confirm'), onPressed: () => Navigator.pop(c, true),
                    child: const Text('Leave')),
              ],
            ),
          );
          if (ok != true || !context.mounted) return;
          try {
            await ref.read(familyRepositoryProvider).leave();
            onChanged();
            if (context.mounted) showInfo(context, 'You left the family. Nothing is shared any more.');
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        },
        child: const Text('Leave family'),
      ),
    ]);
  }
}

/// "Who looked at my family": the admins' logged looks.
class _ViewLogButton extends ConsumerWidget {
  const _ViewLogButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
    key: const ValueKey('family-view-log'),
    icon: const Icon(Icons.policy_outlined),
    label: const Text('Admin looks at my family'),
    onPressed: () => showAppSheet<void>(
      id: 'family.view-log',
      context: context,
      fitContent: true,
      builder: (c) => Consumer(
        builder: (c, ref, _) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Admin looks at my family', style: Theme.of(c).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('An admin opens a family only with a reason. Every look is logged here.'),
            const SizedBox(height: 8),
            AsyncView(
              value: ref.watch(familyViewLogProvider),
              onRetry: () => ref.invalidate(familyViewLogProvider),
              data: (log) => log.isEmpty
                  ? const Padding(padding: EdgeInsets.all(8), child: Text('No looks so far.', key: ValueKey('family-log-empty')))
                  : Column(children: [
                      for (final e in log)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.history),
                          title: Text('${familyViewReasons[e.kind] ?? e.kind}: ${e.reason}'),
                          subtitle: Text('${e.by ?? 'GET.ride admin'} · ${e.at == null ? '' : formatDateForUser(e.at)}'),
                        ),
                    ]),
            ),
          ]),
        ),
      ),
    ),
  );
}

/// An invitation at the top of the page: opens the terms.
class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.invite, required this.onDone});
  final FamilyInvite invite;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey('family-invite-${invite.member.id}'),
    child: ListTile(
      leading: const Icon(Icons.mail_outline),
      title: Text('${invite.hostName} added you to their family'),
      subtitle: const Text('Read what joining means. Nothing is shared until you tap Join.'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final changed = await Navigator.of(context).push<bool>(
          AppPageRoute(id: 'family.invite', builder: (_) => FamilyInviteScreen(invite: invite)),
        );
        if (changed == true) onDone();
      },
    ),
  );
}

/// The invite with plain terms, then Join family or Not now.
class FamilyInviteScreen extends ConsumerWidget {
  const FamilyInviteScreen({super.key, required this.invite});
  final FamilyInvite invite;

  static const _icons = {
    'payments': Icons.payments_outlined,
    'workspace_premium': Icons.workspace_premium_outlined,
    'location_on': Icons.location_on_outlined,
    'visibility': Icons.visibility_outlined,
    'logout': Icons.logout,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final terms = familyJoinTerms(invite, _m);
    Future<void> answer(bool join) async {
      try {
        await ref.read(familyRepositoryProvider).respond(invite.member.id, join: join,
            shown: [for (final (_, text) in terms) text]);
        if (!context.mounted) return;
        Navigator.of(context).pop(true);
        if (join) showInfo(context, 'You joined ${possessive(invite.hostName)} family. You can leave at any time.');
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Family invite')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ResponsiveCenter(
          maxWidth: 560,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${invite.hostName.split(' ').first} added you to their family', style: t.textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('Read what joining means. Nothing is shared until you tap Join.'),
            const SizedBox(height: 12),
            for (final (icon, text) in terms)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(_icons[icon], color: t.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(text, style: t.textTheme.bodyLarge)),
                ]),
              ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: BusyButton.outlined(
                  key: const ValueKey('family-not-now'),
                  onPressed: () => answer(false),
                  child: const Text('Not now'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: BusyButton.filled(
                  key: const ValueKey('family-join'),
                  onPressed: () => answer(true),
                  child: const Text('Join family'),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
