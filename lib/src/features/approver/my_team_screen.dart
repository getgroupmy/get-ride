import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../admin/screens/people/people_logic.dart' show partnerTypeOptions;
import '../../admin/screens/people/people_widgets.dart' show PartnerTypeField;
import '../../core/permits.dart' show PermitItem, PermitStatus;
import '../../core/secure_screen.dart';
import '../../data/approver_inbox_repository.dart';
import '../../data/partner_doc_check.dart' show partnerTypeEntriesProvider;
import '../../widgets/app_notice.dart';
import '../../widgets/common.dart';
import '../../widgets/offline_strip.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../../widgets/storage_image.dart';
import 'approver_inbox_screen.dart' show ApproverInboxScreen, openApproverDocument;

/// Maps an approver_add_credit error to a message for the approver; null when
/// not recognised (a generic message is shown).
String? _creditErrorText(Object e) {
  final m = e is PostgrestException ? e.message : e.toString();
  bool has(String c) => m.contains(c);
  if (has('wrong_pin')) return 'That PIN is not right. Try again.';
  if (has('insufficient_balance')) return "Your GET.wallet doesn't have enough for that.";
  if (has('invalid_amount')) return 'Enter an amount between RM1 and RM10,000.';
  if (has('not_allowed')) return "You're not allowed to add credit.";
  if (has('out_of_scope') || has('invalid_member')) return "This member isn't in your scope.";
  if (has('PIN_LOCKED')) return 'Too many wrong PINs. Try again later.';
  if (has('RATE_LIMITED')) return 'Too many attempts. Try again in a moment.';
  return null;
}

/// Side menu → My Team: the people this approver's grant reaches (migration
/// 0357). A searchable list that loads a few at a time; tapping a person opens
/// their member screen, where the approver manages that person's documents
/// with the same actions the inbox uses. Profile, vehicle and statistics come
/// in later phases.
class MyTeamScreen extends ConsumerStatefulWidget {
  const MyTeamScreen({super.key});

  @override
  ConsumerState<MyTeamScreen> createState() => _MyTeamScreenState();
}

