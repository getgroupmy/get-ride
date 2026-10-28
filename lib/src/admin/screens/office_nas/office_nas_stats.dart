// Admin › Settings › Office NAS › Visitor stats (migration 0321,
// deploy/nas-stats): today's visitors, install page views, top page and top
// source on getride.my and qr.getride.my, read from Umami on the NAS by the
// nas-stats function (key in API Keys › Umami). "NAS off" when it can't be
// reached; nothing else depends on it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/office_nas_stats.dart';
import '../../../data/office_nas_stats_repository.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import '../catalogue/catalogue_widgets.dart' show canEditPage;
import '../../../core/office_nas.dart' show officeNasPage;

final officeNasStatsConfigProvider = FutureProvider.autoDispose<NasStatsSettings>(
  (ref) => ref.watch(officeNasStatsRepositoryProvider).config(),
);

final officeNasStatsTodayProvider = FutureProvider.autoDispose<VisitorStats>(
  (ref) => ref.watch(officeNasStatsRepositoryProvider).today(),
);

class OfficeNasStatsTab extends ConsumerStatefulWidget {
  const OfficeNasStatsTab({super.key});

  @override
  ConsumerState<OfficeNasStatsTab> createState() => _OfficeNasStatsTabState();
}

class _OfficeNasStatsTabState extends ConsumerState<OfficeNasStatsTab> {
  final _website = TextEditingController();
  String? _websiteError;
  NasStatsSettings? _settings;
  bool _filled = false;

  @override
  void dispose() {
    _website.dispose();
    super.dispose();
  }

  OfficeNasStatsRepository get _repo => ref.read(officeNasStatsRepositoryProvider);

  Future<void> _save(NasStatsSettings next) async {
    late NasStatsSettings stored;
    final ok = await runAdminAction(context, () async => stored = await _repo.save(next));
    if (!ok || !mounted) return;
    setState(() => _settings = stored);
    ref.invalidate(officeNasStatsTodayProvider);
  }

  Future<void> _saveWebsite(NasStatsSettings s) async {
    final v = _website.text.trim().toLowerCase();
    if (v.isNotEmpty && !NasStatsSettings.validWebsiteId(v)) {
      setState(() => _websiteError = 'The ID Umami shows: 8-4-4-4-12 letters and digits');
      return;
    }
    setState(() => _websiteError = null);
    await _save(v.isEmpty ? s.copyWith(clearWebsite: true) : s.copyWith(websiteId: v));
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, officeNasPage);
    final t = Theme.of(context);
    return AsyncView(
      value: ref.watch(officeNasStatsConfigProvider),
      onRetry: () => ref.invalidate(officeNasStatsConfigProvider),
      data: (loaded) {
        final s = _settings ?? loaded;
        if (!_filled) {
          _filled = true;
          _website.text = s.websiteId ?? '';
        }
        final stats = ref.watch(officeNasStatsTodayProvider);
        final v = stats.value;
        final today = v?.state == StatsState.on ? v!.today : null;
        String n(int? x) => x == null ? '–' : groupedNumber(x);
        return ResponsiveCenter(
          maxWidth: 900,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(child: Text('Today', style: t.textTheme.titleMedium)),
                  if (v?.at != null)
                    Text('Checked ${DateFormat('HH:mm').format(v!.at!)}', style: t.textTheme.bodySmall),
                  IconButton(
                    key: const ValueKey('stats-reload'),
                    tooltip: 'Check again',
                    icon: const Icon(Icons.refresh),
                    onPressed: stats.isLoading ? null : () => ref.invalidate(officeNasStatsTodayProvider),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, c) {
                  final cols = c.maxWidth >= 640 ? 4 : 2;
                  final w = (c.maxWidth - 12 * (cols - 1)) / cols;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _Tile('Visitors today', n(today?.visitors), width: w, tileKey: 'stats-visitors'),
                      _Tile('Install page views', n(today?.installViews), width: w, tileKey: 'stats-install'),
                      _Tile('Top page', today?.topPage ?? '–', width: w, small: true, tileKey: 'stats-top-page'),
                      _Tile('Top source', today?.topSource ?? '–', width: w, small: true, tileKey: 'stats-top-source'),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              if (stats.isLoading && v == null)
                const LinearProgressIndicator()
              else if (v != null)
                Row(
                  children: [
                    Icon(
                      v.state == StatsState.on ? Icons.check_circle_outline : Icons.cloud_off_outlined,
                      size: 18,
                      color: v.state == StatsState.on ? t.colorScheme.primary : t.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        v.state == StatsState.on && today != null
                            ? 'Counting. ${groupedNumber(today.pageviews)} page views in ${groupedNumber(today.visits)} visits.'
                            : statsStateText(v),
                        key: const ValueKey('stats-state'),
                        style: t.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 16),
              Card(
                key: const ValueKey('stats-settings'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SwitchListTile(
                        key: const ValueKey('stats-on'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Show the stats here'),
                        subtitle: const Text('Off: this page stops asking the NAS.'),
                        value: s.on,
                        onChanged: canEdit ? (on) => _save(s.copyWith(on: on)) : null,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const ValueKey('stats-website'),
                              controller: _website,
                              enabled: canEdit,
                              decoration: InputDecoration(
                                labelText: 'Umami website ID',
                                hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
                                errorText: _websiteError,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            // The app's buttons are full width; this one sits by the box.
                            child: SizedBox(
                              width: 104,
                              child: FilledButton(
                                key: const ValueKey('stats-website-save'),
                                onPressed: canEdit ? () => _saveWebsite(s) : null,
                                child: const Text('Save'),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'The key is in API Keys, Umami. The site sends visits only when its build has the stats script '
                        '(STATS_SCRIPT_URL and STATS_WEBSITE_ID). Setup: deploy/nas-stats/README.md.',
                        style: t.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "Umami on the NAS for getride.my and qr.getride.my: no cookies, no personal data, no banner needed. If "
                "the NAS is off, visits just aren't counted.",
                style: t.textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {required this.width, required this.tileKey, this.small = false});
  final String label;
  final String value;
  final double width;
  final String tileKey;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      key: ValueKey(tileKey),
      width: width,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (small ? t.textTheme.titleMedium : t.textTheme.headlineSmall)?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
