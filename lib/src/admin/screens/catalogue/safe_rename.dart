// Renaming a Vehicle Service or a Partner Service type (docs/KIV.md M2,
// migration 0304). Services, types, switches, locks and promotions find
// them by name, so a rename goes through the server's cascade: the edit
// sheet shows what follows the new name, the preview lists every place with
// examples, a name already used is refused, and the Rename history card
// changes the latest rename back.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/partner_type_rules.dart' show partnerTypeNameKey;
import '../../../providers.dart';
import '../../../widgets/app_notice.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import 'catalogue_data.dart';
import 'catalogue_logic.dart';

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

/// "Vehicle Service" or "Partner Service type".
String renameCategoryLabel(String category) =>
    category == partnerTypeKey ? 'Partner Service type' : 'Vehicle Service';

/// A place of the preview: its title and icon (the server's key).
({String title, IconData icon}) renamePlaceLook(String key) => switch (key) {
      'type_services' => (title: 'Partner type services', icon: Icons.groups_outlined),
      'driver_switches' => (title: 'Driver switches', icon: Icons.toggle_on_outlined),
      'service_locks' => (title: 'Service locks', icon: Icons.lock_outline),
      'partner_type_locks' => (title: 'Partner type locks', icon: Icons.lock_person_outlined),
      'promo_codes' => (title: 'Promo codes', icon: Icons.sell_outlined),
      'commission_promotions' => (title: 'Commission promotions', icon: Icons.percent),
      'permit_services' || 'permit_types' => (title: 'Permit types', icon: Icons.assignment_outlined),
      'partners' => (title: 'Partners', icon: Icons.badge_outlined),
      'vehicles' => (title: 'Vehicles', icon: Icons.directions_car_outlined),
      'vehicle_checks' => (title: 'Per-vehicle service checks', icon: Icons.fact_check_outlined),
      'push_audiences' => (title: 'Push audiences', icon: Icons.notifications_outlined),
      'document_rules' => (title: 'Document rules', icon: Icons.description_outlined),
      'driver_locks' => (title: 'Driver locks', icon: Icons.lock_outline),
      _ => (title: key.replaceAll('_', ' '), icon: Icons.link),
    };

/// "1 place" / "23 places".
String placesText(int n) => n == 1 ? '1 place' : '$n places';

/// The save button of an edit sheet that renames.
String renameSaveLabel(int? places) => places == null ? 'Save and update' : 'Save and update ${placesText(places)}';

/// The success message: "23 places now use Comfort Plus."
String renamedMessage(int total, String newName) => switch (total) {
      0 => 'Nothing else used the old name. It is $newName now.',
      1 => '1 place now uses $newName.',
      _ => '$total places now use $newName.',
    };

/// The undo's message: "23 places use Comfort again."
String undoneMessage(int total, String oldName) => switch (total) {
      0 => 'It is $oldName again.',
      1 => '1 place uses $oldName again.',
      _ => '$total places use $oldName again.',
    };

/// Another entry's name [name] clashes with (no case or extra spaces, or the
/// same key: "premium ", "Pre-mium"), as the server compares them; null when
/// none does.
String? renameClash(String name, Iterable<String> others) {
  final n = name.trim();
  if (n.isEmpty) return null;
  for (final o in others) {
    final t = o.trim();
    if (t.isEmpty) continue;
    if (t.toLowerCase() == n.toLowerCase() || partnerTypeNameKey(t) == partnerTypeNameKey(n)) return t;
  }
  return null;
}

/// The refusal for a name already used.
String renameTakenMessage(String category, String other) => 'A ${renameCategoryLabel(category)} named $other already exists.';

/// What the field says under a name already used.
String renameTakenHint(String other) =>
    'Names are matched without case or extra spaces, so "${other.toLowerCase()} " counts too. Pick another name, '
    'or edit $other instead.';

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// One place a rename changes.
class RenamePlace {
  const RenamePlace({required this.key, required this.count, this.examples = const [], this.more = 0});

  factory RenamePlace.fromJson(Map j) => RenamePlace(
        key: '${j['key'] ?? ''}',
        count: _int(j['count']),
        examples: [for (final x in (j['examples'] as List?) ?? const []) '$x'],
        more: _int(j['more']),
      );