class _MyTeamScreenState extends ConsumerState<MyTeamScreen> {
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  String _query = '';
  final List<TeamMember> _members = [];
  bool _loading = false;
  bool _hasMore = true;
  bool _firstLoadDone = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      _loadMore();
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (value.trim() == _query) return;
      _query = value.trim();
      _reload();
    });
  }

  /// Fresh search / first load: clear the list and fetch the first page.
  Future<void> _reload() async {
    setState(() {
      _members.clear();
      _hasMore = true;
      _error = null;
      _firstLoadDone = false;
    });
    await _loadMore(fresh: true);
  }

  Future<void> _loadMore({bool fresh = false}) async {
    if (_loading || (!_hasMore && !fresh)) return;
    setState(() => _loading = true);
    try {
      final page = await ref.read(approverInboxRepositoryProvider).coveredPartners(
            query: _query,
            after: fresh ? null : _members.lastOrNull,
          );
      if (!mounted) return;
      setState(() {
        _members.addAll(page.members);
        _hasMore = page.hasMore;
        _loading = false;
        _firstLoadDone = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _firstLoadDone = true;
        if (_members.isEmpty) _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Member cards can carry ID numbers and photos; keep the list out of
    // screenshots and recordings, like the inbox.
    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: const Text('My Team')),
        body: OfflineStrip.over(Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: ResponsiveCenter(
                maxWidth: 760,
                child: TextField(
                  key: const ValueKey('my-team-search'),
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search name, phone, plate or ID',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchCtrl.clear();
                              _onSearchChanged('');
                            },
                          ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ),
            Expanded(child: _body(context)),
          ],
        )),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null && _members.isEmpty) {
      return EmptyState(
        icon: Icons.cloud_off,
        title: 'Something went wrong',
        message: errorText(_error!),
        details: errorDetails(_error!),
        action: TextButton(onPressed: _reload, child: const Text('Retry')),
      );
    }
    if (!_firstLoadDone && _members.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_members.isEmpty) {
      return EmptyState(
        icon: Icons.groups_outlined,
        title: _query.isEmpty ? 'No one in your team yet' : 'No matches',
        message: _query.isEmpty
            ? 'People within the scope your admin set appear here.'
            : 'No one in your scope matches "$_query".',
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
        // One extra row for the bottom spinner / "that's everyone" line.
        itemCount: _members.length + 1,
        itemBuilder: (context, i) {
          if (i == _members.length) return _footer(context);
          return ResponsiveCenter(
            maxWidth: 760,
            child: _TeamCard(
              member: _members[i],
              onTap: () => context.push('/my-team/member', extra: _members[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _footer(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (!_hasMore && _members.length > 3) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Center(
          child: Text("That's everyone in your scope.",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
    }
    return const SizedBox(height: 8);
  }
}

/// One person's card in the My Team list.
class _TeamCard extends StatelessWidget {
  const _TeamCard({required this.member, required this.onTap});

  final TeamMember member;
  final VoidCallback onTap;

  static String _money(double v) {
    final neg = v < 0;
    final parts = v.abs().toStringAsFixed(2).split('.');
    final digits = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return '${neg ? '-' : ''}RM $buf.${parts[1]}';
  }

  /// A short, locale-neutral day stamp for the card grid (e.g. "4 Feb 2027").
  static String _shortDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // The subtitle under the name: GET.wallet balance · account number.
    final subtitleParts = <String>[
      if (member.walletBalance != null) _money(member.walletBalance!),
      if (member.displayId != null) '#${member.displayId}',
    ];

    return Card(
      key: ValueKey('my-team-member-${member.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Avatar(url: member.avatarUrl, name: member.name),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(member.name, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (subtitleParts.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(subtitleParts.join(' · '),
                                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (member.status != null) _StatusChip(status: member.status!),
                      if (member.online) ...[
                        const SizedBox(height: 6),
                        const _OnlineChip(),
                      ],
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (member.phone != null) _line(context, Icons.phone_outlined, member.phone!),
              if (member.plate != null || member.vehicleLabel != null)
                _line(context, Icons.directions_car_outlined,
                    [member.vehicleLabel, member.plate].where((e) => e != null).join(' · ')),
              const SizedBox(height: 10),
              _InfoGrid(rows: [
                ('ID NO.', member.nationality != null && member.ic != null
                    ? '${member.ic} · ${member.nationality}'
                    : (member.ic ?? '—')),
                ('SERVICE CITY', member.serviceCity ?? '—'),
                ('REGISTERED', member.registeredAt != null ? _shortDate(member.registeredAt!) : '—'),
                ('LAST UPDATED', member.updatedAt != null ? _shortDate(member.updatedAt!) : '—'),
              ]),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (member.pendingDocs > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: cs.secondaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('${member.pendingDocs} to review',
                          style: text.labelMedium?.copyWith(color: cs.onSecondaryContainer)),
                    )
                  else
                    Text('No documents waiting',
                        style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  const Spacer(),
                  Text('Open', style: text.labelLarge?.copyWith(color: cs.primary)),
                  Icon(Icons.chevron_right, color: cs.primary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value,
                style: Theme.of(context).textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// A small green "Online" pill for a member who is driving right now.
class _OnlineChip extends StatelessWidget {
  const _OnlineChip();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const green = Color(0xFF1B8A4B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: green.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7, height: 7,
            decoration: const BoxDecoration(color: green, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text('Online', style: text.labelSmall?.copyWith(color: green, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// The 2×2 label/value grid on a team card (ID NO. / SERVICE CITY /
/// REGISTERED / LAST UPDATED).
class _InfoGrid extends StatelessWidget {
  const _InfoGrid({required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Widget cell((String, String) r) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.$1, style: text.labelSmall?.copyWith(
                color: cs.onSurfaceVariant, letterSpacing: 0.4, fontSize: 10)),
            const SizedBox(height: 1),
            Text(r.$2, style: text.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        );

    Widget pair(int a, int b) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: cell(rows[a])),
              const SizedBox(width: 12),
              Expanded(child: cell(rows[b])),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          pair(0, 1),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
          pair(2, 3),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({this.url, required this.name});
  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final fallback = CircleAvatar(
      radius: 24,
      backgroundColor: cs.surfaceContainerHighest,
      foregroundColor: cs.onSurfaceVariant,
      child: Text(initial, style: Theme.of(context).textTheme.titleMedium),
    );
    if (url == null) return fallback;
    return ClipOval(
      child: SizedBox(
        width: 48,
        height: 48,
        child: StorageImage(
          url!,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

/// A lifecycle-status pill (approved / blocked / pending…).
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = status.toLowerCase();
    final (bg, fg) = s.contains('block') || s.contains('reject')
        ? (cs.errorContainer, cs.onErrorContainer)
        : (s.contains('approv') ? (cs.primaryContainer, cs.onPrimaryContainer) : (cs.surfaceContainerHighest, cs.onSurfaceVariant));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        status.isEmpty ? status : status[0].toUpperCase() + status.substring(1),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// My Team → a person: their details header and their documents, with the
/// same review actions the inbox offers (migration 0357). Reached by a
/// GoRoute with the [TeamMember] as `extra`. The member's full profile, split
/// into tabs (Profile / Vehicle / Documents); Statistics follows with its own
/// aggregation.
class MyTeamMemberScreen extends ConsumerStatefulWidget {
  const MyTeamMemberScreen({super.key, required this.member});

  final TeamMember member;

  @override
  ConsumerState<MyTeamMemberScreen> createState() => _MyTeamMemberScreenState();
}

/// The member tabs, in the order the mockup shows them.
enum _MemberTab { profile, statistics, vehicle, documents }

class _MyTeamMemberScreenState extends ConsumerState<MyTeamMemberScreen> {
  _MemberTab _tab = _MemberTab.profile;
  String _statsPeriod = 'month';
  TeamMember get member => widget.member;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final grant = ref.watch(approverSelfProvider).value;
    final canCredit = grant?.canCredit ?? false;
    final canEditProfile = grant?.canEditProfile ?? false;
    final wallet = ref.watch(approverMemberWalletProvider(member.id)).value;
    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Member'),
          actions: [
            if (canEditProfile)
              IconButton(
                key: const ValueKey('my-team-edit-profile'),
                tooltip: 'Edit profile',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _openEditProfile,
              ),
          ],
        ),
        body: OfflineStrip.over(RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(approverOwnerDocumentsProvider(member.id));
            ref.invalidate(approverMemberWalletProvider(member.id));
            ref.invalidate(approverMemberDetailProvider(member.id));
            ref.invalidate(approverMemberVehiclesProvider(member.id));
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
            children: [
              ResponsiveCenter(maxWidth: 760, child: _headerCard(cs)),
              const SizedBox(height: 10),
              ResponsiveCenter(maxWidth: 760, child: _tabBar(cs)),
              const SizedBox(height: 8),
              ResponsiveCenter(
                maxWidth: 760,
                child: switch (_tab) {
                  _MemberTab.profile => _profileTab(cs, canCredit: canCredit, canEditProfile: canEditProfile, wallet: wallet),
                  _MemberTab.statistics => _statisticsTab(cs),
                  _MemberTab.vehicle => _vehicleTab(cs),
                  _MemberTab.documents => _documentsTab(cs),
                },
              ),
            ],
          ),
        )),
      ),
    );
  }

  // ---- Header + tab bar -----------------------------------------------------

  Widget _headerCard(ColorScheme cs) {
    final text = Theme.of(context).textTheme;
    final subtitle = [
      if ((member.vehicleLabel ?? '').trim().isNotEmpty) member.vehicleLabel!.trim(),
      if ((member.nationality ?? '').trim().isNotEmpty) member.nationality!.trim(),
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Avatar(url: member.avatarUrl, name: member.name),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(member.name, style: text.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle, style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
            if (member.status != null) ...[
              const SizedBox(width: 8),
              _StatusChip(status: member.status!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tabBar(ColorScheme cs) {
    Widget pill(_MemberTab tab, String label) {
      final selected = _tab == tab;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          key: ValueKey('member-tab-${tab.name}'),
          label: Text(label),
          selected: selected,
          onSelected: (_) => setState(() => _tab = tab),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        pill(_MemberTab.profile, 'Profile'),
        pill(_MemberTab.statistics, 'Statistics'),
        pill(_MemberTab.vehicle, 'Vehicle'),
        pill(_MemberTab.documents, 'Documents'),
      ]),
    );
  }

  // ---- Profile tab ----------------------------------------------------------

  Widget _profileTab(ColorScheme cs, {required bool canCredit, required bool canEditProfile, required double? wallet}) {
    final text = Theme.of(context).textTheme;
    Widget row(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 10),
              SizedBox(width: 92, child: Text(label, style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
              Expanded(child: Text(value, style: text.bodyMedium)),
            ],
          ),
        );
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (member.phone != null) row(Icons.phone_outlined, 'Mobile', member.phone!),
            if (member.ic != null) row(Icons.badge_outlined, 'ID No.', member.ic!),
            if (member.idVerified != null) row(Icons.verified_outlined, 'ID check', member.idVerified!),
            if (member.nationality != null) row(Icons.public_outlined, 'Nationality', member.nationality!),
            if (wallet != null)
              row(Icons.account_balance_wallet_outlined, 'GET.wallet', 'RM${wallet.toStringAsFixed(2)}'),
            if (canCredit || canEditProfile) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (canEditProfile)
                    OutlinedButton.icon(
                      key: const ValueKey('my-team-payout'),
                      onPressed: _openPayout,
                      icon: const Icon(Icons.account_balance_outlined, size: 18),
                      label: const Text('Payout'),
                    ),
                  if (canEditProfile)
                    OutlinedButton.icon(
                      key: const ValueKey('my-team-change-phone'),
                      onPressed: _openChangePhone,
                      icon: const Icon(Icons.phone_iphone_outlined, size: 18),
                      label: const Text('Change mobile'),
                    ),
                  if (canCredit)
                    FilledButton.tonalIcon(
                      key: const ValueKey('my-team-add-credit'),
                      onPressed: _openAddCredit,
                      icon: const Icon(Icons.add_card_outlined, size: 18),
                      label: const Text('Add credit'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---- Statistics tab (migration 0367) --------------------------------------

  Widget _statisticsTab(ColorScheme cs) {
    const bg = Color(0xFF0E0E10);
    const tile = Color(0xFF1C1C1F);
    const muted = Color(0xFF9A9AA0);
    final stats = ref.watch(approverMemberStatsProvider((member: member.id, period: _statsPeriod)));
    const periodLabels = {'month': 'This month', 'last_month': 'Last month', 'all': 'All time'};

    Widget kpiTile(String label, String value) => Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(color: tile, borderRadius: BorderRadius.circular(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: muted, fontSize: 13)),
              const SizedBox(height: 10),
              Text(value, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700)),
            ],
          ),
        );

    Widget grid(List<(String, String)> items) => GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.55,
          children: [for (final (l, v) in items) kpiTile(l, v)],
        );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Driver statistics',
                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
              ),
              PopupMenuButton<String>(
                key: const ValueKey('stats-period'),
                initialValue: _statsPeriod,
                onSelected: (v) => setState(() => _statsPeriod = v),
                color: tile,
                itemBuilder: (_) => [
                  for (final e in periodLabels.entries)
                    PopupMenuItem(value: e.key, child: Text(e.value, style: const TextStyle(color: Colors.white))),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(color: tile, borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.expand_more, color: Colors.white, size: 18),
                    const SizedBox(width: 6),
                    Text(periodLabels[_statsPeriod] ?? 'This month',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          stats.when(
            loading: () => const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator(color: Colors.white))),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text("Couldn't load statistics.\n${errorText(e)}", style: const TextStyle(color: muted)),
            ),
            data: (s) {
              if (s == null) {
                return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('This member is no longer in your scope.', style: TextStyle(color: muted)));
              }
              return grid([
                ('Total in-app jobs', _grp(s.inAppJobs)),
                ('Total myGiG jobs', _grp(s.mygigJobs)),
                ('My earning', 'RM ${_money(s.earning)}'),
                ('Avg. earning / KM', s.avgPerKm == null ? '—' : 'RM ${_money(s.avgPerKm!)}'),
                ('Total minutes online', _grp(s.minutesOnline)),
                ('Online KM travelled', _grp(s.onlineKm)),
                ('Total KM job done', _grp(s.totalKm)),
                ('Cancelled by driver', _grp(s.cancelledByDriver)),
                ('Cancelled by user', _grp(s.cancelledByUser)),
              ]);
            },
          ),
        ],
      ),
    );
  }

  /// 1234567 → "1,234,567".
  static String _grp(int n) {
    final s = n.abs().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return '${n < 0 ? '-' : ''}$b';
  }

  /// A money amount with thousands separators and 2 decimals.
  static String _money(double v) {
    final whole = v.truncate();
    final cents = ((v - whole).abs() * 100).round().toString().padLeft(2, '0');
    return '${_grp(whole)}.$cents';
  }

  // ---- Vehicle tab (migration 0364) -----------------------------------------

  Widget _vehicleTab(ColorScheme cs) {
    final vehicles = ref.watch(approverMemberVehiclesProvider(member.id));
    return vehicles.when(
      loading: () => const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(20),
        child: EmptyState(
          icon: Icons.cloud_off,
          title: "Couldn't load vehicles",
          message: errorText(e),
          action: TextButton(
            onPressed: () => ref.invalidate(approverMemberVehiclesProvider(member.id)),
            child: const Text('Retry'),
          ),
        ),
      ),
      data: (v) {
        if (v == null) {
          return const Padding(padding: EdgeInsets.all(20), child: Text('This member is no longer in your scope.'));
        }
        if (v.registered.isEmpty && v.allowed.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: EmptyState(
              icon: Icons.directions_car_outlined,
              title: 'No vehicles',
              message: 'This member has no vehicle registered or shared to them.',
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (v.registered.isNotEmpty) ...[
              _vehicleSectionHeader(cs, 'REGISTERED UNDER THIS ID', v.registered.length,
                  sub: member.ic == null ? null : 'National ID · ${member.ic}'),
              for (final x in v.registered) _vehicleCard(cs, x),
            ],
            if (v.allowed.isNotEmpty) ...[
              const SizedBox(height: 6),
              _vehicleSectionHeader(cs, 'ALLOWED TO USE', v.allowed.length),
              for (final x in v.allowed) _vehicleCard(cs, x),
            ],
          ],
        );
      },
    );
  }

  Widget _vehicleSectionHeader(ColorScheme cs, String title, int count, {String? sub}) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: text.labelMedium?.copyWith(color: cs.onSurfaceVariant, letterSpacing: 0.5)),
              ),
              CircleAvatar(
                radius: 12,
                backgroundColor: cs.surfaceContainerHighest,
                child: Text('$count', style: text.labelSmall?.copyWith(color: cs.onSurface)),
              ),
            ],
          ),
          if (sub != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(sub, style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }

  Widget _vehicleCard(ColorScheme cs, MemberVehicle v) {
    final text = Theme.of(context).textTheme;
    final ownerLine = v.ownerSelf
        ? 'Owner: Self${v.registeredAt == null ? '' : ' · Registered ${_fmtDate(v.registeredAt!)}'}'
        : 'Owner: ${v.ownerName ?? '—'}${v.ownerIc == null ? '' : ' · National ID ${v.ownerIc}'}';
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(v.plate, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                _VehicleStatusChip(ownerSelf: v.ownerSelf, status: v.status, accessActive: v.accessActive),
              ],
            ),
            if (v.descriptor.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(v.descriptor, style: text.bodyMedium),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(ownerLine, style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: ValueKey('vehicle-view-${v.id}'),
                onPressed: () => _openVehicleDetail(v),
                child: const Text('View'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openVehicleDetail(MemberVehicle v) => showAppSheet<void>(
        id: 'approver.vehicle-detail',
        context: context,
        isScrollControlled: true,
        builder: (c) => _VehicleDetailSheet(vehicleId: v.id, memberId: member.id, memberName: member.name),
      );

  // ---- Documents tab --------------------------------------------------------

  Widget _documentsTab(ColorScheme cs) {
    final docs = ref.watch(approverOwnerDocumentsProvider(member.id));
    return docs.when(
      loading: () => const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(20),
        child: EmptyState(
          icon: Icons.cloud_off,
          title: "Couldn't load documents",
          message: errorText(e),
          action: TextButton(
            onPressed: () => ref.invalidate(approverOwnerDocumentsProvider(member.id)),
            child: const Text('Retry'),
          ),
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: EmptyState(
              icon: Icons.description_outlined,
              title: 'No documents',
              message: 'This person has no documents on file in your scope.',
            ),
          );
        }
        final driver = [for (final d in list) if (d.source != 'vehicle') d];
        final vehicle = [for (final d in list) if (d.source == 'vehicle') d];
        final meta = ref.watch(approverOwnerDocMetaProvider(member.id)).asData?.value ?? const {};
        void onChanged() {
          ref.invalidate(approverOwnerDocumentsProvider(member.id));
          ref.invalidate(approverOwnerDocMetaProvider(member.id));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (driver.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Text('DRIVER DOCUMENTS',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant, letterSpacing: 0.6, fontWeight: FontWeight.w700)),
              ),
              for (final d in driver) _DocCard(doc: d, onChanged: onChanged, meta: meta[d.id] as Map?),
            ],
            if (vehicle.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 2),
                child: Text('VEHICLE DOCUMENTS',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant, letterSpacing: 0.6, fontWeight: FontWeight.w700)),
              ),
              for (final d in vehicle) _DocCard(doc: d, onChanged: onChanged, meta: meta[d.id] as Map?),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 4),
              child: Text(
                'Approve / Reject review the document; Upload or Rescan adds a new image '
                'on the driver’s behalf as a pending replacement, and the previous approved '
                'image stays live until it is approved. Every action re-checks your grant’s '
                'scope and permission on the server before any change.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ],
        );
      },
    );
  }

  /// "2025-02-04" → "04 Feb 2025"; leaves anything unparseable as-is.
  static String _fmtDate(String raw) {
    final d = DateTime.tryParse(raw);
    if (d == null) return raw.length >= 10 ? raw.substring(0, 10) : raw;
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month - 1]} ${d.year}';
  }

  // ---- Action sheets --------------------------------------------------------

  Future<void> _openAddCredit() => showAppSheet<void>(
        id: 'approver.add-credit',
        context: context,
        isScrollControlled: true,
        builder: (c) => _AddCreditSheet(member: member),
      );

  Future<void> _openPayout() => showAppSheet<void>(
        id: 'approver.payout',
        context: context,
        isScrollControlled: true,
        builder: (c) => _PayoutSheet(member: member),
      );

  Future<void> _openEditProfile() => showAppSheet<void>(
        id: 'approver.edit-profile',
        context: context,
        isScrollControlled: true,
        builder: (c) => _EditProfileSheet(member: member),
      );

  Future<void> _openChangePhone() => showAppSheet<void>(
        id: 'approver.propose-phone',
        context: context,
        isScrollControlled: true,
        builder: (c) => _ProposePhoneSheet(member: member),
      );
}

/// A small green status chip on a vehicle card (Active / Access active).
class _VehicleStatusChip extends StatelessWidget {
  const _VehicleStatusChip({required this.ownerSelf, this.status, this.accessActive});
  final bool ownerSelf;
  final String? status;
  final bool? accessActive;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = ownerSelf
        ? ((status ?? '').trim().isEmpty ? 'Registered' : _titleCase(status!))
        : (accessActive == false ? 'Access ended' : 'Access active');
    final ok = ownerSelf ? (status == null || status == 'active' || status == 'approved') : (accessActive != false);
    final bg = ok ? Colors.green.withValues(alpha: 0.15) : cs.surfaceContainerHighest;
    final fg = ok ? Colors.green.shade800 : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
    );
  }

  static String _titleCase(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

/// Add credit to a member: an amount and the approver's PIN, paid from the
/// approver's own GET.wallet (migration 0359). On success the member's wallet
/// provider refreshes and the member is pushed.
class _AddCreditSheet extends ConsumerStatefulWidget {
  const _AddCreditSheet({required this.member});
  final TeamMember member;

  @override
  ConsumerState<_AddCreditSheet> createState() => _AddCreditSheetState();
}

class _AddCreditSheetState extends ConsumerState<_AddCreditSheet> {
  final _amount = TextEditingController();
  final _pin = TextEditingController();
  // One request id per sheet, so a retry after a timeout never double-charges.
  final _requestId = const Uuid().v4();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _pin.dispose();
    super.dispose();
  }

  double? get _parsedAmount {
    final v = double.tryParse(_amount.text.trim());
    if (v == null) return null;
    return (v * 100).roundToDouble() / 100;
  }

  bool get _canSubmit {
    final a = _parsedAmount;
    return a != null && a >= 1 && a <= 10000 && _pin.text.trim().length >= 4 && !_busy;
  }

  Future<void> _submit() async {
    final amount = _parsedAmount;
    if (amount == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(approverInboxRepositoryProvider).addCredit(
            memberId: widget.member.id,
            amount: amount,
            pin: _pin.text.trim(),
            requestId: _requestId,
          );
      ref.invalidate(approverMemberWalletProvider(widget.member.id));
      if (!mounted) return;
      Navigator.pop(context);
      unawaited(showAppNotice(
        id: 'notice.approver-credit',
        context: context,
        message: 'RM${amount.toStringAsFixed(2)} added. ${widget.member.name} has been notified.',
        kind: NoticeKind.success,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      unawaited(showAppNotice(
        id: 'notice.approver-credit',
        context: context,
        message: _creditErrorText(e) ?? "Couldn't add credit. Try again.",
        kind: NoticeKind.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add credit', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Top up ${widget.member.name}’s GET.wallet from your own GET.wallet. Confirm with your sign-in PIN.',
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('add-credit-amount'),
            controller: _amount,
            enabled: !_busy,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(
              labelText: 'Amount',
              prefixText: 'RM ',
              hintText: '0.00',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('add-credit-pin'),
            controller: _pin,
            enabled: !_busy,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Your sign-in PIN',
              border: OutlineInputBorder(),
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('add-credit-submit'),
            onPressed: _canSubmit ? _submit : null,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Add credit'),
          ),
        ],
      ),
    );
  }
}

/// One of a member's documents, with its status.
/// A rich document card for the My Team → Documents tab (the mockup's cards):
/// thumbnail, title, status, expiry and captured number, with inline actions
/// gated by the approver's grant. Approve / Reject review the document inline;
/// Details / Rescan / Upload / Remove open the full viewer, where the capture,
/// edit and delete flows (and their confirmations) already live.
class _DocCard extends ConsumerStatefulWidget {
  const _DocCard({required this.doc, required this.onChanged, this.meta});
  final ApproverDoc doc;
  final VoidCallback onChanged;

  /// Per-document meta from approver_owner_document_meta (migration 0370):
  /// changed_by, provider, is_pwd, uploaded_at, reviewed_at. Null on a legacy DB.
  final Map? meta;

  @override
  ConsumerState<_DocCard> createState() => _DocCardState();
}

class _DocCardState extends ConsumerState<_DocCard> {
  bool _busy = false;

  ApproverDoc get doc => widget.doc;

  String? _metaStr(String key) {
    final v = widget.meta?[key];
    final s = '${v ?? ''}'.trim();
    return s.isEmpty || s == 'null' ? null : s;
  }

  Future<void> _review(String action) async {
    setState(() => _busy = true);
    try {
      await ref.read(approverInboxRepositoryProvider).review(doc, action);
      widget.onChanged();
      if (!mounted) return;
      unawaited(showAppNotice(
        id: 'notice.approver-doc', context: context,
        message: action == 'approve' ? 'Document approved.' : 'Document rejected.',
        kind: NoticeKind.success));
    } catch (e) {
      if (!mounted) return;
      final m = e is PostgrestException ? e.message : e.toString();
      unawaited(showAppNotice(
        id: 'notice.approver-doc', context: context,
        message: m.contains('not_allowed') || m.contains('not_authorized')
            ? "You can't review this document."
            : "Couldn't update the document. Try again.",
        kind: NoticeKind.error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openViewer() => openApproverDocument(context, doc, onChanged: widget.onChanged);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final grant = ref.watch(approverSelfProvider).asData?.value;
    final canApprove = grant?.canApprove == true;
    final canUpload = grant?.canUpload == true;
    final canDelete = grant?.canDelete == true;
    final editable = doc.source != 'identity';

    final status = doc.status ?? 'Pending Review';
    final (statusColor, _) = switch (status) {
      'Approved' => (Colors.green.shade700, Icons.check_circle),
      'Rejected' => (cs.error, Icons.cancel),
      'Expired' => (cs.error, Icons.error_outline),
      _ => (Colors.orange.shade800, Icons.schedule),
    };

    Widget btn(String label, VoidCallback? onTap, {Color? fg, bool filled = false, IconData? icon, Key? key}) {
      final child = Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 15), const SizedBox(width: 5)],
        Text(label),
      ]);
      return filled
          ? FilledButton(key: key, style: FilledButton.styleFrom(
              backgroundColor: fg, visualDensity: VisualDensity.compact), onPressed: onTap, child: child)
          : OutlinedButton(key: key, style: OutlinedButton.styleFrom(
              foregroundColor: fg, visualDensity: VisualDensity.compact), onPressed: onTap, child: child);
    }

    final pendingUrl = _metaStr('pending_file_url');
    final isReplacement = pendingUrl != null;

    return Card(
      key: ValueKey('my-team-doc-${doc.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isReplacement)
              Container(
                margin: const EdgeInsets.only(bottom: 11),
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.hourglass_top, size: 15, color: Colors.orange.shade800),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'New image uploaded on behalf — awaiting approval. The approved image stays '
                        'live until this is approved; Reject keeps it and discards the new one.',
                        style: t.textTheme.bodySmall?.copyWith(
                            color: Colors.orange.shade900, fontWeight: FontWeight.w600, height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isReplacement)
                  Column(
                    children: [
                      _thumb(cs, pendingUrl, label: 'New', accent: true),
                      const SizedBox(height: 6),
                      _thumb(cs, doc.fileUrl, label: 'Live'),
                    ],
                  )
                else
                  _thumb(cs, doc.fileUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(doc.docLabel, style: t.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Row(children: [
                        Text('Status: ', style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                        Text(isReplacement
                                ? 'New image · pending review'
                                : (status == 'Pending Review' ? 'Pending review' : status),
                            style: t.textTheme.bodySmall?.copyWith(color: statusColor, fontWeight: FontWeight.w700)),
                      ]),
                      if (isReplacement)
                        Text('Live image: Approved',
                            style: t.textTheme.bodySmall?.copyWith(color: Colors.green.shade700, fontWeight: FontWeight.w600)),
                      if (doc.expiryDate != null)
                        Text('Expiry: ${doc.expiryDate}',
                            style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      if (doc.documentNumber != null)
                        Text('No. ${doc.documentNumber}',
                            style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      if (doc.plate != null)
                        Text('Plate ${doc.plate}',
                            style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      if (_metaStr('provider') != null)
                        Text('Insurance: ${_metaStr('provider')}',
                            style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (_metaStr('changed_by') != null)
                        Text('Changed by: ${_metaStr('changed_by')}',
                            style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 11),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                btn('Details', _busy ? null : _openViewer, key: ValueKey('doc-details-${doc.id}')),
                if (canUpload && editable) ...[
                  btn('Rescan', _busy ? null : _openViewer),
                  btn('Upload', _busy ? null : _openViewer, icon: Icons.upload_outlined),
                ],
                if (doc.source == 'vehicle' && canDelete)
                  btn('Remove', _busy ? null : _openViewer, fg: cs.error),
                if (doc.isPending && canApprove) ...[
                  btn('Approve', _busy ? null : () => _review('approve'),
                      filled: true, fg: const Color(0xFF1F2B48), key: ValueKey('doc-approve-${doc.id}')),
                  btn('Reject', _busy ? null : () => _review('reject'),
                      filled: true, fg: cs.error, key: ValueKey('doc-reject-${doc.id}')),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// A document thumbnail (56×72), with an optional corner label ("New"/"Live").
  Widget _thumb(ColorScheme cs, String? url, {String? label, bool accent = false}) {
    final img = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 56, height: 72,
        child: url != null
            ? StorageImage(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => _thumbFallback(cs))
            : _thumbFallback(cs),
      ),
    );
    if (label == null) return img;
    return Stack(
      children: [
        img,
        Positioned(
          left: 3, bottom: 3,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: accent ? const Color(0xFF2DABE2) : Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }

  Widget _thumbFallback(ColorScheme cs) => ColoredBox(
        color: cs.surfaceContainerHighest,
        child: Icon(ApproverInboxScreen.iconFor(doc.source), color: cs.onSurfaceVariant),
      );
}

/// Edit a covered member's profile (migration 0360). Pre-filled from
/// approver_member_detail; sends only the changed fields. ID-verify is a
/// separate action, shown only with the can_verify_id grant.
class _EditProfileSheet extends ConsumerStatefulWidget {
  const _EditProfileSheet({required this.member});
  final TeamMember member;

  @override
  ConsumerState<_EditProfileSheet> createState() => _EditProfileSheetState();
}

/// Status values the approver may set, with user-facing labels.
const _statusOptions = <(String, String)>[
  ('approved', 'Active'),
  ('blocked', 'Blocked'),
  ('unapproved', 'Unapproved'),
  ('rejected', 'Rejected'),
];

class _EditProfileSheetState extends ConsumerState<_EditProfileSheet> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _ic = TextEditingController();
  final _nationality = TextEditingController();
  final _address = TextEditingController();
  String? _status;
  List<String> _types = const [];
  List<String> _origTypes = const [];
  bool _loaded = false;
  bool _busy = false;
  Map<String, dynamic> _orig = const {};

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _ic.dispose();
    _nationality.dispose();
    _address.dispose();
    super.dispose();
  }

  void _fill(Map<String, dynamic> d) {
    _orig = d;
    _name.text = (d['name'] as String?)?.trim() ?? '';
    _email.text = (d['email'] as String?)?.trim() ?? '';
    _ic.text = (d['ic'] as String?)?.trim() ?? '';
    _nationality.text = (d['nationality'] as String?)?.trim() ?? '';
    _address.text = (d['address'] as String?)?.trim() ?? '';
    final s = (d['status'] as String?)?.trim();
    _status = _statusOptions.any((o) => o.$1 == s) ? s : null;
    _origTypes = [for (final e in (d['partner_types'] as List? ?? const [])) '$e'.trim()]..removeWhere((e) => e.isEmpty);
    _types = List.of(_origTypes);
    _loaded = true;
  }

  /// Only the fields the approver actually changed.
  Map<String, dynamic> _changes() {
    final out = <String, dynamic>{};
    String o(String k) => (_orig[k] as String?)?.trim() ?? '';
    if (_name.text.trim() != o('name')) out['name'] = _name.text.trim();
    if (_email.text.trim() != o('email')) out['email'] = _email.text.trim();
    if (_ic.text.trim() != o('ic')) out['ic'] = _ic.text.trim();
    if (_nationality.text.trim() != o('nationality')) out['nationality'] = _nationality.text.trim();
    if (_address.text.trim() != o('address')) out['address'] = _address.text.trim();
    if (_status != null && _status != o('status')) out['status'] = _status;
    // Services (partner types): send the list only when the set actually changed.
    if (_types.toSet().difference(_origTypes.toSet()).isNotEmpty ||
        _origTypes.toSet().difference(_types.toSet()).isNotEmpty) {
      out['partner_types'] = _types;
    }
    return out;
  }

  Future<void> _save() async {
    final changes = _changes();
    if (changes.isEmpty) {
      Navigator.pop(context);
      return;
    }
    await _run(changes, 'Profile updated.');
  }

  Future<void> _verifyId() => _run({'id_verified': 'Verified'}, 'ID marked verified.');

  Future<void> _run(Map<String, dynamic> fields, String ok) async {
    setState(() => _busy = true);
    try {
      await ref.read(approverInboxRepositoryProvider).editProfile(widget.member.id, fields);
      ref.invalidate(approverMemberDetailProvider(widget.member.id));
      if (!mounted) return;
      Navigator.pop(context);
      unawaited(showAppNotice(id: 'notice.approver-edit', context: context, message: ok, kind: NoticeKind.success));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      unawaited(showAppNotice(
        id: 'notice.approver-edit',
        context: context,
        message: _editErrorText(e) ?? "Couldn't save. Try again.",
        kind: NoticeKind.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final detail = ref.watch(approverMemberDetailProvider(widget.member.id));
    final canVerify = ref.watch(approverSelfProvider).value?.canVerifyId ?? false;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: detail.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(28),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (_, _) => Padding(
          padding: const EdgeInsets.all(20),
          child: Text("Couldn't load this member.", style: TextStyle(color: t.colorScheme.error)),
        ),
        data: (d) {
          if (d == null) {
            return const Padding(padding: EdgeInsets.all(20), child: Text('This member is no longer in your scope.'));
          }
          if (!_loaded) _fill(d);
          final verified = (d['id_verified'] as String?) == 'Verified';
          final isPartner = d['is_partner'] == true;
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Edit profile', style: t.textTheme.titleLarge),
                const SizedBox(height: 12),
                _field(_name, 'Name', key: 'edit-name'),
                _field(_email, 'Email', key: 'edit-email', keyboard: TextInputType.emailAddress),
                _field(_ic, 'ID / passport no.', key: 'edit-ic', caps: true),
                _field(_nationality, 'Nationality', key: 'edit-nationality'),
                _field(_address, 'Address', key: 'edit-address', lines: 2),
                const SizedBox(height: 4),
                Text('Account status', style: t.textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (value, label) in _statusOptions)
                      ChoiceChip(
                        key: ValueKey('edit-status-$value'),
                        label: Text(label),
                        selected: _status == value,
                        onSelected: _busy ? null : (_) => setState(() => _status = value),
                      ),
                  ],
                ),
                if (isPartner) ...[
                  const SizedBox(height: 14),
                  Text('Services', style: t.textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(
                    'The partner service types this member drives for.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  Builder(builder: (context) {
                    final options = partnerTypeOptions(
                        ref.watch(partnerTypeEntriesProvider).value?.map((e) => e.values) ?? const []);
                    return PartnerTypeField(
                      key: const ValueKey('edit-services'),
                      options: options,
                      value: _types,
                      enabled: !_busy,
                      onChanged: (v) => setState(() => _types = v),
                    );
                  }),
                ],
                const SizedBox(height: 14),
                FilledButton(
                  key: const ValueKey('edit-save'),
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save'),
                ),
                if (canVerify) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('edit-verify-id'),
                    onPressed: (_busy || verified) ? null : _verifyId,
                    icon: Icon(verified ? Icons.verified : Icons.verified_outlined, size: 18),
                    label: Text(verified ? 'ID already verified' : 'Mark ID verified'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _field(TextEditingController c, String label,
      {required String key, TextInputType? keyboard, bool caps = false, int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        key: ValueKey(key),
        controller: c,
        enabled: !_busy,
        keyboardType: keyboard,
        textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.none,
        minLines: lines,
        maxLines: lines,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }
}

/// Maps an approver_edit_profile error to a message for the approver.
String? _editErrorText(Object e) {
  final m = e is PostgrestException ? e.message : e.toString();
  if (m.contains('not_allowed')) return "You're not allowed to make that change.";
  if (m.contains('out_of_scope')) return "This member isn't in your scope.";
  if (m.contains('invalid_status')) return 'Pick a valid status.';
  if (m.contains('invalid_id_verified')) return 'Invalid ID verification value.';
  return null;
}

/// Set a covered member's payout account (migration 0361): a bank or e-wallet,
/// its provider (from the admin list), account number and holder. Pre-filled
/// from the member detail.
class _PayoutSheet extends ConsumerStatefulWidget {
  const _PayoutSheet({required this.member});
  final TeamMember member;

  @override
  ConsumerState<_PayoutSheet> createState() => _PayoutSheetState();
}

class _PayoutSheetState extends ConsumerState<_PayoutSheet> {
  final _account = TextEditingController();
  final _holder = TextEditingController();
  String _type = 'bank';
  String? _provider;
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    _account.dispose();
    _holder.dispose();
    super.dispose();
  }

  void _fill(Map<String, dynamic>? d) {
    final pay = d?['payout'];
    if (pay is Map) {
      _type = (pay['type'] as String?) == 'ewallet' ? 'ewallet' : 'bank';
      _provider = (pay['provider'] as String?)?.trim();
      _account.text = (pay['account'] as String?)?.trim() ?? '';
      _holder.text = (pay['holder'] as String?)?.trim() ?? '';
    } else {
      _holder.text = widget.member.name;
    }
    _loaded = true;
  }

  bool get _canSave =>
      !_busy && (_provider ?? '').isNotEmpty && _account.text.trim().length >= 6 && _holder.text.trim().isNotEmpty;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(approverInboxRepositoryProvider).setMemberPayout(
            widget.member.id,
            provider: _provider!,
            account: _account.text.trim(),
            holder: _holder.text.trim(),
            type: _type,
          );
      ref.invalidate(approverMemberDetailProvider(widget.member.id));
      if (!mounted) return;
      Navigator.pop(context);
      unawaited(showAppNotice(
        id: 'notice.approver-payout', context: context, message: 'Payout account saved.', kind: NoticeKind.success));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final m = e is PostgrestException ? e.message : e.toString();
      unawaited(showAppNotice(
        id: 'notice.approver-payout',
        context: context,
        message: m.contains('invalid_payout')
            ? 'Enter the provider, holder and a 6–20 digit account number.'
            : (m.contains('not_allowed') || m.contains('out_of_scope')
                ? "You can't set this member's payout."
                : "Couldn't save. Try again."),
        kind: NoticeKind.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final detail = ref.watch(approverMemberDetailProvider(widget.member.id));
    final providers = ref.watch(payoutProvidersProvider).value ?? const <PayoutProvider>[];
    if (!_loaded && detail.hasValue) _fill(detail.value);
    // Options for the selected type; keep the current provider even if not listed.
    final names = <String>{
      for (final p in providers) if (p.type == _type) p.name,
      if ((_provider ?? '').isNotEmpty) _provider!,
    }.toList()..sort();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Payout account', style: t.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Where ${widget.member.name} is paid out.',
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const ValueKey('payout-type-bank'),
                  label: const Text('Bank'),
                  selected: _type == 'bank',
                  onSelected: _busy ? null : (_) => setState(() { _type = 'bank'; _provider = null; }),
                ),
                ChoiceChip(
                  key: const ValueKey('payout-type-ewallet'),
                  label: const Text('e-Wallet'),
                  selected: _type == 'ewallet',
                  onSelected: _busy ? null : (_) => setState(() { _type = 'ewallet'; _provider = null; }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SearchableDropdownFormField<String>(
              key: const ValueKey('payout-provider'),
              initialValue: names.contains(_provider) ? _provider : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: _type == 'ewallet' ? 'e-Wallet' : 'Bank',
                border: const OutlineInputBorder(),
              ),
              items: [for (final n in names) DropdownMenuItem(value: n, child: Text(n))],
              onChanged: _busy ? null : (v) => setState(() => _provider = v),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('payout-account'),
              controller: _account,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Account number', border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('payout-holder'),
              controller: _holder,
              enabled: !_busy,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Account holder name', border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: const ValueKey('payout-save'),
              onPressed: _canSave ? _save : null,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save payout'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Propose a new mobile number for a covered member (migration 0362). A
/// member's sign-in number controls OTP sign-in and PIN reset, so an approver
/// can NOT change it silently: this only files a pending proposal and pushes the
/// member, who confirms the new number themselves through the ordinary
/// change-number flow (the only path that proves control of the new number).
/// The number must be full international format (`+60…`).
class _ProposePhoneSheet extends ConsumerStatefulWidget {
  const _ProposePhoneSheet({required this.member});
  final TeamMember member;

  @override
  ConsumerState<_ProposePhoneSheet> createState() => _ProposePhoneSheetState();
}

class _ProposePhoneSheetState extends ConsumerState<_ProposePhoneSheet> {
  final _phone = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  bool get _canSend => !_busy && _phone.text.trim().length >= 8;

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await ref.read(approverInboxRepositoryProvider).proposeMemberPhone(widget.member.id, _phone.text.trim());
      if (!mounted) return;
      Navigator.pop(context);
      unawaited(showAppNotice(
        id: 'notice.approver-phone',
        context: context,
        message: 'Proposed. ${widget.member.name} will get a notification to confirm the new number themselves.',
        kind: NoticeKind.success,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      unawaited(showAppNotice(
        id: 'notice.approver-phone',
        context: context,
        message: _proposePhoneErrorText(e) ?? "Couldn't propose that number. Try again.",
        kind: NoticeKind.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Change mobile number', style: t.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              "You can't change a member's sign-in number directly — it protects their account. "
              'Enter the new number and ${widget.member.name} will be asked to confirm it themselves '
              'with a code texted to the new number. Their current number keeps working until they do.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            if (widget.member.phone != null) ...[
              const SizedBox(height: 12),
              Text('Current: ${widget.member.phone}', style: t.textTheme.bodySmall),
            ],
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('propose-phone'),
              controller: _phone,
              enabled: !_busy,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ \-]'))],
              decoration: const InputDecoration(
                labelText: 'New mobile number',
                hintText: '+60 12-345 6789',
                helperText: 'Full international format, starting with the country code (+60…).',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: const ValueKey('propose-phone-send'),
              onPressed: _canSend ? _send : null,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Send for confirmation'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Maps an approver_propose_member_phone error to a message for the approver.
String? _proposePhoneErrorText(Object e) {
  final m = e is PostgrestException ? e.message : e.toString();
  if (m.contains('invalid_phone')) return 'Enter a full international number, e.g. +60 12-345 6789.';
  if (m.contains('same_phone')) return "That's already this member's number.";
  if (m.contains('phone_in_use')) return 'Another account already uses that number.';
  if (m.contains('not_allowed')) return "You're not allowed to make that change.";
  if (m.contains('out_of_scope')) return "This member isn't in your scope.";
  return null;
}

/// The Vehicle detail sheet (migration 0366): who can drive the vehicle and
/// its documents. An approver with can_manage_vehicle can approve a pending
/// driver or revoke another driver's access; the member's own access is shown
/// but not revocable from here.
class _VehicleDetailSheet extends ConsumerStatefulWidget {
  const _VehicleDetailSheet({required this.vehicleId, required this.memberId, required this.memberName});
  final String vehicleId;
  final String memberId;
  final String memberName;

  @override
  ConsumerState<_VehicleDetailSheet> createState() => _VehicleDetailSheetState();
}

class _VehicleDetailSheetState extends ConsumerState<_VehicleDetailSheet> {
  String? _busyAssignment;
  bool _busyAction = false;

  Future<void> _setAccess(String assignmentId, String action) async {
    setState(() => _busyAssignment = assignmentId);
    try {
      await ref.read(approverInboxRepositoryProvider).setVehicleAccess(assignmentId, action);
      ref.invalidate(approverVehicleDetailProvider(widget.vehicleId));
      ref.invalidate(approverMemberVehiclesProvider(widget.memberId));
      if (!mounted) return;
      unawaited(showAppNotice(
        id: 'notice.approver-vehicle',
        context: context,
        message: action == 'approve' ? 'Access approved.' : 'Access revoked.',
        kind: NoticeKind.success,
      ));
    } catch (e) {
      if (!mounted) return;
      final m = e is PostgrestException ? e.message : e.toString();
      unawaited(showAppNotice(
        id: 'notice.approver-vehicle',
        context: context,
        message: m.contains('not_allowed')
            ? "You can't change vehicle access."
            : (m.contains('out_of_scope') ? "This vehicle isn't in your scope." : "Couldn't update access. Try again."),
        kind: NoticeKind.error,
      ));
    } finally {
      if (mounted) setState(() => _busyAssignment = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final detail = ref.watch(approverVehicleDetailProvider(widget.vehicleId));
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: detail.when(
        loading: () => const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator())),
        error: (e, _) => Padding(padding: const EdgeInsets.all(20),
            child: Text("Couldn't load this vehicle.", style: TextStyle(color: cs.error))),
        data: (v) {
          if (v == null) {
            return const Padding(padding: EdgeInsets.all(20), child: Text('This vehicle is no longer in your scope.'));
          }
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(v.plate, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                if (v.descriptor != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(v.descriptor!, style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                if (v.photos.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionLabel(t, cs, 'VEHICLE PHOTOS · ${v.photos.length} ANGLES'),
                  const SizedBox(height: 8),
                  _photosGrid(v),
                ],
                const SizedBox(height: 16),
                _sectionLabel(t, cs, 'VEHICLE'),
                const SizedBox(height: 8),
                _specGrid(t, cs, v),
                if (v.ownerName != null || v.ownerIc != null || v.ownerPhone != null) ...[
                  const SizedBox(height: 16),
                  _sectionLabel(t, cs, 'OWNER'),
                  const SizedBox(height: 8),
                  if (v.ownerName != null) _ownerRow(t, cs, 'Owner name', v.ownerName!),
                  if (v.ownerIc != null) _ownerRow(t, cs, 'Owner ID', '${v.ownerIc!} · National ID'),
                  if (v.ownerPhone != null) _ownerRow(t, cs, 'Owner phone', v.ownerPhone!),
                ],
                const SizedBox(height: 16),
                _sectionLabel(t, cs, 'SERVICES & PERMITS'),
                const SizedBox(height: 8),
                _PermitsSection(vehicleId: widget.vehicleId, regYear: v.year),
                const SizedBox(height: 16),
                _sectionLabel(t, cs, 'WHO CAN DRIVE THIS · ${v.drivers.length}'),
                const SizedBox(height: 6),
                if (v.drivers.isEmpty)
                  Text('No drivers assigned.', style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                for (final dr in v.drivers) _driverRow(t, cs, v.canManage, dr),
                const SizedBox(height: 16),
                _sectionLabel(t, cs, 'VEHICLE DOCUMENTS'),
                const SizedBox(height: 6),
                if (v.documents.isEmpty)
                  Text('No documents on file.', style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                for (final d in v.documents) _docRow(t, cs, d),
                if (v.canManage) ...[
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('vehicle-edit'),
                          onPressed: _busyAction ? null : () => _editVehicle(v),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text('Edit vehicle'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('vehicle-assign-driver'),
                          onPressed: _busyAction ? null : () => _assignDriver(v),
                          icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                          label: const Text('Assign driver'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// Pick a covered member and assign them as a driver of this vehicle.
  Future<void> _assignDriver(VehicleDetail v) async {
    final List<TeamMember> members;
    try {
      final page = await ref.read(approverInboxRepositoryProvider).coveredPartners(limit: 100);
      members = page.members;
    } catch (_) {
      if (!mounted) return;
      unawaited(showAppNotice(
        id: 'notice.approver-vehicle', context: context,
        message: "Couldn't load your team. Try again.", kind: NoticeKind.error));
      return;
    }
    if (!mounted) return;
    if (members.isEmpty) {
      unawaited(showAppNotice(
        id: 'notice.approver-vehicle', context: context,
        message: 'No one in your team to assign yet.', kind: NoticeKind.info));
      return;
    }
    final choices = <SearchChoice<String>>[
      for (final m in members)
        (
          value: m.id,
          label: m.name,
          subtitle: [
            if (m.displayId != null) '#${m.displayId}',
            if (m.phone != null) m.phone,
          ].whereType<String>().join(' · '),
          leading: null,
        ),
    ];
    final memberId = await showSearchPicker<String>(
      context, title: 'Assign a driver', choices: choices);
    if (memberId == null || !mounted) return;

    setState(() => _busyAction = true);
    try {
      await ref.read(approverInboxRepositoryProvider).assignVehicleDriver(v.id, memberId);
      ref.invalidate(approverVehicleDetailProvider(widget.vehicleId));
      ref.invalidate(approverMemberVehiclesProvider(widget.memberId));
      if (!mounted) return;
      unawaited(showAppNotice(
        id: 'notice.approver-vehicle', context: context,
        message: 'Driver assigned.', kind: NoticeKind.success));
    } catch (e) {
      if (!mounted) return;
      final m = e is PostgrestException ? e.message : e.toString();
      unawaited(showAppNotice(
        id: 'notice.approver-vehicle', context: context,
        message: m.contains('not_allowed')
            ? "You can't manage this vehicle's drivers."
            : (m.contains('member_out_of_scope')
                ? "That person isn't in your team."
                : (m.contains('out_of_scope')
                    ? "This vehicle isn't in your scope."
                    : "Couldn't assign the driver. Try again.")),
        kind: NoticeKind.error));
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  /// Open the edit form for this vehicle's plate / make / model / colour / year.
  Future<void> _editVehicle(VehicleDetail v) async {
    final patch = await showAppSheet<Map<String, String?>>(
      id: 'approver.vehicle-edit',
      context: context,
      isScrollControlled: true,
      builder: (_) => _VehicleEditSheet(vehicle: v),
    );
    if (patch == null || patch.isEmpty || !mounted) return;

    setState(() => _busyAction = true);
    try {
      await ref.read(approverInboxRepositoryProvider).updateVehicle(v.id, patch);
      ref.invalidate(approverVehicleDetailProvider(widget.vehicleId));
      ref.invalidate(approverMemberVehiclesProvider(widget.memberId));
      if (!mounted) return;
      unawaited(showAppNotice(
        id: 'notice.approver-vehicle', context: context,
        message: 'Vehicle updated.', kind: NoticeKind.success));
    } catch (e) {
      if (!mounted) return;
      final m = e is PostgrestException ? e.message : e.toString();
      unawaited(showAppNotice(
        id: 'notice.approver-vehicle', context: context,
        message: m.contains('not_allowed')
            ? "You can't edit this vehicle."
            : (m.contains('out_of_scope')
                ? "This vehicle isn't in your scope."
                : "Couldn't update the vehicle. Try again."),
        kind: NoticeKind.error));
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Widget _driverRow(ThemeData t, ColorScheme cs, bool canManage, VehicleDriver dr) {
    final busy = _busyAssignment == dr.assignmentId;
    Widget trailing;
    if (dr.state == 'pending' && canManage) {
      trailing = FilledButton(
        key: ValueKey('vehicle-approve-${dr.assignmentId}'),
        onPressed: busy ? null : () => _setAccess(dr.assignmentId, 'approve'),
        child: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Approve'),
      );
    } else if (dr.state == 'active' && canManage) {
      trailing = OutlinedButton(
        key: ValueKey('vehicle-revoke-${dr.assignmentId}'),
        style: OutlinedButton.styleFrom(foregroundColor: cs.error),
        onPressed: busy ? null : () => _setAccess(dr.assignmentId, 'revoke'),
        child: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Revoke'),
      );
    } else {
      final (label, good) = switch (dr.state) {
        'active' => ('Active', true),
        'pending' => ('Pending', false),
        _ => ('Access ended', false),
      };
      trailing = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: good ? Colors.green.withValues(alpha: 0.15) : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20)),
        child: Text(label, style: t.textTheme.labelMedium?.copyWith(
            color: good ? Colors.green.shade800 : cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
      );
    }
    final isMember = dr.driverId == widget.memberId;
    final sub = [
      if (dr.driverNo != null) '#${dr.driverNo}',
      if (isMember) 'this member',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dr.name, style: t.textTheme.titleSmall),
                  if (sub.isNotEmpty)
                    Text(sub, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  if (dr.plateMatch != null) ...[
                    const SizedBox(height: 4),
                    _plateMatchChip(t, cs, dr),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }

  Widget _plateMatchChip(ThemeData t, ColorScheme cs, VehicleDriver dr) {
    final ok = dr.plateMatch == true;
    final color = ok ? Colors.green.shade800 : cs.error;
    final bg = ok ? Colors.green.withValues(alpha: 0.14) : cs.errorContainer.withValues(alpha: 0.5);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.cancel_outlined, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            ok ? 'Plate match' : 'Plate mismatch${dr.permitPlate != null ? ' · ${dr.permitPlate}' : ''}',
            style: t.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(ThemeData t, ColorScheme cs, String text) => Text(text,
      style: t.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, letterSpacing: 0.5, fontWeight: FontWeight.w700));

  Widget _ownerRow(ThemeData t, ColorScheme cs, String label, String value) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            Text(label, style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            const Spacer(),
            Flexible(child: Text(value, textAlign: TextAlign.right,
                style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700))),
          ],
        ),
      );

  Widget _photosGrid(VehicleDetail v) => GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 9,
        crossAxisSpacing: 9,
        childAspectRatio: 3 / 2,
        children: [
          for (final (label, url) in v.photos)
            GestureDetector(
              onTap: () => _viewPhoto(label, url),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    StorageImage(url, fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const ColoredBox(color: Color(0x11000000), child: Icon(Icons.directions_car_outlined))),
                    Positioned(
                      left: 6, bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(6)),
                        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );

  void _viewPhoto(String label, String url) {
    showAppDialog<void>(
      id: 'approver.vehicle-photo',
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(children: [
                Text(label, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
              ]),
            ),
            Flexible(child: InteractiveViewer(child: StorageImage(url, fit: BoxFit.contain))),
          ],
        ),
      ),
    );
  }

  Widget _specGrid(ThemeData t, ColorScheme cs, VehicleDetail v) {
    final rows = <(String, String)>[
      ('MAKE / MODEL', [v.make, v.model].whereType<String>().join(' ').trim().isEmpty ? '—' : [v.make, v.model].whereType<String>().join(' ')),
      ('YEAR', v.year ?? '—'),
      ('COLOUR', v.color ?? '—'),
      ('TYPE', v.vehicleType ?? '—'),
      ('ENERGY', v.energy ?? '—'),
      ('STATUS', v.status == null ? '—' : v.status![0].toUpperCase() + v.status!.substring(1)),
      if (v.vin != null) ('VIN', v.vin!),
      if (v.engineNumber != null) ('ENGINE NO.', v.engineNumber!),
    ];
    Widget cell((String, String) r) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.$1, style: t.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 10, letterSpacing: 0.4)),
              const SizedBox(height: 3),
              Text(r.$2, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        );
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 9,
      crossAxisSpacing: 9,
      childAspectRatio: 2.6,
      children: [for (final r in rows) cell(r)],
    );
  }

  Widget _docRow(ThemeData t, ColorScheme cs, VehicleDoc d) {
    final sub = [
      if (d.expiry != null) 'Exp ${d.expiry}',
      if (d.provider != null) d.provider,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.name, style: t.textTheme.titleSmall),
                  if (sub.isNotEmpty)
                    Text(sub, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            if (d.status != null)
              Text(d.status!, style: t.textTheme.labelMedium?.copyWith(
                  color: d.status == 'Approved' ? Colors.green.shade800 : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// The Services & Permits section of the Vehicle sheet (migration 0369):
/// reads the same permit card the admin screen uses, approver-scoped. Shows
/// the vehicle's age and each permit's state; hidden on a legacy database.
class _PermitsSection extends ConsumerWidget {
  const _PermitsSection({required this.vehicleId, this.regYear});
  final String vehicleId;
  final String? regYear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final card = ref.watch(approverVehiclePermitCardProvider(vehicleId));
    return card.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (vp) {
        if (vp == null) {
          return Text('Permit details are unavailable here.',
              style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant));
        }
        final year = int.tryParse(regYear ?? '');
        final age = year == null ? null : (DateTime.now().year - year);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (age != null)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Text('Vehicle age', style: t.textTheme.titleSmall),
                    const Spacer(),
                    Text('$age yr${age == 1 ? '' : 's'} · reg. $year',
                        style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            if (vp.permits.isEmpty)
              Text('No permits configured for this vehicle.',
                  style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant))
            else
              for (final p in vp.permits) _permitRow(t, cs, p),
          ],
        );
      },
    );
  }

  Widget _permitRow(ThemeData t, ColorScheme cs, PermitItem p) {
    final (label, color) = switch (p.status ?? p.state) {
      'with' || 'withPermit' => ('On file', Colors.green.shade800),
      'bypass' => ('Bypass', cs.tertiary),
      'expired' => ('Expired', cs.error),
      'without' => ('Missing', cs.error),
      _ => (PermitStatus.parse(p.status ?? p.state).label, cs.onSurfaceVariant),
    };
    final sub = [
      if (p.validUntil != null) 'Valid to ${p.validUntil!.toIso8601String().split('T').first}',
      if (p.issuer.isNotEmpty) p.issuer,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name.isEmpty ? (p.shortName.isEmpty ? 'Permit' : p.shortName) : p.name,
                      style: t.textTheme.titleSmall),
                  if (sub.isNotEmpty)
                    Text(sub, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
              child: Text(label, style: t.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Edit vehicle form (migration 0369): plate / make / model / colour /
/// year. Returns the patch map to the Vehicle detail sheet on save, or null
/// when cancelled. Plate, make and model are required (they are NOT NULL on
/// the row); colour and year may be cleared.
class _VehicleEditSheet extends StatefulWidget {
  const _VehicleEditSheet({required this.vehicle});
  final VehicleDetail vehicle;

  @override
  State<_VehicleEditSheet> createState() => _VehicleEditSheetState();
}

class _VehicleEditSheetState extends State<_VehicleEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _plate = TextEditingController(text: widget.vehicle.plate == '—' ? '' : widget.vehicle.plate);
  late final _make = TextEditingController(text: widget.vehicle.make ?? '');
  late final _model = TextEditingController(text: widget.vehicle.model ?? '');
  late final _color = TextEditingController(text: widget.vehicle.color ?? '');
  late final _year = TextEditingController(text: widget.vehicle.year ?? '');

  @override
  void dispose() {
    _plate.dispose();
    _make.dispose();
    _model.dispose();
    _color.dispose();
    _year.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // Only the keys present are applied server-side. Colour and year are always
    // sent (so clearing them works); plate/make/model are required and trimmed.
    Navigator.of(context).pop(<String, String?>{
      'plate': _plate.text.trim(),
      'make': _make.text.trim(),
      'model': _model.text.trim(),
      'color': _color.text.trim(),
      'year': _year.text.trim(),
    });
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Edit vehicle', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              TextFormField(
                key: const ValueKey('vehicle-edit-plate'),
                controller: _plate,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Plate', border: OutlineInputBorder()),
                validator: _required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('vehicle-edit-make'),
                controller: _make,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Make', border: OutlineInputBorder()),
                validator: _required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('vehicle-edit-model'),
                controller: _model,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Model', border: OutlineInputBorder()),
                validator: _required,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('vehicle-edit-color'),
                      controller: _color,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Colour', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('vehicle-edit-year'),
                      controller: _year,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Year', border: OutlineInputBorder()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('vehicle-edit-save'),
                      onPressed: _save,
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
