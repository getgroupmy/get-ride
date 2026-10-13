// Admin → App Settings → Backend network: extra addresses the app may reach
// the backend on, and the DNS-over-HTTPS resolvers it asks when the phone's
// own DNS cannot look any of them up (core/backend_network.dart). Saved on
// its own, so a database without migration 0171 only fails this card.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config.dart';
import '../../../core/backend_network.dart';
import '../../../core/backend_route.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import 'branding_screens.dart';

class BackendNetworkCard extends ConsumerStatefulWidget {
  const BackendNetworkCard({super.key, required this.stored, required this.canEdit});

  /// What is saved now.
  final BackendNetwork stored;
  final bool canEdit;

  @override
  ConsumerState<BackendNetworkCard> createState() => _BackendNetworkCardState();
}

class _BackendNetworkCardState extends ConsumerState<BackendNetworkCard> {
  late final _backends = TextEditingController(text: networkListText(widget.stored.backends));
  late final _doh = TextEditingController(text: networkListText(widget.stored.dohResolvers));
  late BackendNetwork _adopted = widget.stored;
  late List<BackendRouteRow> _routes = backendRouteRows(widget.stored.order);

  List<BackendRouteLevel> get _order => backendRouteOrderOf(_routes);

  @override
  void didUpdateWidget(BackendNetworkCard old) {
    super.didUpdateWidget(old);
    // Another admin saved while this card had no unsaved edits: show theirs.
    final unedited =
        _backends.text == networkListText(_adopted.backends) &&
        _doh.text == networkListText(_adopted.dohResolvers) &&
        BackendNetwork(order: _order) == BackendNetwork(order: _adopted.order);
    if (widget.stored != _adopted && unedited) {
      _adopted = widget.stored;
      _backends.text = networkListText(widget.stored.backends);
      _doh.text = networkListText(widget.stored.dohResolvers);
      _routes = backendRouteRows(widget.stored.order);
    }
  }

  @override
  void dispose() {
    _backends.dispose();
    _doh.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final order = _order;
    final err = validateBackendNetwork(_backends.text, _doh.text, AppConfig.supabaseUrl, order: order);
    if (err != null) {
      showError(context, err);
      return;
    }
    final patch = backendNetworkPatch(_backends.text, _doh.text, order: order);
    final ok = await runAdminAction(context, () async {
      try {
        await ref.read(brandingStoreProvider).update({'network': patch});
      } catch (e) {
        if ('$e'.contains('network')) {
          throw 'This database has no Backend network setting yet: run migration 0171 first.';
        }
        rethrow;
      }
    }, success: 'Saved — phones use it from their next launch');
    if (!mounted || !ok) return;
    setState(() => _adopted = BackendNetwork.fromJson(patch));
    ref.invalidate(brandingProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Backend network', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'For networks whose DNS cannot find the server. Each launch, the app tries the routes below in '
              'the order set here, using the phone\'s DNS. If none is found it asks the DNS-over-HTTPS '
              'resolvers and connects to the address they give (still checking the server\'s certificate). '
              'Phones pick changes up from the launch after they last connected.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            Text('Fallback order at launch', style: t.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              'Tried top to bottom with the phone\'s DNS; the first that resolves is used. If none does, the same '
              'routes are asked of the DNS-over-HTTPS resolvers, in the same order. A route switched off is not '
              'tried at all.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            for (final (i, r) in _routes.indexed)
              _RouteRow(
                key: ValueKey('backend-route-${r.level.key}'),
                position: r.on ? '${_routes.take(i + 1).where((x) => x.on).length}' : '–',
                row: r,
                enabled: widget.canEdit,
                isFirst: i == 0,
                isLast: i == _routes.length - 1,
                onToggle: (on) => setState(() => _routes = [
                  for (final x in _routes) x.level == r.level ? (level: x.level, on: on) : x,
                ]),
                onMove: (by) => setState(() => _routes = moveBackendRouteRow(_routes, i, by)),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('backend-network-backends'),
              controller: _backends,
              enabled: widget.canEdit,
              minLines: 2,
              maxLines: 5,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Extra backend addresses (one per line)',
                hintText: 'https://api2.$backendAllowedDomain',
                helperText:
                    'Must be under $backendAllowedDomain and pass traffic to the backend. Up to '
                    '$backendNetworkMaxEntries.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('backend-network-doh'),
              controller: _doh,
              enabled: widget.canEdit,
              minLines: 2,
              maxLines: 5,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'DNS-over-HTTPS resolvers (one per line)',
                hintText: defaultDohResolvers.join('\n'),
                helperText:
                    'JSON API resolvers, best addressed by IP. Blank uses Cloudflare (1.1.1.1) and '
                    'Google (8.8.8.8).',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This phone: ${backendRouteText(AppConfig.supabaseUrl)}',
              key: const ValueKey('backend-network-now'),
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            if (widget.canEdit) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: BusyButton.filled(
                  key: const ValueKey('backend-network-save'),
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  child: const Text('Save backend network'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One route in the Fallback order list: on/off, its place, and arrows to
/// move it up or down.
class _RouteRow extends StatelessWidget {
  const _RouteRow({
    super.key,
    required this.position,
    required this.row,
    required this.enabled,
    required this.isFirst,
    required this.isLast,
    required this.onToggle,
    required this.onMove,
  });

  final String position;
  final BackendRouteRow row;
  final bool enabled;
  final bool isFirst;
  final bool isLast;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        SizedBox(
          width: 20,
          child: Text(position, textAlign: TextAlign.center, style: t.textTheme.labelLarge?.copyWith(color: muted)),
        ),
        Checkbox(
          key: const ValueKey('on'),
          value: row.on,
          onChanged: enabled ? (v) => onToggle(v ?? false) : null,
        ),
        Expanded(
          child: Text(
            row.level.label,
            style: row.on ? null : TextStyle(color: muted, decoration: TextDecoration.lineThrough),
          ),
        ),
        IconButton(
          key: const ValueKey('up'),
          tooltip: 'Move up',
          icon: const Icon(Icons.arrow_upward),
          onPressed: enabled && !isFirst ? () => onMove(-1) : null,
        ),
        IconButton(
          key: const ValueKey('down'),
          tooltip: 'Move down',
          icon: const Icon(Icons.arrow_downward),
          onPressed: enabled && !isLast ? () => onMove(1) : null,
        ),
      ],
    );
  }
}
