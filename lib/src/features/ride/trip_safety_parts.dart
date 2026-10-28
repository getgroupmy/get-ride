// The receipt's safety part (migration 0311): "You were covered on this
// trip" (the admin's passenger cover and the driver's permit), "Report a
// problem with this trip" (a support ticket with the trip linked) and
// "Block this driver". Pure logic: lib/src/core/ride_safety.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ride_chat.dart' show rideVoiceNoteMax;
import '../../core/ride_safety.dart';
import '../../data/ride_safety_repository.dart';
import '../../data/voice_recorder.dart';
import '../../providers.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/voice_note_composer.dart';
import '../support/support_chat_screen.dart' show SupportAttachment, pickSupportAttachment;

/// The rider's safety part of trip [requestId]'s receipt. Nothing for the
/// driver's copy, or before 0311.
class TripSafetySection extends ConsumerWidget {
  const TripSafetySection({super.key, required this.requestId, this.pickAttachment = pickSupportAttachment});
  final String requestId;

  /// The report's photo picker (tests).
  final Future<SupportAttachment?> Function() pickAttachment;

  Future<void> _openReport(BuildContext context, WidgetRef ref, TripSafetyInfo info) async {
    final result = await showAppSheet<TripReportResult>(
      id: 'trip-report.report',
      context: context,
      fitContent: true,
      builder: (_) => TripReportSheet(requestId: requestId, info: info, pickAttachment: pickAttachment),
    );
    if (result == null || !context.mounted) return;
    ref.invalidate(tripSafetyInfoProvider(requestId));
    unawaited(showAppNotice(
      id: 'notice.trip-report',
      context: context,
      message: result.message(info.trip.driverLabel),
      kind: NoticeKind.success,
    ));
  }

  Future<void> _openBlock(BuildContext context, WidgetRef ref, TripSafetyInfo info) async {
    final ok = await showAppSheet<bool>(
      id: 'trip-report.block',
      context: context,
      fitContent: true,
      builder: (_) => BlockDriverSheet(driver: info.trip.driverLabel),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(rideSafetyRepositoryProvider).block(requestId: requestId);
      ref.invalidate(tripSafetyInfoProvider(requestId));
      ref.invalidate(blockedDriversProvider);
      if (context.mounted) {
        unawaited(showAppNotice(
          id: 'notice.trip-report',
          context: context,
          message: '${info.trip.driverLabel} is blocked.',
          kind: NoticeKind.success,
        ));
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _unblock(BuildContext context, WidgetRef ref, TripSafetyInfo info) async {
    final id = info.trip.driverId;
    if (id == null) return;
    try {
      await ref.read(rideSafetyRepositoryProvider).unblock(id);
      ref.invalidate(tripSafetyInfoProvider(requestId));
      ref.invalidate(blockedDriversProvider);
      if (context.mounted) showInfo(context, '${info.trip.driverLabel} is unblocked.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(tripSafetyInfoProvider(requestId)).value;
    if (info == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final report = info.report;
    final hasDriver = info.trip.driverId != null;
    return Column(
      key: const ValueKey('receipt-safety'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (info.showsCoverCard) CoverCard(info: info),
        if (hasDriver) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
            child: Text(
              'Something wrong?',
              style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
          if (report != null)
            _ActionRow(
              key: const ValueKey('receipt-reported'),
              icon: Icons.flag,
              iconColor: t.colorScheme.primary,
              label: 'Reported${report.number == null ? '' : ': ticket #${report.number}'}'
                  '${report.category == null ? '' : ' (${report.category})'}',
              onTap: () async => context.push('/account/support/${report.ticketId}'),
            )
          else if (info.canReport)
            _ActionRow(
              key: const ValueKey('receipt-report'),
              icon: Icons.flag_outlined,
              iconColor: t.colorScheme.primary,
              label: 'Report a problem with this trip',
              onTap: () => _openReport(context, ref, info),
            ),
          _ActionRow(
            key: const ValueKey('receipt-block'),
            icon: Icons.block,
            iconColor: t.colorScheme.error,
            label: info.blocked ? 'Unblock ${info.trip.driverLabel}' : 'Block this driver',
            onTap: () => info.blocked ? _unblock(context, ref, info) : _openBlock(context, ref, info),
          ),
        ],
      ],
    );
  }
}

/// One row of "Something wrong?".
class _ActionRow extends StatelessWidget {
  const _ActionRow({super.key, required this.icon, required this.iconColor, required this.label, required this.onTap});
  final IconData icon;
  final Color iconColor;
  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        minTileHeight: 52,
        leading: Icon(icon, color: iconColor),
        title: Text(label),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => unawaited(onTap()),
      ),
    );
  }
}

/// "You were covered on this trip": the cover, the driver's permit, and how
/// to claim.
class CoverCard extends StatefulWidget {
  const CoverCard({super.key, required this.info});
  final TripSafetyInfo info;

  @override
  State<CoverCard> createState() => _CoverCardState();
}

class _CoverCardState extends State<CoverCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final info = widget.info;
    final cover = info.cover;
    return Card(
      key: const ValueKey('receipt-cover'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.verified_user, color: t.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(info.coverTitle, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 6),
          Text(info.coverText(), key: const ValueKey('receipt-cover-text'), style: t.textTheme.bodyMedium),
          if (cover != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('receipt-cover-claim'),
                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 40)),
                onPressed: () => setState(() => _open = !_open),
                child: Text(_open ? 'Hide claim details' : 'How to claim'),
              ),
            ),
            if (_open) ...[
              Text(cover.claimLine, key: const ValueKey('receipt-cover-claim-text'), style: t.textTheme.bodyMedium),
              if (cover.termsUrl != null) ...[
                const SizedBox(height: 4),
                SelectableText('Terms: ${cover.termsUrl}', style: t.textTheme.bodySmall),
              ],
              const SizedBox(height: 4),
            ],
          ],
        ]),
      ),
    );
  }
}

