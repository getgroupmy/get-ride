import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/secure_screen.dart';
import '../../data/approver_inbox_repository.dart';
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      key: ValueKey('my-team-member-${member.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
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
                        if (member.displayId != null)
                          Text('No. ${member.displayId}',
                              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  if (member.status != null) _StatusChip(status: member.status!),
                ],
              ),
              const SizedBox(height: 10),
              if (member.phone != null) _line(context, Icons.phone_outlined, member.phone!),
              if (member.plate != null || member.vehicleLabel != null)
                _line(context, Icons.directions_car_outlined,
                    [member.vehicleLabel, member.plate].where((e) => e != null).join(' · ')),
              if (member.ic != null)
                _line(context, Icons.badge_outlined,
                    member.nationality != null ? '${member.ic} · ${member.nationality}' : member.ic!),
              const SizedBox(height: 8),
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
/// GoRoute with the [TeamMember] as `extra`.
class MyTeamMemberScreen extends ConsumerWidget {
  const MyTeamMemberScreen({super.key, required this.member});

  final TeamMember member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final docs = ref.watch(approverOwnerDocumentsProvider(member.id));
    final grant = ref.watch(approverSelfProvider).value;
    final canCredit = grant?.canCredit ?? false;
    final canEditProfile = grant?.canEditProfile ?? false;
    final wallet = ref.watch(approverMemberWalletProvider(member.id)).value;
    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: Text(member.name)),
        body: OfflineStrip.over(RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(approverOwnerDocumentsProvider(member.id));
            ref.invalidate(approverMemberWalletProvider(member.id));
            ref.invalidate(approverMemberDetailProvider(member.id));
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
            children: [
              ResponsiveCenter(
                maxWidth: 760,
                child: _header(context, ref, cs,
                    canCredit: canCredit, canEditProfile: canEditProfile, wallet: wallet),
              ),
              const SizedBox(height: 8),
              ResponsiveCenter(
                maxWidth: 760,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                  child: Text('Documents',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
              docs.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(child: CircularProgressIndicator()),
                ),
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
                data: (list) => list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: EmptyState(
                          icon: Icons.description_outlined,
                          title: 'No documents',
                          message: 'This person has no documents on file in your scope.',
                        ),
                      )
                    : Column(
                        children: [
                          for (final d in list)
                            ResponsiveCenter(
                              maxWidth: 760,
                              child: _DocTile(
                                doc: d,
                                onTap: () => openApproverDocument(
                                  context,
                                  d,
                                  onChanged: () => ref.invalidate(approverOwnerDocumentsProvider(member.id)),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        )),
      ),
    );
  }

  Widget _header(BuildContext context, WidgetRef ref, ColorScheme cs,
      {required bool canCredit, required bool canEditProfile, required double? wallet}) {
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
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Avatar(url: member.avatarUrl, name: member.name),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(member.name, style: text.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (member.displayId != null)
                        Text('No. ${member.displayId}', style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (member.status != null) _StatusChip(status: member.status!),
              ],
            ),
            const SizedBox(height: 12),
            if (member.phone != null) row(Icons.phone_outlined, 'Mobile', member.phone!),
            if (member.ic != null) row(Icons.badge_outlined, 'ID No.', member.ic!),
            if (member.idVerified != null) row(Icons.verified_outlined, 'ID check', member.idVerified!),
            if (member.nationality != null) row(Icons.public_outlined, 'Nationality', member.nationality!),
            if (member.plate != null || member.vehicleLabel != null)
              row(Icons.directions_car_outlined, 'Vehicle',
                  [member.vehicleLabel, member.plate].where((e) => e != null).join(' · ')),
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
                      key: const ValueKey('my-team-edit-profile'),
                      onPressed: () => _openEditProfile(context, ref),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Edit profile'),
                    ),
                  if (canEditProfile)
                    OutlinedButton.icon(
                      key: const ValueKey('my-team-payout'),
                      onPressed: () => _openPayout(context, ref),
                      icon: const Icon(Icons.account_balance_outlined, size: 18),
                      label: const Text('Payout'),
                    ),
                  if (canCredit)
                    FilledButton.tonalIcon(
                      key: const ValueKey('my-team-add-credit'),
                      onPressed: () => _openAddCredit(context, ref),
                      icon: const Icon(Icons.add_card_outlined, size: 18),
                      label: const Text('Add credit'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'Vehicle and statistics are coming soon.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAddCredit(BuildContext context, WidgetRef ref) => showAppSheet<void>(
        id: 'approver.add-credit',
        context: context,
        isScrollControlled: true,
        builder: (c) => _AddCreditSheet(member: member),
      );

  Future<void> _openPayout(BuildContext context, WidgetRef ref) => showAppSheet<void>(
        id: 'approver.payout',
        context: context,
        isScrollControlled: true,
        builder: (c) => _PayoutSheet(member: member),
      );

  Future<void> _openEditProfile(BuildContext context, WidgetRef ref) => showAppSheet<void>(
        id: 'approver.edit-profile',
        context: context,
        isScrollControlled: true,
        builder: (c) => _EditProfileSheet(member: member),
      );
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
class _DocTile extends StatelessWidget {
  const _DocTile({required this.doc, required this.onTap});
  final ApproverDoc doc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('my-team-doc-${doc.id}'),
        leading: CircleAvatar(
          backgroundColor: cs.surfaceContainerHighest,
          foregroundColor: cs.onSurfaceVariant,
          child: Icon(ApproverInboxScreen.iconFor(doc.source)),
        ),
        title: Text(doc.docLabel, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(ApproverInboxScreen.sourceLabel(doc.source)),
        trailing: _DocStatus(status: doc.status ?? 'Pending Review'),
        onTap: onTap,
      ),
    );
  }
}

class _DocStatus extends StatelessWidget {
  const _DocStatus({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (color, icon) = switch (status) {
      'Approved' => (cs.primary, Icons.check_circle),
      'Rejected' => (cs.error, Icons.cancel),
      'Expired' => (cs.error, Icons.error_outline),
      _ => (cs.tertiary, Icons.schedule),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 2),
        Text(status == 'Pending Review' ? 'Pending' : status,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
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
                if (isPartner)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'Services for this member are edited from their Vehicle / Services (coming soon).',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ),
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
