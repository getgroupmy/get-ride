import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../widgets/admin_widgets.dart';
import '../maps/maps_screen.dart' show GoogleJsCheck;
import 'api_keys_logic.dart';
import 'security_data.dart';
import '../../../data/live_tables.dart';
import '../../../widgets/page_style_host.dart';

/// Expo gates the provider, service and key screens (and Elife) on this key.
const apiKeysPage = 'admin-settings-api-keys';

final apiProvidersProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('app_settings');
  return ref.watch(securityRepositoryProvider).apiProviders();
});

/// The tests a key can run (the `key-test` function's list).
final keyTestsProvider = FutureProvider.autoDispose((ref) => ref.watch(securityRepositoryProvider).keyTests());

bool _canEdit(WidgetRef ref, String page) =>
    ref.watch(securityLevelProvider('$apiKeysPage,$page')) == AccessLevel.edit;

/// Applies a providers-list change against the freshest row and refreshes.
Future<bool> _mutate(BuildContext context, WidgetRef ref, List<ApiProviderDef> Function(List<ApiProviderDef>) change,
    {String? success}) async {
  final ok = await runAdminAction(context, () => ref.read(securityRepositoryProvider).mutateApiProviders(change),
      success: success);
  if (context.mounted) ref.invalidate(apiProvidersProvider);
  return ok;
}

Future<String?> _askText(BuildContext context, String title, String label, {String? hint}) async {
  final c = TextEditingController();
  final v = await showAppDialog<String>(id: 'api-keys.ask-text',
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onSubmitted: (t) => Navigator.pop(ctx, t),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Add')),
      ],
    ),
  );
  c.dispose();
  return v;
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.outline;
    return Container(
      margin: const EdgeInsets.only(right: 6, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(border: Border.all(color: c), borderRadius: BorderRadius.circular(12)),
      child: Text(text, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
    );
  }
}

// ---- Providers ---------------------------------------------------------------

class AdminApiProvidersScreen extends ConsumerStatefulWidget {
  const AdminApiProvidersScreen({super.key});

  @override
  ConsumerState<AdminApiProvidersScreen> createState() => _ApiProvidersState();
}

class _ApiProvidersState extends ConsumerState<AdminApiProvidersScreen> {
  String _query = '';

  Future<void> _add() async {
    final name = (await _askText(context, 'New provider', 'Provider name', hint: 'e.g. Yandex Maps'))?.trim();
    if (name == null || !mounted) return;
    if (name.isEmpty) {
      showError(context, 'Please enter a provider name.');
      return;
    }
    await _mutate(context, ref, (l) => addProvider(l, name), success: 'Provider added');
  }

  Future<void> _delete(ApiProviderDef p) async {
    if (!await confirm(context, 'Delete provider', 'Remove "${p.name}" and all its services & keys?', ok: 'Delete')) {
      return;
    }
    if (mounted) await _mutate(context, ref, (l) => removeProvider(l, p.id), success: 'Provider removed');
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _canEdit(ref, apiKeysPage);
    final providers = ref.watch(apiProvidersProvider);
    return AdminPage(
      title: 'API providers',
      page: apiKeysPage,
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(apiProvidersProvider)),
      ],
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add provider')),
      body: AsyncView(
        value: providers,
        onRetry: () => ref.invalidate(apiProvidersProvider),
        data: (list) {
          final totals = providerTotals(list);
          final visible = list.where((p) => matchesProvider(p, _query)).toList();
          return ResponsiveCenter(
            maxWidth: 760,
            child: ListView(padding: const EdgeInsets.only(top: 12, bottom: 96), children: [
              Text('${list.length} providers · ${totals.services} services · ${totals.keys} keys',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              const Card(
                child: ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Tap a provider to manage its services and API keys. Multiple keys per service rotate '
                      'automatically on failure.'),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.power_outlined),
                  title: const Text('Elife Transfer API'),
                  subtitle: const Text('Fleet & Ride Management integration'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/admin/m/api-elife'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: 'Search providers...', isDense: true),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 8),
              if (visible.isEmpty)
                EmptyState(
                    icon: Icons.business, title: _query.isNotEmpty ? 'No providers match "$_query".' : 'No providers yet.'),
              for (final p in visible)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.business)),
                    title: Text(p.name),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.description ?? p.category ?? 'Custom provider', maxLines: 1, overflow: TextOverflow.ellipsis),
                      Wrap(children: [_Badge('${p.services.length} services'), _Badge('${p.keyCount} keys')]),
                    ]),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (canEdit)
                        BusyIconButton(tooltip: 'Delete provider', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(p)),
                      const Icon(Icons.chevron_right),
                    ]),
                    onTap: () => context.push('/admin/m/api-keys-services?providerId=${Uri.encodeQueryComponent(p.id)}'),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }
}