/// "What happened?": a category, an optional note, photo and voice note,
/// and "Also block". Pops with the report's result once it is sent.
class TripReportSheet extends ConsumerStatefulWidget {
  const TripReportSheet({
    super.key,
    required this.requestId,
    required this.info,
    this.pickAttachment = pickSupportAttachment,
  });

  final String requestId;
  final TripSafetyInfo info;
  final Future<SupportAttachment?> Function() pickAttachment;

  @override
  ConsumerState<TripReportSheet> createState() => _TripReportSheetState();
}

class _TripReportSheetState extends ConsumerState<TripReportSheet> with VoiceNoteComposer {
  final _note = TextEditingController();
  String? _category;
  bool _alsoBlock = false;
  bool _sending = false;
  SupportAttachment? _photo;
  VoiceClip? _voice;

  @override
  void dispose() {
    disposeVoiceNote();
    _note.dispose();
    super.dispose();
  }

  @override
  Future<void> sendVoiceClip(VoiceClip clip) async {
    if (mounted) setState(() => _voice = clip);
  }

  TripReportCategory? get _picked => widget.info.categories.where((c) => c.id == _category).firstOrNull;

  Future<void> _pickPhoto() async {
    try {
      final p = await widget.pickAttachment();
      if (p != null && mounted) setState(() => _photo = p);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _send() async {
    final c = _picked;
    if (c?.id == null || _sending) return;
    if (recording) await finishVoiceNote();
    setState(() => _sending = true);
    try {
      final result = await ref.read(rideSafetyRepositoryProvider).report(
            requestId: widget.requestId,
            categoryId: c!.id!,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            alsoBlock: _alsoBlock,
          );
      // The photo and the voice note follow as the ticket's messages.
      final photo = _photo, voice = _voice;
      try {
        if (photo != null) {
          await ref.read(accountRepositoryProvider).sendAttachment(result.ticketId, photo.bytes, name: photo.name);
        }
        if (voice != null) {
          await ref
              .read(accountRepositoryProvider)
              .sendVoiceNote(result.ticketId, voice.bytes, ext: voice.ext, duration: voice.duration);
        }
      } catch (_) {
        // The report is in; the rider can add them in the ticket.
      }
      if (result.blocked) ref.invalidate(blockedDriversProvider);
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final info = widget.info;
    final picked = _picked;
    final driver = info.trip.driverLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('What happened?', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          'The trip, route, fare and driver go with your report.',
          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in info.categories)
            ChoiceChip(
              key: ValueKey('report-category-${c.label}'),
              label: Text(c.label),
              selected: c.id == _category,
              onSelected: (_) => setState(() => _category = c.id),
            ),
        ]),
        if (picked?.sosReminder ?? false) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('report-sos-reminder'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(12)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.emergency, color: t.colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(child: Text(sosReminderText, style: TextStyle(color: t.colorScheme.onErrorContainer))),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('report-note'),
          controller: _note,
          maxLength: 1000,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Tell us more (optional)', border: OutlineInputBorder()),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            key: const ValueKey('report-photo'),
            onPressed: _sending ? null : _pickPhoto,
            icon: Icon(_photo == null ? Icons.add_a_photo_outlined : Icons.check_circle),
            label: Text(_photo == null ? 'Photo' : 'Photo added'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('report-voice'),
            onPressed: _sending ? null : (recording ? finishVoiceNote : startVoiceNote),
            icon: Icon(recording ? Icons.stop : (_voice == null ? Icons.mic_none : Icons.check_circle)),
            label: Text(recording
                ? 'Stop ${recordElapsed.inSeconds} s of ${rideVoiceNoteMax.inSeconds} s'
                : (_voice == null ? 'Voice note' : 'Voice note added')),
          ),
        ]),
        if (info.trip.driverId != null && !info.blocked)
          CheckboxListTile(
            key: const ValueKey('report-also-block'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('Also block $driver'),
            value: _alsoBlock,
            onChanged: (v) => setState(() => _alsoBlock = v ?? false),
          ),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('report-send'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: picked == null || _sending ? null : _send,
          child: _sending
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Send report'),
        ),
      ]),
    );
  }
}

/// "Block Hafiz R.?": pops true to block.
class BlockDriverSheet extends StatelessWidget {
  const BlockDriverSheet({super.key, required this.driver});
  final String driver;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Block $driver?', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(blockSheetText(driver), style: t.textTheme.bodyMedium),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('block-confirm'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: t.colorScheme.error,
            foregroundColor: t.colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Block'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const ValueKey('block-cancel'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ]),
    );
  }
}

/// The Safety page's cover card: the cover where the rider last rode.
class PassengerCoverCard extends ConsumerWidget {
  const PassengerCoverCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(myCoverProvider).value;
    final cover = mine?.cover;
    if (mine == null || (cover == null && !mine.showPermit)) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('safety-cover'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.verified_user, color: t.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                cover == null ? 'Licensed drivers' : 'You are covered on your trips',
                style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          if (cover != null) ...[
            Text(cover.coverLine, style: t.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(cover.claimLine, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ],
          if (mine.showPermit) ...[
            if (cover != null) const SizedBox(height: 6),
            Text(
              'Your driver\'s permit and its expiry are on each trip\'s receipt.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ]),
      ),
    );
  }
}
