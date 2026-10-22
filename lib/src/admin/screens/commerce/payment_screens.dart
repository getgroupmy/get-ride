import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/in_app_page.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'commerce_data.dart';
import 'commerce_logic.dart';
import 'commerce_widgets.dart';
import '../../../widgets/search_select.dart';
import '../../../core/media_assets.dart' show MediaKind;
import '../../../widgets/media_image.dart' show MediaIcon;
import '../meterapp/media_picker_sheet.dart' show showMediaPicker;

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
      addAction: PageAddAction(
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
                child: ListView(padding: EdgeInsets.only(top: 8, bottom: addActionListBottomPadding(context)), children: [
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
        leading: CircleAvatar(child: MediaIcon('${v['icon'] ?? ''}', fallback: Icons.credit_card)),
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
  late String _icon = '${widget.entry?.values['icon'] ?? ''}';
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
          Navigator.pop(context, {...r.values!, 'icon': _icon.isEmpty ? null : _icon});
        },
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name *', hintText: 'e.g. Credit Card')),
          const SizedBox(height: 4),
          // Its icon on the rider's payment sheet: one from the Media Gallery,
          // or its kind's (cash, wallet, card).
          ListTile(
            key: const ValueKey('payment-type-icon'),
            contentPadding: EdgeInsets.zero,
            leading: MediaIcon(_icon, fallback: Icons.credit_card),
            title: const Text('Icon'),
            subtitle: Text(_icon.isEmpty ? 'Default for its kind' : 'From the Media Gallery'),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: () async {
              final v = await showMediaPicker(context,
                  kind: MediaKind.icon, current: _icon, title: 'Payment type icon', defaultLabel: 'Default for its kind');
              if (v != null) setState(() => _icon = v);
            },
          ),
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
  const PaymentGatewayScreen({super.key, this.supabaseUrl = AppConfig.supabaseUrl});
  static const page = 'admin-settings-payment-gateway';

  /// Where the `payments` function runs (its webhook addresses are shown to copy).
  final String supabaseUrl;

  @override
  ConsumerState<PaymentGatewayScreen> createState() => _PaymentGatewayScreenState();
}

class _PaymentGatewayScreenState extends ConsumerState<PaymentGatewayScreen> {
  String _q = '';
  String? _provider;

  void _refresh() {
    ref.invalidate(commerceEntriesProvider(paymentGatewayCategory));
    ref.invalidate(gatewayAccountsProvider);
    ref.invalidate(gatewaySecretStatusProvider);
    ref.invalidate(gatewayRoutingProvider);
  }

  Future<void> _add(List<Entry> all) async {
    final counts = _counts(all);
    final providerId = await showSearchPicker<String>(
      context,
      title: 'Choose a provider',
      choices: [
        for (final p in gatewayProviders)
          (
            value: p.id,
            label: p.name,
            subtitle: [
              p.description,
              if (p.charging == ChargeSupport.none) 'charging not built yet',
              if ((counts[p.id] ?? 0) > 0) '${counts[p.id]} account${counts[p.id] == 1 ? '' : 's'}',
            ].join(' · '),
            leading: const Icon(Icons.credit_card),
          ),
      ],
    );
    final provider = providerId == null ? null : gatewayProviders.firstWhere((p) => p.id == providerId);
    if (provider == null || !mounted) return;
    await _edit(all, form: GatewayForm(providerId: provider.id));
  }

  Future<void> _edit(List<Entry> all, {Entry? entry, GatewayForm? form}) async {
    final canEdit = ref.read(pageAccessProvider(PaymentGatewayScreen.page)) == AccessLevel.edit;
    final values = await showFormDialog<Map<String, dynamic>>(
      context,
      (_) => _GatewayForm(
        entry: entry,
        form: form ?? GatewayForm.fromValues(entry!.values),
        supabaseUrl: widget.supabaseUrl,
        canEdit: canEdit,
      ),
    );
    if (values == null || !mounted) {
      ref.invalidate(gatewaySecretStatusProvider);
      return;
    }
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
    }, success: entry == null ? 'Gateway saved. Open it again to set its secret keys.' : 'Gateway saved');
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

  Future<void> _test(Entry e) async {
    final result = await ref.read(commerceRepositoryProvider).testGateway(e.id);
    if (!mounted) return;
    await showAppDialog<void>(
      id: 'payment-gateways.test-result',
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${e.values['providerName'] ?? ''} · ${e.values['accountName'] ?? ''}'),
        content: GatewayTestResultView(result),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(PaymentGatewayScreen.page)) == AccessLevel.edit;
    final entries = ref.watch(commerceEntriesProvider(paymentGatewayCategory));
    final secrets = ref.watch(gatewaySecretStatusProvider).value ?? const {};
    return AdminPage(
      title: 'Payment Gateways',
      page: PaymentGatewayScreen.page,
      addAction: PageAddAction(
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
          return ResponsiveCenter(
            maxWidth: 900,
            child: ListView(padding: EdgeInsets.only(top: 8, bottom: addActionListBottomPadding(context)), children: [
              const _SecretsNotice(),
              if (all.isNotEmpty) _RoutingCard(entries: all, canEdit: canEdit),
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
                  message: 'Add Stripe, Billplz, Fiuu, PayPal and more.',
                ),
              for (final e in rows) _row(e, all, canEdit, secrets[e.id] ?? const {}),
            ]),
          );
        },
      ),
    );
  }

  Widget _row(Entry e, List<Entry> all, bool canEdit, Map<String, GatewaySecretState> set) {
    final v = e.values;
    final mode = '${v['mode'] ?? 'Live'}';
    final active = v['active'] != false;
    final provider = providerById('${v['providerId'] ?? ''}');
    final scheme = Theme.of(context).colorScheme;
    final needed = provider?.secretFields.where((f) => !f.optional).toList() ?? const [];
    final missing = needed.where((f) => !set.containsKey(f.key)).length;
    final secretsLine = provider == null || provider.secretFields.isEmpty
        ? null
        : missing > 0
            ? '$missing required secret key${missing == 1 ? '' : 's'} not set'
            : '${set.length} of ${provider.secretFields.length} secret keys set';
    return Opacity(
      opacity: active ? 1 : 0.6,
      child: Card(
        key: ValueKey('gateway-${e.id}'),
        child: BusyListTile(
          leading: const CircleAvatar(child: Icon(Icons.credit_card)),
          title: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${v['providerName'] ?? ''}'),
            if (v['isDefault'] == true) const Icon(Icons.star, size: 16),
            Chip(
              label: Text(mode),
              visualDensity: VisualDensity.compact,
              backgroundColor: mode == 'Live' ? scheme.primaryContainer : scheme.tertiaryContainer,
              labelStyle: TextStyle(color: mode == 'Live' ? scheme.onPrimaryContainer : scheme.onTertiaryContainer),
            ),
            if (!active) const StatusChip('Inactive'),
          ]),
          subtitle: Text([
            '${v['accountName'] ?? ''}',
            if (provider != null) chargeSupportLabel(provider.charging),
            ?secretsLine,
          ].join(' · ')),
          onTap: () => _edit(all, entry: e),
          trailing: PopupMenuButton<String>(
            onSelected: (a) async {
              if (a == 'edit') return _edit(all, entry: e);
              if (a == 'test') return _test(e);
              if (!await confirm(context, 'Delete',
                  'Remove ${v['providerName']} (${v['accountName']})? Its secret keys are deleted too.', ok: 'Delete')) {
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
              PopupMenuItem(value: 'edit', child: Text(canEdit ? 'Edit' : 'View')),
              if (canEdit) const PopupMenuItem(value: 'test', child: Text('Test connection')),
              if (canEdit) const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecretsNotice extends StatelessWidget {
  const _SecretsNotice();

  @override
  Widget build(BuildContext context) => const Card(
        key: ValueKey('gateway-secrets-notice'),
        child: ListTile(
          leading: Icon(Icons.lock_outline),
          title: Text('Secret keys are write-only'),
          subtitle: Text('Open an account to set or replace its secret keys. They are kept in the server\'s vault: '
              'nobody can read them back here or in the app, only the payments service uses them. The rest of an '
              'account (merchant IDs, publishable keys, mode) is public configuration.'),
        ),
      );
}

/// Which account takes each kind of payment.
class _RoutingCard extends ConsumerWidget {
  const _RoutingCard({required this.entries, required this.canEdit});
  final List<Entry> entries;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routing = ref.watch(gatewayRoutingProvider).value ?? const <String, String?>{};
    final t = Theme.of(context);
    final active = entries.where((e) => e.values['active'] != false).toList();
    String label(Entry e) => '${e.values['providerName'] ?? ''} · ${e.values['accountName'] ?? ''}'
        '${e.values['mode'] == 'Sandbox' ? ' (Sandbox)' : ''}';
    return Card(
      key: const ValueKey('gateway-routing'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Which account takes which payment', style: t.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('"Default account" uses the account marked Default gateway (or the only active one).',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          for (final p in paymentPurposes) ...[
            const SizedBox(height: 12),
            SearchableDropdownFormField<String>(
              key: ValueKey('gateway-route-${p.id}-${routing[p.id]}'),
              isExpanded: true,
              initialValue: active.any((e) => e.id == routing[p.id]) ? routing[p.id] : '',
              decoration: InputDecoration(
                labelText: p.label,
                helperText: () {
                  final eff = effectiveGatewayFor(p.id, routing, entries);
                  final who = entries.where((e) => e.id == eff).firstOrNull;
                  return '${p.about} Now: ${who == null ? 'no account (cannot be paid)' : label(who)}.';
                }(),
                helperMaxLines: 3,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('Default account')),
                for (final e in active) DropdownMenuItem(value: e.id, child: Text(label(e), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: !canEdit
                  ? null
                  : (v) async {
                      if (await runAdminAction(
                        context,
                        () => ref.read(commerceRepositoryProvider).setGatewayRouting(p.id, (v ?? '').isEmpty ? null : v),
                        success: 'Saved',
                      )) {
                        ref.invalidate(gatewayRoutingProvider);
                      }
                    },
            ),
          ],
        ]),
      ),
    );
  }
}

/// What a connection test said.
class GatewayTestResultView extends StatelessWidget {
  const GatewayTestResultView(this.result, {super.key});
  final GatewayTestResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (result.result) {
      'ok' => (Icons.check_circle_outline, scheme.primary),
      'warn' => (Icons.info_outline, scheme.tertiary),
      _ => (Icons.error_outline, scheme.error),
    };
    return Column(
      key: const ValueKey('gateway-test-result'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: color),
          title: Text(result.title),
          subtitle: Text(result.detail),
        ),
        if (result.checkoutUrl != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('gateway-test-checkout'),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open the RM 1.00 test checkout'),
              onPressed: () => openInApp(context, result.checkoutUrl!, title: 'Test checkout'),
            ),
          ),
      ],
    );
  }
}

