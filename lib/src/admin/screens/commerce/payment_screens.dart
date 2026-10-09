import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'commerce_data.dart';
import 'commerce_logic.dart';
import 'commerce_widgets.dart';

// ===========================================================================
// Payment Type (settings_entries / payment-type)
// ===========================================================================

class PaymentTypeScreen extends ConsumerStatefulWidget {
  const PaymentTypeScreen({super.key});
  static const page = 'admin-settings-payment-type';

  @override
  ConsumerState<PaymentTypeScreen> createState() => _PaymentTypeScreenState();
}

class _PaymentTypeScreenState extends ConsumerState<PaymentTypeScreen> {
  String _q = '';

  Future<void> _edit(List<Entry> all, [Entry? entry]) async {
    final values = await showFormDialog<Map<String, dynamic>>(context, (_) => _PaymentTypeForm(entry: entry));
    if (values == null || !mounted) return;
    final ok = await runAdminAction(context, () async {
      final repo = ref.read(adminRepositoryProvider);
      await repo.saveSetting(commerceCategories[paymentTypeCategory]!, id: entry?.id, values: values, position: all.length);
    }, success: 'Saved');
    if (ok) ref.invalidate(commerceEntriesProvider(paymentTypeCategory));
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(PaymentTypeScreen.page)) == AccessLevel.edit;
    final entries = ref.watch(commerceEntriesProvider(paymentTypeCategory));
    return AdminPage(
      title: 'Payment Type',
      page: PaymentTypeScreen.page,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(entries.value ?? []),
        icon: const Icon(Icons.add),
        label: const Text('Add payment type'),
      ),
      body: Column(children: [
        ListSearch(hint: 'Search', onChanged: (v) => setState(() => _q = v)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'Riders choose from the enabled types, in this order, on the booking screen; a change shows there '
            'at once. The type is passed to the driver, who collects it: no gateway charges a ride yet.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: AsyncView(
            value: entries,
            onRetry: () => ref.invalidate(commerceEntriesProvider(paymentTypeCategory)),
            data: (all) {
              final rows = all.where((e) => valuesMatch(e.values, _q)).toList();
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'No payment types yet',
                  message: 'Add a payment method to get started.',
                );
              }
              return ResponsiveCenter(
                maxWidth: 820,
                child: ListView(padding: const EdgeInsets.only(top: 8, bottom: 96), children: [
                  for (final e in rows) _row(e, all, canEdit),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }

  Widget _row(Entry e, List<Entry> all, bool canEdit) {
    final v = e.values;
    final enabled = v['enabled'] != false;
    final gw = '${v['gatewayProviderName'] ?? ''}';
    final acct = '${v['gatewayAccountName'] ?? ''}';
    final gwLabel = gw.isEmpty ? 'No gateway' : '$gw${acct.isEmpty ? '' : ' · $acct'}';
    return Card(
      child: BusyListTile(
        leading: const CircleAvatar(child: Icon(Icons.credit_card)),
        title: Row(children: [
          Flexible(child: Text('${v['name'] ?? 'Untitled'}', overflow: TextOverflow.ellipsis)),
          if (!enabled) ...[const SizedBox(width: 8), const StatusChip('Disabled')],
        ]),
        subtitle: Text('${(v['code'] ?? '').toString().isEmpty ? '—' : v['code']} • $gwLabel'),
        onTap: canEdit ? () => _edit(all, e) : null,
        trailing: canEdit
            ? BusyIconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: () async {
                  if (!await confirm(context, 'Delete', 'Remove this payment type?', ok: 'Delete')) return;
                  if (!mounted) return;
                  if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSetting(
                      commerceCategories[paymentTypeCategory]!, e.id))) {
                    ref.invalidate(commerceEntriesProvider(paymentTypeCategory));
                  }
                },
              )
            : null,
      ),
    );
  }
}

class _PaymentTypeForm extends StatefulWidget {
  const _PaymentTypeForm({this.entry});
  final Entry? entry;

