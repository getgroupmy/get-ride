// Rider tags on the driver rating, admin side (migration 0297):
// - App Settings → Driver rating tags: the two tag lists riders pick from
//   (4-5 stars, 1-3 stars) and the low-rating flag rule (the same 1-3 star
//   tag picked N times within D days).
// - Partners → a driver: the tag totals and any flag, with Mark reviewed.
// Flags are for admins only; the driver sees their totals, never a flag.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ride_rating.dart';
import '../../data/ride_rating_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../widgets/admin_widgets.dart';

Color _goodInk(ThemeData t) => t.brightness == Brightness.dark ? const Color(0xFF5FD3A5) : const Color(0xFF0B7A55);
Color _lowInk(ThemeData t) => t.brightness == Brightness.dark ? const Color(0xFFF2A86B) : const Color(0xFF9A4A00);

/// App Settings → Driver rating tags: the lists and the flag rule.
class DriverRatingTagsCard extends ConsumerStatefulWidget {
  const DriverRatingTagsCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<DriverRatingTagsCard> createState() => _DriverRatingTagsCardState();
}

class _DriverRatingTagsCardState extends ConsumerState<DriverRatingTagsCard> {
  DriverRatingTags? _loadedTags;
  List<String> _high = [], _low = [];
  DriverFlagRule? _loadedRule;
  DriverFlagRule _rule = const DriverFlagRule();

  void _loadTags(DriverRatingTags t) {
    if (identical(_loadedTags, t)) return;
    _loadedTags = t;
    _high = [...t.high];
    _low = [...t.low];
  }

  void _loadRule(DriverFlagRule r) {
    if (identical(_loadedRule, r)) return;
    _loadedRule = r;
    _rule = r;
  }

  bool get _tagsChanged =>
      _loadedTags != null && (!_same(_high, _loadedTags!.high) || !_same(_low, _loadedTags!.low));