  final String key;
  final int count;
  final List<String> examples;
  final int more;

  String get title => renamePlaceLook(key).title;
  IconData get icon => renamePlaceLook(key).icon;

  /// "RIDE10, WEEKEND", "Aiman R., Siti N. and 9 more.", "None use Comfort."
  String examplesText(String oldName) {
    if (count == 0 || examples.isEmpty) return count == 0 ? 'None use $oldName.' : '$count use $oldName.';
    final list = examples.join(', ');
    return more > 0 ? '$list and $more more.' : list;
  }
}

/// What renaming an entry would change (admin_rename_preview).
class RenamePreview {
  const RenamePreview({
    required this.category,
    required this.entryId,
    required this.oldName,
    required this.newName,
    this.problemCode,
    this.problemMessage,
    this.conflictName,
    this.places = const [],
    this.total = 0,
    this.openRequests = 0,
    this.bookings = 0,
    this.finishedRides = 0,
  });

  factory RenamePreview.fromJson(Map j) {
    final p = j['problem'];
    return RenamePreview(
      category: '${j['category'] ?? ''}',
      entryId: '${j['entry_id'] ?? ''}',
      oldName: '${j['old_name'] ?? ''}',
      newName: '${j['new_name'] ?? ''}',
      problemCode: p is Map ? '${p['code'] ?? ''}' : null,
      problemMessage: p is Map ? '${p['message'] ?? ''}' : null,
      conflictName: p is Map && p['conflict_name'] != null ? '${p['conflict_name']}' : null,
      places: [for (final x in (j['places'] as List?) ?? const []) if (x is Map) RenamePlace.fromJson(x)],
      total: _int(j['total']),
      openRequests: _int(j['open_requests']),
      bookings: _int(j['bookings']),
      finishedRides: _int(j['finished_rides']),
    );
  }

  final String category;
  final String entryId;
  final String oldName;
  final String newName;
  final String? problemCode;
  final String? problemMessage;
  final String? conflictName;
  final List<RenamePlace> places;
  final int total;
  final int openRequests;
  final int bookings;
  final int finishedRides;

  bool get conflict => problemCode == 'RENAME_NAME_TAKEN';
  bool get ok => problemCode == null;
  bool get isPartnerType => category == partnerTypeKey;
}

/// A done rename (settings_renames).
class RenameRecord {
  const RenameRecord({
    required this.id,
    required this.oldName,
    required this.newName,
    required this.total,
    required this.at,
    this.byName,
    this.undoneAt,
  });

  factory RenameRecord.fromRow(Map r) => RenameRecord(
        id: '${r['id']}',
        oldName: '${r['old_name'] ?? ''}',
        newName: '${r['new_name'] ?? ''}',
        total: _int(r['total']),
        at: DateTime.tryParse('${r['at'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0),
        byName: (r['by_name'] as String?)?.trim().isEmpty ?? true ? null : (r['by_name'] as String).trim(),
        undoneAt: r['undone_at'] == null ? null : DateTime.tryParse('${r['undone_at']}'),
      );

  final String id;
  final String oldName;
  final String newName;
  final int total;
  final DateTime at;
  final String? byName;
  final DateTime? undoneAt;

  bool get undone => undoneAt != null;

  /// "Farah Z. (admin) · 27 Oct 2026, 14:05 · 23 places updated"
  String get line => [
        '${byName ?? 'An admin'} (admin)',
        DateFormat('d MMM y, HH:mm').format(at.toLocal()),
        '${placesText(total)} updated',
      ].join(' · ');
}

/// What apply and undo answer: the names as the rename had them.
typedef RenameDone = ({String id, String oldName, String newName, int total});

RenameDone _done(Object? j) {
  final m = j is Map ? j : const {};
  return (
    id: '${m['id'] ?? ''}',
    oldName: '${m['old_name'] ?? ''}',
    newName: '${m['new_name'] ?? ''}',
    total: _int(m['total']),
  );
}

class RenameRepository {
  RenameRepository(this._db);
  final SupabaseClient _db;

  Future<RenamePreview> preview(String category, String entryId, String newName) async => RenamePreview.fromJson(
        (await _db.rpc('admin_rename_preview',
            params: {'p_category': category, 'p_entry': entryId, 'p_new_name': newName})) as Map,
      );

