import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../widgets/common.dart';
import '../../admin_settings_models.dart';
import '../../widgets/admin_widgets.dart';
import 'catalogue_data.dart';
import 'catalogue_logic.dart';
import 'catalogue_widgets.dart';

const _listPage = 'admin-settings-assign-service';
const _detailPage = 'admin-settings-assign-service-page';

const _deviceNote = 'Assignments are stored on this device only (as in the Expo app), '
    'so each admin device keeps its own mapping.';

class AssignServiceScreen extends ConsumerStatefulWidget {
  const AssignServiceScreen({super.key});

  @override
  ConsumerState<AssignServiceScreen> createState() => _AssignServiceScreenState();
}

class _AssignServiceScreenState extends ConsumerState<AssignServiceScreen> {
  String _query = '';

  Future<void> _pickDocument(String featureId, String label, Map<String, String> sources) async {
    List<SettingEntry> docs;
    try {
      docs = (await ref.read(catalogueEntriesProvider(requiredDocumentsCategory).future))
          .where((d) => d.values['active'] != false)
          .toList()
        ..sort((a, b) => str(a.values['name']).compareTo(str(b.values['name'])));
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final current = sources[featureId];
    final picked = await showAdminSheet<({String? id})>(
      context,
      title: 'Choose document for $label',
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('The selected document’s uploaded image will be used as the data source.'),
        const SizedBox(height: 12),
        if (docs.isEmpty) const Text('No active required documents. Add them in Required Documents first.'),
        if (current != null)
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('Clear current selection'),
            onTap: () => Navigator.pop(ctx, (id: null)),
          ),
        for (final d in docs)
          ListTile(
            leading: Icon(d.id == current ? Icons.check_circle : Icons.description_outlined),
            title: Text(str(d.values['name']).isEmpty ? 'Untitled document' : str(d.values['name'])),
            subtitle: str(d.values['description']).isEmpty ? null : Text(str(d.values['description'])),
            selected: d.id == current,
            onTap: () => Navigator.pop(ctx, (id: d.id)),
          ),
      ]),
    );
    if (picked == null || !mounted) return;
    await runAdminAction(context, () => AssignmentStore.setDocSource(featureId, picked.id));
    ref.invalidate(documentSourcesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, _listPage);
    final assignments = ref.watch(assignmentsProvider);
    final sources = ref.watch(documentSourcesProvider).value ?? const <String, String>{};
    final docs = ref.watch(catalogueEntriesProvider(requiredDocumentsCategory)).value ?? const <SettingEntry>[];
    String? docLabel(String? id) {
      final e = docs.where((d) => d.id == id).firstOrNull;
      return e == null ? null : (str(e.values['name']).isEmpty ? 'Untitled document' : str(e.values['name']));
    }

    return AdminPage(
      title: 'Assign Service',
      page: _listPage,
      body: AsyncView(
        value: assignments,
        onRetry: () => ref.invalidate(assignmentsProvider),
        data: (map) {
          final totals = assignmentTotals(map);
          final pages = filterMappingPages(_query);
          return ResponsiveCenter(
            maxWidth: 820,
            child: ListView(padding: const EdgeInsets.only(top: 12, bottom: 32), children: [
              Text('${mappingPages.length} pages · ${totals.assigned}/${totals.total} assigned',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Each page below requires one or more mapping capabilities. Tap a page to assign a '
                      'provider service to each capability it uses.\n$_deviceNote'),
                ),
              ),
              CatalogueSearch(hint: 'Search pages...', onChanged: (v) => setState(() => _query = v)),
              const SectionLabel('Document sources'),
              for (final f in documentSourceFeatures)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: Text(f.label),
                    subtitle: Text(
                        '${f.description}\n${docLabel(sources[f.id]) != null ? 'Source: ${docLabel(sources[f.id])}' : 'No document selected'}'),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: canEdit ? () => _pickDocument(f.id, f.label, sources) : null,
                  ),
                ),
              const SectionLabel('Pages'),
              if (pages.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_query.isEmpty ? 'No pages.' : 'No pages match "$_query".', textAlign: TextAlign.center),
                ),
              for (final p in pages)
                Builder(builder: (_) {
                  final assigned = p.capabilities.where((c) => map[p.id]?[c] != null).length;
                  final total = p.capabilities.length;
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.place_outlined),
                      title: Text(p.label),
                      subtitle: Text('${p.description}\n${p.route}'),
                      isThreeLine: true,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        StatusChip(assigned == total ? 'Completed' : '$assigned/$total assigned'),
                        const Icon(Icons.chevron_right),
                      ]),
                      onTap: () async {
                        await context.push(Uri(path: '/admin/m/assign-service-page', queryParameters: {'id': p.id}).toString());
                        ref.invalidate(assignmentsProvider);
                      },
                    ),
                  );
                }),
            ]),
          );
        },
      ),
    );
  }
}

