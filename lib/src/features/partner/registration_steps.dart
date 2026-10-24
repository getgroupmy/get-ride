// Partner registration (0288): the steps that read a document — National
// ID, Check your details, Your company, Driver permit and Register vehicle.
// Each one uploads to the private document buckets, reads the photo
// (core/document_text.dart, through documentTextReaderProvider: the phone
// first, then the id-read function as the admin allows), shows what was
// read for the driver to check and correct, and keeps it on the profile,
// the partner row or the vehicle. Unreadable: the fields open empty.
// Every message is a modal.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/screens/meterapp/pick_image.dart' show PickedImage;
import '../../admin/screens/people/doc_pdf.dart';
import '../../admin/screens/people/people_data.dart';
import '../../admin/screens/people/people_logic.dart';
import '../../core/document_text.dart';
import '../../core/partner_onboarding.dart';
import '../../core/partner_registration.dart';
import '../../core/partner_type_rules.dart';
import '../../core/vehicle_onboarding.dart';
import '../../data/document_text_reader.dart';
import '../../data/partner_onboarding_repository.dart';
import '../../data/vehicle_onboarding_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/live_selfie_gate.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import 'registration_parts.dart';

/// What a step needs from the registration form around it.
abstract class RegHost {
  OnboardingState get state;
  bool get busy;

  /// Runs one save. [stayOn] keeps that step on screen afterwards (a step
  /// with more to do after its first save); null moves to the first step
  /// still missing. False when it failed (a modal said why).
  Future<bool> save(Future<OnboardingState> Function(OnboardingState s) action, {OnboardingStep? stayOn});

  /// Opens [step] ("Change my services", "Retake photo").
  void goTo(OnboardingStep step);

  Iterable<Map<String, dynamic>> get typeValues;

  /// The Partner Service types offered in the area.
  List<String> get offeredTypes;

  /// The ID's front, as photographed in this visit (read on the next step).
  Uint8List? idFront;

  /// Picks the ID photos (the camera or a file).
  Future<PickedImage?> pickIdPhoto(BuildContext context);
}

String _t(Object? v) => '${v ?? ''}'.trim();

DateTime? _day(Object? v) => DateTime.tryParse(_t(v));

String _iso(DateTime? d) => d == null ? '' : isoDate(d);

Widget _title(BuildContext context, String title, [String? subtitle]) {
  final t = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: t.textTheme.titleLarge),
      if (subtitle != null) ...[
        const SizedBox(height: 4),
        Text(subtitle, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ],
    ]),
  );
}

Widget _section(BuildContext context, String label) => Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(label.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                letterSpacing: 0.8,
              )),
    );

/// Picks a document photo, or (with [pdf]) a PDF whose first page is used.
Future<PickedPeopleFile?> pickRegistrationDocument(BuildContext context, WidgetRef ref, {bool pdf = false}) async {
  if (!pdf) return ref.read(docPhotoPickerProvider)(context);
  final tools = ref.read(docPdfToolsProvider);
  try {
    final file = await tools.pick();
    if (file == null) return null;
    final problem = docPdfProblem(file.name, file.bytes.length);
    if (problem != null) {
      if (context.mounted) await showNotice(context, message: problem);
      return null;
    }
    final png = await tools.firstPagePng(file.bytes);
    if (png == null) {
      if (context.mounted) await showNotice(context, message: "That PDF couldn't be opened. Take a photo of it instead.");
      return null;
    }
    return (bytes: png, name: pdfPreviewName(file.name));
  } catch (e) {
    if (context.mounted) await showErrorNotice(context, e);
    return null;
  }
}

// ---- National ID ----------------------------------------------------------------------------------

enum _IdPhase { enter, confirm, photos }

class NationalIdStep extends ConsumerStatefulWidget {
  const NationalIdStep({super.key, required this.host});
  final RegHost host;

  @override
  ConsumerState<NationalIdStep> createState() => _NationalIdStepState();
}

class _NationalIdStepState extends ConsumerState<NationalIdStep> {
  late final Map<String, dynamic> _p = widget.host.state.profile ?? const {};
  late IdDocType _type = IdDocType.parse(_p['id_type']) ?? IdDocType.mykad;
  late final _number = TextEditingController(text: _t(_p['id_number_typed']).isNotEmpty ? _t(_p['id_number_typed']) : _t(_p['ic']));
  late _IdPhase _phase =
      IdDocType.parse(_p['id_type']) != null && _t(_p['ic']).isNotEmpty ? _IdPhase.photos : _IdPhase.enter;
  String? _uploading;

  Map<String, dynamic> get _profile => widget.host.state.profile ?? const {};

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  String get _cleanNumber => _type == IdDocType.passport ? _number.text.trim().toUpperCase() : formatMyKad(_number.text);

  Future<void> _continue() async {
    final n = _cleanNumber;
    String? problem;
    if (n.isEmpty) {
      problem = 'Type your ${_type.label} number.';
    } else if (_type != IdDocType.passport && !RegExp(r'^\d{12}$').hasMatch(idKey(n))) {
      problem = 'A ${_type.label} number has 12 digits, like 900101-14-5678.';
    } else if (_type == IdDocType.passport && !RegExp(r'^[A-Z0-9]{5,12}$').hasMatch(idKey(n))) {
      problem = 'A passport number has 5 to 12 letters and digits.';
    }
    if (problem != null) return showNotice(context, message: problem);
    setState(() {
      _number.text = n;
      _phase = _IdPhase.confirm;
    });
  }

  Future<void> _confirm() async {
    final n = _cleanNumber;
    final was = _t(_profile['id_type']);
    final changedType = was.isNotEmpty && was != _type.key;
    final ok = await widget.host.save((s) async {
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      final profile = await repo.patchProfile({
        'id_type': _type.key,
        'id_number_typed': n,
        'ic': n,
        // Another kind of ID: its photos are taken again.
        if (changedType) ...{'id_image': null, 'id_image_back': null, 'id_number_read': null},
      });
      return s.copyWith(profile: profile);
    }, stayOn: OnboardingStep.id);
    if (ok && mounted) setState(() => _phase = _IdPhase.photos);
  }

  Future<void> _upload(String side) async {
    if (!await ref.read(liveSelfieGateProvider)(context) || !mounted) return;
    final img = await widget.host.pickIdPhoto(context);
    if (img == null || !mounted) return;
    setState(() => _uploading = side);
    await widget.host.save((s) async {
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      final url = await repo.uploadIdSide(img.bytes, img.name, side);
      final profile = await repo.patchProfile({side == 'front' ? 'id_image' : 'id_image_back': url});
      if (side == 'front') widget.host.idFront = img.bytes;
      return s.copyWith(profile: profile);
    }, stayOn: OnboardingStep.id);
    if (mounted) setState(() => _uploading = null);
  }

