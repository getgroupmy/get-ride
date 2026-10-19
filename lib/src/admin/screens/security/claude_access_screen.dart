// Admin → Security & integrations → Claude Code access (migration 0228): the
// Claude cloud sessions and office IPs that use the Supabase MCP tools without
// a permission prompt. The list may only be changed from an office IP; the
// database checks that on every write, this screen just says so up front.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/live_tables.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../widgets/admin_widgets.dart';
import 'claude_access_logic.dart';
import 'security_data.dart';

const _page = 'admin-settings-claude-access';

final _rulesProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('claude_access_rules');
  return ref.watch(securityRepositoryProvider).claudeRules();
});
final _myIpsProvider = FutureProvider.autoDispose((ref) => lookupPublicIps());

class AdminClaudeAccessScreen extends ConsumerStatefulWidget {
  const AdminClaudeAccessScreen({super.key});

  @override
  ConsumerState<AdminClaudeAccessScreen> createState() => _ClaudeAccessState();
}

class _ClaudeAccessState extends ConsumerState<AdminClaudeAccessScreen> {
  ClaudeRuleKind? _kind;

  void _reload() {
    ref.invalidate(_rulesProvider);
    ref.invalidate(_myIpsProvider);
  }

  /// Runs a write and shows this page's own words for the errors it can hit.
  Future<bool> _run(Future<void> Function() action, String success) async {
    try {
      await action();
      if (mounted) showInfo(context, success);
      ref.invalidate(_rulesProvider);
      return true;
    } catch (e) {
      if (mounted) showError(context, friendlyClaudeRuleError(e) ?? e);
      return false;
    }
  }

  Future<void> _edit({ClaudeAccessRule? rule, ClaudeRuleKind? preset}) async {
    final input = await showAppDialog<_RuleInput>(
      id: 'claude-access.edit',
      context: context,
      builder: (_) => _RuleDialog(rule: rule, preset: preset ?? _kind ?? ClaudeRuleKind.session),
    );
    if (input == null || !mounted) return;
    final built = claudeRuleRow(kind: input.kind, value: input.value, label: input.label);
    if (built.error != null) {
      showError(context, built.error!);
      return;
    }
    final repo = ref.read(securityRepositoryProvider);
    await _run(
      () => rule == null ? repo.addClaudeRule(built.row!) : repo.updateClaudeRule(rule.id, built.row!),
      rule == null ? 'Added' : 'Saved',
    );
  }

  Future<void> _delete(ClaudeAccessRule rule) async {
    final what = rule.isSession ? 'session ${rule.value}' : 'office rule ${rule.value}';
    if (!await confirm(context, 'Remove from the list', 'Remove $what? Supabase tools will ask for permission there again.',
        ok: 'Remove')) {
      return;
    }
    if (!mounted) return;
    await _run(() => ref.read(securityRepositoryProvider).deleteClaudeRule(rule.id), 'Removed');
  }