class _GatewayForm extends ConsumerStatefulWidget {
  const _GatewayForm({this.entry, required this.form, required this.supabaseUrl, required this.canEdit});
  final Entry? entry;
  final GatewayForm form;
  final String supabaseUrl;
  final bool canEdit;

  @override
  ConsumerState<_GatewayForm> createState() => _GatewayFormState();
}

class _GatewayFormState extends ConsumerState<_GatewayForm> {
  late final GatewayForm _f = widget.form;
  String? _error;
  GatewayTestResult? _test;
  bool _testing = false;

  Future<void> _setSecret(CredentialField f, bool replace) async {
    final value = await showAppDialog<String>(
      id: 'payment-gateways.set-secret',
      context: context,
      builder: (_) => _SecretDialog(field: f, replace: replace),
    );
    if (value == null || value.trim().isEmpty || !mounted) return;
    if (await runAdminAction(
      context,
      () => ref.read(commerceRepositoryProvider).setGatewaySecret(widget.entry!.id, f.key, value.trim()),
      success: '${f.label} saved',
    )) {
      ref.invalidate(gatewaySecretStatusProvider);
    }
  }

  Future<void> _clearSecret(CredentialField f) async {
    if (!await confirm(context, 'Clear ${f.label}?',
        'Payments through this account that need it stop until a new one is set.', ok: 'Clear')) {
      return;
    }
    if (!mounted) return;
    if (await runAdminAction(
      context,
      () => ref.read(commerceRepositoryProvider).setGatewaySecret(widget.entry!.id, f.key, ''),
      success: '${f.label} cleared',
    )) {
      ref.invalidate(gatewaySecretStatusProvider);
    }
  }