  Future<void> _read() async {
    final h = widget.host;
    final notice = eligibilityNotice(
      idType: _type,
      offered: h.offeredTypes,
      picked: parseStringList(h.state.partner['partner_types']),
      entries: h.typeValues,
      area: ServiceArea.fromRow(h.state.partner),
    );
    if (notice != null) {
      final change = await showEligibilityModal(context, notice, _type);
      if (!mounted) return;
      if (change) return h.goTo(OnboardingStep.partnerType);
    }
    await h.save((s) async => s);
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.host.busy;
    final t = Theme.of(context);
    final mono = t.textTheme.headlineSmall?.copyWith(fontFamily: 'monospace', letterSpacing: 1);
    switch (_phase) {
      case _IdPhase.enter:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(context, 'Your national ID number'),
          SegmentedButton<IdDocType>(
            key: const ValueKey('id-type'),
            segments: [for (final x in IdDocType.values) ButtonSegment(value: x, label: Text(x.label))],
            selected: {_type},
            onSelectionChanged: busy ? null : (v) => setState(() => _type = v.first),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('id-number'),
            controller: _number,
            enabled: !busy,
            textCapitalization: TextCapitalization.characters,
            keyboardType: _type == IdDocType.passport ? TextInputType.text : TextInputType.number,
            inputFormatters: [
              if (_type != IdDocType.passport) FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
              LengthLimitingTextInputFormatter(14),
            ],
            style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 1),
            decoration: InputDecoration(labelText: '${_type.label} number', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Text('${_type.hint} Type the number exactly as it is on your ID. It is used to check your ID photos.',
              style: t.textTheme.bodySmall),
          const SizedBox(height: 16),
          BusyButton.filled(key: const ValueKey('id-continue'), onPressed: busy ? null : _continue, child: const Text('Continue')),
        ]);
      case _IdPhase.confirm:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(context, 'Is this your ID number?'),
          RegNotice(icon: Icons.badge_outlined, children: [
            Text('${_type.label} number', style: t.textTheme.labelMedium),
            Text(_cleanNumber, key: const ValueKey('id-confirm-number'), style: mono),
          ]),
          Text('Check every digit. Your ID photos must show this number.', style: t.textTheme.bodyMedium),
          const SizedBox(height: 16),
          BusyButton.filled(
            key: const ValueKey('id-confirm-yes'),
            onPressed: busy ? null : _confirm,
            child: const Text('Yes, this is correct'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey('id-confirm-edit'),
            onPressed: busy ? null : () => setState(() => _phase = _IdPhase.enter),
            child: const Text('Edit number'),
          ),
        ]);
      case _IdPhase.photos:
        final (front, back) = _type.photoSides;
        final hasFront = _t(_profile['id_image']).isNotEmpty, hasBack = _t(_profile['id_image_back']).isNotEmpty;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(context, 'Take photos of your ID'),
          Card(
            child: ListTile(
              title: Text('${_type.label} number (confirmed)'),
              subtitle: Text(_t(_profile['ic']), style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
              trailing: TextButton(
                key: const ValueKey('id-change'),
                onPressed: busy ? null : () => setState(() => _phase = _IdPhase.enter),
                child: const Text('Change'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          UploadTile(
            key: const ValueKey('id-front'),
            label: front,
            subtitle: hasFront ? 'Added' : 'Required',
            done: hasFront,
            busy: _uploading == 'front',
            onTap: busy ? null : () => _upload('front'),
          ),
          UploadTile(
            key: const ValueKey('id-back'),
            label: back,
            subtitle: hasBack ? 'Added' : 'Required',
            done: hasBack,
            busy: _uploading == 'back',
            onTap: busy ? null : () => _upload('back'),
          ),
          Text(
            'Both photos are required. The next screen checks the number on the card against the one you confirmed, '
            'and shows the other details we read.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          BusyButton.filled(
            key: const ValueKey('id-read'),
            onPressed: busy || !hasFront || !hasBack ? null : _read,
            child: const Text('Read my ID'),
          ),
        ]);
    }
  }
}

// ---- Check your details ---------------------------------------------------------------------------

class DetailsStep extends ConsumerStatefulWidget {
  const DetailsStep({super.key, required this.host});
  final RegHost host;

  @override
  ConsumerState<DetailsStep> createState() => _DetailsStepState();
}

class _DetailsStepState extends ConsumerState<DetailsStep> {
  Map<String, dynamic> get _p => widget.host.state.profile ?? const {};
  late final IdDocType? _type = IdDocType.parse(_p['id_type']);
  late String _typed = _t(_p['id_number_typed']).isNotEmpty ? _t(_p['id_number_typed']) : _t(_p['ic']);
  late String _readNumber = _t(_p['id_number_read']);
  late final _nationality = TextEditingController(text: _t(_p['nationality']));
  late final _name = TextEditingController(text: _t(_p['id_name']));
  late final _dob = TextEditingController(text: _t(_p['birth_date']).split('T').first);
  late final _address = TextEditingController(text: _t(_p['address']));
  bool _reading = false;

  /// Null before reading; true when something was read.
  bool? _read;

  @override
  void initState() {
    super.initState();
    _readId();
  }

