import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'commerce_data.dart';
import 'commerce_logic.dart';
import 'commerce_widgets.dart';
import 'countries.dart';
import '../geo/geo_data.dart';
import '../geo/geo_logic.dart';

final _decimal = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];

/// Shared list scaffold for the entry-shaped EV catalogues.
class _EntryListPage extends ConsumerStatefulWidget {
  const _EntryListPage({
    required this.categoryKey,
    required this.page,
    required this.title,
    required this.addLabel,
    required this.searchHint,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.matches,
    required this.sort,
    required this.rowBuilder,
    required this.onAdd,
    this.header,
  });

  final String categoryKey;
  final String page;
  final String title;
  final String addLabel;
  final String searchHint;
  final String emptyTitle;
  final String emptyMessage;
  final bool Function(Entry e, String q) matches;
  final List<Entry> Function(List<Entry>) sort;
  final Widget Function(BuildContext context, Entry e, List<Entry> sorted, int index, bool canEdit) rowBuilder;
  final void Function(List<Entry> all) onAdd;
  final Widget Function(List<Entry> all, bool canEdit)? header;

  @override
  ConsumerState<_EntryListPage> createState() => _EntryListPageState();
}

class _EntryListPageState extends ConsumerState<_EntryListPage> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(widget.page)) == AccessLevel.edit;
    final entries = ref.watch(commerceEntriesProvider(widget.categoryKey));
    return AdminPage(
      title: widget.title,
      page: widget.page,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => widget.onAdd(entries.value ?? []),
        icon: const Icon(Icons.add),
        label: Text(widget.addLabel),
      ),
      body: Column(children: [
        ListSearch(hint: widget.searchHint, onChanged: (v) => setState(() => _q = v)),
        Expanded(
          child: AsyncView(
            value: entries,
            onRetry: () => ref.invalidate(commerceEntriesProvider(widget.categoryKey)),
            data: (all) {
              final sorted = widget.sort(all);
              final rows = sorted.where((e) => widget.matches(e, _q)).toList();
              return ResponsiveCenter(
                maxWidth: 860,
                child: ListView(padding: const EdgeInsets.only(top: 8, bottom: 96), children: [
                  ?widget.header?.call(all, canEdit),
                  if (rows.isEmpty) EmptyState(icon: Icons.inbox_outlined, title: widget.emptyTitle, message: widget.emptyMessage),
                  for (var i = 0; i < rows.length; i++) widget.rowBuilder(context, rows[i], rows, i, canEdit),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

Future<void> _saveEntry(
  BuildContext context,
  WidgetRef ref,
  String key,
  Map<String, dynamic> values, {
  String? id,
  required List<Entry> all,
  bool singleDefault = false,
}) async {
  final ok = await runAdminAction(context, () async {
    final repo = ref.read(commerceRepositoryProvider);
    var savedId = id;
    if (id != null) {
      await ref.read(adminRepositoryProvider).saveSetting(commerceCategories[key]!, id: id, values: values);
    } else {
      savedId = await repo.insertEntry(key, values, all.length);
    }
    if (singleDefault && values['isDefault'] == true) await repo.clearOtherDefaults(key, all, savedId);
  }, success: 'Saved');
  if (ok) ref.invalidate(commerceEntriesProvider(key));
}

Future<void> _deleteEntry(BuildContext context, WidgetRef ref, String key, String id, String message) async {
  if (!await confirm(context, 'Delete', message, ok: 'Delete')) return;
  if (!context.mounted) return;
  if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSetting(commerceCategories[key]!, id))) {
    ref.invalidate(commerceEntriesProvider(key));
  }
}

Widget _deleteButton(BusyAction onPressed) =>
    BusyIconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: onPressed);

// ===========================================================================
// Order fee (ev_order_fee)
// ===========================================================================

class EvOrderFeeScreen extends ConsumerWidget {
  const EvOrderFeeScreen({super.key});
  static const page = 'admin-settings-ev-order-fee';
  static const catKey = 'ev-order-fee';

  Future<void> _edit(BuildContext context, WidgetRef ref, List<Entry> all, [Entry? e]) async {
    // The regions as Admin → Country / States / Cities saves them (the
    // region tables), for each country's currency.
    final csc = await ref.read(geoAdminRepositoryProvider).regions().catchError((_) => <RegionEntry>[]);
    if (!context.mounted) return;
    final values = await showFormDialog<Map<String, dynamic>>(
      context,
      (_) => _OrderFeeForm(entry: e, all: all, countryStatesCities: [for (final c in csc) c.values]),
    );
    if (values == null || !context.mounted) return;
    await _saveEntry(context, ref, catKey, values, id: e?.id, all: all, singleDefault: true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _EntryListPage(
        categoryKey: catKey,
        page: page,
        title: 'Order Fee',
        addLabel: 'Add order fee',
        searchHint: 'Search country',
        emptyTitle: 'No order fees yet',
        emptyMessage: 'Add a non-refundable order fee for a country.',
        matches: (e, q) => valuesMatch(e.values, q),
        sort: (all) => sortOrderFees(all, (e) => e.values),
        onAdd: (all) => _edit(context, ref, all),
        header: (all, canEdit) => all.isEmpty && canEdit
            ? Card(
                child: ListTile(
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('Start with the default'),
                  subtitle: const Text('$defaultOrderFeeCountry · $defaultOrderFeeCurrency $defaultOrderFeeAmount (default country)'),
                  trailing: BusyButton.filled(
                    style: FilledButton.styleFrom(minimumSize: const Size(72, 40)),
                    onPressed: () => _saveEntry(context, ref, catKey, Map.of(orderFeeSeed), all: all),
                    child: const Text('Add'),
                  ),
                ),
              )
            : const SizedBox.shrink(),
        rowBuilder: (context, e, sorted, i, canEdit) {
          final v = e.values;
          return Card(
            child: BusyListTile(
              leading: const CircleAvatar(child: Icon(Icons.payments_outlined)),
              title: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${v['country'] ?? ''}'),
                if (v['isDefault'] == true) const Chip(avatar: Icon(Icons.star, size: 14), label: Text('Default'), visualDensity: VisualDensity.compact),
                if (v['active'] == false) const StatusChip('Inactive'),
              ]),
              subtitle: Text('${v['currency'] ?? defaultOrderFeeCurrency} ${groupedNumber(toNum(v['amount']))}'
                  '${(v['gatewayProviderName'] ?? '').toString().isNotEmpty ? ' · ${v['gatewayProviderName']}' : ''}'),
              onTap: canEdit ? () => _edit(context, ref, sorted, e) : null,
              trailing: canEdit
                  ? _deleteButton(() async {
                      if (!canDeleteOrderFee(v)) {
                        showInfo(context,
                            '$defaultOrderFeeCountry is the default country and cannot be removed. You can edit the fee instead.');
                        return;
                      }
                      await _deleteEntry(context, ref, catKey, e.id, 'Remove order fee for ${v['country']}?');
                    })
                  : null,
            ),
          );
        },
      );
}

class _OrderFeeForm extends StatefulWidget {
  const _OrderFeeForm({this.entry, required this.all, required this.countryStatesCities});
  final Entry? entry;
  final List<Entry> all;
  final List<Map<String, dynamic>> countryStatesCities;

  @override
  State<_OrderFeeForm> createState() => _OrderFeeFormState();
}

class _OrderFeeFormState extends State<_OrderFeeForm> {
  late final Map<String, dynamic> _v = widget.entry?.values ?? const {};
  late String _country = '${_v['country'] ?? ''}';
  late final _currency = TextEditingController(text: '${_v['currency'] ?? defaultOrderFeeCurrency}');
  late final _amount = TextEditingController(text: _v['amount'] == null ? '' : '${_v['amount']}');
  late bool _isDefault = _v['isDefault'] == true;
  late bool _active = _v['active'] != false;
  late SelectedGateway? _gateway = SelectedGateway.fromReference(_v);
  String? _error;

  @override
  void dispose() {
    _currency.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FormDialogScaffold(
        title: widget.entry == null ? 'Add Order Fee' : 'Edit Order Fee',
        error: _error,
        onSave: () {
          final r = buildOrderFeeValues(
            country: _country,
            currency: _currency.text,
            amount: _amount.text,
            isDefault: _isDefault,
            active: _active,
            gateway: _gateway,
            others: widget.all,
            editingId: widget.entry?.id,
            existing: widget.entry?.values,
          );
          if (r.error != null) return setState(() => _error = r.error);
          Navigator.pop(context, r.values);
        },
        children: [
          CountryField(
            value: _country,
            onChanged: (name) => setState(() {
              _country = name;
              final cur = resolveCurrencyForCountry(name, widget.countryStatesCities, worldCountryCurrencies);
              if (cur.isNotEmpty) _currency.text = cur;
            }),
          ),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 110,
              child: TextField(
                controller: _currency,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Currency', hintText: 'RM'),
                onChanged: (t) {
                  final up = t.toUpperCase();
                  if (up != t) _currency.value = _currency.value.copyWith(text: up);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _amount,
                inputFormatters: _decimal,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Order fee amount *', hintText: '3000'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          GatewayPickerField(
            value: _gateway,
            onChanged: (g) => setState(() => _gateway = g),
            helperText: 'Account used to collect this order fee. Leave as None to use the default gateway.',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Default country'),
            subtitle: const Text("Used when a customer's country has no specific fee."),
            value: _isDefault,
            onChanged: (v) => setState(() => _isDefault = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
        ],
      );
}

// ===========================================================================
// Finance options (ev_finance_options)
// ===========================================================================

class EvFinanceOptionsScreen extends ConsumerWidget {
  const EvFinanceOptionsScreen({super.key});
  static const page = 'admin-settings-ev-finance-options';
  static const catKey = 'ev-finance-options';

  Future<void> _edit(BuildContext context, WidgetRef ref, List<Entry> all, [Entry? e]) async {
    final values = await showFormDialog<Map<String, dynamic>>(context, (_) => _FinanceForm(entry: e, count: all.length));
    if (values == null || !context.mounted) return;
    await _saveEntry(context, ref, catKey, values, id: e?.id, all: all);
  }

  Future<void> _move(BuildContext context, WidgetRef ref, List<Entry> sorted, String id, int dir) async {
    final changes = reorderPriorities(sorted, id, dir);
    if (changes.isEmpty) return;
    final repo = ref.read(adminRepositoryProvider);
    await runAdminAction(context, () async {
      for (final c in changes.entries) {
        final e = sorted.firstWhere((x) => x.id == c.key);
        await repo.saveSetting(commerceCategories[catKey]!, id: c.key, values: {...e.values, 'displayPriority': c.value});
      }
    });
    ref.invalidate(commerceEntriesProvider(catKey));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _EntryListPage(
        categoryKey: catKey,
        page: page,
        title: 'EV Finance Options',
        addLabel: 'Add option',
        searchHint: 'Search',
        emptyTitle: 'No finance options yet',
        emptyMessage: 'Cash, Leasing, Hire Purchase & Rental for TEKSI EV.',
        matches: (e, q) => valuesMatch(e.values, q),
        sort: (all) => sortByPriority(all, (e) => e.values),
        onAdd: (all) => _edit(context, ref, all),
        header: (all, canEdit) => all.isEmpty && canEdit
            ? Card(
                child: ListTile(
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('Start with the default plans'),
                  subtitle: Text(financeOptionSeeds.map((s) => s['name']).join(' · ')),
                  trailing: BusyButton.filled(
                    style: FilledButton.styleFrom(minimumSize: const Size(72, 40)),
                    onPressed: () => runAdminAction(context, () async {
                      final repo = ref.read(commerceRepositoryProvider);
                      for (var i = 0; i < financeOptionSeeds.length; i++) {
                        await repo.insertEntry(catKey, Map.of(financeOptionSeeds[i]), i);
                      }
                    }, success: 'Default plans added').then((_) => ref.invalidate(commerceEntriesProvider(catKey))),
                    child: const Text('Add'),
                  ),
                ),
              )
            : const SizedBox.shrink(),
        rowBuilder: (context, e, sorted, i, canEdit) {
          final v = e.values;
          return Card(
            child: BusyListTile(
              leading: canEdit
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      InkWell(
                        onTap: i == 0 ? null : () => _move(context, ref, sorted, e.id, -1),
                        child: Icon(Icons.keyboard_arrow_up, color: i == 0 ? Theme.of(context).disabledColor : null),
                      ),
                      InkWell(
                        onTap: i == sorted.length - 1 ? null : () => _move(context, ref, sorted, e.id, 1),
                        child: Icon(Icons.keyboard_arrow_down,
                            color: i == sorted.length - 1 ? Theme.of(context).disabledColor : null),
                      ),
                    ])
                  : CircleAvatar(child: Text('${v['displayPriority'] ?? '-'}')),
              title: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${v['name'] ?? 'Untitled'}'),
                Chip(label: Text('#${v['displayPriority'] ?? '-'}'), visualDensity: VisualDensity.compact),
                if (v['active'] == false) const StatusChip('Inactive'),
              ]),
              subtitle: Text('${v['type'] ?? ''} • ${v['country'] ?? '—'}\n${financeOptionMeta(v)}'),
              isThreeLine: true,
              onTap: canEdit ? () => _edit(context, ref, sorted, e) : null,
              trailing: canEdit ? _deleteButton(() => _deleteEntry(context, ref, catKey, e.id, 'Remove this finance option?')) : null,
            ),
          );
        },
      );
}

class _FinanceForm extends StatefulWidget {
  const _FinanceForm({this.entry, required this.count});
  final Entry? entry;
  final int count;

  @override
  State<_FinanceForm> createState() => _FinanceFormState();
}

class _FinanceFormState extends State<_FinanceForm> {
  late final Map<String, dynamic> _v = widget.entry?.values ?? const {};
  late final _name = TextEditingController(text: '${_v['name'] ?? ''}');
  late String _type = financeOptionTypes.contains(_v['type']) ? _v['type'] as String : 'Cash';
  late String _country = '${_v['country'] ?? ''}';
  late String _mode = _v['paymentMode'] == 'Custom' ? 'Custom' : 'Full Balance';
  late final _amount = TextEditingController(text: '${_v['paymentAmount'] ?? ''}');
  late final _rate = TextEditingController(text: '${_v['rate'] ?? ''}');
  late final _term = TextEditingController(text: '${_v['termValue'] ?? ''}');
  late String _unit = financeTermUnits.contains(_v['termUnit']) ? _v['termUnit'] as String : 'Month';
  late final _details = TextEditingController(text: '${_v['details'] ?? ''}');
  late bool _active = _v['active'] != false;
  late final num _priority = widget.entry == null
      ? widget.count + 1
      : (_v['displayPriority'] is num ? _v['displayPriority'] as num : (num.tryParse('${_v['displayPriority']}') ?? widget.count + 1));
  late SelectedGateway? _gateway = SelectedGateway.fromReference(_v);
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _amount, _rate, _term, _details]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FormDialogScaffold(
        title: widget.entry == null ? 'Add EV Finance Option' : 'Edit EV Finance Option',
        error: _error,
        onSave: () {
          final r = buildFinanceOptionValues(
            name: _name.text,
            type: _type,
            country: _country,
            paymentMode: _mode,
            paymentAmount: _amount.text,
            rate: _rate.text,
            termValue: _term.text,
            termUnit: _unit,
            details: _details.text,
            active: _active,
            displayPriority: _priority,
            gateway: _gateway,
            existing: widget.entry?.values,
          );
          if (r.error != null) return setState(() => _error = r.error);
          Navigator.pop(context, r.values);
        },
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Plan name *', hintText: 'e.g. Leasing 24m')),
          const SectionLabel('Type'),
          ChoiceRow(options: financeOptionTypes, value: _type, onChanged: (t) => setState(() => _type = t)),
          const SizedBox(height: 12),
          CountryField(value: _country, onChanged: (c) => setState(() => _country = c)),
          const SectionLabel('Payment'),
          ChoiceRow(options: financePaymentModes, value: _mode, onChanged: (m) => setState(() => _mode = m)),
          if (_mode == 'Custom') ...[
            const SizedBox(height: 10),
            TextField(
              controller: _amount,
              inputFormatters: _decimal,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Custom payment amount *', hintText: 'Custom payment sum'),
            ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _rate,
                inputFormatters: _decimal,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Interest rate', suffixText: '%', hintText: '0.00'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _term,
                inputFormatters: _decimal,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Term', hintText: '0'),
              ),
            ),
          ]),
          const SectionLabel('Term unit'),
          ChoiceRow(options: financeTermUnits, value: _unit, onChanged: (u) => setState(() => _unit = u)),
          const SizedBox(height: 12),
          TextField(
            controller: _details,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Details', hintText: 'Provider, downpayment, monthly summary'),
          ),
          const SizedBox(height: 12),
          GatewayPickerField(
            value: _gateway,
            onChanged: (g) => setState(() => _gateway = g),
            label: 'Payment Gateway Account (if applicable)',
            helperText: 'Optional. Only set when this option is collected via a specific gateway account.',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
        ],
      );
}

// ===========================================================================
// Vehicle details (ev_vehicle_details)
// ===========================================================================

/// Picks an image and returns it as a `data:` URL, the format the Expo app
/// stores in `imageUri` / gallery lists.
Future<String?> _pickImageDataUrl(BuildContext context) async {
  try {
    final files = await FilePicker.pickFiles(type: FileType.image);
    final file = files.firstOrNull;
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final dot = file.name.lastIndexOf('.');
    final ext = dot < 0 ? 'jpeg' : file.name.substring(dot + 1).toLowerCase();
    final mime = switch (ext) { 'png' => 'image/png', 'webp' => 'image/webp', 'gif' => 'image/gif', _ => 'image/jpeg' };
    return 'data:$mime;base64,${base64Encode(bytes)}';
  } catch (e) {
    if (context.mounted) showError(context, 'Could not pick image.');
    return null;
  }
}

class EvVehicleDetailsScreen extends ConsumerWidget {
  const EvVehicleDetailsScreen({super.key});
  static const page = 'admin-settings-ev-vehicle-details';
  static const catKey = 'ev-vehicle-details';

  Future<void> _edit(BuildContext context, WidgetRef ref, List<Entry> all, [Entry? e]) async {
    final values = await showFormDialog<Map<String, dynamic>>(context, (_) => _VehicleDetailsForm(entry: e));
    if (values == null || !context.mounted) return;
    await _saveEntry(context, ref, catKey, values, id: e?.id, all: all);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _EntryListPage(
        categoryKey: catKey,
        page: page,
        title: 'EV Vehicle Details',
        addLabel: 'Add vehicle',
        searchHint: 'Search make or model',
        emptyTitle: 'No EV models yet',
        emptyMessage: 'Models, colours, pricing & accessories.',
        matches: (e, q) => '${e.values['make'] ?? ''} ${e.values['model'] ?? ''}'.toLowerCase().contains(q.trim().toLowerCase()),
        sort: (all) => all,
        onAdd: (all) => _edit(context, ref, all),
        rowBuilder: (context, e, sorted, i, canEdit) {
          final v = e.values;
          final exterior = enabledItems(v, 'exteriorColors').length;
          final features = enabledItems(v, 'features').length;
          final locked = v['isDefault'] == true;
          return Card(
            child: BusyListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: StoredImage('${v['imageUri'] ?? ''}', width: 64, height: 44),
              ),
              title: Text('${v['make'] ?? ''} ${v['model'] ?? ''}'),
              subtitle: Text('RM ${groupedNumber(toNum(v['price']))} • $exterior colours • $features features'
                  '${locked ? ' • Default (locked)' : ''}'),
              onTap: canEdit ? () => _edit(context, ref, sorted, e) : null,
              trailing: canEdit && !locked
                  ? _deleteButton(() => _deleteEntry(context, ref, catKey, e.id, 'Remove this vehicle?'))
                  : (locked ? const Tooltip(message: 'Default vehicles can be edited but not deleted.', child: Icon(Icons.lock_outline)) : null),
            ),
          );
        },
      );
}

class _VehicleDetailsForm extends StatefulWidget {
  const _VehicleDetailsForm({this.entry});
  final Entry? entry;

  @override
  State<_VehicleDetailsForm> createState() => _VehicleDetailsFormState();
}

class _VehicleDetailsFormState extends State<_VehicleDetailsForm> {
  late final VehicleDetailsForm _f =
      widget.entry == null ? VehicleDetailsForm() : VehicleDetailsForm.fromValues(widget.entry!.values);
  String? _error;

  Widget _galleryRow(String title, IconData icon, String key) {
    final limit = galleryLimits[key]!;
    final items = _f.gallery[key] ?? [];
    final slots = [for (var i = 0; i < limit; i++) i < items.length ? items[i] : ''];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(title, icon: icon, trailing: Text('${slots.where((s) => s.isNotEmpty).length}/$limit')),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (var i = 0; i < slots.length; i++)
          SizedBox(
            width: 96,
            height: 72,
            child: Stack(fit: StackFit.expand, children: [
              InkWell(
                onTap: () async {
                  final uri = await _pickImageDataUrl(context);
                  if (uri != null) setState(() => _f.setGallerySlot(key, i, uri));
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: slots[i].isEmpty
                      ? Container(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.add_photo_alternate_outlined),
                        )
                      : StoredImage(slots[i]),
                ),
              ),
              if (slots[i].isNotEmpty)
                Positioned(
                  right: 2,
                  top: 2,
                  child: IconButton.filledTonal(
                    visualDensity: VisualDensity.compact,
                    iconSize: 14,
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _f.setGallerySlot(key, i, '')),
                  ),
                ),
            ]),
          ),
      ]),
    ]);
  }

  Widget _itemsSection({
    required String title,
    required IconData icon,
    required List<Map<String, dynamic>> items,
    required Map<String, dynamic> Function() blank,
    required List<(String key, String label, bool numeric)> fields,
  }) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionLabel(title,
            icon: icon,
            trailing: TextButton.icon(
              onPressed: () => setState(() => items.add(blank())),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add'),
            )),
        if (items.isEmpty) Text('None added.', style: Theme.of(context).textTheme.bodySmall),
        for (final item in items)
          Card(
            key: ObjectKey(item),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Column(children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final f in fields)
                    SizedBox(
                      width: f.$3 ? 120 : 220,
                      child: TextFormField(
                        initialValue: '${item[f.$1] ?? ''}',
                        inputFormatters: f.$3 ? _decimal : null,
                        keyboardType: f.$3 ? const TextInputType.numberWithOptions(decimal: true) : null,
                        decoration: InputDecoration(labelText: f.$2, isDense: true),
                        onChanged: (v) => item[f.$1] = v,
                      ),
                    ),
                ]),
                Row(children: [
                  Switch(value: item['enabled'] != false, onChanged: (v) => setState(() => item['enabled'] = v)),
                  Text(item['enabled'] != false ? 'Enabled' : 'Disabled'),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => setState(() => items.remove(item))),
                ]),
              ]),
            ),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic> color() => {'id': newItemId(), 'name': '', 'code': '', 'enabled': true};
    Map<String, dynamic> priced() => {'id': newItemId(), 'name': '', 'price': '', 'enabled': true};
    return FormDialogScaffold(
      title: widget.entry == null ? 'Add Vehicle' : 'Edit Vehicle',
      error: _error,
      onSave: () {
        final r = buildVehicleDetailsValues(_f, existing: widget.entry?.values);
        if (r.error != null) return setState(() => _error = r.error);
        Navigator.pop(context, r.values);
      },
      children: [
        InkWell(
          onTap: () async {
            final uri = await _pickImageDataUrl(context);
            if (uri != null) setState(() => _f.imageUri = uri);
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: _f.imageUri.isEmpty
                  ? Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.add_photo_alternate_outlined, size: 32),
                        Text('Tap to upload image'),
                      ]),
                    )
                  : StoredImage(_f.imageUri),
            ),
          ),
        ),
        _galleryRow('Exterior Images (optional)', Icons.directions_car_outlined, 'exteriorImages'),
        _galleryRow('Interior Images (optional)', Icons.weekend_outlined, 'interiorImages'),
        _galleryRow('Storage Area Images (optional)', Icons.inventory_2_outlined, 'storageImages'),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: TextFormField(
              initialValue: _f.make,
              decoration: const InputDecoration(labelText: 'Make *', hintText: 'TEKSI'),
              onChanged: (v) => _f.make = v,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              initialValue: _f.model,
              decoration: const InputDecoration(labelText: 'Model *', hintText: 'EV One'),
              onChanged: (v) => _f.model = v,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: _f.price,
          inputFormatters: _decimal,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Price (RM)', hintText: '150000'),
          onChanged: (v) => _f.price = v,
        ),
        _itemsSection(
          title: 'Exterior Colours',
          icon: Icons.palette_outlined,
          items: _f.exteriorColors,
          blank: color,
          fields: const [('name', 'Colour name', false), ('code', '#hex', false)],
        ),
        _itemsSection(
          title: 'Interior Colours',
          icon: Icons.weekend_outlined,
          items: _f.interiorColors,
          blank: color,
          fields: const [('name', 'Colour name', false), ('code', '#hex', false)],
        ),
        _itemsSection(
          title: 'Taxes',
          icon: Icons.receipt_long_outlined,
          items: _f.taxes,
          blank: () => {'id': newItemId(), 'name': '', 'description': '', 'amount': '', 'enabled': true},
          fields: const [('name', 'Tax name (e.g. SST)', false), ('amount', 'Amount', true), ('description', 'Description', false)],
        ),
        _itemsSection(
          title: 'Add-on Features',
          icon: Icons.auto_awesome_outlined,
          items: _f.features,
          blank: priced,
          fields: const [('name', 'Feature name', false), ('price', 'Price', true)],
        ),
        _itemsSection(
          title: 'Optional Accessories',
          icon: Icons.shopping_bag_outlined,
          items: _f.accessories,
          blank: priced,
          fields: const [('name', 'Accessory name', false), ('price', 'Price', true)],
        ),
      ],
    );
  }
}