  Future<RenameDone> apply(String category, String entryId, String newName) async => _done(
        await _db.rpc('admin_rename_apply', params: {'p_category': category, 'p_entry': entryId, 'p_new_name': newName}),
      );

  Future<RenameDone> undo(String renameId) async =>
      _done(await _db.rpc('admin_rename_undo', params: {'p_rename_id': renameId}));

  /// The entry's renames, newest first.
  Future<List<RenameRecord>> history(String entryId) async => [
        for (final r in await _db
            .from('settings_renames')
            .select()
            .eq('entry_id', entryId)
            .order('at', ascending: false)
            .limit(20))
          RenameRecord.fromRow(r),
      ];
}

final renameRepositoryProvider = Provider((ref) => RenameRepository(ref.watch(supabaseProvider)));

final renameHistoryProvider = FutureProvider.autoDispose.family<List<RenameRecord>, String>(
  (ref, entryId) => ref.watch(renameRepositoryProvider).history(entryId),
);

// ---------------------------------------------------------------------------
// The name field of an edit sheet
// ---------------------------------------------------------------------------

/// The name of an entry being edited and, when it changed, what the server
/// says about the new one.
class RenameFieldController extends ChangeNotifier {
  RenameFieldController({
    required this.category,
    required this.entryId,
    required String name,
    this.otherNames = const [],
  })  : originalName = name.trim(),
        text = TextEditingController(text: name);

  final String category;

  /// Null for a new entry: nothing to rename.
  final String? entryId;
  final String originalName;

  /// The category's other names, for a clash seen before the server answers.
  final List<String> otherNames;
  final TextEditingController text;

  RenamePreview? _preview;
  bool loading = false;
  Object? error;
  Timer? _debounce;

  String get newName => text.text.trim();

  /// The name changed on an entry that had one.
  bool get renaming => entryId != null && originalName.isNotEmpty && newName.isNotEmpty && newName != originalName;

  /// The server's answer for the name as typed now, else null.
  RenamePreview? get preview => renaming && _preview?.newName == newName ? _preview : null;

  /// The other entry the new name clashes with.
  String? get takenBy {
    if (!renaming) return null;
    final local = renameClash(newName, otherNames);
    if (local != null) return local;
    final p = preview;
    return p != null && p.conflict ? (p.conflictName ?? newName) : null;
  }

  /// Why the new name can't be saved (taken, Teksi, a comma …), else null.
  String? get problem {
    final t = takenBy;
    if (t != null) return renameTakenMessage(category, t);
    final p = preview;
    return p != null && !p.ok ? p.problemMessage : null;
  }

  /// The places the rename would update, once known.
  int? get places => preview?.ok == true ? preview!.total : null;

  /// Asks the server about the name as typed now.
  Future<RenamePreview?> refresh(RenameRepository repo) async {
    _debounce?.cancel();
    if (!renaming || renameClash(newName, otherNames) != null) {
      notifyListeners();
      return null;
    }
    final asked = newName;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final p = await repo.preview(category, entryId!, asked);
      if (asked == newName) _preview = p;
      return p;
    } catch (e) {
      if (asked == newName) error = e;
      return null;
    } finally {
      if (asked == newName) loading = false;
      notifyListeners();
    }
  }

  /// [refresh] a moment after the typing stops.
  void schedule(RenameRepository repo, {Duration after = const Duration(milliseconds: 400)}) {
    _debounce?.cancel();
    notifyListeners();
    if (!renaming) return;
    _debounce = Timer(after, () => refresh(repo));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    text.dispose();
    super.dispose();
  }
}

/// The name field: the old name under it, a name already used refused, and
/// "What follows the new name" while it changes.
class RenameNameField extends ConsumerStatefulWidget {
  const RenameNameField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.enabled = true,
    this.onReview,
  });

  final RenameFieldController controller;
  final String label;
  final String? hint;
  final bool enabled;

  /// "See every place": the preview, as Save shows it.
  final VoidCallback? onReview;

  @override
  ConsumerState<RenameNameField> createState() => _RenameNameFieldState();
}

