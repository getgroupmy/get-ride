// Admin → SMS / WhatsApp → Session access (migration 0226): the keys that let
// a test session (a Claude Code cloud session, a CI job) take part in a live
// test without a phone of its own — text one test number through the gateway
// phone, read the sign-in codes sent to it, and reach the internet through a
// gateway phone's mobile data. A full admin adds and removes them; every
// admin sees the list. The key itself is shown once, when it is added.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/messaging.dart';
import '../../core/session_access.dart';
import '../../data/messaging_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import 'messaging_screen.dart' show messagingClockProvider;

final sessionKeysProvider = FutureProvider.autoDispose((ref) => ref.watch(messagingRepositoryProvider).sessionKeys());

/// Where a session reads how to use its key.
const sessionAccessDocs = 'docs/session-access.md';

/// The guide on GitHub, for the card's link row.
final sessionAccessDocsUrl = Uri.parse('https://github.com/getgroupmy/get-ride/blob/main/$sessionAccessDocs');

class SessionAccessCard extends ConsumerWidget {
  const SessionAccessCard({super.key, required this.devices});

  /// The devices on the page; the gateway phones among them can carry a
  /// session's internet.
  final List<MessagingDevice> devices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final now = ref.watch(messagingClockProvider)();
    final fullAdmin = ref.watch(adminAccessProvider).value?.isFullAdmin ?? false;
    final time = DateFormat('d MMM, h:mm a');
    return Card(
      key: const ValueKey('session-access-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Session access', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'A key for a test session with no phone of its own (a cloud session, a CI job): it texts one test '
              'number through the gateway phone and reads its sign-in codes. Shown once; remove it any time.',
              style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
            ),
            ListTile(
              key: const ValueKey('session-docs'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('How a session uses it'),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () async {
                var opened = false;
                try {
                  opened = await launchUrl(sessionAccessDocsUrl, mode: LaunchMode.externalApplication);
                } catch (_) {}
                if (opened) return;
                await Clipboard.setData(const ClipboardData(text: sessionAccessDocs));
                if (context.mounted) showInfo(context, "Copied the guide's path: $sessionAccessDocs");
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (fullAdmin)
                  FilledButton.tonalIcon(
                    key: const ValueKey('session-add'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add a session'),
                    onPressed: () => _add(context, ref),
                  )
                else
                  Text(
                    'Only a full admin adds or removes a session, since a key can read sign-in codes.',
                    style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            AsyncView(
              value: ref.watch(sessionKeysProvider),
              onRetry: () => ref.invalidate(sessionKeysProvider),
              data: (keys) => Column(
                children: [
                  if (keys.isEmpty) const ListTile(contentPadding: EdgeInsets.zero, title: Text('No sessions yet')),
                  for (final k in keys)
                    ListTile(
                      key: ValueKey('session-key-${k.id}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.terminal,
                        color: k.activeAt(now) ? Colors.green : t.colorScheme.outline,
                      ),
                      title: Text(k.label),
                      subtitle: Text(sessionKeySubtitle(k, now, time.format)),
                      trailing: fullAdmin && k.activeAt(now)
                          ? IconButton(
                              key: ValueKey('session-remove-${k.id}'),
                              tooltip: 'Remove',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _remove(context, ref, k),
                            )
                          : StatusChip(sessionKeyStatus(k, now)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, SessionKey k) async {
    final ok = await confirm(
      context,
      'Remove this session?',
      '"${k.label}" stops working at once: it can no longer text ${k.testPhone}, read its codes or use a phone\'s '
          'internet. Add a new session to let it back in.',
      ok: 'Remove',
    );
    if (!ok || !context.mounted) return;
    await runAdminAction(
      context,
      () => ref.read(messagingRepositoryProvider).revokeSessionKey(k.id),
      success: 'Session removed',
    );
    ref.invalidate(sessionKeysProvider);
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final gateways = devices.where((d) => d.isGateway).toList();
    final draft = await showAppDialog<_SessionDraft>(
      id: 'messaging.session-add',
      context: context,
      builder: (c) => _AddSessionDialog(gateways: gateways),
    );
    if (draft == null || !context.mounted) return;
    ({String key, DateTime? expiresAt})? made;
    final ok = await runAdminAction(context, () async {
      made = await ref
          .read(messagingRepositoryProvider)
          .createSessionKey(
            label: draft.label,
            testPhone: draft.phone,
            scopes: draft.scopes,
            hours: draft.hours,
            proxyDevice: draft.proxyDevice,
          );
    });
    ref.invalidate(sessionKeysProvider);
    final result = made;
    if (!ok || result == null || !context.mounted) return;
    await showAppDialog<void>(
      id: 'messaging.session-key',
      context: context,
      builder: (c) => _ShowKeyDialog(label: draft.label, made: result),
    );
  }
}

class _SessionDraft {
  const _SessionDraft({
    required this.label,
    required this.phone,
    required this.scopes,
    required this.hours,
    this.proxyDevice,
  });
  final String label;
  final String phone;
  final Set<SessionScope> scopes;
  final int hours;
  final String? proxyDevice;
}

/// "Add a session": its name, the test number, what it may do, how long.
class _AddSessionDialog extends StatefulWidget {
  const _AddSessionDialog({required this.gateways});
  final List<MessagingDevice> gateways;

  @override
  State<_AddSessionDialog> createState() => _AddSessionDialogState();
}

class _AddSessionDialogState extends State<_AddSessionDialog> {
  final _label = TextEditingController();
  final _phone = TextEditingController();
  final _scopes = {SessionScope.sms, SessionScope.codes};
  int _hours = sessionKeyDefaultHours;
  String? _proxyDevice;

  @override
  void dispose() {
    _label.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _submit() {
    final phone = normalizeSessionPhone(_phone.text) ?? _phone.text;
    final problem = sessionKeyProblem(label: _label.text, phone: phone, scopes: _scopes, proxyDevice: _proxyDevice);
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    Navigator.pop(
      context,
      _SessionDraft(
        label: _label.text.trim(),
        phone: phone,
        scopes: {..._scopes},
        hours: _hours,
        proxyDevice: _scopes.contains(SessionScope.proxy) ? _proxyDevice : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final wantsProxy = _scopes.contains(SessionScope.proxy);
    // Scrolls as a whole at large text, with the actions always in view.
    return AlertDialog(
      title: const Text('Add a session'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('session-label'),
            controller: _label,
            autofocus: true,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Claude cloud session',
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('session-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: 'Test phone number',
              hintText: '+60123456789',
              helperText: 'The only number the session may text or read codes for.',
              helperMaxLines: 2,
              helperStyle: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
            ),
          ),
          // How long, before the list of what it may do, so it is never
          // below the fold.
          const SizedBox(height: 12),
          SearchableDropdownFormField<int>(
            key: const ValueKey('session-hours'),
            isExpanded: true,
            initialValue: _hours,
            decoration: const InputDecoration(labelText: 'Lasts', isDense: true),
            items: [
              for (final h in sessionKeyHoursChoices) DropdownMenuItem(value: h, child: Text(sessionKeyHoursLabel(h))),
            ],
            onChanged: (v) => setState(() => _hours = v ?? _hours),
          ),
          const SizedBox(height: 12),
          Text('The session may', style: t.textTheme.labelLarge),
          for (final s in SessionScope.values)
            CheckboxListTile(
              key: ValueKey('session-scope-${s.id}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(s.label),
              subtitle: Text(s.description, style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
              value: _scopes.contains(s),
              onChanged: (v) => setState(() => v == true ? _scopes.add(s) : _scopes.remove(s)),
            ),
          if (wantsProxy) ...[
            const SizedBox(height: 4),
            if (widget.gateways.isEmpty)
              Text(
                'No gateway phone yet: pair one with "Pair a gateway phone" first.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
              )
            else
              SearchableDropdownFormField<String>(
                key: const ValueKey('session-proxy-device'),
                isExpanded: true,
                initialValue: _proxyDevice,
                decoration: const InputDecoration(labelText: 'Internet through', isDense: true),
                items: [
                  for (final d in widget.gateways)
                    DropdownMenuItem(value: d.id, child: Text(d.title, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _proxyDevice = v),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('session-add-confirm'), onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}

/// The key, once: copy it into the session's environment.
class _ShowKeyDialog extends StatelessWidget {
  const _ShowKeyDialog({required this.label, required this.made});
  final String label;
  final ({String key, DateTime? expiresAt}) made;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ends = made.expiresAt?.toLocal();
    return AlertDialog(
      title: Text('Key for "$label"'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The key in a filled box, Copy beside it.
          DecoratedBox(
            decoration: BoxDecoration(
              color: t.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(children: [
                Expanded(
                  child: SelectableText(
                    made.key,
                    key: const ValueKey('session-key-value'),
                    style: t.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace', color: t.colorScheme.onSurface),
                  ),
                ),
                IconButton(
                  key: const ValueKey('session-key-copy'),
                  tooltip: 'Copy key',
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: made.key));
                    if (context.mounted) showInfo(context, 'Copied');
                  },
                ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Shown once. Put it in the session\'s environment: as a network secret that adds the header '
            'X-Session-Key to requests to proxy.getride.my and the backend (nothing in the session sees it), '
            'or as the environment variable $sessionKeyEnvName. '
            '${ends == null ? '' : 'It works until ${DateFormat('d MMM, h:mm a').format(ends)}. '}'
            'The session calls the backend with it as in $sessionAccessDocs; remove it here to end it early.',
            style: t.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}
