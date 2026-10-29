// Admin › Settings › Public holidays (migration 0328): the dates a weekly
// or monthly hire skips (where its settings say so), for one country or
// every country. Added with the date in boxes, searched when the list is long.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/hourly_hire_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/search_select.dart';
import '../widgets/admin_widgets.dart';

class PublicHolidaysCard extends ConsumerStatefulWidget {
  const PublicHolidaysCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<PublicHolidaysCard> createState() => _PublicHolidaysCardState();
}

class _PublicHolidaysCardState extends ConsumerState<PublicHolidaysCard> {
  final _day = TextEditingController();
  final _name = TextEditingController();
  final _country = TextEditingController();

  @override
  void dispose() {
    for (final c in [_day, _name, _country]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _add() async {
    final day = parseIsoDate(_day.text.trim());
    final name = _name.text.trim();
    if (day == null || name.isEmpty || name.length > 80) {
      showInfo(context, 'Give the date and the holiday\'s name (up to 80 characters).');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(hourlyHireRepositoryProvider).addHoliday(day, name, country: _country.text),
      success: 'Holiday added',
    );
    if (ok && mounted) {
      setState(() {
        _day.clear();
        _name.clear();
      });
      ref.invalidate(publicHolidaysProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('public-holidays-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Public holidays', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(
            'Weekly and monthly hires skip these days where their settings say so: no trip that day, and it '
            'isn\'t charged. Leave the country empty for every country.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: ref.watch(publicHolidaysProvider),
            onRetry: () => ref.invalidate(publicHolidaysProvider),
            data: (all) => all.isEmpty
                ? Text('No public holidays yet.', style: t.textTheme.bodyMedium)
                : ListSearchFilter(
                    count: all.length,
                    hint: 'Search holidays',
                    fieldKey: const ValueKey('public-holidays-search'),
                    builder: (context, query) {
                      final q = query.toLowerCase();
                      return Column(children: [
                        for (final h in all)
                          if (q.isEmpty ||
                              '${h.name} ${h.country} ${formatDateForUser(h.day)}'.toLowerCase().contains(q))
                            ListTile(
                              key: ValueKey('public-holiday-${h.id}'),
                              contentPadding: EdgeInsets.zero,
                              title: Text(h.name),
                              subtitle: Text(
                                '${formatDateForUser(h.day)} · ${h.country.isEmpty ? 'Every country' : h.country}',
                              ),
                              trailing: widget.canEdit
                                  ? IconButton(
                                      tooltip: 'Remove ${h.name}',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () async {
                                        if (await runAdminAction(context,
                                            () => ref.read(hourlyHireRepositoryProvider).removeHoliday(h.id))) {
                                          ref.invalidate(publicHolidaysProvider);
                                        }
                                      },
                                    )
                                  : null,
                            ),
                      ]);
                    },
                  ),
          ),
          if (widget.canEdit) ...[
            const SizedBox(height: 12),
            DateBoxesField(
              key: const ValueKey('public-holiday-day'),
              label: 'Date',
              controller: _day,
              firstDate: DateTime(DateTime.now().year - 1),
              lastDate: DateTime(DateTime.now().year + 5, 12, 31),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 16, runSpacing: 8, children: [
              SizedBox(
                width: 240,
                child: TextField(
                  key: const ValueKey('public-holiday-name'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Holiday', helperText: 'Such as Hari Merdeka'),
                ),
              ),
              SizedBox(
                width: 240,
                child: TextField(
                  key: const ValueKey('public-holiday-country'),
                  controller: _country,
                  decoration: const InputDecoration(labelText: 'Country', helperText: 'Empty: every country'),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: BusyButton.filled(
                key: const ValueKey('public-holiday-add'),
                onPressed: _add,
                icon: const Icon(Icons.add),
                child: const Text('Add holiday'),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
