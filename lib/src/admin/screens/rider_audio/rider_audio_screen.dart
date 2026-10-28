// Admin → Services & catalogue → Rider audio protection (migration 0315):
// whether riders may record their trips, and how long the phone keeps a
// recording, as a Default rule and a rule per country, state, city or
// suburb (the smallest place that sets a part decides it). Its own table
// (rider_audio_rules) and page id, so it can later sit under "City ride
// extras" as one card.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/partner_type_rules.dart' show RegionScope;
import '../../../core/rider_audio.dart';
import '../../../data/rider_audio_repository.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../admin_registry.dart' show AdminScreenEntry;
import '../../widgets/admin_widgets.dart';
import '../../widgets/region_scope_picker.dart' show pickRegionScope;
import '../city_to_city/c2c_widgets.dart' show C2cCardTitle, C2cStepper;

const riderAudioPath = '/admin/m/rider-audio';

final riderAudioRoutes = <RouteBase>[
  GoRoute(path: riderAudioPath, builder: (_, _) => const RiderAudioScreen()),
];

const riderAudioEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'Rider audio protection',
    subtitle: 'Whether riders may record their trips, and how long the phone keeps it, by region',
    path: riderAudioPath,
    pages: [riderAudioPage],
    icon: Icons.mic_none,
  ),
];

/// The next value up or down: by the hour to a day, then by six hours.
int stepKeepHours(int h, {required bool up}) {
  final step = (up ? h >= 24 : h > 24) ? 6 : 1;
  return clampKeepHours(up ? h + step : h - step);
}

class RiderAudioScreen extends ConsumerStatefulWidget {
  const RiderAudioScreen({super.key});

  @override
  ConsumerState<RiderAudioScreen> createState() => _RiderAudioScreenState();
}

class _RiderAudioScreenState extends ConsumerState<RiderAudioScreen> {
  List<RiderAudioRule>? _loaded;
  List<RiderAudioRule>? _draft;
  final _removed = <String>{};

  String _sig(List<RiderAudioRule> l) => [for (final r in l) '${r.id}|${r.scope.key}|${r.enabled}|${r.keepHours}'].join(';');

  bool get _changed => _draft != null && _loaded != null && (_sig(_draft!) != _sig(_loaded!) || _removed.isNotEmpty);

  void _set(int i, RiderAudioRule r) => setState(() => _draft![i] = r);

  Future<void> _add() async {
    final scope = await pickRegionScope(context, title: 'Rule for');
    if (scope == null || scope.isAll || !mounted) return;
    if (_draft!.any((r) => r.scope.key == scope.key)) {
      showError(context, 'There is already a rule for ${scope.label}.');
      return;
    }
    setState(() => _draft!.add(RiderAudioRule(scope: scope)));
  }

  void _remove(int i) => setState(() {
    final id = _draft![i].id;
    if (id != null) _removed.add(id);
    _draft!.removeAt(i);
  });

