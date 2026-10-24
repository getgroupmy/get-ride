// Admin › Dispatch › Partner selfie checks (migration 0290): when a partner
// going online on a phone takes a live selfie (a new phone always; random
// with its chance and daily cap), what counts as a low match, who gets the
// push on one, and how long the partner has to answer. The watch list
// (partners checked more often) is a page of its own.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/online_selfie.dart';
import '../../../data/online_selfie_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';

/// The page key of Dispatch › Partner selfie checks and the watch list.
const dispatchSelfiePage = 'admin-dispatch-selfie-checks';

final onlineSelfieConfigProvider = FutureProvider.autoDispose<OnlineSelfieConfig>(
  (ref) => ref.watch(onlineSelfieRepositoryProvider).config(),
);

/// Every admin and sub-admin, for "Selected admins".
final onlineSelfieAdminsProvider = FutureProvider.autoDispose<List<({String id, String name})>>(
  (ref) => ref.watch(onlineSelfieRepositoryProvider).admins(),
);

class SelfieChecksSettingsTab extends ConsumerWidget {
  const SelfieChecksSettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(onlineSelfieConfigProvider),
    onRetry: () => ref.invalidate(onlineSelfieConfigProvider),
    data: (c) => SelfieChecksSettingsForm(
      key: ValueKey(c),
      initial: c,
      canEdit: (ref.watch(adminAccessProvider).value ?? AdminAccess.none).canEdit([dispatchSelfiePage]),
    ),
  );
}

class SelfieChecksSettingsForm extends ConsumerStatefulWidget {
  const SelfieChecksSettingsForm({super.key, required this.initial, required this.canEdit});
  final OnlineSelfieConfig initial;
  final bool canEdit;

  @override
  ConsumerState<SelfieChecksSettingsForm> createState() => _SelfieChecksSettingsFormState();
}

class _SelfieChecksSettingsFormState extends ConsumerState<SelfieChecksSettingsForm> {
  late OnlineSelfieConfig _c = widget.initial;
  late final _pct = TextEditingController(text: '${widget.initial.randomPct}');
  late final _low = TextEditingController(text: '${widget.initial.lowBelow}');
  bool _saving = false;

  @override
  void dispose() {
    _pct.dispose();
    _low.dispose();
    super.dispose();
  }

  OnlineSelfieConfig get _edited =>
      _c.copyWith(randomPct: int.tryParse(_pct.text.trim()) ?? -1, lowBelow: int.tryParse(_low.text.trim()) ?? -1);

  Future<void> _addAdmin(List<({String id, String name})> admins) async {
    final id = await showSearchPicker<String>(
      context,
      title: 'Send the alert to',
      choices: [
        for (final a in admins)
          if (!_c.alertAdmins.contains(a.id)) (value: a.id, label: a.name, subtitle: null, leading: null),
      ],
    );
    if (id != null && mounted) setState(() => _c = _c.copyWith(alertAdmins: [..._c.alertAdmins, id]));
  }