  Future<void> _runTest(GatewayProvider p) async {
    setState(() {
      _testing = true;
      _test = null;
    });
    // Providers with no harmless API call also get an RM 1 checkout to open.
    final r = await ref.read(commerceRepositoryProvider).testGateway(
          widget.entry!.id,
          checkout: const {'fiuu', 'ipay88', 'eghl', 'senangpay'}.contains(p.id),
        );
    if (mounted) {
      setState(() {
        _testing = false;
        _test = r;
      });
    }
  }

  Widget _address(String label, String url, String key) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: SelectableText(url, key: ValueKey('$key-url')),
        trailing: IconButton(
          key: ValueKey('copy-$key'),
          tooltip: 'Copy',
          icon: const Icon(Icons.copy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (mounted) showInfo(context, 'Copied');
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final provider = providerById(_f.providerId);
    final entry = widget.entry;
    final t = Theme.of(context);
    final set = entry == null ? const <String, GatewaySecretState>{} : ref.watch(gatewaySecretStatusProvider).value?[entry.id] ?? const {};
    return FormDialogScaffold(
      title: entry == null ? 'Add ${provider?.name ?? 'Gateway'}' : (widget.canEdit ? 'Edit Gateway' : 'Gateway'),
      error: _error,
      onSave: () {
        if (!widget.canEdit) return Navigator.pop(context);
        final r = buildGatewayValues(_f, existing: entry?.values);
        if (r.error != null) return setState(() => _error = r.error);
        Navigator.pop(context, r.values);
      },
      children: [
        if (provider != null) Text(provider.description, style: t.textTheme.bodySmall),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Provider', prefixIcon: Icon(Icons.credit_card)),
          child: Text(provider?.name ?? 'Unknown provider (${_f.providerId})'),
        ),
        if (provider != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${chargeSupportLabel(provider.charging)}. ${chargeSupportAbout(provider.charging)}',
              key: const ValueKey('gateway-charging'),
              style: t.textTheme.bodySmall?.copyWith(
                color: provider.charging == ChargeSupport.checked ? t.colorScheme.onSurfaceVariant : t.colorScheme.tertiary,
              ),
            ),
          ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: _f.accountName,
          enabled: widget.canEdit,
          decoration: const InputDecoration(labelText: 'Account name *', hintText: 'e.g. Stripe MY Live'),
          onChanged: (v) => _f.accountName = v,
        ),
        const SectionLabel('Mode'),
        ChoiceRow(
          options: gatewayModes,
          value: _f.mode,
          onChanged: (m) => widget.canEdit ? setState(() => _f.mode = m) : null,
        ),
        if (provider != null) ...[
          SectionLabel('Credentials', icon: Icons.vpn_key_outlined, trailing: Text('${provider.publicFields.length} public')),
          for (final f in provider.publicFields)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextFormField(
                initialValue: _f.credentials[f.key] ?? '',
                enabled: widget.canEdit,
                decoration: InputDecoration(labelText: '${f.label}${f.optional ? '' : ' *'}', hintText: f.placeholder),
                onChanged: (v) => _f.credentials[f.key] = v,
              ),
            ),
          if (provider.secretFields.isNotEmpty) ...[
            SectionLabel('Secret keys', icon: Icons.lock_outline,
                trailing: Text('${set.length} of ${provider.secretFields.length} set')),
            Text(
              entry == null
                  ? 'Save the account first, then open it again to set its secret keys.'
                  : 'Saved at once, to the server\'s vault. They are never shown again: replace one to change it.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            for (final f in provider.secretFields)
              ListTile(
                key: ValueKey('secret-${f.key}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(set.containsKey(f.key) ? Icons.lock : Icons.lock_open_outlined,
                    color: set.containsKey(f.key) ? t.colorScheme.primary : (f.optional ? null : t.colorScheme.error)),
                title: Text('${f.label}${f.optional ? ' (optional)' : ' *'}'),
                subtitle: Text(secretStatusLine(set[f.key]), key: ValueKey('secret-status-${f.key}')),
                trailing: entry == null || !widget.canEdit
                    ? null
                    : Wrap(spacing: 4, children: [
                        TextButton(
                          key: ValueKey('secret-set-${f.key}'),
                          onPressed: () => _setSecret(f, set.containsKey(f.key)),
                          child: Text(set.containsKey(f.key) ? 'Replace' : 'Set'),
                        ),
                        if (set.containsKey(f.key))
                          IconButton(
                            key: ValueKey('secret-clear-${f.key}'),
                            tooltip: 'Clear',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _clearSecret(f),
                          ),
                      ]),
              ),
          ],
          if (entry != null) ...[
            const SectionLabel('Addresses to paste at the provider', icon: Icons.link),
            _address(provider.dashboardUrls ? 'Callback URL' : 'Webhook / callback URL',
                gatewayWebhookUrl(widget.supabaseUrl, provider.id, entry.id), 'webhook'),
            if (provider.dashboardUrls)
              _address('Return URL', gatewayReturnUrl(widget.supabaseUrl, provider.id, entry.id), 'return'),
            if (!provider.dashboardUrls)
              Text('The payer\'s return address is sent with each payment; nothing to set for it.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            if (widget.canEdit) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('gateway-test'),
                  onPressed: _testing ? null : () => _runTest(provider),
                  icon: _testing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.network_check),
                  label: const Text('Test connection'),
                ),
              ),
              if (_test != null) Padding(padding: const EdgeInsets.only(top: 8), child: GatewayTestResultView(_test!)),
            ],
          ],
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Active'),
          value: _f.active,
          onChanged: widget.canEdit ? (v) => setState(() => _f.active = v) : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Default gateway'),
          subtitle: const Text('Takes a payment no account is chosen for (see "Which account takes which payment").'),
          value: _f.isDefault,
          onChanged: widget.canEdit ? (v) => setState(() => _f.isDefault = v) : null,
        ),
      ],
    );
  }
}

/// Types one secret. It is sent once and never shown again.
class _SecretDialog extends StatefulWidget {
  const _SecretDialog({required this.field, required this.replace});
  final CredentialField field;
  final bool replace;

  @override
  State<_SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends State<_SecretDialog> {
  final _c = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('${widget.replace ? 'Replace' : 'Set'} ${widget.field.label}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: const ValueKey('secret-value'),
            controller: _c,
            autofocus: true,
            obscureText: !_show,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: widget.field.label,
              hintText: widget.field.placeholder,
              suffixIcon: IconButton(
                tooltip: _show ? 'Hide' : 'Show',
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 8),
          Text(
            widget.replace
                ? 'The one set now is replaced. Neither can be read back.'
                : 'It is saved to the server\'s vault and can\'t be read back.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('secret-save'),
            onPressed: () => Navigator.pop(context, _c.text),
            child: const Text('Save'),
          ),
        ],
      );
}
