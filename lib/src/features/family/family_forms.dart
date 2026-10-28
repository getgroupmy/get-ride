// The host's forms (migration 0317): invite a member by phone, add a child
// without a phone, change what a member gets (limits, services, location),
// and ask the admin for more members. Values the admin's region allows only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/family.dart';
import '../../core/format.dart' show formatMoney;
import '../../data/family_repository.dart';
import '../../data/photo_picker.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/page_style_host.dart';

String _m(num v) => formatMoney(v);

/// Opens the right form: invite with a phone, or a child without one.
Future<bool> openAddFamilyMember(BuildContext context, FamilyView view) async {
  if (view.full) {
    return openAskForMore(context, view);
  }
  final choice = await showAppSheet<String>(
    id: 'family.add',
    context: context,
    fitContent: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          key: const ValueKey('family-add-invite'),
          leading: const Icon(Icons.phone_iphone),
          title: const Text('Invite with a phone number'),
          subtitle: const Text('They read what joining means and tap Join. Nothing is shared before.'),
          onTap: () => Navigator.pop(c, 'invite'),
        ),
        if (view.settings.children)
          ListTile(
            key: const ValueKey('family-add-child'),
            leading: const Icon(Icons.child_care),
            title: const Text('Add a child without a phone'),
            subtitle: const Text('A profile under you. You book their rides; the driver checks a pickup code.'),
            onTap: () => Navigator.pop(c, 'child'),
          ),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return false;
  final done = await showAppSheet<bool>(
    id: choice == 'invite' ? 'family.invite-form' : 'family.child-form',
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => choice == 'invite' ? FamilyMemberForm(view: view) : FamilyChildForm(view: view),
  );
  return done == true;
}

