// Admin → SMS / WhatsApp (migration 0120): which signed-in device carries
// each channel, each way — OTP, marketing blasts, support calls and support
// messages, inbound and outbound — plus the devices that can carry them and
// the SMS queue.
//
// SMS go out through a phone running the GET.ride Gateway app (its SIM);
// WhatsApp through the Business Cloud API number; a support call is the
// in-app VoIP call, and its devices are the ones that ring or call.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/messaging.dart';
import '../../data/live_tables.dart';
import '../../data/messaging_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';

const messagingPage = 'admin-settings-messaging';

/// The latest GET.ride Gateway APK, published by .github/workflows/gateway.yml.
const gatewayApkUrl = 'https://github.com/getgroupmy/get-ride/releases/download/gateway-latest/getride-gateway.apk';

final _devicesProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('messaging_devices');
  return ref.watch(messagingRepositoryProvider).devices();
});
final _routesProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('messaging_routes');
  return ref.watch(messagingRepositoryProvider).routes();
});
final _outboxProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('sms_outbox');
  return ref.watch(messagingRepositoryProvider).recentOutbox();
});
final _inboxProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('sms_inbox');
  return ref.watch(messagingRepositoryProvider).recentInbox();
});

/// The clock, for "online" and "seen … ago"; a provider so tests can fix it.
final messagingClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

class AdminMessagingScreen extends ConsumerWidget {
  const AdminMessagingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit =
        ref.watch(pageAccessProvider(messagingPage)) == AccessLevel.edit ||
        ref.watch(moduleAccessProvider('messaging')) == AccessLevel.edit;
    final devices = ref.watch(_devicesProvider);
    final routes = ref.watch(_routesProvider);
    final t = Theme.of(context);
    return AdminPage(
      title: 'SMS / WhatsApp',
      page: messagingPage,
      body: AsyncView(
        value: devices,
        onRetry: () => ref.invalidate(_devicesProvider),
        data: (deviceList) => AsyncView(
          value: routes,
          onRetry: () => ref.invalidate(_routesProvider),
          data: (routeList) => ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              ResponsiveCenter(
                maxWidth: 880,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.info_outline),
                            title: const Text('Which device carries each channel'),
                            subtitle: Text(
                              'SMS go out through a phone running the GET.ride Gateway app, from its SIM. '
                              'WhatsApp goes through your WhatsApp Business (Cloud API) number. Support calls '
                              'are in-app VoIP calls: pick the devices that ring for them.',
                              style: t.textTheme.bodySmall,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                key: const ValueKey('messaging-gateway-download'),
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('Download the Gateway app (Android)'),
                                onPressed: () =>
                                    launchUrl(Uri.parse(gatewayApkUrl), mode: LaunchMode.externalApplication),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final c in MessagingChannel.values)
                      _ChannelCard(
                        channel: c,
                        routes: messagingRouteTable(routeList).where((r) => r.channel == c).toList(),
                        devices: deviceList,
                        canEdit: canEdit,
                      ),
                    const SizedBox(height: 16),
                    _DevicesCard(devices: deviceList, canEdit: canEdit),
                    const SizedBox(height: 16),
                    _QueueCard(canEdit: canEdit),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One channel: its inbound and outbound routes.
class _ChannelCard extends StatelessWidget {
  const _ChannelCard({required this.channel, required this.routes, required this.devices, required this.canEdit});
  final MessagingChannel channel;
  final List<MessagingRoute> routes;
  final List<MessagingDevice> devices;
  final bool canEdit;

  IconData get _icon => switch (channel) {
    MessagingChannel.otp => Icons.password,
    MessagingChannel.marketing => Icons.campaign_outlined,
    MessagingChannel.supportCall => Icons.call_outlined,
    MessagingChannel.supportMessage => Icons.chat_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: ValueKey('messaging-channel-${channel.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_icon, color: t.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(channel.label, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      Text(channel.description, style: t.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            for (final r in routes) _RouteEditor(route: r, devices: devices, canEdit: canEdit),
          ],
        ),
      ),
    );
  }
}

/// One channel, one way: on/off, the transport, and the devices or number.
class _RouteEditor extends ConsumerStatefulWidget {
  const _RouteEditor({required this.route, required this.devices, required this.canEdit});
  final MessagingRoute route;
  final List<MessagingDevice> devices;
  final bool canEdit;

  @override
  ConsumerState<_RouteEditor> createState() => _RouteEditorState();
}

class _RouteEditorState extends ConsumerState<_RouteEditor> {
  late MessagingRoute _r = widget.route;
  late final _number = TextEditingController(text: widget.route.whatsappNumber ?? '');
  bool _dirty = false;