  @override
  void dispose() {
    for (final c in [_nationality, _name, _dob, _address]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _readId() async {
    final url = _t(_p['id_image']);
    if (url.isEmpty) return setState(() => _read = false);
    setState(() => _reading = true);
    IdRead r = const IdRead();
    try {
      final text = await ref.read(documentTextReaderProvider)(widget.host.idFront ?? Uint8List(0), fileUrl: url);
      if (text != null) r = readIdText(text, _type ?? IdDocType.mykad);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _reading = false;
      _read = !r.isEmpty;
      if (r.number != null) _readNumber = r.number!;
      if (r.nationality != null && _nationality.text.isEmpty) _nationality.text = r.nationality!;
      if (r.name != null && _name.text.isEmpty) _name.text = r.name!;
      if (r.dateOfBirth != null && _dob.text.isEmpty) _dob.text = isoDate(r.dateOfBirth!);
      if (r.address != null && _address.text.isEmpty) _address.text = r.address!;
      if (_dob.text.isEmpty && (_type == IdDocType.mykad || _type == IdDocType.mypr)) {
        final d = dobFromMyKad(_typed);
        if (d != null) _dob.text = isoDate(d);
      }
    });
  }

  bool get _mismatch => _readNumber.isNotEmpty && !sameIdNumber(_typed, _readNumber);

  Future<void> _correctNumber() async {
    final c = TextEditingController(text: _typed);
    final next = await _correctNumberDialog(context, c, '${_type?.label ?? 'ID'} number');
    c.dispose();
    if (next != null && next.trim().isNotEmpty && mounted) {
      setState(() => _typed = _type == IdDocType.passport ? next.trim().toUpperCase() : formatMyKad(next));
    }
  }

  Future<void> _confirm() async {
    final h = widget.host;
    final birth = _day(_dob.text);
    final problem = detailsProblem(
      idType: _type,
      number: _typed,
      name: _name.text,
      dateOfBirth: birth,
      address: _address.text,
    );
    if (problem != null) return showNotice(context, message: problem);
    if (_mismatch) {
      final keep = await askRegistration(
        context,
        id: 'partner-registration.id-mismatch',
        title: "The number on your ID doesn't match the one you typed",
        message: 'You typed $_typed; the card reads $_readNumber. Retake the photo or correct the number. If the number '
            'you typed is right, keep it: an admin will check it against your ID photo.',
        yes: 'Keep it as typed',
        no: 'Go back',
      );
      if (!keep || !mounted) return;
    }
    if (_type == IdDocType.mykad && idShowsNonCitizen(_type, _nationality.text)) {
      final notice = eligibilityNotice(
        idType: _type,
        nationality: _nationality.text,
        offered: h.offeredTypes,
        picked: parseStringList(h.state.partner['partner_types']),
        entries: h.typeValues,
        area: ServiceArea.fromRow(h.state.partner),
      );
      if (notice != null) {
        final change = await showEligibilityModal(context, notice, _type);
        if (!mounted) return;
        if (change) return h.goTo(OnboardingStep.partnerType);
      }
    }
    await h.save((s) async {
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      final profile = await repo.patchProfile({
        'ic': _typed,
        'id_number_typed': _typed,
        'id_number_read': _readNumber.isEmpty ? null : _readNumber,
        'nationality': _nationality.text.trim().isEmpty ? null : _nationality.text.trim(),
        'id_name': _name.text.trim().toUpperCase(),
        'birth_date': isoDate(birth!),
        'address': _address.text.trim(),
      });
      final s2 = s.copyWith(profile: profile);
      return s2.copyWith(partner: await repo.patchPartner(s2, withRegistrationStep(s2.partner, regStepDetails)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final busy = widget.host.busy || _reading;
    final label = _type?.label ?? 'ID';
    final mono = t.textTheme.titleMedium?.copyWith(fontFamily: 'monospace');
    final nonCitizen = idShowsNonCitizen(_type, _nationality.text);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title(context, 'Check your details'),
      if (_reading)
        const RegNotice(icon: Icons.document_scanner_outlined, children: [Text('Reading your ID…')])
      else if (_read == true)
        RegNotice(
          icon: Icons.document_scanner_outlined,
          tone: NoticeTone.done,
          children: [Text('Read from your $label. Check each line, then confirm.')],
        )
      else
        const RegNotice(
          key: ValueKey('details-unread'),
          icon: Icons.edit_note,
          children: [Text("We couldn't read your ID. Type your details exactly as they are on it.")],
        ),
      Card(
        key: const ValueKey('details-number'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: _mismatch ? t.colorScheme.error : t.colorScheme.primary),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
            Text('$label number', style: t.textTheme.labelMedium),
            Row(children: [
              SizedBox(width: 96, child: Text('You typed', style: t.textTheme.bodySmall)),
              Expanded(child: Text(_typed, style: mono)),
            ]),
            Row(children: [
              SizedBox(width: 96, child: Text('On the card', style: t.textTheme.bodySmall)),
              Expanded(child: Text(_readNumber.isEmpty ? 'Not read' : _readNumber, style: mono)),
              if (_readNumber.isNotEmpty)
                Icon(_mismatch ? Icons.error : Icons.verified, color: _mismatch ? t.colorScheme.error : t.colorScheme.primary),
            ]),
            if (_readNumber.isNotEmpty)
              Text(
                _mismatch ? "The number on your ID doesn't match the one you typed" : 'Matches',
                key: const ValueKey('details-number-state'),
                style: t.textTheme.bodySmall?.copyWith(color: _mismatch ? t.colorScheme.error : t.colorScheme.primary),
              ),
            if (_mismatch)
              Wrap(spacing: 8, children: [
                TextButton(
                  key: const ValueKey('details-retake'),
                  onPressed: busy ? null : () => widget.host.goTo(OnboardingStep.id),
                  child: const Text('Retake photo'),
                ),
                TextButton(
                  key: const ValueKey('details-correct'),
                  onPressed: busy ? null : _correctNumber,
                  child: const Text('Correct the number'),
                ),
              ]),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      RegField(controller: _nationality, label: 'Nationality', enabled: !busy, caps: false),
      if (nonCitizen)
        Card(
          key: const ValueKey('details-eligibility'),
          child: ListTile(
            leading: Icon(Icons.warning_amber, color: t.colorScheme.tertiary),
            title: const Text('You may not be eligible for some services'),
            subtitle: const Text('Tap to see which'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final h = widget.host;
              final n = eligibilityNotice(
                idType: _type,
                nationality: _nationality.text,
                offered: h.offeredTypes,
                picked: parseStringList(h.state.partner['partner_types']),
                entries: h.typeValues,
                area: ServiceArea.fromRow(h.state.partner),
              );
              if (n == null) return;
              if (await showEligibilityModal(context, n, _type)) h.goTo(OnboardingStep.partnerType);
            },
          ),
        ),
      RegField(controller: _name, label: 'Full name (as on ID)', enabled: !busy),
      DateBoxesField(
        key: const ValueKey('details-dob'),
        label: 'Date of birth',
        controller: _dob,
        enabled: !busy,
        firstDate: DateTime(1900),
        lastDate: DateTime.now(),
        isRequired: true,
      ),
      const SizedBox(height: 12),
      RegField(controller: _address, label: 'Address (as on ID)', enabled: !busy, maxLines: 3),
      Text(
        'The ID number, full name and date of birth are what the admin checks against the ID photo.'
        '${_type == IdDocType.mykad || _type == IdDocType.mypr ? ' For a ${_type!.label}, the date of birth must match the first six digits of the number.' : ''}'
        ' If a line was read wrongly, correct it here.',
        style: t.textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      BusyButton.filled(key: const ValueKey('details-confirm'), onPressed: busy ? null : _confirm, child: const Text('Confirm details')),
    ]);
  }
}

/// One line typed in a modal (correcting a number); null when cancelled.
Future<String?> _correctNumberDialog(BuildContext context, TextEditingController c, String label) => showAppDialog<String>(
      id: 'partner-registration.correct-number',
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Correct the number'),
        content: TextField(
          key: const ValueKey('correct-number-field'),
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('correct-number-save'),
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

// ---- Your company ----------------------------------------------------------------------------------

class CompanyStep extends ConsumerStatefulWidget {
  const CompanyStep({super.key, required this.host});
  final RegHost host;

  @override
  ConsumerState<CompanyStep> createState() => _CompanyStepState();
}

class _CompanyStepState extends ConsumerState<CompanyStep> {
  Map<String, dynamic> get _pa => widget.host.state.partner;
  late final _name = TextEditingController(text: _t(_pa['company_name']));
  late final _reg = TextEditingController(text: _t(_pa['company_reg_no']));
  late final _type = TextEditingController(text: _t(_pa['company_type']));
  late final _date = TextEditingController(text: _t(_pa['company_reg_date']));
  late final _address = TextEditingController(text: _t(_pa['company_address']));
  late final _directors = TextEditingController(text: _directorsText(_pa['company_directors']));
  late bool _check = _t(_pa['company_document_url']).isNotEmpty && _t(_pa['company_name']).isNotEmpty;
  bool _reading = false;
  bool? _read;

  static String _directorsText(Object? raw) => [
        if (raw is List)
          for (final d in raw)
            if (d is Map && _t(d['name']).isNotEmpty) _t(d['name']),
      ].join(', ');

  @override
  void dispose() {
    for (final c in [_name, _reg, _type, _date, _address, _directors]) {
      c.dispose();
    }
    super.dispose();
  }

  List<CompanyPerson> _people() => [
        for (final n in _directors.text.split(RegExp(r'[,;\n]')))
          if (n.trim().isNotEmpty) (name: n.trim().toUpperCase(), id: null),
      ];

  Future<void> _upload({bool pdf = false}) async {
    final file = await pickRegistrationDocument(context, ref, pdf: pdf);
    if (file == null || !mounted) return;
    setState(() => _reading = true);
    String? url;
    final ok = await widget.host.save((s) async {
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      url = await repo.uploadPartnerFile(s.partnerId, 'company', 'front', file.bytes, file.name);
      return s.copyWith(partner: await repo.patchPartner(s, {'company_document_url': url}));
    }, stayOn: OnboardingStep.company);
    if (!ok || !mounted) return setState(() => _reading = false);
    CompanyRead r = const CompanyRead();
    try {
      final text = await ref.read(documentTextReaderProvider)(file.bytes, fileUrl: url);
      if (text != null) r = readCompanyText(text);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _reading = false;
      _read = !r.isEmpty;
      _check = true;
      if (r.name != null) _name.text = r.name!;
      if (r.regNo != null) _reg.text = r.regNo!;
      if (r.type != null) _type.text = r.type!;
      if (r.regDate != null) _date.text = isoDate(r.regDate!);
      if (r.address != null) _address.text = r.address!;
      if (r.directors.isNotEmpty) _directors.text = r.directors.map((d) => d.name).join(', ');
    });
  }

  bool get _isDirector {
    final p = widget.host.state.profile;
    return driverIsDirector(
      _people(),
      name: _t(p?['id_name']).isNotEmpty ? _t(p?['id_name']) : _t(p?['name']),
      idNumber: _t(p?['ic']),
    );
  }

  Future<void> _confirm() async {
    if (_name.text.trim().isEmpty || _reg.text.trim().isEmpty) {
      return showNotice(context, message: 'Enter the company name and its registration number.');
    }
    final director = _isDirector;
    await widget.host.save((s) async {
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      return s.copyWith(
        partner: await repo.patchPartner(s, {
          'company_name': _name.text.trim(),
          'company_reg_no': _reg.text.trim(),
          'company_type': _type.text.trim().isEmpty ? null : _type.text.trim(),
          'company_reg_date': _date.text.trim().isEmpty ? null : _date.text.trim(),
          'company_address': _address.text.trim().isEmpty ? null : _address.text.trim(),
          'company_directors': [for (final d in _people()) {'name': d.name}],
          'company_driver_is_director': director,
          ...withRegistrationStep(s.partner, regStepCompany),
        }),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final h = widget.host;
    final busy = h.busy || _reading;
    final why = businessRegistrationTypes(
      parseStringList(h.state.partner['partner_types']),
      h.typeValues,
      ServiceArea.fromRow(h.state.partner),
    );
    final need = RegNotice(
      icon: Icons.apartment,
      tone: NoticeTone.warn,
      children: [Text('${why.join(', ')} ${why.length == 1 ? 'needs' : 'need'} a registered business in your area.')],
    );
    if (!_check) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title(context, 'Your company registration',
            'Upload your company registration or company profile. We read your company details from it and add them to your partner profile.'),
        need,
        Text('SSM certificate / company profile (Form 9, Section 17, or e-Info printout)', style: t.textTheme.bodyMedium),
        const SizedBox(height: 8),
        UploadTile(
          key: const ValueKey('company-photo'),
          label: 'Photo of the document',
          done: false,
          busy: _reading,
          icon: Icons.upload_file,
          onTap: busy ? null : _upload,
        ),
        UploadTile(
          key: const ValueKey('company-pdf'),
          label: 'Or upload the PDF',
          done: false,
          icon: Icons.picture_as_pdf_outlined,
          onTap: busy ? null : () => _upload(pdf: true),
        ),
      ]);
    }
    final directors = _people();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title(context, 'Check your company details'),
      RegNotice(
        icon: _read == false ? Icons.edit_note : Icons.document_scanner_outlined,
        tone: _read == false ? NoticeTone.info : NoticeTone.done,
        children: [
          Text(_read == false
              ? "We couldn't read the document. Type the details as they are on it."
              : 'Read from your company document. These go on your partner profile.'),
        ],
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('Company document'),
          subtitle: const Text('Saved to your partner profile'),
          trailing: TextButton(
            key: const ValueKey('company-replace'),
            onPressed: busy ? null : () => setState(() => _check = false),
            child: const Text('Replace'),
          ),
        ),
      ),
      const SizedBox(height: 8),
      RegField(controller: _name, label: 'Company name', enabled: !busy),
      RegField(controller: _reg, label: 'Registration no. (SSM)', enabled: !busy),
      RegField(controller: _type, label: 'Type', enabled: !busy, caps: false),
      DateBoxesField(
        key: const ValueKey('company-date'),
        label: 'Registered on',
        controller: _date,
        enabled: !busy,
        firstDate: DateTime(1900),
        lastDate: DateTime.now(),
      ),
      const SizedBox(height: 12),
      RegField(controller: _address, label: 'Business address', enabled: !busy, maxLines: 3),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: const ValueKey('company-directors'),
          controller: _directors,
          enabled: !busy,
          textCapitalization: TextCapitalization.characters,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Directors / owners',
            helperText: 'Separate names with commas',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      if (directors.isNotEmpty)
        RegNotice(
          key: const ValueKey('company-director'),
          icon: _isDirector ? Icons.verified_user : Icons.info_outline,
          tone: _isDirector ? NoticeTone.done : NoticeTone.warn,
          children: [
            Text(_isDirector
                ? 'You are listed as a director.'
                : "You aren't listed as a director or owner. The admin checks how you drive for this company."),
          ],
        ),
      BusyButton.filled(key: const ValueKey('company-confirm'), onPressed: busy ? null : _confirm, child: const Text('Confirm company')),
    ]);
  }
}

// ---- Driver permit -------------------------------------------------------------------------------------

class DriverPermitStep extends ConsumerStatefulWidget {
  const DriverPermitStep({super.key, required this.host, this.now});
  final RegHost host;
  final DateTime? now;

  @override
  ConsumerState<DriverPermitStep> createState() => _DriverPermitStepState();
}

class _DriverPermitStepState extends ConsumerState<DriverPermitStep> {
  Map<String, dynamic> get _pa => widget.host.state.partner;
  late final _card = TextEditingController(text: _t(_pa['driver_permit_card_no']));
  late final _from = TextEditingController(text: _t(_pa['driver_permit_valid_from']));
  late final _until = TextEditingController(text: _t(_pa['driver_permit_valid_until']));
  late final _service = TextEditingController(text: _t(_pa['driver_permit_service_type']));
  late final _issuer = TextEditingController(text: _t(_pa['driver_permit_issuer']));
  late final _name = TextEditingController(text: _t(_pa['driver_permit_name']));
  late final _ic = TextEditingController(text: _t(_pa['driver_permit_ic']));
  late final _operator = TextEditingController(text: _t(_pa['driver_permit_operator_name']));
  late final _licence = TextEditingController(text: _t(_pa['driver_permit_operator_licence']));
  late final _plate = TextEditingController(text: _t(_pa['driver_permit_plate']));
  late int? _position = (_pa['driver_permit_position'] as num?)?.toInt();
  late bool _check = _t(_pa['driver_permit_card_no']).isNotEmpty;
  final Map<String, Uint8List> _bytes = {};
  String? _uploading;
  bool _reading = false;
  bool? _read;

  List<TextEditingController> get _all => [_card, _from, _until, _service, _issuer, _name, _ic, _operator, _licence, _plate];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  PermitNeed? get _need {
    final h = widget.host;
    return driverPermitFor(
      parseStringList(h.state.partner['partner_types']),
      h.typeValues,
      ServiceArea.fromRow(h.state.partner),
    ).firstOrNull;
  }

  Future<void> _upload(String side) async {
    if (!await ref.read(liveSelfieGateProvider)(context) || !mounted) return;
    final file = await pickRegistrationDocument(context, ref);
    if (file == null || !mounted) return;
    setState(() => _uploading = side);
    await widget.host.save((s) async {
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      final url = await repo.uploadPartnerFile(s.partnerId, 'driver-permit', side, file.bytes, file.name);
      _bytes[side] = file.bytes;
      return s.copyWith(
        partner: await repo.patchPartner(s, {side == 'front' ? 'driver_permit_front_url' : 'driver_permit_back_url': url}),
      );
    }, stayOn: OnboardingStep.driverPermit);
    if (mounted) setState(() => _uploading = null);
  }

  Future<void> _readPermit() async {
    setState(() => _reading = true);
    final reader = ref.read(documentTextReaderProvider);
    var text = '';
    for (final side in ['front', 'back']) {
      try {
        final url = _t(_pa[side == 'front' ? 'driver_permit_front_url' : 'driver_permit_back_url']);
        final got = await reader(_bytes[side] ?? Uint8List(0), fileUrl: url);
        if (got != null) text = '$text\n$got';
      } catch (_) {}
    }
    final r = readDriverPermitText(text);
    if (!mounted) return;
    final need = _need;
    setState(() {
      _reading = false;
      _read = !r.isEmpty;
      _check = true;
      void put(TextEditingController c, String? v) {
        if (v != null && v.isNotEmpty) c.text = v;
      }

      put(_card, r.cardNo);
      put(_from, r.validFrom == null ? null : isoDate(r.validFrom!));
      put(_until, r.validUntil == null ? null : isoDate(r.validUntil!));
      put(_service, r.serviceType);
      put(_issuer, r.issuer ?? (need == null || need.issuer.isEmpty ? null : need.issuer));
      put(_name, r.name);
      put(_ic, r.idNumber);
      put(_operator, r.operatorName);
      put(_licence, r.operatorLicence);
      put(_plate, r.plate);
      _position = r.position ?? _position;
    });
  }

  DriverPermitRead get _values => DriverPermitRead(
        cardNo: _card.text.trim(),
        validFrom: _day(_from.text),
        validUntil: _day(_until.text),
        serviceType: _service.text.trim(),
        issuer: _issuer.text.trim(),
        name: _name.text.trim(),
        idNumber: _ic.text.trim(),
        operatorName: _operator.text.trim(),
        operatorLicence: _licence.text.trim(),
        plate: _plate.text.trim().isEmpty ? null : _plate.text.trim().toUpperCase(),
        position: _position,
      );

  List<PermitCheck> _checks() {
    final p = widget.host.state.profile;
    return driverPermitChecks(
      p: _values,
      idName: _t(p?['id_name']).isNotEmpty ? _t(p?['id_name']) : _t(p?['name']),
      idNumber: _t(p?['ic']),
      companyName: _t(_pa['company_name']).isEmpty ? null : _t(_pa['company_name']),
      companyRegNo: _t(_pa['company_reg_no']),
      now: widget.now,
    );
  }

  Future<void> _confirm() async {
    if (_card.text.trim().isEmpty) return showNotice(context, message: 'Enter the permit card number.');
    final checks = _checks();
    final blocking = checks.where((c) => c.blocking && !c.ok).toList();
    if (blocking.isNotEmpty) return showNotice(context, title: "This permit can't be submitted", message: blocking.first.text);
    final flags = permitFlags(checks);
    if (flags.isNotEmpty) {
      final go = await askRegistration(
        context,
        id: 'partner-registration.permit-checks',
        title: "Some checks didn't pass",
        message: '${checks.where((c) => !c.ok).map((c) => c.text).join('\n')}\n\nLook again at what was read. If it is right, '
            'confirm it: the admin checks it when reviewing your application.',
        yes: 'Confirm anyway',
        no: 'Look again',
      );
      if (!go || !mounted) return;
    }
    final v = _values;
    await widget.host.save((s) async {
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      return s.copyWith(
        partner: await repo.patchPartner(s, {
          'driver_permit_card_no': v.cardNo,
          'driver_permit_valid_from': _iso(v.validFrom).isEmpty ? null : _iso(v.validFrom),
          'driver_permit_valid_until': _iso(v.validUntil),
          'driver_permit_service_type': v.serviceType,
          'driver_permit_issuer': v.issuer,
          'driver_permit_name': v.name,
          'driver_permit_ic': v.idNumber,
          'driver_permit_operator_name': v.operatorName,
          'driver_permit_operator_licence': v.operatorLicence,
          'driver_permit_plate': v.plate,
          'driver_permit_position': v.position,
          'driver_permit_flags': flags,
          ...withRegistrationStep(s.partner, regStepDriverPermit),
        }),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final busy = widget.host.busy || _reading;
    final need = _need;
    final permitName = need == null || need.name.isEmpty ? 'Driver permit' : need.name;
    final issuer = need == null || need.issuer.isEmpty ? '' : ' issued by ${need.issuer}';
    final hasFront = _t(_pa['driver_permit_front_url']).isNotEmpty, hasBack = _t(_pa['driver_permit_back_url']).isNotEmpty;
    if (!_check) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title(context, 'Upload your driver permit', 'We read the permit and add its details to your driver profile.'),
        RegNotice(
          icon: Icons.badge_outlined,
          tone: NoticeTone.warn,
          children: [Text('${need?.type ?? 'Your service'} needs a driver permit in your area: $permitName$issuer.')],
        ),
        UploadTile(
          key: const ValueKey('permit-front'),
          label: 'Front',
          subtitle: hasFront ? 'Added' : 'Required',
          done: hasFront,
          busy: _uploading == 'front',
          onTap: busy ? null : () => _upload('front'),
        ),
        UploadTile(
          key: const ValueKey('permit-back'),
          label: 'Back',
          subtitle: hasBack ? 'Added' : 'Required',
          done: hasBack,
          busy: _uploading == 'back',
          onTap: busy ? null : () => _upload('back'),
        ),
        Text('A printout of the permit is fine. Photograph it in good light so every line can be read.',
            style: t.textTheme.bodySmall),
        const SizedBox(height: 16),
        BusyButton.filled(
          key: const ValueKey('permit-read'),
          onPressed: busy || !hasFront || !hasBack ? null : _readPermit,
          child: const Text('Read my permit'),
        ),
      ]);
    }
    final checks = _checks();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title(context, 'Check your permit details'),
      RegNotice(
        icon: _read == false ? Icons.edit_note : Icons.document_scanner_outlined,
        tone: _read == false ? NoticeTone.info : NoticeTone.done,
        children: [
          Text(_read == false
              ? "We couldn't read the permit. Type the details as they are on it."
              : 'Read from your $permitName. These go on your driver profile.'),
        ],
      ),
      _section(context, 'Card'),
      RegField(controller: _card, label: '$permitName number', enabled: !busy),
      DateBoxesField(
        key: const ValueKey('permit-from'),
        label: 'Valid from',
        controller: _from,
        enabled: !busy,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      ),
      const SizedBox(height: 12),
      DateBoxesField(
        key: const ValueKey('permit-until'),
        label: 'Valid until',
        controller: _until,
        enabled: !busy,
        isRequired: true,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        helperText: 'An expired permit can\'t be submitted',
      ),
      const SizedBox(height: 12),
      RegField(controller: _service, label: 'Service type', enabled: !busy, caps: false),
      RegField(controller: _issuer, label: 'Issued by', enabled: !busy, caps: false),
      _section(context, 'Driver'),
      RegField(controller: _name, label: 'Name', enabled: !busy),
      RegField(controller: _ic, label: 'MyKad number', enabled: !busy, mono: true),
      _section(context, 'Operator'),
      RegField(controller: _operator, label: 'Company / operator', enabled: !busy),
      RegField(controller: _licence, label: 'Operator licence (permit) number', enabled: !busy),
      _section(context, 'Vehicle'),
      RegField(controller: _plate, label: 'Vehicle registration number', enabled: !busy),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SearchableDropdownFormField<int>(
          key: ValueKey('permit-position-$_position'),
          initialValue: _position,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Driver for this vehicle', border: OutlineInputBorder()),
          items: [for (var i = 1; i <= 5; i++) DropdownMenuItem(value: i, child: Text(driverPositionLabel(i)))],
          onChanged: busy ? null : (v) => setState(() => _position = v),
        ),
      ),
      _section(context, 'Checks'),
      RegNotice(
        key: const ValueKey('permit-checks'),
        icon: Icons.fact_check_outlined,
        children: [for (final c in checks) CheckLine(ok: c.ok, text: c.text)],
      ),
      Text(
        'A failed check asks you to look again; if you confirm it anyway, the admin checks it. An expired card '
        "can't be submitted.",
        style: t.textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        key: const ValueKey('permit-reupload'),
        onPressed: busy ? null : () => setState(() => _check = false),
        child: const Text('Upload the permit again'),
      ),
      const SizedBox(height: 8),
      BusyButton.filled(key: const ValueKey('permit-confirm'), onPressed: busy ? null : _confirm, child: const Text('Confirm permit')),
    ]);
  }
}

// ---- Register vehicle ------------------------------------------------------------------------------------

enum _VehiclePhase { grant, details, finish }

class VehicleRegistrationStep extends ConsumerStatefulWidget {
  const VehicleRegistrationStep({super.key, required this.host, required this.vehicle, required this.onVehicle, this.now});
  final RegHost host;

