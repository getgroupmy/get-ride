// Sign-in checks (migration 0283): who compares the selfie with the ID photo
// (off, AWS Rekognition, the self-hosted server, the server then AWS) and
// who reads the MyKad or passport (the phone, the phone then Google Vision,
// Google Vision always). In Dispatch → Accounts next to "Ask for a new ID".
// Each change is saved as it is picked. A line under each says when its key
// is missing in Admin → API Keys, so nobody wonders why a face reads "Not
// checked". The face match is a score only: nothing here approves anyone.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/signin_checks.dart';
import '../../../data/identity_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';

class IdentityProviderFields extends ConsumerStatefulWidget {
  const IdentityProviderFields({super.key, this.enabled = true});

  final bool enabled;

  @override
  ConsumerState<IdentityProviderFields> createState() => _IdentityProviderFieldsState();
}

class _IdentityProviderFieldsState extends ConsumerState<IdentityProviderFields> {
  IdentityConfig? _saved;
  bool _busy = false;

  Future<void> _set({String? face, String? idRead}) async {
    setState(() => _busy = true);
    try {
      final c = await ref.read(identityRepositoryProvider).setProviders(face: face, idRead: idRead);
      if (!mounted) return;
      setState(() => _saved = c);
      ref.invalidate(identityConfigProvider);
      showInfo(context, 'Saved');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final warn = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error);
    final c = _saved ?? ref.watch(identityConfigProvider).value;
    if (c == null) return const SizedBox.shrink();
    final on = widget.enabled && !_busy;
    Widget note(String? s, String key) =>
        s == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 4), child: Text(s, key: ValueKey(key), style: warn));
    return Column(
      key: const ValueKey('identity-providers'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Checking their photos', style: t.textTheme.titleSmall),
        const SizedBox(height: 8),
        SearchableDropdownFormField<String>(
          key: ValueKey('face-provider-${c.faceProvider}'),
          initialValue: c.faceProvider,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Face match', border: OutlineInputBorder(), isDense: true),
          items: [
            for (final e in faceProviders.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: on ? (v) => v == null || v == c.faceProvider ? null : _set(face: v) : null,
        ),
        const SizedBox(height: 4),
        Text(
          'Compares the selfie with the ID photo as a score that helps you decide. It never approves anyone. '
          'Self-hosted, then AWS asks AWS only when your server can\'t answer.',
          style: muted,
        ),
        note(c.faceNote, 'face-provider-note'),
        const SizedBox(height: 12),
        SearchableDropdownFormField<String>(
          key: ValueKey('id-read-${c.idRead}'),
          initialValue: c.idRead,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'ID card reading', border: OutlineInputBorder(), isDense: true),
          items: [
            for (final e in idReadModes.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: on ? (v) => v == null || v == c.idRead ? null : _set(idRead: v) : null,
        ),
        const SizedBox(height: 4),
        Text(
          'Reads the name, IC or passport number and expiry off the card, to check against the profile. '
          'Google Vision also reads on the web and desktop, where the phone can\'t. First 1,000 reads a month free.',
          key: const ValueKey('id-read-help'),
          style: muted,
        ),
        note(c.visionNote, 'id-read-note'),
      ],
    );
  }
}
