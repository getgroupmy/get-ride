import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/partner_type_rules.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../screens/geo/geo_data.dart' show regionsProvider;
import '../screens/geo/geo_logic.dart' show RegionEntry, RegionLevel, regionNamesAt;

/// Country, then state, city and suburb, each picked from Admin → Country /
/// States / Cities / Suburbs (the regions tables, as tariffs, commission
/// promotions and promo codes pick theirs), with a search box on long lists.
/// A level shows once the one above is picked and has places under it.
class RegionScopePicker extends ConsumerWidget {
  const RegionScopePicker({super.key, required this.value, required this.onChanged, this.keyPrefix = 'region'});

  final RegionScope value;
  final ValueChanged<RegionScope> onChanged;
  final String keyPrefix;

  static const _any = '';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final picked = [value.country, value.state, value.city, value.suburb];
    const names = ['country', 'state', 'city', 'suburb'];
    final fields = <Widget>[];
    for (var i = 0; i < 4; i++) {
      if (i > 0 && picked[i - 1].isEmpty) break;
      final options = regionNamesAt(
        regions,
        RegionLevel.values[i],
        country: value.country,
        state: value.state,
        city: value.city,
      );
      final current = picked[i];
      // A stored name no longer on the list is still shown.
      final all = [...options, if (current.isNotEmpty && !options.any((o) => o.toLowerCase() == current.toLowerCase())) current];
      if (all.isEmpty) break;
      final selected = all.firstWhere((o) => o.toLowerCase() == current.toLowerCase(), orElse: () => _any);
      final label = names[i][0].toUpperCase() + names[i].substring(1);
      fields.add(Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
        child: SearchableDropdownFormField<String>(
          key: ValueKey('$keyPrefix-${names[i]}-${picked.take(i).join('/')}'),
          isExpanded: true,
          initialValue: selected,
          decoration: InputDecoration(labelText: label),
          items: [
            DropdownMenuItem(
              value: _any,
              child: Text(i == 0 ? 'Choose a country' : 'All of ${picked[i - 1]}'),
            ),
            for (final o in all) DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) {
            final next = [...picked];
            next[i] = v ?? _any;
            // A new pick clears the levels under it.
            for (var j = i + 1; j < 4; j++) {
              next[j] = '';
            }
            onChanged(RegionScope(country: next[0], state: next[1], city: next[2], suburb: next[3]));
          },
        ),
      ));
    }
    if (fields.isEmpty) {
      fields.add(const Text('No regions yet. Add countries in Admin, under Country / States / Cities.'));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: fields);
  }
}

/// Asks for one region. [allowAll] offers "All regions" (an age rule may
/// apply everywhere; a region list has its own All switch). Null: cancelled.
Future<RegionScope?> pickRegionScope(
  BuildContext context, {
  required String title,
  RegionScope initial = RegionScope.all,
  bool allowAll = false,
}) =>
    showAppDialog<RegionScope>(
      id: 'region-scope.pick',
      context: context,
      builder: (_) => _RegionScopeDialog(title: title, initial: initial, allowAll: allowAll),
    );

class _RegionScopeDialog extends StatefulWidget {
  const _RegionScopeDialog({required this.title, required this.initial, required this.allowAll});
  final String title;
  final RegionScope initial;
  final bool allowAll;

  @override
  State<_RegionScopeDialog> createState() => _RegionScopeDialogState();
}

class _RegionScopeDialogState extends State<_RegionScopeDialog> {
  late RegionScope _scope = widget.initial;
  late bool _all = widget.allowAll && widget.initial.isAll;

  @override
  Widget build(BuildContext context) {
    final ready = _all || !_scope.isAll;
    return AlertDialog(
      key: const ValueKey('region-scope-dialog'),
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.allowAll)
              SwitchListTile(
                key: const ValueKey('region-scope-all'),
                contentPadding: EdgeInsets.zero,
                title: const Text('All regions'),
                value: _all,
                onChanged: (v) => setState(() => _all = v),
              ),
            if (!_all) RegionScopePicker(value: _scope, onChanged: (s) => setState(() => _scope = s)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('region-scope-ok'),
          onPressed: ready ? () => Navigator.pop(context, _all ? RegionScope.all : _scope) : null,
          child: const Text('Use this region'),
        ),
      ],
    );
  }
}