// ---- Services ----------------------------------------------------------------

class AdminApiServicesScreen extends ConsumerStatefulWidget {
  const AdminApiServicesScreen({super.key, required this.providerId});
  final String providerId;

  @override
  ConsumerState<AdminApiServicesScreen> createState() => _ApiServicesState();
}

class _ApiServicesState extends ConsumerState<AdminApiServicesScreen> {
  String _query = '';

  Future<void> _add() async {
    final result = await showDialog<({String name, String description})>(
      context: context,
      builder: (_) => const _ServiceDialog(),
    );
    if (result == null || !mounted) return;
    if (result.name.trim().isEmpty) {
      showError(context, 'Please enter a service name.');
      return;
    }
    await _mutate(context, ref, (l) => addService(l, widget.providerId, result.name, description: result.description),
        success: 'Service added');
  }

  Future<void> _delete(ApiServiceDef s) async {
    if (!await confirm(context, 'Delete service', 'Remove "${s.name}" and its keys?', ok: 'Delete')) return;
    if (mounted) await _mutate(context, ref, (l) => removeService(l, widget.providerId, s.id), success: 'Service removed');
  }

  Future<void> _bulkAdd(ApiProviderDef p) async {
    final result = await showDialog<({String label, String value, Set<String> services})>(
      context: context,
      builder: (_) => _BulkKeyDialog(provider: p),
    );
    if (result == null || !mounted) return;
    await _mutate(context, ref, (l) {
      var next = l;
      for (final sid in result.services) {
        next = addKey(next, widget.providerId, sid, result.label, result.value);
      }
      return next;
    }, success: 'Key added to ${result.services.length} service${result.services.length == 1 ? '' : 's'}');
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _canEdit(ref, 'admin-settings-api-keys-services');
    final providers = ref.watch(apiProvidersProvider);
    final provider = providers.value?.where((p) => p.id == widget.providerId).firstOrNull;
    return AdminPage(
      title: provider?.name ?? 'Services',
      page: apiKeysPage,
      actions: [
        if (canEdit && provider != null && provider.services.isNotEmpty)
          BusyIconButton(
              tooltip: 'Add one key to several services',
              icon: const Icon(Icons.library_add_outlined),
              onPressed: () => _bulkAdd(provider)),
      ],
      floatingActionButton: provider == null
          ? null
          : FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add service')),
      body: AsyncView(
        value: providers,
        onRetry: () => ref.invalidate(apiProvidersProvider),
        data: (_) {
          if (provider == null) return const EmptyState(icon: Icons.search_off, title: 'Provider not found.');
          final visible = provider.services.where((s) => matchesService(s, _query)).toList();
          return ResponsiveCenter(
            maxWidth: 760,
            child: ListView(padding: const EdgeInsets.only(top: 12, bottom: 96), children: [
              Text('${provider.services.length} services', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: 'Search services...', isDense: true),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 8),
              if (visible.isEmpty)
                EmptyState(
                  icon: Icons.vpn_key_outlined,
                  title: _query.isNotEmpty ? 'No services match "$_query".' : 'No services yet.',
                  message: _query.isEmpty ? 'Add one to get started.' : null,
                ),
              for (final s in visible)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.vpn_key_outlined)),
                    title: Text(s.name),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (s.description != null) Text(s.description!, maxLines: 2, overflow: TextOverflow.ellipsis),
                      Wrap(children: [
                        _Badge('${s.keys.length} keys'),
                        _Badge('${s.activeKeyCount} active', color: s.activeKeyCount > 0 ? Colors.green : null),
                      ]),
                    ]),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (canEdit)
                        BusyIconButton(tooltip: 'Delete service', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(s)),
                      const Icon(Icons.chevron_right),
                    ]),
                    onTap: () => context.push('/admin/m/api-keys-keys?providerId=${Uri.encodeQueryComponent(provider.id)}'
                        '&serviceId=${Uri.encodeQueryComponent(s.id)}'),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }
}