class _RenameNameFieldState extends ConsumerState<RenameNameField> {
  RenameFieldController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
  }

  @override
  void didUpdateWidget(RenameNameField old) {
    super.didUpdateWidget(old);
    if (old.controller != c) {
      old.controller.removeListener(_changed);
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final taken = c.takenBy;
    final problem = c.problem;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        key: const ValueKey('rename-name'),
        controller: c.text,
        enabled: widget.enabled,
        onChanged: (_) => c.schedule(ref.read(renameRepositoryProvider)),
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          errorText: problem,
          errorMaxLines: 3,
          helperText: c.renaming && problem == null
              ? 'Was ${c.originalName}. Saving moves every place that uses the old name.'
              : null,
          helperMaxLines: 3,
        ),
      ),
      if (taken != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            renameTakenHint(taken),
            key: const ValueKey('rename-taken-hint'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
      if (c.renaming && problem == null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: RenameSummaryCard(
            preview: c.preview,
            oldName: c.originalName,
            loading: c.loading,
            error: c.error,
            onRetry: () => c.refresh(ref.read(renameRepositoryProvider)),
            onSeeAll: widget.onReview,
          ),
        ),
    ]);
  }
}

/// "What follows the new name": the places with a count, and the finished
/// rides that keep the old name.
class RenameSummaryCard extends StatelessWidget {
  const RenameSummaryCard({
    super.key,
    required this.preview,
    required this.oldName,
    this.loading = false,
    this.error,
    this.onRetry,
    this.onSeeAll,
  });

  final RenamePreview? preview;
  final String oldName;
  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final muted = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final p = preview;
    final rows = p == null ? const <RenamePlace>[] : [for (final x in p.places) if (x.count > 0) x];
    return Container(
      key: const ValueKey('rename-summary'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('What follows the new name', style: t.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (p == null && error != null) ...[
          Text(errorText(error!), style: t.textTheme.bodyMedium?.copyWith(color: cs.error)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onRetry, child: const Text('Try again')),
          ),
        ] else if (p == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          )
        else ...[
          if (rows.isEmpty)
            Text('Nothing else uses $oldName.', style: t.textTheme.bodyMedium)
          else
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Text(r.title, style: t.textTheme.bodyMedium)),
                  Text('${r.count}', key: ValueKey('rename-summary-${r.key}'), style: t.textTheme.bodyMedium),
                ]),
              ),
          if (!p.isPartnerType && p.finishedRides > 0) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.history, size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${p.finishedRides} finished ride${p.finishedRides == 1 ? '' : 's'} keep${p.finishedRides == 1 ? 's' : ''} the name $oldName.',
                  style: muted,
                ),
              ),
            ]),
          ],
          if (onSeeAll != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('rename-see-all'),
                onPressed: onSeeAll,
                child: const Text('See every place'),
              ),
            ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// The preview
// ---------------------------------------------------------------------------

