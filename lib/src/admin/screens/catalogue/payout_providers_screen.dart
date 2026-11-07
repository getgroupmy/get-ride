import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import '../../widgets/admin_widgets.dart';
import 'catalogue_data.dart';
import 'catalogue_logic.dart';
import 'catalogue_widgets.dart';

/// Admin → Payout Providers: the banks and e-wallets a partner (or an approver
/// on their behalf) can pick as a payout account. Each entry is a
/// `settings_entries` row in the `payout_provider` category, shaped
/// `{name, type: 'bank'|'ewallet', active}` — the same list the app's
/// `payout_providers()` RPC serves to the payout dropdowns. Listed by name
/// (the RPC orders by position then name); add / edit / delete, and turn one
/// off without deleting it.
class PayoutProvidersScreen extends ConsumerStatefulWidget {
  const PayoutProvidersScreen({super.key});

  @override
  ConsumerState<PayoutProvidersScreen> createState() => _PayoutProvidersScreenState();
}

class _PayoutProvidersScreenState extends ConsumerState<PayoutProvidersScreen> {
  String _query = '';
  static const _c = payoutProviderCategory;

  Future<void> _edit(List<SettingEntry> all, SettingEntry? e) async {
    final values = await openEditor<Map<String, dynamic>>(
      context,
      e == null ? 'Add provider' : 'Edit provider',
      _PayoutProviderEditor(entry: e, canEdit: canEditPage(ref, _c.page)),
    );
    if (values == null || !mounted) return;
    // New entries sit after the current ones; edits keep their position.
    final nextPos = all.fold<int>(0, (m, x) => x.position > m ? x.position : m) + 1;
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveSetting(_c, id: e?.id, values: values, position: nextPos),
      success: 'Saved',
    );
    if (ok) ref.invalidate(catalogueEntriesProvider(_c));
  }

  Future<void> _delete(SettingEntry e) async {
    if (!await confirm(context, 'Delete', 'Remove this payout provider?', ok: 'Delete') || !mounted) return;
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSetting(_c, e.id),
        success: 'Deleted')) {
      ref.invalidate(catalogueEntriesProvider(_c));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, _c.page);
    final entries = ref.watch(catalogueEntriesProvider(_c));
    return AdminPage(
      title: _c.title,
      page: _c.page,
      addAction: PageAddAction(
        onPressed: () => _edit(entries.value ?? const [], null),
        icon: const Icon(Icons.add),
        label: const Text('Add provider'),
      ),
      body: AsyncView(
        value: entries,
        onRetry: () => ref.invalidate(catalogueEntriesProvider(_c)),
        data: (all) {
          final sorted = [...all]..sort((a, b) =>
              str(a.values['name']).toLowerCase().compareTo(str(b.values['name']).toLowerCase()));
          final rows = sorted.where((e) => entryMatches(e, _query)).toList();
          return ResponsiveCenter(
            maxWidth: 820,
            child: Column(children: [
              CatalogueSearch(onChanged: (v) => setState(() => _query = v)),
              Expanded(
                child: rows.isEmpty
                    ? EmptyState(icon: Icons.account_balance_outlined, title: 'No payout providers', message: _c.subtitle)
                    : ListView.builder(
                        padding: EdgeInsets.only(bottom: addActionListBottomPadding(context)),
                        itemCount: rows.length,
                        itemBuilder: (_, i) {
                          final e = rows[i];
                          final v = e.values;
                          final isEwallet = str(v['type']) == 'ewallet';
                          final active = jsBool(v['active'], true);
                          return Card(
                            child: ListTile(
                              key: ValueKey('payout-provider-${e.id}'),
                              leading: Icon(isEwallet ? Icons.account_balance_wallet_outlined : Icons.account_balance_outlined),
                              title: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                                Text(str(v['name']).isEmpty ? 'Untitled' : str(v['name'])),
                                Pill(isEwallet ? 'e-Wallet' : 'Bank'),
                                StatusChip(active ? 'Active' : 'Inactive'),
                              ]),
                              onTap: () => _edit(all, e),
                              trailing: canEdit
                                  ? BusyIconButton(
                                      tooltip: 'Delete',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _delete(e),
                                    )
                                  : null,
                            ),
                          );
                        },
                      ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _PayoutProviderEditor extends StatefulWidget {
  const _PayoutProviderEditor({this.entry, required this.canEdit});
  final SettingEntry? entry;
  final bool canEdit;

  @override
  State<_PayoutProviderEditor> createState() => _PayoutProviderEditorState();
}

class _PayoutProviderEditorState extends State<_PayoutProviderEditor> {
  late final v = widget.entry?.values ?? const <String, dynamic>{};
  late final _name = TextEditingController(text: str(v['name']));
  late String _type = str(v['type']) == 'ewallet' ? 'ewallet' : 'bank';
  late bool _active = jsBool(v['active'], true);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Enter a provider name.');
    Navigator.pop(context, {'name': name, 'type': _type, 'active': _active});
  }

  @override
  Widget build(BuildContext context) => EditorBody(
        error: _error,
        saveLabel: widget.entry == null ? 'Add provider' : 'Save changes',
        onSave: widget.canEdit ? _save : null,
        children: [
          TextField(
            key: const ValueKey('payout-provider-name'),
            controller: _name,
            enabled: widget.canEdit,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Provider name *', hintText: 'e.g. Maybank'),
          ),
          const SizedBox(height: 12),
          const SectionLabel('Type'),
          Wrap(spacing: 8, children: [
            ChoiceChip(
              key: const ValueKey('payout-provider-type-bank'),
              label: const Text('Bank'),
              selected: _type == 'bank',
              onSelected: widget.canEdit ? (_) => setState(() => _type = 'bank') : null,
            ),
            ChoiceChip(
              key: const ValueKey('payout-provider-type-ewallet'),
              label: const Text('e-Wallet'),
              selected: _type == 'ewallet',
              onSelected: widget.canEdit ? (_) => setState(() => _type = 'ewallet') : null,
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            subtitle: Text(_active ? 'Shown in the payout dropdowns' : 'Hidden from the payout dropdowns'),
            value: _active,
            onChanged: widget.canEdit ? (x) => setState(() => _active = x) : null,
          ),
        ],
      );
}