class AssignServicePageScreen extends ConsumerWidget {
  const AssignServicePageScreen({super.key, required this.pageId});
  final String pageId;

  Future<void> _pick(BuildContext context, WidgetRef ref, MappingPage page, String cap, AssignmentsMap map,
      List<ApiProviderInfo> providers) async {
    final current = map[page.id]?[cap];
    final picked = await showAdminSheet<({String providerId, String serviceId})>(
      context,
      title: 'Assign for ${capabilityLabels[cap] ?? cap}',
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (providers.isEmpty) const Text('No providers configured. Add providers in API Keys first.'),
        for (final prov in providers) ...[
          SectionLabel('${prov.name}${prov.category.isNotEmpty ? ' · ${prov.category}' : ''}'),
          if (prov.services.isEmpty) const Text('No services in this provider.'),
          for (final s in prov.services)
            Builder(builder: (_) {
              final selected = current?['providerId'] == prov.id && current?['serviceId'] == s.id;
              return ListTile(
                dense: true,
                selected: selected,
                leading: Icon(selected ? Icons.check_circle : Icons.layers_outlined),
                title: Text(s.name),
                subtitle: Text([
                  if (s.description.isNotEmpty) s.description,
                  '${s.keyCount} key${s.keyCount == 1 ? '' : 's'}',
                ].join('\n')),
                onTap: () => Navigator.pop(ctx, (providerId: prov.id, serviceId: s.id)),
              );
            }),
        ],
      ]),
    );
    if (picked == null || !context.mounted) return;
    await _write(context, ref, page.id, cap, picked);
  }

  Future<void> _write(BuildContext context, WidgetRef ref, String pageId, String cap,
      ({String providerId, String serviceId})? a) async {
    await runAdminAction(context, () async {
      final map = await AssignmentStore.load();
      await AssignmentStore.save(setAssignment(map, pageId, cap, a));
    });
    ref.invalidate(assignmentsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = mappingPages.where((p) => p.id == pageId).firstOrNull;
    if (page == null) {
      return const AdminPage(
        title: 'Assign Service',
        page: _detailPage,
        body: EmptyState(icon: Icons.link_off, title: 'Page not found'),
      );
    }
    final canEdit = canEditPage(ref, _detailPage) || canEditPage(ref, _listPage);
    final assignments = ref.watch(assignmentsProvider);
    final providers = ref.watch(apiProvidersProvider);
    return AdminPage(
      title: page.label,
      page: _detailPage,
      body: AsyncView(
        value: assignments,
        onRetry: () => ref.invalidate(assignmentsProvider),
        data: (map) {
          final provs = providers.value ?? const <ApiProviderInfo>[];
          return ResponsiveCenter(
            maxWidth: 720,
            child: ListView(padding: const EdgeInsets.only(top: 12, bottom: 32), children: [
              Text(page.route, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Assign a provider service to each capability this page needs. Failures rotate keys '
                      'within the chosen service automatically.\n$_deviceNote'),
                ),
              ),
              if (providers.hasError)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('Could not load providers: ${errorText(providers.error!)}'),
                ),
              for (final cap in page.capabilities)
                Builder(builder: (_) {
                  final a = map[page.id]?[cap];
                  final prov = provs.where((p) => p.id == a?['providerId']).firstOrNull;
                  final svc = prov?.services.where((s) => s.id == a?['serviceId']).firstOrNull;
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.link),
                      title: Text(capabilityLabels[cap] ?? cap),
                      subtitle: Text(a == null
                          ? 'Tap to assign provider service'
                          : prov != null && svc != null
                              ? '${prov.name} · ${svc.name}\n${svc.keyCount} key${svc.keyCount == 1 ? '' : 's'}'
                              : '${a['providerId']} · ${a['serviceId']}'),
                      onTap: canEdit && providers.hasValue ? () => _pick(context, ref, page, cap, map, provs) : null,
                      trailing: a != null && canEdit
                          ? IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close),
                              onPressed: () => _write(context, ref, page.id, cap, null),
                            )
                          : null,
                    ),
                  );
                }),
            ]),
          );
        },
      ),
    );
  }
}