  @override
  State<_PaymentTypeForm> createState() => _PaymentTypeFormState();
}

class _PaymentTypeFormState extends State<_PaymentTypeForm> {
  late final _name = TextEditingController(text: '${widget.entry?.values['name'] ?? ''}');
  late final _code = TextEditingController(text: '${widget.entry?.values['code'] ?? ''}');
  late bool _enabled = widget.entry?.values['enabled'] != false;
  late SelectedGateway? _gateway = widget.entry == null ? null : SelectedGateway.fromReference(widget.entry!.values);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FormDialogScaffold(
        title: widget.entry == null ? 'Add Payment Type' : 'Edit Payment Type',
        error: _error,
        onSave: () {
          final r = buildPaymentTypeValues(
            name: _name.text,
            code: _code.text,
            enabled: _enabled,
            gateway: _gateway,
            existing: widget.entry?.values,
          );
          if (r.error != null) return setState(() => _error = r.error);
          Navigator.pop(context, r.values);
        },
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name *', hintText: 'e.g. Credit Card')),
          const SizedBox(height: 12),
          TextField(controller: _code, decoration: const InputDecoration(labelText: 'Code', hintText: 'e.g. CARD')),
          const SizedBox(height: 12),
          GatewayPickerField(value: _gateway, onChanged: (g) => setState(() => _gateway = g)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
        ],
      );
}

// ===========================================================================
// Payment Gateways (settings_entries / payment-gateway)
// ===========================================================================

class PaymentGatewayScreen extends ConsumerStatefulWidget {
  const PaymentGatewayScreen({super.key});
  static const page = 'admin-settings-payment-gateway';

  @override
  ConsumerState<PaymentGatewayScreen> createState() => _PaymentGatewayScreenState();
}

class _PaymentGatewayScreenState extends ConsumerState<PaymentGatewayScreen> {
  String _q = '';
  String? _provider;

  void _refresh() {
    ref.invalidate(commerceEntriesProvider(paymentGatewayCategory));
    ref.invalidate(gatewayAccountsProvider);
  }