/// Light and dark: the green of "these keep running".
({Color bg, Color fg}) _runningColors(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? (bg: const Color(0xFF1F3A26), fg: const Color(0xFFA8DBB3))
    : (bg: const Color(0xFFE3F1E6), fg: const Color(0xFF1D5B2B));

/// "Rename Comfort to Comfort Plus?": every place with its count (a row
/// opens its examples) and what is not changed. True on Rename.
Future<bool> showRenamePreviewDialog(BuildContext context, RenamePreview preview) async =>
    await showAppDialog<bool>(
      id: 'catalogue.rename-preview',
      context: context,
      builder: (ctx) => RenamePreviewDialog(preview: preview),
    ) ==
    true;

class RenamePreviewDialog extends StatefulWidget {
  const RenamePreviewDialog({super.key, required this.preview});
  final RenamePreview preview;

  @override
  State<RenamePreviewDialog> createState() => _RenamePreviewDialogState();
}

class _RenamePreviewDialogState extends State<RenamePreviewDialog> {
  // The first row starts open, as the owner's mockup.
  final _open = <int>{0};

  RenamePreview get p => widget.preview;

  Widget _row(BuildContext context, int i, RenamePlace r) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final open = _open.contains(i);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        key: ValueKey('rename-place-${r.key}'),
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => open ? _open.remove(i) : _open.add(i)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 2, 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(children: [
                  Icon(r.icon, color: cs.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(child: Text(r.title, style: t.textTheme.bodyLarge)),
                  Text('${r.count}', style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  IconButton(
                    tooltip: '${open ? 'Hide' : 'Show'} examples for ${r.title}',
                    icon: Icon(open ? Icons.expand_less : Icons.expand_more),
                    onPressed: () => setState(() => open ? _open.remove(i) : _open.add(i)),
                  ),
                ]),
              ),
              if (open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(34, 0, 48, 10),
                  child: Text(
                    r.examplesText(p.oldName),
                    key: ValueKey('rename-examples-${r.key}'),
                    style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _note({required IconData icon, required String text, String? count, required Color bg, required Color fg,
      Key? key}) {
    final t = Theme.of(context);
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: fg),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: fg))),
        if (count != null) ...[
          const SizedBox(width: 8),
          Text(count, style: t.textTheme.bodyLarge?.copyWith(color: fg, fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final muted = t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant);
    final running = _runningColors(context);
    return AlertDialog(
      key: const ValueKey('rename-preview'),
      scrollable: true,
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (p.isPartnerType) Text('Partner Service type', style: t.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
        Text('Rename ${p.oldName} to ${p.newName}?'),
      ]),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'These ${placesText(p.total)} change to the new name together.'
            '${p.places.isEmpty ? '' : ' Tap a row to see examples.'}',
            style: muted,
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < p.places.length; i++) _row(context, i, p.places[i]),
          if (p.isPartnerType)
            _note(
              key: const ValueKey('rename-approved-note'),
              icon: Icons.info_outline,
              text: 'Approved partners\' types change too, without asking them again. They keep their approval and '
                  'their jobs.',
              bg: cs.primaryContainer,
              fg: cs.onPrimaryContainer,
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text('Not changed', style: t.textTheme.titleSmall),
            ),
            _note(
              key: const ValueKey('rename-running'),
              icon: Icons.play_circle_outline,
              text: 'Open requests and bookings for later, these keep running',
              count: '${p.openRequests} + ${p.bookings}',
              bg: running.bg,
              fg: running.fg,
            ),
            _note(
              key: const ValueKey('rename-finished'),
              icon: Icons.history,
              text: 'Finished rides keep the old name',
              count: '${p.finishedRides}',
              bg: cs.surfaceContainerHighest,
              fg: cs.onSurface,
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('rename-confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// Before an edit sheet saves a new name: the server's answer for it (asked
/// again when the one on hand is for another name), then the preview. True
/// when the admin chose Rename; false on a problem (the field shows it) or
/// Cancel.
Future<bool> reviewRename(BuildContext context, WidgetRef ref, RenameFieldController c) async {
  if (!c.renaming) return true;
  if (c.problem != null) return false;
  final p = c.preview ?? await c.refresh(ref.read(renameRepositoryProvider));
  if (p == null) {
    if (c.error != null && context.mounted) showError(context, c.error!);
    return false;
  }
  if (!p.ok || !context.mounted) return false;
  return showRenamePreviewDialog(context, p);
}

// ---------------------------------------------------------------------------
// Saving and undoing
// ---------------------------------------------------------------------------

/// "Renamed. 23 places now use Comfort Plus." as a modal with an OK.
Future<void> showRenamedNotice(BuildContext context, {required int total, required String newName}) => showAppNotice(
      id: 'notice.catalogue-rename',
      context: context,
      title: 'Renamed',
      message: renamedMessage(total, newName),
      kind: NoticeKind.success,
    );

/// Saves an edited entry whose name changed: its other values first, under
/// the old name, then the rename with every place that uses it (0304), then
/// "Renamed". True when both went through.
Future<bool> saveEntryWithRename(
  BuildContext context,
  WidgetRef ref, {
  required SettingsCategory category,
  required SettingEntry entry,
  required Map<String, dynamic> values,
}) async {
  final newName = str(values['name']).trim();
  try {
    await ref.read(adminRepositoryProvider).saveSetting(
      category,
      id: entry.id,
      values: {...values, 'name': entry.values['name']},
      position: 0,
    );
    final done = await ref.read(renameRepositoryProvider).apply(category.key, entry.id, newName);
    ref.invalidate(catalogueEntriesProvider(category));
    ref.invalidate(renameHistoryProvider(entry.id));
    if (context.mounted) unawaited(showRenamedNotice(context, total: done.total, newName: newName));
    return true;
  } catch (e) {
    ref.invalidate(catalogueEntriesProvider(category));
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Whether [values] rename [entry] (its name, trimmed, changed).
bool renamesEntry(SettingEntry? entry, Map<String, dynamic> values) {
  if (entry == null) return false;
  final was = str(entry.values['name']).trim();
  return was.isNotEmpty && str(values['name']).trim() != was;
}

// ---------------------------------------------------------------------------
// Rename history
// ---------------------------------------------------------------------------

/// The entry's renames, newest first; the latest, not undone yet, can be
/// changed back ("Change 23 places back?"). Undoing closes the edit sheet.
class RenameHistoryCard extends ConsumerStatefulWidget {
  const RenameHistoryCard({super.key, required this.category, required this.entryId, this.canEdit = true});
  final SettingsCategory category;
  final String entryId;
  final bool canEdit;

  @override
  ConsumerState<RenameHistoryCard> createState() => _RenameHistoryCardState();
}

class _RenameHistoryCardState extends ConsumerState<RenameHistoryCard> {
  bool _asking = false;

  Future<void> _undo(RenameRecord r) async {
    final nav = Navigator.of(context);
    try {
      final done = await ref.read(renameRepositoryProvider).undo(r.id);
      ref.invalidate(catalogueEntriesProvider(widget.category));
      ref.invalidate(renameHistoryProvider(widget.entryId));
      if (!mounted) return;
      // The sheet shows the name from before: closed, the list has the old one.
      final at = nav.context;
      nav.maybePop();
      if (!at.mounted) return;
      unawaited(showAppNotice(
        id: 'notice.catalogue-rename',
        context: at,
        title: 'Changed back',
        message: undoneMessage(done.total, done.oldName.isEmpty ? r.oldName : done.oldName),
        kind: NoticeKind.success,
      ));
    } catch (e) {
      if (mounted) {
        setState(() => _asking = false);
        ref.invalidate(renameHistoryProvider(widget.entryId));
        showError(context, e);
      }
    }
  }

  Widget _record(BuildContext context, RenameRecord r, bool latest) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final muted = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    Widget? trailing;
    if (latest && !r.undone && widget.canEdit) {
      trailing = _asking
          ? Wrap(
              key: const ValueKey('rename-undo-ask'),
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Change ${placesText(r.total)} back?', style: t.textTheme.bodySmall),
                TextButton(onPressed: () => setState(() => _asking = false), child: const Text('Keep')),
                BusyButton.filled(
                  key: const ValueKey('rename-undo-confirm'),
                  onPressed: () => _undo(r),
                  child: const Text('Undo'),
                ),
              ],
            )
          : OutlinedButton.icon(
              key: const ValueKey('rename-undo'),
              onPressed: () => setState(() => _asking = true),
              icon: const Icon(Icons.undo, size: 20),
              label: const Text('Undo rename'),
            );
    } else if (r.undone) {
      trailing = Text('Changed back', style: muted);
    } else if (!latest) {
      trailing = Text('Only the latest can be undone', style: muted);
    }
    final names = Text.rich(TextSpan(style: t.textTheme.bodyLarge, children: [
      TextSpan(text: r.oldName),
      TextSpan(text: ' to ', style: TextStyle(color: cs.onSurfaceVariant)),
      TextSpan(text: r.newName, style: const TextStyle(fontWeight: FontWeight.w600)),
    ]));
    return Container(
      key: ValueKey('rename-record-${r.id}'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: cs.outlineVariant))),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            names,
            const SizedBox(height: 2),
            Text(r.line, style: muted),
          ]),
          ?trailing,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final list = ref.watch(renameHistoryProvider(widget.entryId)).value ?? const <RenameRecord>[];
    if (list.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('rename-history'),
      margin: const EdgeInsets.only(top: 16, bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.history, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('Rename history', style: t.textTheme.titleMedium),
        ]),
        const SizedBox(height: 8),
        for (var i = 0; i < list.length; i++) _record(context, list[i], i == 0),
      ]),
    );
  }
}
