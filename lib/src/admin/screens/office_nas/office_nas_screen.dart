// Admin > Settings > Office NAS: one page for every service on the office
// NAS, a tab each (one file per tab in this folder). get.ride keeps working
// when the NAS is off: everything here is a fallback or a side job. The
// status in the corner is the NAS's newest check-in (nas_services, 0318).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/office_nas.dart';
import '../../../data/office_nas_repository.dart';
import '../../widgets/admin_widgets.dart';
import 'office_nas_backups.dart';
import 'office_nas_overview.dart';
import 'office_nas_uptime.dart';

/// One tab of the page.
class OfficeNasTab {
  const OfficeNasTab(this.id, this.label, this.builder);

  /// In the address: `/admin/m/office-nas?tab=<id>`.
  final String id;
  final String label;
  final WidgetBuilder builder;
}

/// The tabs, in order (the mockup's: Overview, Backups, Maps, Uptime, ID and
/// face, Test database, Visitor stats; each batch adds its own).
final officeNasTabs = <OfficeNasTab>[
  OfficeNasTab('overview', 'Overview', (_) => const OfficeNasOverview()),
  OfficeNasTab('backups', 'Backups', (_) => const OfficeNasBackups()),
  OfficeNasTab('uptime', 'Uptime', (_) => const OfficeNasUptime()),
];

class OfficeNasScreen extends ConsumerStatefulWidget {
  const OfficeNasScreen({super.key, this.initialTab});
  final String? initialTab;

  @override
  ConsumerState<OfficeNasScreen> createState() => _OfficeNasScreenState();
}

class _OfficeNasScreenState extends ConsumerState<OfficeNasScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The NAS checks in every minute: keep its status and the runs fresh.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) ref.invalidate(officeNasProvider);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = officeNasTabs.indexWhere((t) => t.id == widget.initialTab);
    final nas = ref.watch(officeNasProvider).value;
    return DefaultTabController(
      length: officeNasTabs.length,
      initialIndex: start < 0 ? 0 : start,
      child: AdminPage(
        title: 'Office NAS',
        page: officeNasPage,
        actions: [if (nas != null) Padding(padding: const EdgeInsets.only(right: 12), child: NasOnlineChip(nas))],
        bottom: TabBar(
          key: const ValueKey('office-nas-tabs'),
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final t in officeNasTabs) Tab(key: ValueKey('office-nas-tab-${t.id}'), text: t.label)],
        ),
        body: TabBarView(children: [for (final t in officeNasTabs) t.builder(context)]),
      ),
    );
  }
}