  @override
  void didUpdateWidget(_RouteEditor old) {
    super.didUpdateWidget(old);
    // A live change from elsewhere, while nothing here is unsaved.
    if (!_dirty) {
      _r = widget.route;
      _number.text = widget.route.whatsappNumber ?? '';
    }
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _change(MessagingRoute r) => setState(() {
    _r = r;
    _dirty = true;
  });

  Future<void> _save() async {
    final r = _r.copyWith(whatsappNumber: () => _number.text);
    final problem = messagingRouteProblem(r, widget.devices);
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(messagingRepositoryProvider).saveRoute(r),
      success: '${r.channel.label} ${r.direction.label.toLowerCase()} saved',
    );
    if (ok && mounted) setState(() => _dirty = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final now = ref.watch(messagingClockProvider)();
    final r = _r;
    final usable = devicesFor(r.transport, widget.devices);
    final edit = widget.canEdit;
    return Padding(
      key: ValueKey('messaging-route-${r.channel.id}-${r.direction.id}'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                r.direction == MessagingDirection.inbound ? Icons.call_received : Icons.call_made,
                size: 18,
                color: t.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                r.direction.label.toUpperCase(),
                style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.8),
              ),
              const Spacer(),
              if (r.channel.transports.length > 1)
                SegmentedButton<MessagingTransport>(
                  key: ValueKey('messaging-transport-${r.channel.id}-${r.direction.id}'),
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: [for (final tr in r.channel.transports) ButtonSegment(value: tr, label: Text(tr.label))],
                  selected: {r.transport},
                  onSelectionChanged: edit ? (v) => _change(r.copyWith(transport: v.first)) : null,
                ),
              const SizedBox(width: 8),
              Switch(
                key: ValueKey('messaging-enabled-${r.channel.id}-${r.direction.id}'),
                value: r.enabled,
                onChanged: edit ? (v) => _change(r.copyWith(enabled: v)) : null,
              ),
            ],
          ),
          if (r.enabled) ...[
            const SizedBox(height: 6),
            if (r.transport == MessagingTransport.whatsapp)
              TextField(
                key: ValueKey('messaging-number-${r.channel.id}-${r.direction.id}'),
                controller: _number,
                enabled: edit,
                keyboardType: TextInputType.phone,
                onChanged: (_) => setState(() => _dirty = true),
                decoration: const InputDecoration(
                  labelText: 'WhatsApp Business number',
                  hintText: '+60 12 345 6789',
                  isDense: true,
                ),
              )
            else if (usable.isEmpty)
              Text(
                r.transport == MessagingTransport.sms
                    ? 'No gateway phone yet. Install the GET.ride Gateway app on an Android phone with a SIM '
                          'and sign in with an admin account; it then appears here.'
                    : 'No device yet. A device appears here once an admin signs in to the app on it.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final d in usable)
                    FilterChip(
                      key: ValueKey('messaging-device-${r.channel.id}-${r.direction.id}-${d.id}'),
                      avatar: Icon(
                        Icons.circle,
                        size: 10,
                        color: d.onlineAt(now) ? Colors.green : t.colorScheme.outline,
                      ),
                      label: Text(d.title),
                      tooltip: deviceSeenLabel(d, now),
                      selected: r.deviceIds.contains(d.id),
                      onSelected: edit
                          ? (on) => _change(
                              r.copyWith(
                                deviceIds: on ? [...r.deviceIds, d.id] : r.deviceIds.where((x) => x != d.id).toList(),
                              ),
                            )
                          : null,
                    ),
                ],
              ),
            if (r.transport == MessagingTransport.sms && r.deviceIds.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'The first online phone sends; the others take over when it is offline.',
                  style: t.textTheme.bodySmall,
                ),
              ),
            if (r.transport == MessagingTransport.voip && r.direction == MessagingDirection.inbound)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Every device picked rings; the first to answer takes the call.',
                  style: t.textTheme.bodySmall,
                ),
              ),
          ],
          if (edit && _dirty)
            Align(
              alignment: Alignment.centerRight,
              child: BusyButton.text(
                key: ValueKey('messaging-save-${r.channel.id}-${r.direction.id}'),
                icon: const Icon(Icons.save_outlined),
                onPressed: _save,
                child: const Text('Save'),
              ),
            ),
          const Divider(height: 20),
        ],
      ),
    );
  }
}

/// The devices that can carry a channel.
class _DevicesCard extends ConsumerWidget {
  const _DevicesCard({required this.devices, required this.canEdit});
  final List<MessagingDevice> devices;
  final bool canEdit;

