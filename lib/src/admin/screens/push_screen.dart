import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../core/media_assets.dart' show MediaKind, mediaPublicUrl;
import '../../core/notification_delivery.dart';
import '../../core/push_message.dart';
import '../../core/ride_bidding.dart' show BiddingRegion;
import '../../features/ride/map_place_picker.dart' show pickPlaceOnMap;
import '../../data/media_repository.dart' show mediaAssetsProvider;
import '../../providers.dart' show rideRepositoryProvider;
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/media_image.dart';
import '../../widgets/search_select.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../push_area.dart';
import '../push_composer.dart';
import '../saved_push.dart';
import '../widgets/admin_widgets.dart';
import 'meterapp/media_picker_sheet.dart' show MediaStore, showMediaPicker;
import 'meterapp/media_upload_dialog.dart' show showMediaUploadDialog;
import 'people/people_logic.dart' show partnerTypeOptions;
import 'push_area_picker.dart';
import 'push_composer_widgets.dart';
import '../../data/live_tables.dart';

/// Trip pushes delivered over the last day (migration 0144), re-read live.
final notificationDeliveryProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('notification_outbox');
  return ref.watch(adminRepositoryProvider).notificationDelivery();
});

final pushHistoryProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('push_notifications');
  return ref.watch(adminRepositoryProvider).pushHistory();
});

/// Notifications kept to send again (`settings_entries`, `push-notification`).
final savedPushesProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('settings_entries');
  return ref.watch(adminRepositoryProvider).savedPushes();
});

/// The admin's Regions, for sending by region.
final pushRegionsProvider = FutureProvider.autoDispose<List<BiddingRegion>>(
  (ref) => ref.watch(rideRepositoryProvider).biddingRegions(),
);

/// Pushes waiting to go (push_schedules, 0279). A scheduled send lands in
/// the history, so the list is re-read when that changes.
final pushSchedulesProvider = FutureProvider.autoDispose<List<PushSchedule>>((ref) {
  ref.watchAdminLive('push_notifications');
  return ref.watch(adminRepositoryProvider).pushSchedules();
});

/// The partner types and every partner's, for the "Which partners" chips.
final pushPartnerAudienceProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('partners');
  return ref.watch(adminRepositoryProvider).pushPartnerAudience();
});

class AdminPushScreen extends ConsumerStatefulWidget {
  const AdminPushScreen({super.key, this.now});

  /// Clock override for tests.
  final DateTime Function()? now;

  @override
  ConsumerState<AdminPushScreen> createState() => _AdminPushScreenState();
}