class _ServiceDialog extends StatefulWidget {
  const _ServiceDialog();

  @override
  State<_ServiceDialog> createState() => _ServiceDialogState();
}

class _ServiceDialogState extends State<_ServiceDialog> {
  final _name = TextEditingController();
  final _desc = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New service'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'Service name')),
          TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Description (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, (name: _name.text, description: _desc.text)),
            child: const Text('Add'),
          ),
        ],
      );
}

class _BulkKeyDialog extends StatefulWidget {
  const _BulkKeyDialog({required this.provider});
  final ApiProviderDef provider;

  @override
  State<_BulkKeyDialog> createState() => _BulkKeyDialogState();
}

class _BulkKeyDialogState extends State<_BulkKeyDialog> {
  final _label = TextEditingController();
  final _value = TextEditingController();
  final _selected = <String>{};
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.provider.services;
    final allSelected = services.every((s) => _selected.contains(s.id));
    return AlertDialog(
      title: const Text('Add key to services'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _label, decoration: const InputDecoration(labelText: 'Label (optional)')),
          TextField(
            controller: _value,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'API key value'),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => allSelected ? _selected.clear() : _selected.addAll(services.map((s) => s.id))),
              child: Text(allSelected ? 'Clear all' : 'Select all'),
            ),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final s in services)
                CheckboxListTile(
                  dense: true,
                  value: _selected.contains(s.id),
                  title: Text(s.name),
                  subtitle: Text('${s.keys.length} keys'),
                  onChanged: (v) => setState(() => v == true ? _selected.add(s.id) : _selected.remove(s.id)),
                ),
            ]),
          ),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_value.text.trim().isEmpty) {
              setState(() => _error = 'Please enter the API key value.');
              return;
            }
            if (_selected.isEmpty) {
              setState(() => _error = 'Please select at least one service.');
              return;
            }
            Navigator.pop(context, (label: _label.text.trim(), value: _value.text, services: {..._selected}));
          },
          child: Text('Add to ${_selected.length}'),
        ),
      ],
    );
  }
}

// ---- Keys --------------------------------------------------------------------