  /// The vehicle registered in this application, when there is one.
  final Map<String, dynamic>? vehicle;
  final ValueChanged<Map<String, dynamic>> onVehicle;
  final DateTime? now;

  @override
  ConsumerState<VehicleRegistrationStep> createState() => _VehicleRegistrationStepState();
}

class _VehicleRegistrationStepState extends ConsumerState<VehicleRegistrationStep> {
  late Map<String, dynamic>? _v = widget.vehicle;
  late _VehiclePhase _phase = _v == null ? _VehiclePhase.grant : _VehiclePhase.finish;
  String? _grantFront = '', _grantBack = '';
  final Map<String, Uint8List> _bytes = {};
  String? _uploading;
  bool _reading = false;
  bool? _read;

  late final _plate = TextEditingController();
  late final _make = TextEditingController();
  late final _model = TextEditingController();
  late final _year = TextEditingController();
  late final _colour = TextEditingController();
  late final _engine = TextEditingController();
  late final _chassis = TextEditingController();
  late final _registered = TextEditingController();
  late final _cc = TextEditingController();
  late final _owner = TextEditingController();
  late final _ownerId = TextEditingController();

  List<TextEditingController> get _all =>
      [_plate, _make, _model, _year, _colour, _engine, _chassis, _registered, _cc, _owner, _ownerId];

