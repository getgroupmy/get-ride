// Dispatch > Telematics (migration 0255): a fleet owner's fleet vehicles and
// the drivers in them; a stand's orders for its stand admin (and staff who
// may see reports). The server holds each to that (telematics_access).
import 'package:flutter/material.dart';

import '../../data/dispatch_repository.dart';
import '../../data/telematics_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/search_select.dart';
import '../telematics/telematics_scope_view.dart';

/// What the person may look at: each fleet they own, each stand they run
/// or see reports of.
List<TelematicsScope> telematicsScopesFor(DispatchRoles r) => [
  for (final f in r.fleets) TelematicsScope.fleet(f.id, f.name),
  for (final s in r.stands)
    if (s.isStandAdmin || s.perms.reports) TelematicsScope.stand(s.id, s.shortName),
];

class DispatchTelematicsTab extends StatefulWidget {
  const DispatchTelematicsTab({super.key, required this.scopes});

  final List<TelematicsScope> scopes;

  @override
  State<DispatchTelematicsTab> createState() => _DispatchTelematicsTabState();
}

class _DispatchTelematicsTabState extends State<DispatchTelematicsTab> {
  int _at = 0;

  @override
  Widget build(BuildContext context) {
    final scopes = widget.scopes;
    if (scopes.isEmpty) {
      return const EmptyState(icon: Icons.speed_outlined, title: 'Nothing to show');
    }
    final at = _at.clamp(0, scopes.length - 1);
    final scope = scopes[at];
    String name(TelematicsScope s) => s.kind == 'fleet' ? 'Fleet: ${s.name}' : 'Stand: ${s.name}';
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
      children: [
        ResponsiveCenter(
          maxWidth: 1100,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (scopes.length > 1) ...[
                SearchableDropdownFormField<int>(
                  key: const ValueKey('telematics-scope'),
                  isExpanded: true,
                  initialValue: at,
                  decoration: const InputDecoration(labelText: 'Show', isDense: true),
                  items: [
                    for (var i = 0; i < scopes.length; i++) DropdownMenuItem(value: i, child: Text(name(scopes[i]))),
                  ],
                  onChanged: (i) => setState(() => _at = i ?? 0),
                ),
                const SizedBox(height: 12),
              ],
              TelematicsScopeView(key: ValueKey('${scope.kind}-${scope.id}'), scope: scope),
            ],
          ),
        ),
      ],
    );
  }
}