class AdminApiKeysScreen extends ConsumerWidget {
  const AdminApiKeysScreen({super.key, required this.providerId, required this.serviceId});
  final String providerId;
  final String serviceId;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<({String label, String value})>(context: context, builder: (_) => const _KeyDialog());
    if (result == null || !context.mounted) return;
    if (result.value.trim().isEmpty) {
      showError(context, 'Please enter the API key value.');
      return;
    }
    await _mutate(context, ref, (l) => addKey(l, providerId, serviceId, result.label, result.value), success: 'Key added');
  }

  Future<void> _patch(BuildContext context, WidgetRef ref, ApiKeyEntry k, ApiKeyEntry Function(ApiKeyEntry) f) =>
      _mutate(context, ref, (l) => updateKey(l, providerId, serviceId, k.id, f));

  Future<void> _delete(BuildContext context, WidgetRef ref, ApiKeyEntry k) async {
    if (!await confirm(context, 'Delete key', 'Remove "${k.label}"?', ok: 'Delete')) return;
    if (context.mounted) await _mutate(context, ref, (l) => removeKey(l, providerId, serviceId, k.id), success: 'Key removed');
  }

  Future<void> _test(BuildContext context, List<ApiKeyEntry> keys, bool canSave) => showAppDialog<void>(id: 'api-keys.delete',
        context: context,
        builder: (_) => KeyTestDialog(providerId: providerId, serviceId: serviceId, keys: keys, canSave: canSave),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = _canEdit(ref, 'admin-settings-api-keys-keys');
    final providers = ref.watch(apiProvidersProvider);
    final provider = providers.value?.where((p) => p.id == providerId).firstOrNull;
    final service = provider?.services.where((s) => s.id == serviceId).firstOrNull;
    final next = service == null ? null : pickNextKey(service);
    final testable = service?.keys.where((k) => k.hasValue).toList() ?? const <ApiKeyEntry>[];
    return AdminPage(
      title: service?.name ?? 'Keys',
      page: apiKeysPage,
      actions: [
        if (testable.length > 1)
          IconButton(
            key: const ValueKey('api-keys-test-all'),
            tooltip: 'Test all keys',
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () => _test(context, testable, canEdit),
          ),
      ],
      floatingActionButton: service == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _add(context, ref), icon: const Icon(Icons.add), label: const Text('Add key')),
      body: AsyncView(
        value: providers,
        onRetry: () => ref.invalidate(apiProvidersProvider),
        data: (_) {
          if (service == null) return const EmptyState(icon: Icons.search_off, title: 'Service not found.');
          return ResponsiveCenter(
            maxWidth: 760,
            child: ListView(padding: const EdgeInsets.only(top: 12, bottom: 96), children: [
              Text('${provider!.name} · ${service.keys.length} keys', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Card(
                color: Colors.orange.withValues(alpha: 0.1),
                child: const ListTile(
                  leading: Icon(Icons.warning_amber, color: Colors.orange),
                  title: Text('These keys are shipped to every app'),
                  subtitle: Text('The provider list is one app_settings row that any client can read, because the '
                      'apps call these services directly. Only store keys restricted to your apps / referrers.'),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text('Automatic failover'),
                  subtitle: Text('When a key fails, the next available key with the lowest failure count is used. '
                      'Disabled keys are skipped.\n'
                      '${next == null ? 'No active keys available' : 'Next in rotation: ${next.label}'}'),
                  isThreeLine: true,
                ),
              ),
              if (service.keys.isEmpty)
                EmptyState(icon: Icons.vpn_key_off_outlined, title: 'No keys yet.', message: 'Add one to enable ${service.name}.'),
              for (final (i, k) in service.keys.indexed)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        CircleAvatar(radius: 14, child: Text('#${i + 1}', style: const TextStyle(fontSize: 11))),
                        const SizedBox(width: 8),
                        Expanded(child: Text(k.label, style: Theme.of(context).textTheme.titleSmall)),
                        if (next?.id == k.id) const _Badge('NEXT', color: Colors.green),
                        if (k.isDisabled) const _Badge('DISABLED', color: Colors.red),
                      ]),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(
                          child: Text(k.hasValue ? maskSecret(k.value) : '(no value)',
                              style: const TextStyle(fontFamily: 'monospace')),
                        ),
                        if (canEdit && k.hasValue)
                          IconButton(
                            tooltip: 'Copy key',
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: k.value));
                              if (context.mounted) showInfo(context, 'API key copied to clipboard.');
                            },
                          ),
                      ]),
                      Text('Used ${k.useCount} · Failed ${k.failedCount}'
                          '${k.lastUsedAt != null ? ' · last used ${dateText(DateTime.fromMillisecondsSinceEpoch(k.lastUsedAt!).toIso8601String())}' : ''}'),
                      if (KeyLastTest.fromKey(k) case final last?)
                        _LastTestLine(last, key: ValueKey('api-key-last-test-${k.id}')),
                      Wrap(spacing: 4, children: [
                        if (k.hasValue)
                          TextButton.icon(
                            key: ValueKey('api-key-test-${k.id}'),
                            icon: const Icon(Icons.network_check, size: 16),
                            label: const Text('Test'),
                            onPressed: () => _test(context, [k], canEdit),
                          ),
                        if (canEdit) ...[
                            BusyButton.text(
                              icon: const Icon(Icons.check_circle_outline, size: 16),
                              child: const Text('+ Use'),
                              onPressed: () =>
                                  _mutate(context, ref, (l) => reportKeyUsage(l, providerId, serviceId, k.id, true)),
                            ),
                            BusyButton.text(
                              icon: const Icon(Icons.highlight_off, size: 16),
                              child: const Text('+ Fail'),
                              onPressed: () =>
                                  _mutate(context, ref, (l) => reportKeyUsage(l, providerId, serviceId, k.id, false)),
                            ),
                            BusyButton.text(
                              icon: const Icon(Icons.restart_alt, size: 16),
                              child: const Text('Reset'),
                              onPressed: () => _patch(context, ref, k, (x) => x.copyWith(useCount: 0, failedCount: 0)),
                            ),
                            BusyButton.text(
                              icon: const Icon(Icons.power_settings_new, size: 16),
                              child: Text(k.isDisabled ? 'Enable' : 'Disable'),
                              onPressed: () => _patch(context, ref, k, (x) => x.copyWith(disabled: !x.isDisabled)),
                            ),
                            BusyButton.text(
                              icon: const Icon(Icons.delete_outline, size: 16),
                              child: const Text('Delete'),
                              onPressed: () => _delete(context, ref, k),
                            ),
                        ],
                      ]),
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