/// Asks the admin for more members than the region allows.
Future<bool> openAskForMore(BuildContext context, FamilyView view) async {
  var wanted = view.cap + 2;
  final reason = TextEditingController();
  final ok = await showAppDialog<bool>(
    id: 'family.ask-more',
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Ask for more members'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your family has ${view.count} of ${view.cap}. An admin decides.'),
          const SizedBox(height: 12),
          Row(children: [
            const Expanded(child: Text('Members')),
            IconButton(
              tooltip: 'Fewer',
              onPressed: wanted > view.cap + 1 ? () => set(() => wanted--) : null,
              icon: const Icon(Icons.remove),
            ),
            Text('$wanted', key: const ValueKey('family-ask-wanted')),
            IconButton(
              key: const ValueKey('family-ask-more-plus'),
              tooltip: 'More',
              onPressed: wanted < 200 ? () => set(() => wanted++) : null,
              icon: const Icon(Icons.add),
            ),
          ]),
          TextField(
            key: const ValueKey('family-ask-reason'),
            controller: reason,
            maxLength: 300,
            decoration: const InputDecoration(labelText: 'Why (optional)'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('family-ask-send'), onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    await container.read(familyRepositoryProvider).requestCap(wanted, reason: reason.text.trim());
    if (context.mounted) showInfo(context, 'Request sent. You get a message when an admin decides.');
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// The modules a member can be allowed, ticked; none ticked means all.
class _ServicePicker extends StatelessWidget {
  const _ServicePicker({required this.modules, required this.picked, required this.onChanged});
  final List<FamilyModule> modules;
  final Set<String>? picked;
  final ValueChanged<Set<String>?> onChanged;

  @override
  Widget build(BuildContext context) {
    final all = picked == null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Services they can use', style: Theme.of(context).textTheme.titleSmall),
      Wrap(spacing: 6, runSpacing: 6, children: [
        FilterChip(
          key: const ValueKey('family-services-all'),
          label: const Text('All the family covers'),
          selected: all,
          onSelected: (v) => onChanged(v ? null : {for (final m in modules) m.key}),
        ),
        for (final m in modules)
          FilterChip(
            key: ValueKey('family-service-${m.key}'),
            label: Text(m.name),
            selected: all || picked!.contains(m.key),
            onSelected: (v) {
              final next = {...(picked ?? {for (final x in modules) x.key})};
              v ? next.add(m.key) : next.remove(m.key);
              onChanged(next.length == modules.length ? null : next);
            },
          ),
      ]),
    ]);
  }
}

/// Location the host may see, never more than the admin's rule.
class _LocationPicker extends StatelessWidget {
  const _LocationPicker({required this.max, required this.value, required this.onChanged});
  final FamilyLocationRule max;
  final FamilyLocationRule value;
  final ValueChanged<FamilyLocationRule> onChanged;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Their location you can see', style: Theme.of(context).textTheme.titleSmall),
    const SizedBox(height: 6),
    SegmentedButton<FamilyLocationRule>(
      key: const ValueKey('family-location'),
      segments: [
        for (final r in FamilyLocationRule.values)
          if (r.index <= max.index)
            ButtonSegment(value: r, label: Text(r == FamilyLocationRule.always ? 'Always, if allowed' : r.label)),
      ],
      selected: {value.atMost(max)},
      onSelectionChanged: (s) => onChanged(s.first),
    ),
    const SizedBox(height: 4),
    Text(
      'They are told before joining and see "Shared with family" whenever it is on. More than they agreed to '
      'waits for them to accept.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  ]);
}

/// Monthly limit (up to the region's highest) and a per-trip limit choice.
class _Limits extends StatelessWidget {
  const _Limits({
    required this.settings,
    required this.monthly,
    required this.perRide,
    required this.onPerRide,
    required this.onChanged,
  });
  final FamilySettings settings;
  final TextEditingController monthly;
  final double? perRide;
  final ValueChanged<double?> onPerRide;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    TextField(
      key: const ValueKey('family-monthly'),
      controller: monthly,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: 'Monthly limit',
        helperText: 'Empty: up to ${_m(settings.monthCap)}, the most your area allows',
      ),
      onChanged: (_) => onChanged(),
    ),
    const SizedBox(height: 10),
    Text('Per-trip limit', style: Theme.of(context).textTheme.titleSmall),
    Wrap(spacing: 6, children: [
      ChoiceChip(
        key: const ValueKey('family-per-ride-none'),
        label: const Text('None'),
        selected: perRide == null,
        onSelected: (_) => onPerRide(null),
      ),
      for (final c in settings.perRideChoices)
        ChoiceChip(
          key: ValueKey('family-per-ride-${c.toStringAsFixed(0)}'),
          label: Text(_m(c)),
          selected: perRide == c,
          onSelected: (_) => onPerRide(c),
        ),
    ]),
  ]);
}

/// Why the monthly field can't be used, or null.
String? _monthlyProblem(String raw, double cap) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null || v < 0) return 'Enter an amount.';
  if (v > cap) return 'Up to ${_m(cap)} a month.';
  return null;
}

/// Invite with a phone number, or change a member ([member]).
class FamilyMemberForm extends ConsumerStatefulWidget {
  const FamilyMemberForm({super.key, required this.view, this.member});
  final FamilyView view;
  final FamilyMember? member;

  @override
  ConsumerState<FamilyMemberForm> createState() => _FamilyMemberFormState();
}

class _FamilyMemberFormState extends ConsumerState<FamilyMemberForm> {
  late final _name = TextEditingController(text: widget.member?.name ?? '');
  late final _phone = TextEditingController(text: widget.member?.phone ?? '');
  late final _relation = TextEditingController(text: widget.member?.relation ?? '');
  late final _monthly = TextEditingController(
      text: widget.member?.monthlyLimit == null ? '' : widget.member!.monthlyLimit!.toStringAsFixed(0));
  late double? _perRide = widget.member?.perRideLimit;
  late Set<String>? _services = widget.member?.services?.toSet();
  late FamilyLocationRule _location = widget.member?.locationPending ?? widget.member?.location ?? FamilyLocationRule.ride;

  bool get _editing => widget.member != null;