class _AdminPushScreenState extends ConsumerState<AdminPushScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _audience = 'all';
  PushArea _area = const PushArea.everywhere();
  bool _sending = false;
  bool _saving = false;

  /// The full message's markup (core/push_message.dart), the picture's
  /// address, and which field the emoji grid types into (0279).
  final _rich = TextEditingController();
  String? _image;
  TextEditingController? _emojiFor;

  /// With the partner audience: the chosen types (none is every partner)
  /// and whether only approved partners are told.
  final _partnerTypes = <String>[];
  bool _approvedOnly = true;

  /// Send now, or at [_date] [_time] Malaysia time, repeating [_repeat].
  bool _later = false;
  final _date = TextEditingController();
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  PushRepeat _repeat = PushRepeat.once;

  /// "Reaches N people…" for the current audience and area, from a dry run.
  String? _reach;
  bool _reachLoading = false;
  Timer? _reachDebounce;
  int _reachSeq = 0;

  /// The saved notification being edited in the compose card, if any.
  SavedPush? _editing;

  /// The scheduled push being edited, if any.
  PushSchedule? _editingSchedule;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _setDefaultTime();
    // The preview follows every keystroke.
    for (final c in [_title, _body, _rich]) {
      c.addListener(_changed);
    }
    _checkReach();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Tomorrow at 09:00 Malaysia time.
  void _setDefaultTime() {
    final my = malaysiaClock(_now()).add(const Duration(days: 1));
    _date.text = isoDate(DateTime(my.year, my.month, my.day));
    _time = const TimeOfDay(hour: 9, minute: 0);
  }

  /// The scheduled time, or null while the date is not a real one.
  DateTime? get _sendAt {
    final d = parseIsoDate(_date.text);
    return d == null ? null : fromMalaysiaClock(d.year, d.month, d.day, _time.hour, _time.minute);
  }

  List<String> get _types => _audience == 'partners' ? List.of(_partnerTypes) : const [];
  bool? get _approved => _audience == 'partners' ? _approvedOnly : null;

  /// Re-counts who the compose card would reach, a moment after the last
  /// change; an answer for an older choice is dropped.
  void _checkReach() {
    _reachDebounce?.cancel();
    if (!_area.complete) {
      setState(() {
        _reach = _area.kind == PushAreaKind.radius ? 'Pick a point on the map.' : 'Choose a country.';
        _reachLoading = false;
      });
      return;
    }
    setState(() => _reachLoading = true);
    final seq = ++_reachSeq;
    final audience = _audience, area = _area, types = _types, approved = _approved;
    _reachDebounce = Timer(const Duration(milliseconds: 500), () async {
      String text;
      try {
        final r = await ref.read(adminRepositoryProvider).sendPush('preview', 'preview', audience,
            area: area.toJson(), dryRun: true, partnerTypes: types, approvedOnly: approved);
        text = pushReachText(r, area);
      } catch (e) {
        text = "Couldn't count the reach: $e";
      }
      if (!mounted || seq != _reachSeq) return;
      setState(() {
        _reach = text;
        _reachLoading = false;
      });
    });
  }

  void _setAudience(String v) {
    setState(() => _audience = v);
    _checkReach();
  }

  void _setArea(PushArea a) {
    setState(() => _area = a);
    _checkReach();
  }

  void _togglePartnerType(String type) {
    setState(() {
      final i = _partnerTypes.indexWhere((t) => t.toLowerCase() == type.toLowerCase());
      if (i >= 0) {
        _partnerTypes.removeAt(i);
      } else {
        _partnerTypes.add(type);
      }
    });
    _checkReach();
  }

  void _setApprovedOnly(bool v) {
    setState(() => _approvedOnly = v);
    _checkReach();
  }

  void _toggleEmoji(TextEditingController c) => setState(() => _emojiFor = _emojiFor == c ? null : c);

  void _pickEmoji(String e) {
    final c = _emojiFor;
    if (c != null) c.value = insertAtCursor(c.value, e);
  }

  @override
  void dispose() {
    _reachDebounce?.cancel();
    _title.dispose();
    _body.dispose();
    _rich.dispose();
    _date.dispose();
    super.dispose();
  }

  static const _who = {'all': 'everyone', 'users': 'all passengers', 'partners': 'all partners'};

  /// "partners of type eHailing, Teksi" for the chosen types, else _who.
  String _whoText(String audience, List<String> types) =>
      audience == 'partners' && types.isNotEmpty ? 'partners of type ${types.join(', ')}' : _who[audience]!;

  void _resetCompose() {
    _title.clear();
    _body.clear();
    _rich.clear();
    _image = null;
    _emojiFor = null;
    _audience = 'all';
    _area = const PushArea.everywhere();
    _partnerTypes.clear();
    _approvedOnly = true;
    _later = false;
    _repeat = PushRepeat.once;
    _setDefaultTime();
    _editing = null;
    _editingSchedule = null;
    _checkReach();
  }

  /// The full message's blocks, as stored.
  List<Map<String, dynamic>> get _blocks => encodePushBlocks(parsePushMarkup(_rich.text));

  /// Stores the compose card as a saved notification (a new one, or the one
  /// being edited). False when nothing was saved.
  Future<bool> _persist() async {
    final values = savedPushValues(
      existing: _editing?.values,
      title: _title.text,
      body: _body.text,
      audience: _audience,
      area: _area,
      now: DateTime.now(),
      imageUrl: _image,
      partnerTypes: _types,
      approvedOnly: _approvedOnly,
      blocks: _blocks,
    );
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).savePushTemplate(id: _editing?.id, values: values),
    );
    if (ok) ref.invalidate(savedPushesProvider);
    return ok;
  }

  Future<void> _save() async {
    final problem = validatePushDraft(_title.text, _body.text);
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    final editing = _editing != null;
    setState(() => _saving = true);
    final ok = await _persist();
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _resetCompose();
    });
    if (ok) showInfo(context, editing ? 'Saved notification updated' : 'Notification saved');
  }

  /// Sends one now: its full message stored first (when it has one), so the
  /// push can carry the id.
  Future<void> _dispatch(
    String title,
    String body,
    String audience,
    PushArea area, {
    String? image,
    List<String> partnerTypes = const [],
    bool approvedOnly = true,
    List<Map<String, dynamic>> blocks = const [],
  }) async {
    final repo = ref.read(adminRepositoryProvider);
    final messageId = blocks.isEmpty
        ? null
        : await repo.savePushMessage(title: title, body: body, image: image, blocks: blocks);
    final partners = audience == 'partners';
    final r = await repo.sendPush(title, body, audience,
        area: area.toJson(),
        image: image,
        messageId: messageId,
        partnerTypes: partners ? partnerTypes : const [],
        approvedOnly: partners ? approvedOnly : null);
    if (!mounted) return;
    showInfo(context, pushResultText(r, audience, area));
    ref.invalidate(pushHistoryProvider);
  }

  /// Stores the compose card as a scheduled push (a new one, or the one
  /// being edited), with its full message.
  Future<void> _schedule(DateTime sendAt) async {
    final repo = ref.read(adminRepositoryProvider);
    final s = _editingSchedule;
    final blocks = _blocks;
    final title = _title.text.trim(), body = _body.text.trim();
    final messageId = blocks.isEmpty
        ? null
        : await repo.savePushMessage(id: s?.messageId, title: title, body: body, image: _image, blocks: blocks);
    final row = pushScheduleRow(
      title: title,
      body: body,
      audience: _audience,
      sendAt: sendAt,
      repeat: _repeat,
      area: _area,
      imageUrl: _image,
      messageId: messageId,
      partnerTypes: _types,
      approvedOnly: _approvedOnly,
    );
    // An unchanged time keeps the series' first time (a monthly push on the
    // 31st stays on the 31st).
    if (s != null && sendAt.isAtSameMomentAs(s.when) && _repeat == s.repeat) row.remove('send_at');
    await repo.savePushSchedule(id: s?.id, row: row);
    ref.invalidate(pushSchedulesProvider);
  }

  Future<void> _send() async {
    final problem = validatePushDraft(_title.text, _body.text);
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    if (!_area.complete) {
      showInfo(context, _area.kind == PushAreaKind.radius ? 'Pick a point on the map.' : 'Choose a country.');
      return;
    }
    final sendAt = _sendAt;
    if (_later) {
      final unchanged = _editingSchedule != null && sendAt != null && sendAt.isAtSameMomentAs(_editingSchedule!.when);
      final timeProblem = unchanged ? null : scheduleTimeProblem(sendAt, _now());
      if (timeProblem != null) {
        showInfo(context, timeProblem);
        return;
      }
    }
    final where = _area.label.isEmpty ? '' : ' ${_area.label}';
    final who = _whoText(_audience, _types);
    final ok = _later
        ? await confirm(context, _editingSchedule == null ? 'Schedule notification?' : 'Save scheduled notification?',
            'This goes to $who$where on ${malaysiaTimeText(sendAt!)} Malaysia time'
            '${_repeat == PushRepeat.once ? '' : ', then ${pushRepeatLabel(_repeat, sendAt).toLowerCase()}'}.',
            ok: _editingSchedule == null ? 'Schedule' : 'Save')
        : await confirm(context, 'Send notification?',
            'This goes to $who$where immediately and cannot be recalled.',
            ok: 'Send');
    if (!ok) return;
    setState(() => _sending = true);
    try {
      // Sending an edited saved notification keeps the edit (Expo did too).
      if (_editing != null && !await _persist()) return;
      if (_later) {
        final editing = _editingSchedule != null;
        await _schedule(sendAt!);
        if (mounted) {
          showInfo(context, editing ? 'Scheduled notification updated' : 'Scheduled for ${malaysiaTimeText(sendAt)}');
        }
      } else {
        await _dispatch(_title.text.trim(), _body.text.trim(), _audience, _area,
            image: _image, partnerTypes: _types, approvedOnly: _approvedOnly, blocks: _blocks);
      }
      if (mounted) setState(_resetCompose);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _edit(SavedPush p) {
    setState(() {
      _editing = p;
      _editingSchedule = null;
      _title.text = p.title;
      _body.text = p.body;
      _audience = p.audience;
      _area = p.area;
      _image = p.imageUrl;
      _partnerTypes
        ..clear()
        ..addAll(p.partnerTypes);
      _approvedOnly = p.approvedOnly;
      _rich.text = pushMarkup(decodePushBlocks(p.blocks));
      _later = false;
    });
    _checkReach();
  }

  Future<void> _editSchedule(PushSchedule s) async {
    Map<String, dynamic>? message;
    if (s.messageId != null) {
      try {
        message = await ref.read(adminRepositoryProvider).pushMessage(s.messageId!);
      } catch (_) {}
    }
    if (!mounted) return;
    final my = malaysiaClock(s.when);
    setState(() {
      _editing = null;
      _editingSchedule = s;
      _title.text = s.title;
      _body.text = s.body;
      _audience = s.audience;
      _area = s.area;
      _image = s.imageUrl;
      _partnerTypes
        ..clear()
        ..addAll(s.partnerTypes);
      _approvedOnly = s.approvedOnly;
      _rich.text = message == null ? '' : pushMarkup(decodePushBlocks(message['blocks']));
      _later = true;
      _date.text = isoDate(DateTime(my.year, my.month, my.day));
      _time = TimeOfDay(hour: my.hour, minute: my.minute);
      _repeat = s.repeat;
    });
    _checkReach();
  }

  Future<void> _cancelSchedule(PushSchedule s) async {
    if (!await confirm(context, 'Cancel scheduled notification?',
        '"${s.title}" will not be sent${s.repeat == PushRepeat.once ? '' : ' again'}. Pushes already sent stay sent.',
        ok: 'Stop sending')) {
      return;
    }
    if (!mounted) return;
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).cancelPushSchedule(s.id),
        success: 'Scheduled notification cancelled')) {
      if (_editingSchedule?.id == s.id && mounted) setState(_resetCompose);
      ref.invalidate(pushSchedulesProvider);
    }
  }

  Future<void> _resend(SavedPush p) async {
    if (!p.sendable) {
      showInfo(context, 'This notification is missing a title or message.');
      return;
    }
    if (!await confirm(context, 'Send notification?',
        'Send "${p.title}" to ${_whoText(p.audience, p.partnerTypes)}${p.area.label.isEmpty ? '' : ' ${p.area.label}'}? '
        'It goes out immediately and cannot be recalled.',
        ok: 'Send')) {
      return;
    }
    try {
      await _dispatch(p.title, p.body, p.audience, p.area,
          image: p.imageUrl,
          partnerTypes: p.partnerTypes,
          approvedOnly: p.approvedOnly,
          blocks: encodePushBlocks(decodePushBlocks(p.blocks)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(SavedPush p) async {
    if (!await confirm(context, 'Delete saved notification?', 'Delete "${p.title}"? Pushes already sent stay sent.',
        ok: 'Delete')) {
      return;
    }
    if (!mounted) return;
    if (await runAdminAction(context, () => ref.read(adminRepositoryProvider).deleteSavedPush(p.id),
        success: 'Deleted')) {
      if (_editing?.id == p.id && mounted) setState(_resetCompose);
      ref.invalidate(savedPushesProvider);
    }
  }

  Future<void> _chooseImage() async {
    final v = await showMediaPicker(context,
        kind: MediaKind.image, current: _image, title: 'Choose a picture', offerDefault: false, store: MediaStore.url);
    if (v == null || v.isEmpty || !mounted) return;
    _takeImage(v);
  }

  Future<void> _uploadImage() async {
    final asset = await showMediaUploadDialog(context, kind: MediaKind.image, lockKind: true);
    if (asset == null || !mounted) return;
    ref.invalidate(mediaAssetsProvider);
    final path = asset.path ?? asset.darkPath;
    if (path != null) _takeImage(mediaPublicUrl(AppConfig.supabaseUrl, path));
  }

  /// A picked picture: phones show only https JPG and PNG pictures.
  void _takeImage(String url) {
    final safe = safePushImageUrl(url);
    if (safe == null || safe.toLowerCase().endsWith('.svg')) {
      showInfo(context, 'Choose a JPG or PNG picture. Phones do not show this one in a notification.');
      return;
    }
    setState(() => _image = safe);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: _time, helpText: 'Malaysia time');
    if (t != null && mounted) setState(() => _time = t);
  }

  Widget _compose(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final today = malaysiaClock(_now());
    final audience = ref.watch(pushPartnerAudienceProvider);
    final counts = audience.value == null
        ? const <({String type, int count})>[]
        : partnerTypeCounts(audience.value!.partners, partnerTypeOptions(audience.value!.types),
            approvedOnly: _approvedOnly);
    final editingTitle = _editingSchedule != null
        ? 'Edit scheduled notification'
        : _editing != null
        ? 'Edit saved notification'
        : 'New broadcast';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(editingTitle, style: t.textTheme.titleMedium)),
            if (_editing != null || _editingSchedule != null)
              TextButton(
                key: const ValueKey('push-cancel-edit'),
                onPressed: () => setState(_resetCompose),
                child: const Text('Cancel edit'),
              ),
          ]),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('push-title'),
            controller: _title,
            decoration: InputDecoration(
              labelText: 'Title',
              suffixIcon: EmojiButton(
                key: const ValueKey('push-title-emoji'),
                open: _emojiFor == _title,
                onPressed: () => _toggleEmoji(_title),
              ),
            ),
          ),
          if (_emojiFor == _title) ...[const SizedBox(height: 8), EmojiGrid(onPick: _pickEmoji)],
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('push-body'),
            controller: _body,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: 'Message',
              suffixIcon: EmojiButton(
                key: const ValueKey('push-body-emoji'),
                open: _emojiFor == _body,
                onPressed: () => _toggleEmoji(_body),
              ),
            ),
          ),
          if (_emojiFor == _body) ...[const SizedBox(height: 8), EmojiGrid(onPick: _pickEmoji)],
          const SizedBox(height: 16),
          Text('Full message, shown when they tap it (optional)', style: t.textTheme.labelLarge),
          PushRichEditor(controller: _rich, emojiOpen: _emojiFor == _rich, onEmoji: () => _toggleEmoji(_rich)),
          if (_emojiFor == _rich) ...[const SizedBox(height: 8), EmojiGrid(onPick: _pickEmoji)],
          const SizedBox(height: 16),
          Text('Picture (optional)', style: t.textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (_image != null)
              ClipRRect(
                key: const ValueKey('push-image-thumb'),
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 96,
                  height: 48,
                  child: MediaImage(_image,
                      fit: BoxFit.cover, fallback: Icon(Icons.image_outlined, color: t.colorScheme.onSurfaceVariant)),
                ),
              ),
            OutlinedButton.icon(
              key: const ValueKey('push-image-gallery'),
              onPressed: _chooseImage,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(_image == null ? 'Choose from Media Gallery' : 'Change'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('push-image-upload'),
              onPressed: _uploadImage,
              icon: const Icon(Icons.upload),
              label: const Text('Upload'),
            ),
            if (_image != null)
              TextButton.icon(
                key: const ValueKey('push-image-remove'),
                onPressed: () => setState(() => _image = null),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove'),
              ),
          ]),
          const SizedBox(height: 4),
          Text('Shown large in the notification on Android (and on iPhone once the app supports it). '
              'JPG or PNG, up to 1 MB; wide (2:1) works best.',
              style: t.textTheme.bodySmall?.copyWith(color: muted)),
          const SizedBox(height: 16),
          Text('Send to', style: t.textTheme.labelLarge),
          const SizedBox(height: 8),
          // Full width, no tick, one line each: no "Every-one".
          SegmentedButton<String>(
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'all', label: SegmentLabel('Everyone')),
              ButtonSegment(value: 'users', label: SegmentLabel('Passengers')),
              ButtonSegment(value: 'partners', label: SegmentLabel('Partners')),
            ],
            selected: {_audience},
            onSelectionChanged: (v) => _setAudience(v.first),
          ),
          if (_audience == 'partners') ...[
            const SizedBox(height: 12),
            PartnerTypeChips(
              counts: counts,
              selected: _partnerTypes.toSet(),
              onToggle: _togglePartnerType,
              approvedOnly: _approvedOnly,
              onApprovedOnly: _setApprovedOnly,
              loading: audience.isLoading,
            ),
          ],
          const SizedBox(height: 12),
          PushAreaPicker(
            area: _area,
            regions: ref.watch(pushRegionsProvider).value ?? const [],
            onChanged: _setArea,
            pickPoint: (start) async => (await pickPlaceOnMap(context, start: start))?.point,
          ),
          const SizedBox(height: 8),
          Row(
            key: const ValueKey('push-reach'),
            children: [
              Icon(Icons.people_outline, size: 18, color: t.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _reachLoading ? 'Counting who this reaches…' : (_reach ?? ''),
                  style: t.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('When', style: t.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            key: const ValueKey('push-when'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: SegmentLabel('Send now')),
              ButtonSegment(value: true, label: SegmentLabel('Schedule')),
            ],
            selected: {_later},
            onSelectionChanged: (v) => setState(() => _later = v.first),
          ),
          if (_later) ...[
            const SizedBox(height: 12),
            DateBoxesField(
              key: const ValueKey('push-date'),
              label: 'Date (Malaysia time)',
              controller: _date,
              firstDate: DateTime(today.year, today.month, today.day),
              lastDate: DateTime(today.year + 1, today.month, today.day),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                key: const ValueKey('push-time'),
                onPressed: _pickTime,
                icon: const Icon(Icons.schedule),
                label: Text('${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}'),
              ),
              Text('Malaysia time (UTC+8)', style: t.textTheme.bodySmall?.copyWith(color: muted)),
            ]),
            const SizedBox(height: 12),
            SearchableDropdownFormField<PushRepeat>(
              key: ValueKey('push-repeat-${_editingSchedule?.id ?? 'new'}-${_repeat.name}'),
              initialValue: _repeat,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Repeat'),
              items: [
                for (final r in PushRepeat.values)
                  DropdownMenuItem(value: r, child: Text(pushRepeatLabel(r, _sendAt))),
              ],
              onChanged: (r) => setState(() => _repeat = r ?? PushRepeat.once),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
            if (_editingSchedule == null)
              OutlinedButton.icon(
                key: const ValueKey('push-save'),
                onPressed: _sending || _saving ? null : _save,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: Text(_editing == null ? 'Save for later' : 'Save changes'),
              ),
            BusyButton.filled(
              key: const ValueKey('push-send'),
              onPressed: _sending || _saving ? null : _send,
              icon: Icon(_later ? Icons.schedule_send_outlined : Icons.send),
              child: Text(_later ? (_editingSchedule == null ? 'Schedule' : 'Save schedule') : 'Send'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _preview() => PushPreview(
    title: _title.text,
    body: _body.text,
    imageUrl: _image,
    blocks: parsePushMarkup(_rich.text),
  );

  Widget _scheduled(BuildContext context, bool canEdit) => AsyncView(
    value: ref.watch(pushSchedulesProvider),
    onRetry: () => ref.invalidate(pushSchedulesProvider),
    data: (rows) => rows.isEmpty
        ? const EmptyState(
            icon: Icons.schedule_send_outlined,
            title: 'Nothing scheduled',
            message: 'Choose Schedule to send a notification later, or every day, week or month.',
          )
        : Column(children: [
            for (final s in rows)
              ListTile(
                key: ValueKey('push-schedule-${s.id}'),
                contentPadding: EdgeInsets.zero,
                selected: _editingSchedule?.id == s.id,
                title: Text(s.title),
                subtitle: Text('${malaysiaTimeText(s.when)} · ${pushRepeatLabel(s.repeat, s.sendAt)}\n${s.toText}'),
                isThreeLine: true,
                trailing: canEdit
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          key: ValueKey('push-schedule-edit-${s.id}'),
                          tooltip: 'Edit',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _editSchedule(s),
                        ),
                        IconButton(
                          key: ValueKey('push-schedule-cancel-${s.id}'),
                          tooltip: 'Cancel',
                          icon: const Icon(Icons.event_busy_outlined),
                          onPressed: () => _cancelSchedule(s),
                        ),
                      ])
                    : null,
              ),
          ]),
  );

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(moduleAccessProvider('push')) == AccessLevel.edit;
    return AdminPage(
      title: 'Push notifications',
      module: 'push',
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ResponsiveCenter(
          maxWidth: 1080,
          padding: EdgeInsets.zero,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (canEdit)
              // The phone preview beside the composer on a wide screen, under it on a phone.
              LayoutBuilder(
                builder: (context, c) => c.maxWidth >= 880
                    ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: _compose(context)),
                        const SizedBox(width: 16),
                        SizedBox(width: 320, child: _preview()),
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        _compose(context),
                        const SizedBox(height: 12),
                        _preview(),
                      ]),
              ),
            const SizedBox(height: 16),
            Text('Scheduled', style: Theme.of(context).textTheme.titleMedium),
            _scheduled(context, canEdit),
            const SizedBox(height: 16),
            Text('Saved', style: Theme.of(context).textTheme.titleMedium),
            AsyncView(
              value: ref.watch(savedPushesProvider),
              onRetry: () => ref.invalidate(savedPushesProvider),
              data: (saved) => saved.isEmpty
                  ? const EmptyState(
                      icon: Icons.bookmarks_outlined,
                      title: 'No saved notifications',
                      message: 'Save a notification to send it again later.',
                    )
                  : Column(children: [
                      for (final p in saved)
                        ListTile(
                          key: ValueKey('saved-push-${p.id}'),
                          contentPadding: EdgeInsets.zero,
                          selected: _editing?.id == p.id,
                          title: Text(p.title.isEmpty ? '(no title)' : p.title),
                          subtitle: Text('${p.body}\n${pushAudienceLabel(p.audience)}'
                              '${p.area.label.isEmpty ? '' : ' ${p.area.label}'}'
                              '${p.updatedAt == null ? '' : ' · ${dateText(p.updatedAt)}'}'),
                          isThreeLine: true,
                          trailing: canEdit
                              ? Row(mainAxisSize: MainAxisSize.min, children: [
                                  IconButton(
                                    key: ValueKey('saved-push-send-${p.id}'),
                                    tooltip: 'Send again',
                                    icon: const Icon(Icons.send_outlined),
                                    onPressed: _sending ? null : () => _resend(p),
                                  ),
                                  IconButton(
                                    key: ValueKey('saved-push-edit-${p.id}'),
                                    tooltip: 'Edit',
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: () => _edit(p),
                                  ),
                                  IconButton(
                                    key: ValueKey('saved-push-delete-${p.id}'),
                                    tooltip: 'Delete',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _delete(p),
                                  ),
                                ])
                              : null,
                        ),
                    ]),
            ),
            const SizedBox(height: 16),
            const DeliveryCard(),
            const SizedBox(height: 16),
            Text('Recent', style: Theme.of(context).textTheme.titleMedium),
            AsyncView(
              value: ref.watch(pushHistoryProvider),
              onRetry: () => ref.invalidate(pushHistoryProvider),
              data: (rows) => rows.isEmpty
                  ? const EmptyState(icon: Icons.campaign_outlined, title: 'Nothing sent yet')
                  : Column(children: [
                      for (final r in rows)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${r['title']}'),
                          subtitle: Text('${r['body']}\n${dateText(r['created_at'])} · ${r['audience']}'
                              '${(r['partner_types'] as List?)?.isNotEmpty ?? false ? ' (${(r['partner_types'] as List).join(', ')})' : ''}'
                              '${PushArea.fromJson(r['target']).label.isEmpty ? '' : ' ${PushArea.fromJson(r['target']).label}'}'
                              '${r['schedule_id'] == null ? '' : ' · scheduled'}'),
                          isThreeLine: true,
                          trailing: Text('${r['sent'] ?? 0}/${r['recipients'] ?? 0}'),
                        ),
                    ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Trip updates and payment pushes are retried until an app acknowledges
/// them: how many arrived, how fast, and how many gave up (last 24 h).
class DeliveryCard extends ConsumerWidget {
  const DeliveryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('push-delivery'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(notificationDeliveryProvider),
          onRetry: () => ref.invalidate(notificationDeliveryProvider),
          data: (rows) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('Delivery (last 24 h)', style: t.textTheme.titleMedium)),
              Text(deliveryRateText(overallDeliveryRate(rows)),
                  key: const ValueKey('push-delivery-rate'),
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            Text('Trip updates and payment pushes are sent again until the app confirms it has them.',
                style: t.textTheme.bodySmall),
            if (rows.isEmpty)
              const Padding(padding: EdgeInsets.only(top: 12), child: Text('No trip pushes yet.'))
            else
              for (final r in rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${r.label}${r.priority == 'critical' ? ' · critical' : ''}'),
                  subtitle: Text('${r.delivered}/${r.sent} delivered · ${r.pending} retrying · ${r.gaveUp} gave up'
                      ' · acknowledged in ${ackTimeText(r.avgAckSeconds)}'),
                  trailing: Text(deliveryRateText(r.rate),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: (r.rate ?? 1) < 0.9 ? t.colorScheme.error : null,
                      )),
                ),
          ]),
        ),
      ),
    );
  }
}