  static bool _same(List<String> a, List<String> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  Future<void> _add(bool low) async {
    final list = low ? _low : _high;
    final tag = await showAppDialog<String>(
      id: 'admin.driver-rating-tag-add',
      context: context,
      builder: (_) => _AddTagDialog(low: low, taken: [..._high, ..._low]),
    );
    if (tag == null || !mounted) return;
    setState(() => list.add(tag));
  }

  Future<void> _saveTags() async {
    if (_high.isEmpty || _low.isEmpty) {
      showInfo(context, 'Keep at least one tag in each list.');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(driverRatingAdminRepositoryProvider).setTags(DriverRatingTags(high: _high, low: _low)),
      success: 'Rating tags saved',
    );
    if (ok && mounted) {
      ref.invalidate(adminDriverRatingTagsProvider);
      ref.invalidate(driverRatingTagsProvider);
    }
  }

  Future<void> _saveRule() async {
    final ok = await runAdminAction(
      context,
      () => ref.read(driverRatingAdminRepositoryProvider).setRule(_rule),
      success: 'Flag rule saved',
    );
    if (ok && mounted) {
      ref.invalidate(adminDriverFlagRuleProvider);
      ref.invalidate(adminRatingFlagsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    return Card(
      key: const ValueKey('driver-rating-tags-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Driver rating tags', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'Riders pick from the 4–5 star list or the 1–3 star list after rating their driver. Changes reach '
              'every app straight away. A removed tag keeps its past totals. Drivers see totals only, never who.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            AsyncView<DriverRatingTags>(
              value: ref.watch(adminDriverRatingTagsProvider),
              onRetry: () => ref.invalidate(adminDriverRatingTagsProvider),
              data: (tags) {
                _loadTags(tags);
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _list('4–5 stars', _high, low: false),
                  const SizedBox(height: 12),
                  _list('1–3 stars', _low, low: true),
                  if (widget.canEdit) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: BusyButton.filled(
                        key: const ValueKey('driver-rating-tags-save'),
                        onPressed: _tagsChanged ? _saveTags : null,
                        icon: const Icon(Icons.save_outlined),
                        child: const Text('Save tags'),
                      ),
                    ),
                  ],
                ]);
              },
            ),
            const Divider(height: 32),
            Text('Low-rating flag', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            AsyncView<DriverFlagRule>(
              value: ref.watch(adminDriverFlagRuleProvider),
              onRetry: () => ref.invalidate(adminDriverFlagRuleProvider),
              data: (rule) {
                _loadRule(rule);
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      const Text('Flag a driver when the same 1–3 star tag is picked'),
                      _Stepper(
                        keyName: 'times',
                        value: _rule.times,
                        less: 'Fewer times',
                        more: 'More times',
                        onLess: widget.canEdit && _rule.times > DriverFlagRule.timesMin
                            ? () => setState(() => _rule = _rule.copyWith(times: _rule.times - 1))
                            : null,
                        onMore: widget.canEdit && _rule.times < DriverFlagRule.timesMax
                            ? () => setState(() => _rule = _rule.copyWith(times: _rule.times + 1))
                            : null,
                      ),
                      const Text('times within'),
                      _Stepper(
                        keyName: 'days',
                        value: _rule.days,
                        less: 'Fewer days',
                        more: 'More days',
                        onLess: widget.canEdit && _rule.days > DriverFlagRule.daysMin
                            ? () => setState(() => _rule = _rule.copyWith(days: _rule.days - 1))
                            : null,
                        onMore: widget.canEdit && _rule.days < DriverFlagRule.daysMax
                            ? () => setState(() => _rule = _rule.copyWith(days: _rule.days + 1))
                            : null,
                      ),
                      const Text('days.'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.visibility_off_outlined, size: 16, color: muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Flags show only here in admin: on the driver in Partners and on the Partners list. '
                        'The driver is not told.',
                        style: t.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ),
                  ]),
                  if (widget.canEdit) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: BusyButton.filled(
                        key: const ValueKey('driver-flag-rule-save'),
                        onPressed: _rule == rule ? null : _saveRule,
                        icon: const Icon(Icons.save_outlined),
                        child: const Text('Save flag rule'),
                      ),
                    ),
                  ],
                ]);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(String title, List<String> tags, {required bool low}) {
    final t = Theme.of(context);
    final ink = low ? _lowInk(t) : _goodInk(t);
    final key = low ? 'low' : 'high';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final tag in tags)
          InputChip(
            key: ValueKey('driver-rating-tag-$key-$tag'),
            label: Text(tag),
            labelStyle: TextStyle(color: ink),
            side: BorderSide(color: ink.withValues(alpha: 0.5)),
            onDeleted: widget.canEdit ? () => setState(() => tags.remove(tag)) : null,
            deleteButtonTooltipMessage: 'Remove $tag',
            deleteIconColor: ink,
          ),
        if (widget.canEdit && tags.length < driverRatingTagsMax)
          OutlinedButton.icon(
            key: ValueKey('driver-rating-tag-add-$key'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => _add(low),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add tag'),
          ),
      ]),
    ]);
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.keyName,
    required this.value,
    required this.less,
    required this.more,
    required this.onLess,
    required this.onMore,
  });
  final String keyName;
  final int value;
  final String less, more;
  final VoidCallback? onLess, onMore;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    IconButton.outlined(
      key: ValueKey('driver-flag-$keyName-less'),
      tooltip: less,
      onPressed: onLess,
      icon: const Icon(Icons.remove),
    ),
    SizedBox(
      width: 36,
      child: Text(
        '$value',
        key: ValueKey('driver-flag-$keyName'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    IconButton.outlined(
      key: ValueKey('driver-flag-$keyName-more'),
      tooltip: more,
      onPressed: onMore,
      icon: const Icon(Icons.add),
    ),
  ]);
}

class _AddTagDialog extends StatefulWidget {
  const _AddTagDialog({required this.low, required this.taken});
  final bool low;
  final List<String> taken;

  @override
  State<_AddTagDialog> createState() => _AddTagDialogState();
}