// ===========================================================================
// Vehicle inventory (ev_vehicle_inventory)
// ===========================================================================

class EvVehicleInventoryScreen extends ConsumerWidget {
  const EvVehicleInventoryScreen({super.key});
  static const page = 'admin-settings-ev-vehicle-inventory';
  static const catKey = 'ev-vehicle-inventory';

  Future<void> _edit(BuildContext context, WidgetRef ref, List<Entry> all, [Entry? e]) async {
    final vehicles = await ref.read(commerceEntriesProvider('ev-vehicle-details').future).catchError((Object err) {
      if (context.mounted) showError(context, err);
      return <Entry>[];
    });
    if (!context.mounted) return;
    final values = await showFormDialog<Map<String, dynamic>>(context, (_) => _InventoryForm(entry: e, vehicles: vehicles));
    if (values == null || !context.mounted) return;
    await _saveEntry(context, ref, catKey, values, id: e?.id, all: all);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicles = ref.watch(commerceEntriesProvider('ev-vehicle-details')).value ?? const <Entry>[];
    final byId = {for (final v in vehicles) v.id: v.values};
    String makeModel(Map<String, dynamic> v) {
      final veh = byId['${v['vehicleId'] ?? ''}'];
      return '${(veh ?? v)['make'] ?? ''} ${(veh ?? v)['model'] ?? ''}';
    }

    return _EntryListPage(
      categoryKey: catKey,
      page: page,
      title: 'EV Vehicle Inventory',
      addLabel: 'Add unit',
      searchHint: 'Search make, model or VIN',
      emptyTitle: 'No inventory units yet',
      emptyMessage: 'Available units ready for fast delivery.',
      matches: (e, q) => '${makeModel(e.values)} ${e.values['vin'] ?? ''}'.toLowerCase().contains(q.trim().toLowerCase()),
      sort: (all) => all,
      onAdd: (all) => _edit(context, ref, all),
      rowBuilder: (context, e, sorted, i, canEdit) {
        final v = e.values;
        final veh = byId['${v['vehicleId'] ?? ''}'];
        final ext = '${v['exteriorColor'] ?? ''}', intr = '${v['interiorColor'] ?? ''}';
        return Card(
          child: BusyListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: StoredImage('${veh?['imageUri'] ?? ''}', width: 64, height: 44),
            ),
            title: Text(makeModel(v)),
            subtitle: Text([
              'VIN ${'${v['vin'] ?? ''}'.isEmpty ? '—' : v['vin']}',
              [if (ext.isNotEmpty) 'Ext: $ext', if (intr.isNotEmpty) 'Int: $intr'].join('  •  '),
            ].where((s) => s.isNotEmpty).join('\n')),
            onTap: canEdit ? () => _edit(context, ref, sorted, e) : null,
            trailing: canEdit ? _deleteButton(() => _deleteEntry(context, ref, catKey, e.id, 'Remove this inventory unit?')) : null,
          ),
        );
      },
    );
  }
}