class _KeyDialog extends StatefulWidget {
  const _KeyDialog();

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  final _label = TextEditingController();
  final _value = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New key'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _label, autofocus: true, decoration: const InputDecoration(labelText: 'Label (optional)')),
          TextField(
            controller: _value,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'API key value'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, (label: _label.text, value: _value.text)),
            child: const Text('Add'),
          ),
        ],
      );
}

// ---- Key tests -----------------------------------------------------------------

({IconData icon, Color color}) _outcomeLook(BuildContext context, KeyTestOutcome o) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (o) {
    KeyTestOutcome.ok => (icon: Icons.check_circle, color: dark ? Colors.green.shade300 : Colors.green.shade700),
    KeyTestOutcome.warn => (icon: Icons.warning_amber, color: dark ? Colors.orange.shade300 : Colors.orange.shade800),
    KeyTestOutcome.fail => (icon: Icons.error, color: Theme.of(context).colorScheme.error),
  };
}

/// "Last test: Map Tiles API · Works · 2026-10-16 17:29" under a key.
class _LastTestLine extends StatelessWidget {
  const _LastTestLine(this.last, {super.key});
  final KeyLastTest last;

  @override
  Widget build(BuildContext context) {
    final look = _outcomeLook(context, last.outcome);
    final when = dateText(DateTime.fromMillisecondsSinceEpoch(last.at).toIso8601String());
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(look.icon, size: 16, color: look.color),
        const SizedBox(width: 6),
        Expanded(child: Text('Last test: ${last.label} · ${last.title} · $when')),
      ]),
    );
  }
}

/// Admin → API Keys → Test: pick a test, how to send it, and run it on
/// [keys] (one, or every key of the service). Each answer is shown, and kept
/// on the key when [canSave].
class KeyTestDialog extends ConsumerStatefulWidget {
  const KeyTestDialog({
    super.key,
    required this.providerId,
    required this.serviceId,
    required this.keys,
    this.canSave = false,
  });

  final String providerId;
  final String serviceId;
  final List<ApiKeyEntry> keys;
  final bool canSave;

  @override
  ConsumerState<KeyTestDialog> createState() => _KeyTestDialogState();
}

class _KeyTestDialogState extends ConsumerState<KeyTestDialog> {
  final _cert = TextEditingController();
  String? _testId;
  KeySendAs? _as;
  bool _running = false;
  final _results = <String, KeyTestResult>{};

  @override
  void dispose() {
    _cert.dispose();
    super.dispose();
  }

  List<KeyTestDef> _choices(List<KeyTestDef> all) {
    final list = keyTestsFor(all, widget.providerId, widget.serviceId);
    // Google's JavaScript map runs in this page, one key at a time.
    return widget.keys.length > 1 ? list.where((t) => !t.browser).toList() : list;
  }