  Future<void> _toggle(ClaudeAccessRule rule, bool enabled) =>
      _run(() => ref.read(securityRepositoryProvider).setClaudeRuleEnabled(rule.id, enabled), enabled ? 'Enabled' : 'Disabled');

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(securityLevelProvider(_page)) == AccessLevel.edit;
    final rules = ref.watch(_rulesProvider);
    final myIps = ref.watch(_myIpsProvider);
    final ips = myIps.value ?? const <String>[];
    final office = isOfficeDevice(ips, rules.value ?? const []);
    final mayEdit = canEdit && office;
    return AdminPage(
      title: 'Claude access',
      page: _page,
      actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _reload)],
      addAction: mayEdit
          ? PageAddAction(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Add'))
          : null,
      body: AsyncView(
        value: rules,
        onRetry: _reload,
        data: (all) {
          final counts = countClaudeRules(all);
          final visible = filterClaudeRules(all, kind: _kind);
          return ResponsiveCenter(
            maxWidth: 760,
            child: ListView(padding: EdgeInsets.only(top: 12, bottom: addActionListBottomPadding(context)), children: [
              Card(
                child: ListTile(
                  leading: Icon(office ? Icons.verified_user : Icons.lock_outline, color: office ? Colors.green : null),
                  title: Text(myIps.isLoading ? 'Looking up…' : (ips.isEmpty ? 'Unavailable' : ips.join(' · '))),
                  subtitle: Text(myIps.isLoading
                      ? "This device's public addresses"
                      : office
                          ? "This device's public addresses · one is an office address, so this list can be changed from here"
                          : ips.isEmpty
                              ? "This device's addresses could not be looked up · the list is read-only here"
                              : "This device's public addresses · none is an office address, so the list is read-only here"),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('In a Claude cloud session on this list, and on a machine whose public address is an '
                    'office address or inside an office network on this list, Claude Code runs the Supabase tools '
                    'without asking for permission each time. Anywhere else it asks as usual. Only an admin '
                    'connected from an office address can change the list, and the last office rule cannot be '
                    'removed or disabled. An office network is written as a CIDR, e.g. 2001:db8::/64.'),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                ChoiceChip(label: Text('All (${all.length})'), selected: _kind == null, onSelected: (_) => setState(() => _kind = null)),
                ChoiceChip(
                  label: Text('Sessions (${counts.sessions})'),
                  selected: _kind == ClaudeRuleKind.session,
                  onSelected: (_) => setState(() => _kind = ClaudeRuleKind.session),
                ),
                ChoiceChip(
                  label: Text('Office addresses (${counts.ips})'),
                  selected: _kind == ClaudeRuleKind.ip,
                  onSelected: (_) => setState(() => _kind = ClaudeRuleKind.ip),
                ),
              ]),
              const SizedBox(height: 8),
              ListSearchFilter(
                count: visible.length,
                hint: 'Search by session id, IP or label...',
                builder: (context, query) {
                  final shown = filterClaudeRules(visible, query: query);
                  if (shown.isEmpty) {
                    return EmptyState(
                      icon: Icons.smart_toy_outlined,
                      title: query.isNotEmpty || _kind != null ? 'Nothing matches your filter.' : 'The list is empty.',
                      message: query.isEmpty && _kind == null && mayEdit ? 'Add a Claude session or an office IP.' : null,
                    );
                  }
                  return Column(children: [
                    for (final r in shown)
                      Card(
                        child: ListTile(
                          leading: Icon(r.isSession ? Icons.smart_toy_outlined : Icons.public,
                              color: r.enabled ? (r.isSession ? Colors.blue : Colors.green) : Colors.grey),
                          title: Text(r.value),
                          subtitle: Text(r.isSession ? '${claudeRuleSubtitle(r)}\n${r.sessionUrl}' : claudeRuleSubtitle(r)),
                          isThreeLine: r.isSession,
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            BusySwitch(value: r.enabled, onChanged: mayEdit ? (v) => _toggle(r, v) : null),
                            if (mayEdit) ...[
                              BusyIconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(rule: r)),
                              BusyIconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r)),
                            ],
                          ]),
                        ),
                      ),
                  ]);
                },
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _RuleInput {
  const _RuleInput(this.kind, this.value, this.label);
  final ClaudeRuleKind kind;
  final String value;
  final String label;
}

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({this.rule, required this.preset});
  final ClaudeAccessRule? rule;
  final ClaudeRuleKind preset;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final _value = TextEditingController(text: widget.rule?.value ?? '');
  late final _label = TextEditingController(text: widget.rule?.label ?? '');
  late ClaudeRuleKind _kind = widget.rule?.kind ?? widget.preset;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _label.dispose();
    super.dispose();
  }

  void _save() {
    final built = claudeRuleRow(kind: _kind, value: _value.text, label: _label.text);
    if (built.error != null) {
      setState(() => _error = built.error);
      return;
    }
    Navigator.pop(context, _RuleInput(_kind, _value.text, _label.text));
  }

  @override
  Widget build(BuildContext context) {
    final isSession = _kind == ClaudeRuleKind.session;
    return AlertDialog(
      title: Text(widget.rule == null ? 'Add to the list' : 'Edit entry'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<ClaudeRuleKind>(
            segments: const [
              ButtonSegment(value: ClaudeRuleKind.session, icon: Icon(Icons.smart_toy_outlined), label: Text('Claude session')),
              ButtonSegment(value: ClaudeRuleKind.ip, icon: Icon(Icons.public), label: Text('Office address')),
            ],
            selected: {_kind},
            // The kind of an existing entry stays: remove it and add the other.
            onSelectionChanged: widget.rule == null ? (s) => setState(() => _kind = s.first) : null,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _value,
            autofocus: true,
            keyboardType: isSession ? TextInputType.url : TextInputType.text,
            decoration: InputDecoration(
              labelText: isSession ? 'Session link or id' : 'Address or network',
              hintText: isSession ? 'https://claude.ai/code/session_…' : 'e.g. $defaultOfficeIp or 2001:db8::/64',
              helperText: isSession ? null : 'One address, or a network up to /$minIpv4Prefix (IPv4) or /$minIpv6Prefix (IPv6)',
              errorText: _error,
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          TextField(controller: _label, decoration: const InputDecoration(labelText: 'Label (optional)')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