  @override
  void dispose() {
    for (final c in [_name, _phone, _relation, _monthly]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get _problem {
    if (!_editing) {
      if (_name.text.trim().isEmpty) return 'Enter their name.';
      final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
      if (digits.length < 6 || digits.length > 15) return 'Enter their phone number.';
    }
    return _monthlyProblem(_monthly.text, widget.view.settings.monthCap);
  }

  Future<void> _save() async {
    final repo = ref.read(familyRepositoryProvider);
    final monthly = _monthly.text.trim().isEmpty ? null : double.parse(_monthly.text.trim());
    try {
      if (_editing) {
        await repo.updateMember(widget.member!.id, {
          'monthlyLimit': monthly,
          'perRideLimit': _perRide,
          'services': _services?.toList(),
          'location': _location.db,
          if (_relation.text.trim().isNotEmpty) 'relation': _relation.text.trim(),
        });
      } else {
        await repo.invite(
          phone: _phone.text.trim(),
          name: _name.text.trim(),
          relation: _relation.text.trim().isEmpty ? null : _relation.text.trim(),
          monthlyLimit: monthly,
          perRideLimit: _perRide,
          services: _services?.toList(),
          location: _location,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      showInfo(
        context,
        _editing
            ? 'Saved. ${widget.member!.name.split(' ').first} gets a notice of the change.'
            : 'Invited. They see the invite when they open GET.ride with that number.',
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final problem = _problem;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_editing ? widget.member!.name : 'Invite a family member',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (!_editing) ...[
            TextField(
              key: const ValueKey('family-invite-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const ValueKey('family-invite-phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number', hintText: '+60 12 345 6789'),
              onChanged: (_) => setState(() {}),
            ),
          ],
          TextField(
            key: const ValueKey('family-invite-relation'),
            controller: _relation,
            decoration: const InputDecoration(labelText: 'Relation (optional)', hintText: 'Daughter, husband, mother'),
          ),
          const SizedBox(height: 12),
          _Limits(
            settings: v.settings,
            monthly: _monthly,
            perRide: _perRide,
            onPerRide: (x) => setState(() => _perRide = x),
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _ServicePicker(modules: v.payModules, picked: _services, onChanged: (s) => setState(() => _services = s)),
          const SizedBox(height: 12),
          _LocationPicker(
            max: v.settings.locationRule,
            value: _location,
            onChanged: (r) => setState(() => _location = r),
          ),
          const SizedBox(height: 16),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(problem, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          BusyButton.filled(
            key: const ValueKey('family-invite-save'),
            onPressed: problem == null ? _save : null,
            child: Text(_editing ? 'Save' : 'Send invite'),
          ),
        ]),
      ),
    );
  }
}

/// A child without a phone: name, birth date (the boxes), photo for the
/// driver's check, and the services they can be booked on.
class FamilyChildForm extends ConsumerStatefulWidget {
  const FamilyChildForm({super.key, required this.view, this.member});
  final FamilyView view;
  final FamilyMember? member;

  @override
  ConsumerState<FamilyChildForm> createState() => _FamilyChildFormState();
}

class _FamilyChildFormState extends ConsumerState<FamilyChildForm> {
  late final _name = TextEditingController(text: widget.member?.name ?? '');
  late final _relation = TextEditingController(text: widget.member?.relation ?? '');
  late final _birth = TextEditingController(
      text: widget.member?.birthDate == null ? '' : widget.member!.birthDate!.toIso8601String().substring(0, 10));
  late Set<String>? _services = widget.member?.services?.toSet();
  late String? _photo = widget.member?.photoUrl;
  bool _uploading = false;

  bool get _editing => widget.member != null;

  @override
  void dispose() {
    for (final c in [_name, _relation, _birth]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get _problem {
    if (_name.text.trim().isEmpty) return 'Enter the child\'s name.';
    if (parseIsoDate(_birth.text) == null) return 'Enter the date of birth.';
    return null;
  }

  Future<void> _pickPhoto() async {
    final pick = await ref.read(photoPickerProvider)(PhotoSource.gallery);
    if (pick == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final url = await ref.read(familyRepositoryProvider).uploadChildPhoto(pick.bytes);
      if (mounted) setState(() => _photo = url);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    final repo = ref.read(familyRepositoryProvider);
    try {
      if (_editing) {
        await repo.updateMember(widget.member!.id, {
          'name': _name.text.trim(),
          'birthDate': _birth.text,
          'photoUrl': _photo,
          'services': _services?.toList(),
          if (_relation.text.trim().isNotEmpty) 'relation': _relation.text.trim(),
        });
      } else {
        await repo.addChild(
          name: _name.text.trim(),
          birthDate: _birth.text,
          photoUrl: _photo,
          relation: _relation.text.trim().isEmpty ? null : _relation.text.trim(),
          services: _services?.toList(),
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      showInfo(context, _editing ? 'Saved.' : 'Added. Book their rides from any booking screen.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final now = DateTime.now();
    final problem = _problem;
    final childModules = [for (final m in v.modules) if (m.switches.childAllowed) m];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_editing ? widget.member!.name : 'Add a child', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Children under ${v.settings.aloneAge} ride with an adult. '
            '${v.settings.womenDriversForChildren ? 'Women drivers take children\'s rides. ' : ''}'
            'The driver checks a new 4-digit code at every pickup.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          TextField(
            key: const ValueKey('family-child-name'),
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          DateBoxesField(
            key: const ValueKey('family-child-birth'),
            label: 'Date of birth',
            controller: _birth,
            firstDate: DateTime(now.year - 18, now.month, now.day + 1),
            lastDate: now,
            isRequired: true,
            onChanged: (_) => setState(() {}),
          ),
          if (parseIsoDate(_birth.text) case final b?)
            Text('Age ${childAge(b, now)} · born ${formatStoredDateForUser(_birth.text)}',
                style: Theme.of(context).textTheme.bodySmall),
          TextField(
            key: const ValueKey('family-child-relation'),
            controller: _relation,
            decoration: const InputDecoration(labelText: 'Relation (optional)', hintText: 'Son, daughter'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            const Expanded(child: Text('A photo helps the driver know them')),
            TextButton.icon(
              key: const ValueKey('family-child-photo'),
              onPressed: _uploading ? null : _pickPhoto,
              icon: Icon(_photo == null ? Icons.add_a_photo_outlined : Icons.check_circle_outline),
              label: Text(_uploading ? 'Uploading' : (_photo == null ? 'Add photo' : 'Change photo')),
            ),
          ]),
          const SizedBox(height: 8),
          _ServicePicker(modules: childModules, picked: _services, onChanged: (s) => setState(() => _services = s)),
          const SizedBox(height: 16),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(problem, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          BusyButton.filled(
            key: const ValueKey('family-child-save'),
            onPressed: problem == null && !_uploading ? _save : null,
            child: Text(_editing ? 'Save' : 'Add child'),
          ),
        ]),
      ),
    );
  }
}

/// Change a member or child; or remove them.
Future<bool> openEditFamilyMember(BuildContext context, FamilyView view, FamilyMember m) async {
  final done = await showAppSheet<bool>(
    id: 'family.member-edit',
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => m.isChild ? FamilyChildForm(view: view, member: m) : FamilyMemberForm(view: view, member: m),
  );
  return done == true;
}

/// Asks, then removes [m]: sharing and family payment stop at once.
Future<bool> confirmRemoveFamilyMember(BuildContext context, FamilyMember m) async {
  final ok = await showAppDialog<bool>(
    id: 'family.remove',
    context: context,
    builder: (c) => AlertDialog(
      title: Text(m.isInvited ? 'Cancel the invite?' : 'Remove ${m.name.split(' ').first}?'),
      content: Text(m.isInvited
          ? 'The invite stops working.'
          : 'Nothing is shared any more and the family stops paying for them, at once.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
        FilledButton(key: const ValueKey('family-remove-confirm'), onPressed: () => Navigator.pop(c, true),
            child: Text(m.isInvited ? 'Cancel invite' : 'Remove')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  try {
    await ProviderScope.containerOf(context, listen: false).read(familyRepositoryProvider).removeMember(m.id);
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}