  Future<void> _save() async {
    final c = _edited;
    final problem = c.problem;
    if (problem != null) return showNotice(context, title: "Can't save yet", message: problem);
    setState(() => _saving = true);
    try {
      final saved = await ref.read(onlineSelfieRepositoryProvider).setConfig(c);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _c = saved;
      });
      await showNotice(context, title: 'Saved', message: 'Partner selfie checks are updated.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      await showErrorNotice(context, e, title: "Couldn't save");
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final on = widget.canEdit;
    final admins = ref.watch(onlineSelfieAdminsProvider).value ?? const <({String id, String name})>[];
    final names = {for (final a in admins) a.id: a.name};
    Widget tag(String s, {Key? key}) => DecoratedBox(
      key: key,
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        child: Text(s, style: t.textTheme.labelMedium),
      ),
    );
    return ListView(
      key: const ValueKey('selfie-settings'),
      padding: const EdgeInsets.all(16),
      children: [
        ResponsiveCenter(
          maxWidth: 720,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "When a partner goes online on a phone, they may be asked for a live selfie. It is compared with "
                "their approved profile photo and their ID photo. The live check (blink or turn) is required; there "
                "is no photo from a file. They always go online once the selfie is taken. The web and desktops are "
                "never asked.",
                style: muted,
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.phonelink_lock),
                        title: const Text('On a new phone (mobile only)'),
                        trailing: tag('Always', key: const ValueKey('selfie-new-phone')),
                      ),
                      SwitchListTile(
                        key: const ValueKey('selfie-random'),
                        secondary: const Icon(Icons.casino_outlined),
                        title: const Text('Random check when going online'),
                        value: _c.randomOn,
                        onChanged: on ? (v) => setState(() => _c = _c.copyWith(randomOn: v)) : null,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            SizedBox(
                              width: 220,
                              child: TextFormField(
                                key: const ValueKey('selfie-random-pct'),
                                controller: _pct,
                                enabled: on && _c.randomOn,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Chance on each go-online',
                                  suffixText: '%',
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 220,
                              child: SearchableDropdownFormField<int>(
                                key: const ValueKey('selfie-random-cap'),
                                isExpanded: true,
                                initialValue: randomCapChoices.contains(_c.randomCap) ? _c.randomCap : null,
                                decoration: const InputDecoration(labelText: 'At most'),
                                items: [
                                  for (final n in randomCapChoices)
                                    DropdownMenuItem(value: n, child: Text(perDayText(n))),
                                ],
                                onChanged: on && _c.randomOn
                                    ? (v) => setState(() => _c = _c.copyWith(randomCap: v ?? _c.randomCap))
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('The result', style: t.textTheme.titleSmall),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: 220,
                        child: TextFormField(
                          key: const ValueKey('selfie-low-below'),
                          controller: _low,
                          enabled: on,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Low match below', suffixText: '%'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Expanded(child: Text('On a low match')),
                          Flexible(child: tag('Goes online · push alert sent')),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text('Send the alert to', style: t.textTheme.bodyMedium),
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SegmentedButton<AlertTo>(
                          key: const ValueKey('selfie-alert-to'),
                          segments: [
                            for (final a in AlertTo.values)
                              ButtonSegment(
                                value: a,
                                label: Text(a.label, key: ValueKey('selfie-alert-${a.value}')),
                              ),
                          ],
                          selected: {_c.alertTo},
                          onSelectionChanged: on ? (s) => setState(() => _c = _c.copyWith(alertTo: s.first)) : null,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(_c.alertTo.help, style: muted),
                      if (_c.alertTo == AlertTo.selected) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final id in _c.alertAdmins)
                              InputChip(
                                key: ValueKey('selfie-admin-$id'),
                                label: Text(names[id] ?? 'Admin'),
                                onDeleted: on
                                    ? () =>
                                          setState(() => _c = _c.copyWith(alertAdmins: [..._c.alertAdmins]..remove(id)))
                                    : null,
                              ),
                            if (on)
                              ActionChip(
                                key: const ValueKey('selfie-admin-add'),
                                avatar: const Icon(Icons.add, size: 18),
                                label: const Text('Add admin'),
                                onPressed: () => _addAdmin(admins),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: 320,
                        child: SearchableDropdownFormField<int>(
                          key: const ValueKey('selfie-answer'),
                          isExpanded: true,
                          initialValue: answerSecondsChoices.contains(_c.answerSeconds) ? _c.answerSeconds : null,
                          decoration: const InputDecoration(labelText: 'Time to answer'),
                          items: [
                            for (final s in answerSecondsChoices)
                              DropdownMenuItem(value: s, child: Text('${answerTimeText(s)}, then stays offline')),
                          ],
                          onChanged: on
                              ? (v) => setState(() => _c = _c.copyWith(answerSeconds: v ?? _c.answerSeconds))
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (on)
                    FilledButton.icon(
                      key: const ValueKey('selfie-save'),
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(_saving ? 'Saving…' : 'Save'),
                    ),
                  OutlinedButton.icon(
                    key: const ValueKey('selfie-watch-list'),
                    onPressed: () => context.push('/admin/m/selfie-watch-list'),
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('Watch list'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Every check is listed in Admin › Documents › Sign-in checks, low matches first.', style: muted),
            ],
          ),
        ),
      ],
    );
  }
}