class _AddTagDialogState extends State<_AddTagDialog> {
  final _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() {
    final problem = driverTagProblem(_text.text, widget.taken);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, _text.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.low ? 'Add a 1–3 star tag' : 'Add a 4–5 star tag'),
    content: TextField(
      key: const ValueKey('driver-rating-tag-new'),
      controller: _text,
      autofocus: true,
      maxLength: driverRatingTagLengthMax,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(labelText: 'Tag', errorText: _error),
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      onSubmitted: (_) => _done(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(key: const ValueKey('driver-rating-tag-new-add'), onPressed: _done, child: const Text('Add')),
    ],
  );
}

/// Partners → a driver: any flag (with Mark reviewed) and the tag totals.
/// [partnerUserId] is the partner's sign-in id (partners.auth_user_id).
class DriverRatingPanel extends ConsumerWidget {
  const DriverRatingPanel({super.key, required this.partnerUserId, required this.canEdit});
  final String partnerUserId;
  final bool canEdit;

  Future<void> _review(BuildContext context, WidgetRef ref, String tag) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(driverRatingAdminRepositoryProvider).markReviewed(partnerUserId, tag),
      success: 'Marked reviewed. "$tag" is counted afresh from now.',
    );
    if (ok) {
      ref.invalidate(adminDriverTagsProvider(partnerUserId));
      ref.invalidate(adminRatingFlagsProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final data = ref.watch(adminDriverTagsProvider(partnerUserId));
    // A database before 0297, or a read-only failure: the sheet stays as it was.
    final d = data.value;
    if (d == null) {
      return data.isLoading ? const LinearProgressIndicator() : const SizedBox.shrink();
    }
    final dark = t.brightness == Brightness.dark;
    final flagBg = dark ? const Color(0xFF4A2A10) : const Color(0xFFFDEEDD);
    final flagInk = dark ? const Color(0xFFFFD2A8) : const Color(0xFF6B3300);
    final okBg = dark ? const Color(0xFF103A2A) : const Color(0xFFE1F3EB);
    final okInk = dark ? const Color(0xFFA8E8CC) : const Color(0xFF075E41);
    final tags = [...d.totals.tags]..sort((a, b) => a.low == b.low ? b.n.compareTo(a.n) : (a.low ? 1 : -1));
    return Column(
      key: const ValueKey('driver-rating-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        for (final f in d.flags)
          Container(
            key: ValueKey('driver-flag-${f.tag}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: flagBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: flagInk.withValues(alpha: 0.35)),
            ),
            child: Semantics(
              liveRegion: true,
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.flag_outlined, color: flagInk),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: 'Flagged: ${f.tag}. ', style: const TextStyle(fontWeight: FontWeight.w700)),
                          TextSpan(text: driverFlagText(f, d.rule)),
                        ]),
                        style: t.textTheme.bodyMedium?.copyWith(color: flagInk),
                      ),
                    ),
                  ]),
                  if (canEdit)
                    BusyButton.filled(
                      key: ValueKey('driver-flag-review-${f.tag}'),
                      style: FilledButton.styleFrom(backgroundColor: flagInk, foregroundColor: flagBg),
                      onPressed: () => _review(context, ref, f.tag),
                      child: const Text('Mark reviewed'),
                    ),
                ],
              ),
            ),
          ),
        if (d.flags.isEmpty)
          Container(
            key: const ValueKey('driver-not-flagged'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: okBg, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.check_circle_outline, color: okInk),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Not flagged: no 1–3 star tag reached ${d.rule.times} in ${d.rule.days} days.',
                  style: t.textTheme.bodyMedium?.copyWith(color: okInk),
                ),
              ),
            ]),
          ),
        const SizedBox(height: 12),
        Text('Tags from riders · ${d.rule.days} days',
            style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        if (tags.isEmpty)
          Text('No tags yet.', style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)))
        else
          for (final c in tags)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(c.low ? Icons.thumb_down_outlined : Icons.thumb_up_outlined,
                    size: 16, color: c.low ? _lowInk(t) : _goodInk(t)),
                const SizedBox(width: 8),
                Expanded(child: Text(c.tag)),
                Text('${c.n}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
        Text(
          'From ${d.totals.rated} rated trip${d.totals.rated == 1 ? '' : 's'}.',
          style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
        ),
      ],
    );
  }
}