  Future<void> _add(List<Entry> all) async {
    final counts = _counts(all);
    final provider = await showDialog<GatewayProvider>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose a provider'),
        children: [
          for (final p in gatewayProviders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: ListTile(
                leading: const Icon(Icons.credit_card),
                title: Text(p.name),
                subtitle: Text(p.description),
                trailing: (counts[p.id] ?? 0) > 0
                    ? Text('${counts[p.id]} account${counts[p.id] == 1 ? '' : 's'}')
                    : const Icon(Icons.chevron_right),
              ),
            ),
        ],
      ),
    );
    if (provider == null || !mounted) return;
    await _edit(all, form: GatewayForm(providerId: provider.id));
  }

  Future<void> _edit(List<Entry> all, {Entry? entry, GatewayForm? form}) async {
    final values = await showFormDialog<Map<String, dynamic>>(
      context,
      (_) => _GatewayForm(entry: entry, form: form ?? GatewayForm.fromValues(entry!.values)),
    );
    if (values == null || !mounted) return;
    final ok = await runAdminAction(context, () async {
      final repo = ref.read(commerceRepositoryProvider);
      final c = commerceCategories[paymentGatewayCategory]!;
      String id;
      if (entry != null) {
        await ref.read(adminRepositoryProvider).saveSetting(c, id: entry.id, values: values);
        id = entry.id;
      } else {
        id = await repo.insertEntry(paymentGatewayCategory, values, all.length);
      }
      if (values['isDefault'] == true) await repo.clearOtherDefaults(paymentGatewayCategory, all, id);
    }, success: 'Gateway saved');
    if (ok) _refresh();
  }

  Map<String, int> _counts(List<Entry> all) {
    final m = <String, int>{};
    for (final e in all) {
      final id = '${e.values['providerId'] ?? ''}';
      m[id] = (m[id] ?? 0) + 1;
    }
    return m;
  }

  Future<void> _stripSecrets(Entry e) async {
    final keys = storedSecretKeys(e.values);
    if (!await confirm(
      context,
      'Remove stored secrets?',
      'This removes ${keys.length} secret credential${keys.length == 1 ? '' : 's'} from this account record. '
          'Server-side payment code that reads them from here will stop working until they are provided another way.',
      ok: 'Remove',
    )) {
      return;
    }
    if (!mounted) return;
    if (await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveSetting(
            commerceCategories[paymentGatewayCategory]!,
            id: e.id,
            values: stripSecrets(e.values),
          ),
      success: 'Secrets removed',
    )) {
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(PaymentGatewayScreen.page)) == AccessLevel.edit;
    final entries = ref.watch(commerceEntriesProvider(paymentGatewayCategory));
    return AdminPage(
      title: 'Payment Gateways',
      page: PaymentGatewayScreen.page,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(entries.value ?? []),
        icon: const Icon(Icons.add),
        label: const Text('Add gateway'),
      ),
      body: AsyncView(
        value: entries,
        onRetry: _refresh,
        data: (all) {
          final counts = _counts(all);
          final sorted = [...all]..sort((a, b) {
              final ap = '${a.values['providerName'] ?? ''}', bp = '${b.values['providerName'] ?? ''}';
              if (ap != bp) return ap.compareTo(bp);
              return '${a.values['accountName'] ?? ''}'.compareTo('${b.values['accountName'] ?? ''}');
            });
          final rows = sorted
              .where((e) => _provider == null || e.values['providerId'] == _provider)
              .where((e) => valuesMatch(stripSecrets(e.values), _q))
              .toList();
          final active = all.where((e) => e.values['active'] != false).length;
          final live = all.where((e) => '${e.values['mode'] ?? 'Live'}' == 'Live').length;
          final def = all.where((e) => e.values['isDefault'] == true).firstOrNull;
          final withSecrets = all.where((e) => storedSecretKeys(e.values).isNotEmpty).length;
          return ResponsiveCenter(
            maxWidth: 900,
            child: ListView(padding: const EdgeInsets.only(top: 8, bottom: 96), children: [
              const _SecretNotice(),
              if (withSecrets > 0)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber),
                    title: Text('$withSecrets account${withSecrets == 1 ? ' has' : 's have'} secret credentials stored here'),
                    subtitle: const Text('This table is readable by every app user. Move the secrets to server-side '
                        'storage and remove them from the record (open the account menu).'),
                  ),
                ),
              TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search account or provider', isDense: true),
                onChanged: (v) => setState(() => _q = v),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('All (${all.length})'),
                      selected: _provider == null,
                      onSelected: (_) => setState(() => _provider = null),
                    ),
                  ),
                  for (final p in gatewayProviders)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${p.name}${(counts[p.id] ?? 0) > 0 ? '  ·  ${counts[p.id]}' : ''}'),
                        selected: _provider == p.id,
                        onSelected: (_) => setState(() => _provider = _provider == p.id ? null : p.id),
                      ),
                    ),
                ]),
              ),
              if (all.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    Chip(label: Text('Total ${all.length}')),
                    Chip(label: Text('Active $active')),
                    Chip(label: Text('Live $live')),
                    if (def != null)
                      Chip(avatar: const Icon(Icons.star, size: 16), label: Text('Default: ${def.values['providerName'] ?? ''}')),
                  ]),
                ),
              if (rows.isEmpty)
                const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'No gateways yet',
                  message: 'Add Stripe, Fiuu, PayPal and more.',
                ),
              for (final e in rows) _row(e, all, canEdit),
            ]),
          );
        },
      ),
    );
  }

  Widget _row(Entry e, List<Entry> all, bool canEdit) {
    final v = e.values;
    final mode = '${v['mode'] ?? 'Live'}';
    final active = v['active'] != false;
    final secrets = storedSecretKeys(v);
    return Opacity(
      opacity: active ? 1 : 0.6,
      child: Card(
        child: BusyListTile(
          leading: const CircleAvatar(child: Icon(Icons.credit_card)),

          title: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${v['providerName'] ?? ''}'),
            if (v['isDefault'] == true) const Icon(Icons.star, size: 16),
            Chip(
              label: Text(mode),
              visualDensity: VisualDensity.compact,
              backgroundColor: (mode == 'Live' ? Colors.green : Colors.orange).withValues(alpha: 0.15),
            ),
            if (!active) const StatusChip('Inactive'),
            if (secrets.isNotEmpty)
              Tooltip(
                message: '${secrets.length} secret credential(s) stored in a client-readable table',
                child: Icon(Icons.key, size: 16, color: Theme.of(context).colorScheme.error),
              ),
          ]),
          subtitle: Text('${v['accountName'] ?? ''}'),
          onTap: canEdit ? () => _edit(all, entry: e) : null,
          trailing: canEdit
              ? PopupMenuButton<String>(
                  onSelected: (a) async {
                    if (a == 'edit') return _edit(all, entry: e);
                    if (a == 'strip') return _stripSecrets(e);
                    if (!await confirm(context, 'Delete',
                        'Remove ${v['providerName']} (${v['accountName']})?', ok: 'Delete')) {
                      return;
                    }
                    if (!mounted) return;
                    if (await runAdminAction(
                        context,
                        () => ref
                            .read(adminRepositoryProvider)
                            .deleteSetting(commerceCategories[paymentGatewayCategory]!, e.id))) {
                      _refresh();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    if (secrets.isNotEmpty) const PopupMenuItem(value: 'strip', child: Text('Remove stored secrets')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                )
              : null,
        ),
      ),
    );
  }
}