  Future<void> _rename(BuildContext context, WidgetRef ref, MessagingDevice d) async {
    final c = TextEditingController(text: d.label ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (x) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(hintText: 'e.g. Office gateway (Maxis)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(x, true), child: const Text('Save')),
        ],
      ),
    );
    final label = c.text;
    c.dispose();
    if (ok != true || !context.mounted) return;
    await runAdminAction(context, () => ref.read(messagingRepositoryProvider).renameDevice(d.id, label));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final now = ref.watch(messagingClockProvider)();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Devices', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text(
              'Phones with the GET.ride Gateway app, and admins\' app installs. Each says it is here every minute.',
              style: t.textTheme.bodySmall,
            ),
            if (devices.isEmpty)
              const ListTile(contentPadding: EdgeInsets.zero, title: Text('No devices yet'))
            else
              for (final d in devices)
                ListTile(
                  key: ValueKey('messaging-devices-${d.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    d.isGateway ? Icons.sim_card_outlined : Icons.phone_iphone,
                    color: d.onlineAt(now) ? Colors.green : t.colorScheme.outline,
                  ),
                  title: Text(d.title),
                  subtitle: Text(
                    [
                      d.isGateway ? 'Gateway' : 'App',
                      if (d.simNumber != null) d.simNumber!,
                      if (d.capabilities.isNotEmpty) d.capabilities.map((c) => c.toUpperCase()).join(' · '),
                      deviceSeenLabel(d, now),
                    ].join(' · '),
                  ),
                  trailing: canEdit
                      ? PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'rename') return _rename(context, ref, d);
                            if (!await confirm(
                                  context,
                                  'Remove device?',
                                  'It comes back the next time it says it is here.',
                                  ok: 'Remove',
                                ) ||
                                !context.mounted) {
                              return;
                            }
                            await runAdminAction(
                              context,
                              () => ref.read(messagingRepositoryProvider).removeDevice(d.id),
                            );
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('Rename')),
                            PopupMenuItem(value: 'remove', child: Text('Remove')),
                          ],
                        )
                      : null,
                ),
          ],
        ),
      ),
    );
  }
}

/// A test message, and what has gone out and come in lately.
class _QueueCard extends ConsumerStatefulWidget {
  const _QueueCard({required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<_QueueCard> createState() => _QueueCardState();
}

class _QueueCardState extends ConsumerState<_QueueCard> {
  final _to = TextEditingController();
  final _body = TextEditingController(text: 'Test message from GET.ride');
  MessagingChannel _channel = MessagingChannel.supportMessage;

  @override
  void dispose() {
    _to.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final to = normalizeSmsNumber(_to.text);
    if (to == null) return showInfo(context, 'Enter the phone number with its country code, e.g. +60123456789.');
    if (_body.text.trim().isEmpty) return showInfo(context, 'Write the message.');
    await runAdminAction(
      context,
      () => ref.read(messagingRepositoryProvider).queueSms(channel: _channel, to: to, body: _body.text.trim()),
      success: 'Queued. The gateway phone routed to ${_channel.label} sends it.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final time = DateFormat('d MMM, h:mm a');
    String when(Object? v) {
      final d = DateTime.tryParse('${v ?? ''}');
      return d == null ? '' : time.format(d.toLocal());
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('SMS queue', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (widget.canEdit) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<MessagingChannel>(
                initialValue: _channel,
                decoration: const InputDecoration(labelText: 'Channel', isDense: true),
                items: [
                  for (final c in MessagingChannel.values)
                    if (!c.isCall) DropdownMenuItem(value: c, child: Text(c.label)),
                ],
                onChanged: (v) => setState(() => _channel = v ?? _channel),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('messaging-test-to'),
                controller: _to,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'To', hintText: '+60123456789', isDense: true),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _body,
                maxLength: 160,
                decoration: const InputDecoration(labelText: 'Message', isDense: true),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: BusyButton.tonal(
                  key: const ValueKey('messaging-test-send'),
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                  child: const Text('Send test SMS'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text('Outgoing', style: t.textTheme.labelLarge),
            AsyncView(
              value: ref.watch(_outboxProvider),
              onRetry: () => ref.invalidate(_outboxProvider),
              data: (rows) => Column(
                children: [
                  if (rows.isEmpty) const ListTile(dense: true, title: Text('Nothing sent yet')),
                  for (final r in rows)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${r['to_phone']} · ${r['body']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          MessagingChannel.fromId(r['channel'])?.label ?? '${r['channel']}',
                          when(r['created_at']),
                          if (r['error'] != null) '${r['error']}',
                        ].join(' · '),
                      ),
                      trailing: StatusChip('${r['status']}'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text('Incoming', style: t.textTheme.labelLarge),
            AsyncView(
              value: ref.watch(_inboxProvider),
              onRetry: () => ref.invalidate(_inboxProvider),
              data: (rows) => Column(
                children: [
                  if (rows.isEmpty) const ListTile(dense: true, title: Text('Nothing received yet')),
                  for (final r in rows)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${r['from_phone']} · ${r['body']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          MessagingChannel.fromId(r['channel'])?.label ?? 'Unrouted',
                          when(r['received_at']),
                        ].join(' · '),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