  Future<void> _run(KeyTestDef test, KeySendAs as) async {
    setState(() {
      _running = true;
      _results.clear();
    });
    final repo = ref.read(securityRepositoryProvider);
    for (final k in widget.keys) {
      final r = await repo.testKey(
        providerId: widget.providerId,
        serviceId: widget.serviceId,
        keyId: k.id,
        testId: test.id,
        sendAs: as,
        cert: as == KeySendAs.android ? _cert.text : null,
      );
      if (!mounted) return;
      setState(() => _results[k.id] = r);
    }
    if (widget.canSave) {
      try {
        await repo.mutateApiProviders((l) {
          var next = l;
          for (final e in _results.entries) {
            next = recordKeyTest(next, widget.providerId, widget.serviceId, e.key, test, e.value);
          }
          return next;
        });
        ref.invalidate(apiProvidersProvider);
      } catch (_) {
        // The answers are on screen; keeping them on the key is a nicety.
      }
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tests = ref.watch(keyTestsProvider);
    final one = widget.keys.length == 1;
    final choices = _choices(tests.value ?? const []);
    final test = choices.where((c) => c.id == _testId).firstOrNull ?? choices.firstOrNull;
    final as = _as ?? defaultSendAs(widget.serviceId, test);
    return AlertDialog(
      key: const ValueKey('key-test-dialog'),
      title: Text(one ? 'Test ${widget.keys.single.label}' : 'Test ${widget.keys.length} keys'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (tests.isLoading && !tests.hasValue)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (tests.hasError && !tests.hasValue)
              Text("Couldn't load the tests. Try again in a moment.", style: TextStyle(color: t.colorScheme.error))
            else if (test == null)
              const Text('There is no test for this provider yet.', key: ValueKey('key-test-none'))
            else ...[
              DropdownButtonFormField<String>(
                key: const ValueKey('key-test-pick'),
                initialValue: test.id,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Test'),
                items: [
                  for (final c in choices)
                    DropdownMenuItem(value: c.id, child: Text(c.label, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: _running
                    ? null
                    : (v) => setState(() {
                          _testId = v;
                          _as = null;
                          _results.clear();
                        }),
              ),
              if (test.about.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 6), child: Text(test.about, style: t.textTheme.bodySmall)),
              const SizedBox(height: 12),
              if (test.browser)
                GoogleJsCheck(key: ValueKey('key-test-js-${widget.keys.single.id}'), apiKey: widget.keys.single.value)
              else ...[
                DropdownButtonFormField<KeySendAs>(
                  key: const ValueKey('key-test-as'),
                  initialValue: as,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Send as',
                    helperText: 'As the app or site the key is kept to',
                  ),
                  items: [for (final a in KeySendAs.values) DropdownMenuItem(value: a, child: Text(a.label))],
                  onChanged: _running ? null : (v) => setState(() => _as = v),
                ),
                if (as == KeySendAs.android) ...[
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('key-test-cert'),
                    controller: _cert,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'SHA-1 of the signing key (optional)',
                      hintText: 'AB:CD:…',
                      helperText: 'Play Console → App integrity. Without it, a key kept to the app is refused.',
                      helperMaxLines: 2,
                    ),
                  ),
                ],
              ],
              for (final k in widget.keys)
                if (_results[k.id] case final r?)
                  _ResultRow(label: one ? null : k.label, result: r, key: ValueKey('key-test-result-${k.id}'))
                else if (_running)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(children: [
                      const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(one ? 'Testing…' : '${k.label}: testing…')),
                    ]),
                  ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (test != null && !test.browser)
          FilledButton.icon(
            key: const ValueKey('key-test-run'),
            onPressed: _running ? null : () => _run(test, as),
            icon: const Icon(Icons.play_arrow),
            label: Text(_results.isEmpty ? 'Run test' : 'Run again'),
          ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({super.key, required this.result, this.label});
  final KeyTestResult result;

  /// The key's label, when several are tested.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = _outcomeLook(context, result.outcome);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: look.color.withValues(alpha: 0.08),
        border: Border.all(color: look.color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(look.icon, color: look.color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label == null ? result.title : '$label: ${result.title}',
                style: t.textTheme.titleSmall?.copyWith(color: look.color)),
            if (result.detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(result.detail)),
            if (result.meta.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text(result.meta, style: t.textTheme.bodySmall)),
          ]),
        ),
      ]),
    );
  }
}