class _InventoryForm extends StatefulWidget {
  const _InventoryForm({this.entry, required this.vehicles});
  final Entry? entry;
  final List<Entry> vehicles;

  @override
  State<_InventoryForm> createState() => _InventoryFormState();
}

class _InventoryFormState extends State<_InventoryForm> {
  late final Map<String, dynamic> _v = widget.entry?.values ?? const {};
  late String _vehicleId = '${_v['vehicleId'] ?? ''}';
  late final _vin = TextEditingController(text: '${_v['vin'] ?? ''}');
  late final Map<String, List<String>> _ids = {
    for (final k in ['exteriorColorIds', 'interiorColorIds', 'featureIds', 'accessoryIds']) k: parseIdList(_v[k]),
  };
  String? _error;

  Map<String, dynamic>? get _vehicle => widget.vehicles.where((v) => v.id == _vehicleId).firstOrNull?.values;

  @override
  void dispose() {
    _vin.dispose();
    super.dispose();
  }

  Future<void> _pickVehicle() async {
    if (widget.vehicles.isEmpty) {
      showInfo(context, 'Add a vehicle in EV Vehicle Details first.');
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Select vehicle'), children: [
        for (final v in widget.vehicles)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, v.id),
            child: ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: StoredImage('${v.values['imageUri'] ?? ''}', width: 56, height: 40),
              ),
              title: Text('${v.values['make'] ?? ''} ${v.values['model'] ?? ''}'),
              subtitle: Text('RM ${groupedNumber(toNum(v.values['price']))}'),
              trailing: v.id == _vehicleId ? const Icon(Icons.check) : null,
            ),
          ),
      ]),
    );
    if (picked == null) return;
    setState(() {
      if (picked != _vehicleId) {
        for (final k in _ids.keys) {
          _ids[k] = [];
        }
      }
      _vehicleId = picked;
    });
  }

  Widget _chips(String title, IconData icon, String itemsKey, String idsKey, {bool priced = false}) {
    final items = enabledItems(_vehicle, itemsKey);
    final selected = _ids[idsKey]!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(title, icon: icon),
      if (items.isEmpty)
        Text(_vehicle == null ? 'Select a vehicle first.' : 'None available.', style: Theme.of(context).textTheme.bodySmall)
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in items)
            FilterChip(
              avatar: priced ? null : _swatch('${c['code'] ?? ''}'),
              label: Text(priced
                  ? '${c['name'] ?? ''}${toNum(c['price']) > 0 ? ' • RM ${groupedNumber(toNum(c['price']))}' : ''}'
                  : '${'${c['name'] ?? ''}'.isEmpty ? c['code'] : c['name']}'),
              selected: selected.contains('${c['id']}'),
              onSelected: (on) => setState(() {
                final id = '${c['id']}';
                on ? selected.add(id) : selected.remove(id);
              }),
            ),
        ]),
    ]);
  }

  Widget _swatch(String code) {
    final hex = code.replaceFirst('#', '');
    final value = int.tryParse(hex.length == 6 ? 'FF$hex' : hex, radix: 16);
    return CircleAvatar(
      radius: 8,
      backgroundColor: value == null ? Theme.of(context).colorScheme.outlineVariant : Color(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final veh = _vehicle;
    return FormDialogScaffold(
      title: widget.entry == null ? 'Add Inventory Unit' : 'Edit Inventory Unit',
      error: _error,
      onSave: () {
        final r = buildInventoryValues(
          vehicleId: _vehicleId,
          vehicle: veh,
          vin: _vin.text,
          exteriorColorIds: _ids['exteriorColorIds']!,
          interiorColorIds: _ids['interiorColorIds']!,
          featureIds: _ids['featureIds']!,
          accessoryIds: _ids['accessoryIds']!,
          existing: widget.entry?.values,
        );
        if (r.error != null) return setState(() => _error = r.error);
        Navigator.pop(context, r.values);
      },
      children: [
        InkWell(
          onTap: _pickVehicle,
          child: InputDecorator(
            decoration: const InputDecoration(labelText: 'Vehicle *', suffixIcon: Icon(Icons.arrow_drop_down)),
            child: veh == null
                ? const Text('Choose a vehicle from EV Vehicle Details')
                : Text('${veh['make'] ?? ''} ${veh['model'] ?? ''} · RM ${groupedNumber(toNum(veh['price']))}'),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _vin,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'VIN *', hintText: '1HGBH41JXMN109186', prefixIcon: Icon(Icons.tag)),
          onChanged: (t) {
            final up = t.toUpperCase();
            if (up != t) _vin.value = _vin.value.copyWith(text: up);
          },
        ),
        _chips('Exterior Colour', Icons.palette_outlined, 'exteriorColors', 'exteriorColorIds'),
        _chips('Interior Colour', Icons.weekend_outlined, 'interiorColors', 'interiorColorIds'),
        _chips('Add-on Features', Icons.auto_awesome_outlined, 'features', 'featureIds', priced: true),
        _chips('Optional Accessories', Icons.shopping_bag_outlined, 'accessories', 'accessoryIds', priced: true),
      ],
    );
  }
}