  Future<void> _save() async {
    final draft = _draft!;
    final before = {for (final r in _loaded!) r.id: r};
    final repo = ref.read(riderAudioRepositoryProvider);
    final ok = await runAdminAction(context, () async {
      for (final id in _removed) {
        await repo.deleteRule(id);
      }
      for (final r in draft) {
        final was = before[r.id];
        if (r.id == null || was == null || _sig([was]) != _sig([r])) await repo.saveRule(r);
      }
    }, success: 'Rider audio protection saved');
    if (ok && mounted) {
      setState(() {
        _removed.clear();
        _loaded = null;
        _draft = null;
      });
      ref.invalidate(riderAudioRulesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(riderAudioPage)) == AccessLevel.edit;
    final async = ref.watch(riderAudioRulesProvider);
    return AdminPage(
      title: 'Rider audio protection',
      page: riderAudioPage,
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(riderAudioRulesProvider),
        data: (stored) {
          if (_loaded == null || (!_changed && _sig(_loaded!) != _sig(stored.rules))) {
            _loaded = [...stored.rules];
            final def = stored.defaultRule;
            _draft = [def, ...stored.regionRules];
          }
          final draft = _draft!;
          final rules = RiderAudioRules(draft);
          final t = Theme.of(context);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(
                    'Riders turn audio protection on themselves (it is off until they do). While their ride is '
                    'under way their phone records the trip, keeps it encrypted for the hours set here, and never '
                    'plays it back. Support can request it on a ticket or the ride\'s page, and the driver sees '
                    '"$riderAudioDriverLine". A region rule only changes what it sets; the smallest place that '
                    'sets a part decides it.',
                    style: t.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  for (var i = 0; i < draft.length; i++)
                    _RuleCard(
                      key: ValueKey('rider-audio-rule-${draft[i].scope.key}'),
                      rule: draft[i],
                      inherited: draft[i].isDefault ? null : rules.at(_parentOf(draft[i].scope)),
                      onChanged: canEdit ? (r) => _set(i, r) : null,
                      onRemove: canEdit && !draft[i].isDefault ? () => _remove(i) : null,
                    ),
                  if (canEdit) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('rider-audio-add'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                        onPressed: _add,
                        icon: const Icon(Icons.add_location_alt_outlined),
                        label: const Text('Add a region rule'),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            _changed ? 'Not saved yet.' : 'Saved.',
                            key: const ValueKey('rider-audio-state'),
                            style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                          ),
                        ),
                        FilledButton.icon(
                          key: const ValueKey('rider-audio-save'),
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                          onPressed: _changed ? _save : null,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Save'),
                        ),
                      ]),
                    ),
                  ],
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The place above [s] (Default above a country).
  static RegionScope _parentOf(RegionScope s) {
    final p = s.path;
    return RegionScope(
      country: p.length > 1 ? p[0] : '',
      state: p.length > 2 ? p[1] : '',
      city: p.length > 3 ? p[2] : '',
    );
  }
}

/// One place's rule: on / off and the hours, each set here or left to the
/// place above ([inherited]; null for Default, which sets both).
class _RuleCard extends StatelessWidget {
  const _RuleCard({super.key, required this.rule, required this.inherited, this.onChanged, this.onRemove});

  final RiderAudioRule rule;
  final RiderAudioAt? inherited;
  final ValueChanged<RiderAudioRule>? onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final on = onChanged;
    final t = Theme.of(context);
    final isDefault = rule.isDefault;
    final above = inherited;
    final enabled = rule.enabled ?? above?.enabled ?? true;
    final hours = rule.keepHours ?? above?.keepHours ?? riderAudioDefaultHours;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: C2cCardTitle(
                isDefault ? Icons.public : Icons.location_on_outlined,
                isDefault ? 'Default (everywhere)' : rule.scope.label,
              ),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: 'Remove the rule for ${rule.scope.label}',
                icon: const Icon(Icons.delete_outline),
                onPressed: onRemove,
              ),
          ]),
          SwitchListTile(
            key: const ValueKey('rider-audio-on'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Riders may turn it on'),
            subtitle: Text(
              isDefault || rule.enabled != null
                  ? (enabled ? 'On: the switch is on the booking sheet' : 'Off: not offered here')
                  : 'As the place above (${enabled ? 'on' : 'off'})',
            ),
            value: enabled,
            onChanged: on == null ? null : (v) => on(rule.copyWith(enabled: () => v)),
          ),
          if (!isDefault && rule.enabled != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('rider-audio-on-inherit'),
                onPressed: on == null ? null : () => on(rule.copyWith(enabled: () => null)),
                child: const Text('Use the place above'),
              ),
            ),
          C2cStepper(
            label: 'Kept on the phone for',
            hint: isDefault || rule.keepHours != null ? 'Then deleted from the phone' : 'As the place above',
            value: keepHoursLabel(hours),
            valueKey: const ValueKey('rider-audio-hours'),
            onDown: on == null || hours <= riderAudioMinHours
                ? null
                : () => on(rule.copyWith(keepHours: () => stepKeepHours(hours, up: false))),
            onUp: on == null || hours >= riderAudioMaxHours
                ? null
                : () => on(rule.copyWith(keepHours: () => stepKeepHours(hours, up: true))),
          ),
          if (!isDefault && rule.keepHours != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('rider-audio-hours-inherit'),
                onPressed: on == null ? null : () => on(rule.copyWith(keepHours: () => null)),
                child: const Text('Use the place above'),
              ),
            ),
          Text(
            'Like the driver\'s VoiceProtection: never played in the app; support can request it on a report.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}