  @override
  void initState() {
    super.initState();
    _fromVehicle(_v);
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _fromVehicle(Map<String, dynamic>? v) {
    if (v == null) return;
    _plate.text = _t(v['plate']);
    _make.text = _t(v['make']);
    _model.text = _t(v['model']);
    _year.text = _t(v['year']);
    _colour.text = _t(v['color']);
    _engine.text = _t(v['engine_number']);
    _chassis.text = _t(v['vin']);
    _registered.text = _t(v['registration_date']);
    _cc.text = _t(v['engine_cc']);
    _owner.text = _t(v['grant_owner_name']);
    _ownerId.text = _t(v['grant_owner_id']);
    _grantFront = _t(v['grant_front_url']);
    _grantBack = _t(v['grant_back_url']);
  }

  OnboardingState get _s => widget.host.state;
  ServiceArea get _area => ServiceArea.fromRow(_s.partner);
  List<String> get _services => vehicleServicesOf(parseStringList(_s.partner['partner_types']), widget.host.typeValues);

  Future<void> _uploadGrant(String side, {bool pdf = false}) async {
    final file = await pickRegistrationDocument(context, ref, pdf: pdf);
    if (file == null || !mounted) return;
    setState(() => _uploading = side);
    try {
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      final url = await repo.uploadPartnerFile(_s.partnerId, 'vehicle-grant', side, file.bytes, file.name);
      _bytes[side] = file.bytes;
      if (!mounted) return;
      setState(() => side == 'front' ? _grantFront = url : _grantBack = url);
    } catch (e) {
      if (mounted) await showErrorNotice(context, e);
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  Future<void> _readGrant() async {
    setState(() => _reading = true);
    final reader = ref.read(documentTextReaderProvider);
    var text = '';
    for (final (side, url) in [('front', _grantFront), ('back', _grantBack)]) {
      if (_t(url).isEmpty) continue;
      try {
        final got = await reader(_bytes[side] ?? Uint8List(0), fileUrl: url);
        if (got != null) text = '$text\n$got';
      } catch (_) {}
    }
    final r = readVehicleGrantText(text);
    if (!mounted) return;
    setState(() {
      _reading = false;
      _read = !r.isEmpty;
      _phase = _VehiclePhase.details;
      void put(TextEditingController c, Object? v) {
        if (v != null && '$v'.isNotEmpty) c.text = '$v';
      }

      put(_plate, r.plate);
      put(_make, r.make);
      put(_model, r.model);
      put(_year, r.year ?? r.registrationDate?.year);
      put(_colour, r.colour);
      put(_engine, r.engineNo);
      put(_chassis, r.chassisNo);
      put(_registered, r.registrationDate == null ? null : isoDate(r.registrationDate!));
      put(_cc, r.engineCc);
      put(_owner, r.ownerName);
      put(_ownerId, r.ownerId);
    });
  }

  OwnerMatch get _ownerMatch {
    final p = _s.profile;
    return ownerMatchFor(
      owner: _owner.text,
      ownerId: _ownerId.text,
      driverName: _t(p?['id_name']).isNotEmpty ? _t(p?['id_name']) : _t(p?['name']),
      driverId: _t(p?['ic']),
      companyName: _t(_s.partner['company_name']),
      companyRegNo: _t(_s.partner['company_reg_no']),
    );
  }

  List<VehicleServiceStatus> _statuses() => vehicleServiceStatuses(
        services: _services,
        entries: widget.host.typeValues,
        area: _area,
        registered: _day(_registered.text) ?? (int.tryParse(_year.text) == null ? null : DateTime(int.parse(_year.text))),
        now: widget.now,
      );

  Future<void> _saveVehicle() async {
    final plate = normalizePlate(_plate.text);
    if (plate.isEmpty || _make.text.trim().isEmpty || _model.text.trim().isEmpty) {
      return showNotice(context, message: 'Enter the plate number, make and model.');
    }
    final yearProblem = vehicleYearColorProblem(_year.text, _colour.text);
    if (yearProblem != null) return showNotice(context, message: yearProblem);
    if (_registered.text.trim().isEmpty) return showNotice(context, message: 'Enter the date the vehicle was registered.');
    if (_owner.text.trim().isEmpty) return showNotice(context, message: "Enter the registered owner's name.");
    final statuses = _statuses();
    final match = _ownerMatch;
    Map<String, dynamic>? catalogue;
    try {
      catalogue = matchMakeModel(await ref.read(peopleRepositoryProvider).makeModels(), _make.text, _model.text);
    } catch (_) {}
    if (!mounted) return;
    Map<String, dynamic>? saved;
    final ok = await widget.host.save((s) async {
      final vehicles = ref.read(vehicleOnboardingRepositoryProvider);
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      final start = _v != null && normalizePlate(_t(_v!['plate'])) == plate ? _v! : await vehicles.startWithPlate(plate, s.partner);
      final id = start['id'] as String;
      // Registered in this application first, so a service over its age
      // limit is paused rather than refused (0288).
      final partner = await repo.patchPartner(s, {'registration_vehicle_id': id});
      final v = await vehicles.update(id, {
        'plate': plate,
        'make': _make.text.trim().toUpperCase(),
        'model': _model.text.trim().toUpperCase(),
        'year': _year.text.trim(),
        'color': _colour.text.trim().toUpperCase(),
        'engine_number': _engine.text.trim().isEmpty ? null : _engine.text.trim().toUpperCase(),
        'vin': _chassis.text.trim().isEmpty ? null : _chassis.text.trim().toUpperCase(),
        'registration_date': _registered.text.trim(),
        'engine_cc': int.tryParse(_cc.text.trim()),
        'grant_owner_name': _owner.text.trim().toUpperCase(),
        'grant_owner_id': _ownerId.text.trim().isEmpty ? null : _ownerId.text.trim(),
        'grant_front_url': _t(_grantFront).isEmpty ? null : _grantFront,
        'grant_back_url': _t(_grantBack).isEmpty ? null : _grantBack,
        'owner_match': match.key,
        'owner_name': _owner.text.trim().toUpperCase(),
        if (_ownerId.text.trim().isNotEmpty) 'owner_ic': _ownerId.text.trim(),
        'partner_types': _services,
        if (catalogue != null) ...{
          'service_id': _t(catalogue['service_id']).isEmpty ? null : _t(catalogue['service_id']),
          'vehicle_type': _t(catalogue['vehicle_type']).isEmpty ? null : _t(catalogue['vehicle_type']),
        },
      });
      await vehicles.saveServiceStatuses(id, [for (final st in statuses) st.toRow(id)]);
      saved = v;
      return s.copyWith(partner: partner);
    }, stayOn: OnboardingStep.vehicle);
    if (ok && saved != null && mounted) {
      widget.onVehicle(saved!);
      setState(() {
        _v = saved;
        _phase = _VehiclePhase.finish;
      });
    }
  }

  Future<void> _uploadVehicleFile(String column, String folder) async {
    final v = _v;
    if (v == null) return;
    final file = await pickRegistrationDocument(context, ref);
    if (file == null || !mounted) return;
    setState(() => _uploading = column);
    try {
      final vehicles = ref.read(vehicleOnboardingRepositoryProvider);
      final id = v['id'] as String;
      final url = folder == 'photos'
          ? await vehicles.uploadPhoto(id, column.replaceFirst('image_', ''), file.bytes, file.name)
          : await vehicles.uploadFile(id, folder, 'front', file.bytes, file.name);
      final next = await vehicles.update(id, {column: url});
      if (!mounted) return;
      widget.onVehicle(next);
      setState(() => _v = next);
    } catch (e) {
      if (mounted) await showErrorNotice(context, e);
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  Future<void> _finish() async {
    final v = _v!;
    if (vehiclePhotoSlots.any((s) => _t(v['image_$s']).isEmpty)) {
      return showNotice(context, message: 'Add all four photos of the vehicle.');
    }
    if (OwnerMatch.parse(v['owner_match']) == OwnerMatch.other && _t(v['authorisation_letter_url']).isEmpty) {
      return showNotice(context, message: "Add the owner's authorisation letter.");
    }
    await widget.host.save((s) async {
      final repo = ref.read(partnerOnboardingRepositoryProvider);
      return s.copyWith(partner: await repo.patchPartner(s, withRegistrationStep(s.partner, regStepVehicle)));
    });
  }

  Widget _statusBlocks(BuildContext context, List<VehicleServiceStatus> st, {required String regLabel}) {
    if (st.isEmpty) return const SizedBox.shrink();
    final anyPaused = st.any((s) => s.state == VehicleServiceState.pausedAge);
    final withLimit = st.where((s) => s.limit != null).toList();
    final reg = _day(_registered.text);
    final age = reg == null ? null : vehicleAgeYears(reg, now: widget.now);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (withLimit.isNotEmpty)
        RegNotice(
          key: const ValueKey('vehicle-age'),
          icon: Icons.event,
          tone: anyPaused ? NoticeTone.warn : NoticeTone.info,
          children: [
            Text(age == null ? 'Vehicle age' : '$regLabel: $age years old', style: const TextStyle(fontWeight: FontWeight.w600)),
            for (final s in st)
              CheckLine(
                ok: s.state != VehicleServiceState.pausedAge,
                paused: s.state == VehicleServiceState.pausedAge,
                text: vehicleAgeLine(s),
              ),
            Text(
              anyPaused
                  ? 'You can carry on. The other services work with this vehicle; the paused one turns on when you add a newer vehicle later.'
                  : 'We remind you a year before a limit is reached.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      RegNotice(
        key: const ValueKey('vehicle-permits'),
        icon: Icons.verified_outlined,
        children: [
          const Text('Vehicle permits', style: TextStyle(fontWeight: FontWeight.w600)),
          for (final s in st) CheckLine(ok: s.permit == null, paused: s.permit != null, text: vehiclePermitLine(s)),
          Text("You don't upload these; we tell you when each one is ready.", style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final busy = widget.host.busy || _reading;
    switch (_phase) {
      case _VehiclePhase.grant:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(context, 'Register your vehicle',
              'Start with your vehicle ownership certificate. We keep it on your vehicle record and fill in the vehicle details from it.'),
          Text('Vehicle grant (geran) / VOC / vehicle registration certificate', style: t.textTheme.bodyMedium),
          const SizedBox(height: 8),
          UploadTile(
            key: const ValueKey('grant-front'),
            label: 'Front / page 1',
            subtitle: _t(_grantFront).isEmpty ? 'Required' : 'Added',
            done: _t(_grantFront).isNotEmpty,
            busy: _uploading == 'front',
            onTap: busy ? null : () => _uploadGrant('front'),
          ),
          UploadTile(
            key: const ValueKey('grant-back'),
            label: 'Back / page 2 (if any)',
            subtitle: _t(_grantBack).isEmpty ? 'Optional' : 'Added',
            done: _t(_grantBack).isNotEmpty,
            busy: _uploading == 'back',
            onTap: busy ? null : () => _uploadGrant('back'),
          ),
          UploadTile(
            key: const ValueKey('grant-pdf'),
            label: 'Or upload the PDF (e.g. MyJPJ e-VOC)',
            done: false,
            icon: Icons.picture_as_pdf_outlined,
            onTap: busy ? null : () => _uploadGrant('front', pdf: true),
          ),
          Text('Photograph the whole page in good light so every line can be read.', style: t.textTheme.bodySmall),
          const SizedBox(height: 16),
          BusyButton.filled(
            key: const ValueKey('grant-read'),
            onPressed: busy || _t(_grantFront).isEmpty ? null : _readGrant,
            child: const Text('Read my grant'),
          ),
        ]);
      case _VehiclePhase.details:
        final st = _statuses();
        final match = _ownerMatch;
        final hasCompany = _t(_s.partner['company_name']).isNotEmpty;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(context, 'Check your vehicle details'),
          RegNotice(
            icon: _read == false ? Icons.edit_note : Icons.document_scanner_outlined,
            tone: _read == false ? NoticeTone.info : NoticeTone.done,
            children: [
              Text(_read == false
                  ? "We couldn't read the grant. Type the details as they are on it."
                  : 'Read from your vehicle grant. Check each line, then continue.'),
            ],
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Vehicle grant'),
              subtitle: const Text("Saved to this vehicle's record"),
              trailing: TextButton(
                key: const ValueKey('grant-replace'),
                onPressed: busy ? null : () => setState(() => _phase = _VehiclePhase.grant),
                child: const Text('Replace'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          RegField(controller: _plate, label: 'Plate number', enabled: !busy),
          RegField(controller: _make, label: 'Make', enabled: !busy),
          RegField(controller: _model, label: 'Model', enabled: !busy),
          RegField(controller: _year, label: 'Year made', enabled: !busy, keyboard: TextInputType.number),
          RegField(controller: _colour, label: 'Colour', enabled: !busy),
          RegField(controller: _engine, label: 'Engine number', enabled: !busy),
          RegField(controller: _chassis, label: 'Chassis number', enabled: !busy),
          DateBoxesField(
            key: const ValueKey('vehicle-registered'),
            label: 'Registered on',
            controller: _registered,
            enabled: !busy,
            isRequired: true,
            firstDate: DateTime(1950),
            lastDate: DateTime.now(),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          RegField(controller: _cc, label: 'Engine capacity (cc)', enabled: !busy, keyboard: TextInputType.number),
          _statusBlocks(context, st, regLabel: 'Registered ${_day(_registered.text)?.year ?? ''}'.trim()),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              key: const ValueKey('vehicle-owner'),
              controller: _owner,
              enabled: !busy,
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Registered owner', border: OutlineInputBorder()),
            ),
          ),
          RegField(controller: _ownerId, label: "Owner's ID or company number (if printed)", enabled: !busy),
          RegNotice(
            key: const ValueKey('vehicle-owner-check'),
            icon: match == OwnerMatch.other ? Icons.info_outline : Icons.verified_user,
            tone: match == OwnerMatch.other ? NoticeTone.warn : NoticeTone.done,
            children: [
              Text(switch (match) {
                OwnerMatch.driver => 'Owner matches your ID. Nothing more is needed.',
                OwnerMatch.company => 'Owner matches your company. Nothing more is needed.',
                OwnerMatch.other =>
                  "The owner doesn't match ${hasCompany ? 'you or your company' : 'your ID'}. After saving, add the owner's permission to drive this vehicle.",
              }),
            ],
          ),
          BusyButton.filled(key: const ValueKey('vehicle-save'), onPressed: busy ? null : _saveVehicle, child: const Text('Save vehicle')),
        ]);
      case _VehiclePhase.finish:
        final v = _v!;
        final st = _statuses();
        final other = OwnerMatch.parse(v['owner_match']) == OwnerMatch.other;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(context, 'Your vehicle', 'Add the photos to finish registering it.'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.directions_car),
              title: Text('${_t(v['plate'])} · ${_t(v['make'])} ${_t(v['model'])}'.trim()),
              subtitle: Text([
                if (_t(v['year']).isNotEmpty) _t(v['year']),
                if (_t(v['color']).isNotEmpty) _t(v['color']),
                if (_t(v['registration_date']).isNotEmpty) 'Registered ${formatStoredDateForUser(v['registration_date'])}',
              ].join(' · ')),
              trailing: TextButton(
                key: const ValueKey('vehicle-edit'),
                onPressed: busy
                    ? null
                    : () => setState(() {
                          _fromVehicle(v);
                          _phase = _VehiclePhase.details;
                        }),
                child: const Text('Edit'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _statusBlocks(context, st, regLabel: 'Registered ${_day(_registered.text)?.year ?? ''}'.trim()),
          if (other) ...[
            UploadTile(
              key: const ValueKey('vehicle-authorisation'),
              label: 'Authorisation letter from the owner',
              subtitle: _t(v['authorisation_letter_url']).isEmpty
                  ? 'Required · on letterhead, naming you and plate ${_t(v['plate'])}'
                  : 'Uploaded',
              done: _t(v['authorisation_letter_url']).isNotEmpty,
              icon: Icons.upload_file,
              busy: _uploading == 'authorisation_letter_url',
              onTap: busy ? null : () => _uploadVehicleFile('authorisation_letter_url', 'authorisation'),
            ),
            UploadTile(
              key: const ValueKey('vehicle-agreement'),
              label: 'Rental / hire-purchase agreement',
              subtitle: _t(v['hire_agreement_url']).isEmpty ? 'Optional' : 'Uploaded',
              done: _t(v['hire_agreement_url']).isNotEmpty,
              icon: Icons.upload_file,
              busy: _uploading == 'hire_agreement_url',
              onTap: busy ? null : () => _uploadVehicleFile('hire_agreement_url', 'agreement'),
            ),
          ],
          _section(context, 'Photos of the vehicle'),
          for (final slot in vehiclePhotoSlots)
            UploadTile(
              key: ValueKey('vehicle-photo-$slot'),
              label: '${slot[0].toUpperCase()}${slot.substring(1)}',
              subtitle: _t(v['image_$slot']).isEmpty ? 'Required' : 'Added',
              done: _t(v['image_$slot']).isNotEmpty,
              busy: _uploading == 'image_$slot',
              onTap: busy ? null : () => _uploadVehicleFile('image_$slot', 'photos'),
            ),
          const SizedBox(height: 16),
          BusyButton.filled(key: const ValueKey('vehicle-continue'), onPressed: busy ? null : _finish, child: const Text('Continue')),
        ]);
    }
  }
}