class _SecretNotice extends StatelessWidget {
  const _SecretNotice();

  @override
  Widget build(BuildContext context) => const Card(
        child: ListTile(
          leading: Icon(Icons.lock_outline),
          title: Text('Secret keys are not entered here'),
          subtitle: Text('Gateway accounts are stored in a table every app user can read, so this screen only '
              'manages public configuration (merchant IDs, publishable keys, mode). Secret keys, passwords and '
              'webhook secrets belong in server-side secrets used by the payment edge function.'),
        ),
      );
}

class _GatewayForm extends StatefulWidget {
  const _GatewayForm({this.entry, required this.form});
  final Entry? entry;
  final GatewayForm form;

  @override
  State<_GatewayForm> createState() => _GatewayFormState();
}

class _GatewayFormState extends State<_GatewayForm> {
  late final GatewayForm _f = widget.form;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final provider = providerById(_f.providerId);
    return FormDialogScaffold(
      title: widget.entry == null ? 'Add ${provider?.name ?? 'Gateway'}' : 'Edit Gateway',
      error: _error,
      onSave: () {
        final r = buildGatewayValues(_f, existing: widget.entry?.values);
        if (r.error != null) return setState(() => _error = r.error);
        Navigator.pop(context, r.values);
      },
      children: [
        if (provider != null) Text(provider.description, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Provider', prefixIcon: Icon(Icons.credit_card)),
          child: Text(provider?.name ?? 'Unknown provider (${_f.providerId})'),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: _f.accountName,
          decoration: const InputDecoration(labelText: 'Account name *', hintText: 'e.g. Stripe MY Live'),
          onChanged: (v) => _f.accountName = v,
        ),
        const SectionLabel('Mode'),
        ChoiceRow(options: gatewayModes, value: _f.mode, onChanged: (m) => setState(() => _f.mode = m)),
        if (provider != null) ...[
          SectionLabel('Credentials', icon: Icons.vpn_key_outlined, trailing: Text('${provider.publicFields.length} public')),
          for (final f in provider.publicFields)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextFormField(
                initialValue: _f.credentials[f.key] ?? '',
                decoration: InputDecoration(labelText: '${f.label}${f.optional ? '' : ' *'}', hintText: f.placeholder),
                onChanged: (v) => _f.credentials[f.key] = v,
              ),
            ),
          if (provider.secretFields.isNotEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('Server-side secrets'),
                subtitle: Text('${provider.secretFields.map((f) => f.label).join(', ')} must be configured as '
                    'server-side secrets, not in this client-readable record.'),
              ),
            ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Active'),
          value: _f.active,
          onChanged: (v) => setState(() => _f.active = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Default gateway'),
          subtitle: const Text('Used when an order or fee has no specific gateway account.'),
          value: _f.isDefault,
          onChanged: (v) => setState(() => _f.isDefault = v),
        ),
      ],
    );
  }
}
