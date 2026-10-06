import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../widgets/admin_widgets.dart';
import 'ip_access_logic.dart';
import 'security_data.dart';
import '../../../data/live_tables.dart';

const _page = 'admin-settings-ip-access';

final _rulesProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('ip_access_rules');
  return ref.watch(securityRepositoryProvider).ipRules();
});
final _myIpProvider = FutureProvider.autoDispose((ref) => lookupPublicIp());

class AdminIpAccessScreen extends ConsumerStatefulWidget {
  const AdminIpAccessScreen({super.key});

  @override
  ConsumerState<AdminIpAccessScreen> createState() => _IpAccessState();
}

class _IpAccessState extends ConsumerState<AdminIpAccessScreen> {
  String _query = '';
  IpListType? _filter;

  void _reload() {
    ref.invalidate(_rulesProvider);
    ref.invalidate(_myIpProvider);
  }

  Future<void> _edit({IpAccessRule? rule, IpListType? preset, String? presetIp}) async {
    final result = await showDialog<({String ip, IpListType type, String label})>(
      context: context,
      builder: (_) => _RuleDialog(rule: rule, preset: preset, presetIp: presetIp),
    );
    if (result == null || !mounted) return;
    final built = ipRuleRow(ip: result.ip, listType: result.type, label: result.label);
    if (built.error != null) {
      showError(context, built.error!);
      return;
    }
    final repo = ref.read(securityRepositoryProvider);
    final ok = await runAdminAction(
      context,
      () => rule == null ? repo.addIpRule(built.row!) : repo.updateIpRule(rule.id, built.row!),
      success: rule == null ? 'Rule added' : 'Rule updated',
    );
    if (ok) ref.invalidate(_rulesProvider);
  }

  Future<void> _delete(IpAccessRule rule) async {
    if (!await confirm(context, 'Remove rule', 'Remove ${rule.ipAddress} from the ${rule.listType.name}?', ok: 'Remove')) {
      return;
    }
    if (!mounted) return;
    final ok = await runAdminAction(context, () => ref.read(securityRepositoryProvider).deleteIpRule(rule.id),
        success: 'Rule removed');
    if (ok) ref.invalidate(_rulesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(securityLevelProvider(_page)) == AccessLevel.edit;
    final rules = ref.watch(_rulesProvider);
    final myIp = ref.watch(_myIpProvider);
    return AdminPage(
      title: 'IP whitelist / blacklist',
      page: _page,
      actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _reload)],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add rule'),
      ),
      body: AsyncView(
        value: rules,
        onRetry: _reload,
        data: (all) {
          final counts = countRules(all);
          final visible = filterRules(all, query: _query, filter: _filter);
          final ip = myIp.value;
          final mine = ip == null ? null : all.where((r) => r.ipAddress == ip).firstOrNull;
          return ResponsiveCenter(
            maxWidth: 760,
            child: ListView(padding: const EdgeInsets.only(top: 12, bottom: 96), children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.public),
                  title: Text(myIp.isLoading ? 'Looking up…' : (ip ?? 'Unavailable')),
                  subtitle: Text(mine == null
                      ? "This device's IP"
                      : "This device's IP · ${mine.isWhitelist ? 'Whitelisted' : 'Blacklisted'}"),
                  trailing: canEdit && ip != null && mine == null
                      ? TextButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Add this IP'),
                          onPressed: () => _edit(preset: IpListType.whitelist, presetIp: ip),
                        )
                      : null,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('Whitelisted IPs skip the admin PIN; blacklisted IPs are blocked at login '
                    '("Service Not Available"). A blacklist entry wins if an IP is on both lists.'),
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: 'Search by IP or label...', isDense: true),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: Text('All (${all.length})'), selected: _filter == null, onSelected: (_) => setState(() => _filter = null)),
                ChoiceChip(
                  label: Text('Whitelist (${counts.white})'),
                  selected: _filter == IpListType.whitelist,
                  onSelected: (_) => setState(() => _filter = IpListType.whitelist),
                ),
                ChoiceChip(
                  label: Text('Blacklist (${counts.black})'),
                  selected: _filter == IpListType.blacklist,
                  onSelected: (_) => setState(() => _filter = IpListType.blacklist),
                ),
              ]),
              const SizedBox(height: 8),
              if (visible.isEmpty)
                EmptyState(
                  icon: Icons.shield_outlined,
                  title: _query.isNotEmpty || _filter != null ? 'No rules match your filter.' : 'No IP rules yet.',
                  message: _query.isEmpty && _filter == null && canEdit ? 'Add a whitelist or blacklist entry.' : null,
                ),
              for (final r in visible)
                Card(
                  child: ListTile(
                    leading: Icon(r.isWhitelist ? Icons.verified_user : Icons.gpp_bad,
                        color: r.isWhitelist ? Colors.green : Colors.red),
                    title: Text(r.ipAddress),
                    subtitle: Text(ruleSubtitle(r)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      StatusChip(r.isWhitelist ? 'Allow' : 'Blocked'),
                      if (canEdit) ...[
                        IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(rule: r)),
                        IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r)),
                      ],
                    ]),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }
}

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({this.rule, this.preset, this.presetIp});
  final IpAccessRule? rule;
  final IpListType? preset;
  final String? presetIp;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final _ip = TextEditingController(text: widget.rule?.ipAddress ?? widget.presetIp ?? '');
  late final _label = TextEditingController(text: widget.rule?.label ?? '');
  late IpListType _type = widget.rule?.listType ?? widget.preset ?? IpListType.whitelist;
  String? _error;

  @override
  void dispose() {
    _ip.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.rule == null ? 'Add IP rule' : 'Edit IP rule'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<IpListType>(
              segments: const [
                ButtonSegment(
                    value: IpListType.whitelist, icon: Icon(Icons.verified_user), label: Text('Whitelist')),
                ButtonSegment(value: IpListType.blacklist, icon: Icon(Icons.gpp_bad), label: Text('Blacklist')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 4),
            Text(_type == IpListType.whitelist ? 'Allow & bypass login' : 'Block service',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: _ip,
              autofocus: true,
              decoration: InputDecoration(labelText: 'IP address', hintText: 'e.g. 203.0.113.42', errorText: _error),
            ),
            const SizedBox(height: 8),
            TextField(controller: _label, decoration: const InputDecoration(labelText: 'Label (optional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (_ip.text.trim().isEmpty) {
                setState(() => _error = 'Enter an IP address to add.');
                return;
              }
              Navigator.pop(context, (ip: _ip.text, type: _type, label: _label.text));
            },
            child: const Text('Save'),
          ),
        ],
      );
}
