// Admin › Country / States / Cities › a country › Phone numbers and sign-in
// (migration 0292): who may get a sign-in code from this country, filled
// from Google's phone number data and changed here. Only sign-in codes,
// sign-up and sign-in follow these rules; other messages to the country's
// numbers (rides, deliveries, support) are sent as before.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../widgets/admin_widgets.dart';
import 'geo_logic.dart' show RegionLevel, RegionRow;

/// Opens [iso]'s phone rules ([name] for the title).
Future<void> openCountryPhoneRules(BuildContext context, {required String iso, required String name, required bool canEdit}) =>
    Navigator.of(context).push(AppPageRoute(
      id: 'admin-regions.country-phone',
      builder: (_) => CountryPhoneScreen(iso: iso, name: name, canEdit: canEdit),
    ));

/// What a country's numbers may do (country_phone_rules.access).
enum PhoneAccess {
  allowed('Allowed'),
  registrationClosed('Registration closed'),
  blocked('Blocked');

  const PhoneAccess(this.label);
  final String label;

  String get key => switch (this) {
        PhoneAccess.allowed => 'allowed',
        PhoneAccess.registrationClosed => 'registration_closed',
        PhoneAccess.blocked => 'blocked',
      };

  static PhoneAccess of(Object? v) => switch (v) {
        'registration_closed' => PhoneAccess.registrationClosed,
        'blocked' => PhoneAccess.blocked,
        _ => PhoneAccess.allowed,
      };

  String get help => switch (this) {
        PhoneAccess.allowed => 'Sign-up, sign-in and codes as usual.',
        PhoneAccess.registrationClosed =>
          'No new accounts with these numbers. People who already have one sign in as usual.',
        PhoneAccess.blocked =>
          'No sign-up and no sign-in. Anyone already signed in with these numbers is signed out.',
      };
}

/// The digits [text] lists, comma or space separated ("1, 8 9" -> [1, 8, 9]).
List<String> parsePrefixes(String text) =>
    {for (final p in text.split(RegExp(r'[\s,]+'))) if (RegExp(r'^\d{1,6}$').hasMatch(p)) p}.toList()..sort();

class CountryPhoneScreen extends ConsumerStatefulWidget {
  const CountryPhoneScreen({super.key, required this.iso, required this.name, required this.canEdit});
  final String iso;
  final String name;
  final bool canEdit;

  @override
  ConsumerState<CountryPhoneScreen> createState() => _CountryPhoneScreenState();
}

class _CountryPhoneScreenState extends ConsumerState<CountryPhoneScreen> {
  Map<String, dynamic>? _rule;
  Map<String, dynamic> _stats = const {};
  List<Map<String, dynamic>> _blocks = const [];
  String? _error;
  final _min = TextEditingController(), _max = TextEditingController();
  final _prefixes = TextEditingController(), _limit = TextEditingController();
  bool _mobileOnly = true;
  PhoneAccess _access = PhoneAccess.allowed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_min, _max, _prefixes, _limit]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(supabaseProvider);
    try {
      final rule = await db.from('country_phone_rules').select().eq('iso', widget.iso).maybeSingle();
      var stats = const <String, dynamic>{};
      var blocks = const <Map<String, dynamic>>[];
      if (widget.canEdit) {
        stats = Map<String, dynamic>.from(await db.rpc('admin_country_phone_stats', params: {'p_iso': widget.iso}) as Map);
        blocks = [
          for (final b in await db.from('phone_number_blocks').select().eq('iso', widget.iso).order('created_at', ascending: true))
            Map<String, dynamic>.from(b),
        ];
      }
      if (!mounted) return;
      setState(() {
        _rule = rule;
        _stats = stats;
        _blocks = blocks;
        _error = rule == null ? 'There is no phone number data for ${widget.name} (${widget.iso}).' : null;
        if (rule != null) _fill(rule);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _fill(Map<String, dynamic> r) {
    _min.text = '${r['mobile_min'] ?? ''}';
    _max.text = '${r['mobile_max'] ?? ''}';
    _prefixes.text = ((r['mobile_prefixes'] as List?) ?? const []).join(', ');
    _limit.text = '${r['daily_code_limit'] ?? ''}';
    _mobileOnly = r['mobile_only'] != false;
    _access = PhoneAccess.of(r['access']);
  }

  /// Puts the phone number data's values back (not saved until Save).
  void _fillFromData() {
    final d = Map<String, dynamic>.from((_rule?['defaults'] as Map?) ?? const {});
    setState(() {
      _min.text = '${d['min'] ?? ''}';
      _max.text = '${d['max'] ?? ''}';
      _prefixes.text = ((d['prefixes'] as List?) ?? const []).join(', ');
      _mobileOnly = d['mobileOnly'] != false;
    });
  }

  Future<void> _setAccess(PhoneAccess a) async {
    if (a == PhoneAccess.blocked && _access != PhoneAccess.blocked) {
      final n = (_stats['people'] as num?)?.toInt() ?? 0;
      final ok = await confirm(
        context,
        'Block ${_rule?['dial_code'] ?? ''} numbers?',
        '$n ${n == 1 ? 'person' : 'people'} with numbers from ${widget.name} will be signed out and won\'t be able '
            'to sign in or sign up. People with other numbers aren\'t affected. Save to apply.',
        ok: 'Block',
      );
      if (!ok) return;
    }
    setState(() => _access = a);
  }

  Future<void> _save() async {
    final min = int.tryParse(_min.text.trim()), max = int.tryParse(_max.text.trim());
    if ((min == null) != (max == null) || (min != null && max != null && min > max)) {
      showInfo(context, 'Enter both the shortest and the longest number, the shortest first.');
      return;
    }
    final limitText = _limit.text.trim();
    await runAdminAction(context, () async {
      await ref.read(supabaseProvider).rpc('admin_country_phone_rule_set', params: {
        'p_iso': widget.iso,
        'p': {
          'min': min,
          'max': max,
          'prefixes': parsePrefixes(_prefixes.text),
          'mobileOnly': _mobileOnly,
          'access': _access.key,
          'dailyLimit': limitText.isEmpty ? null : int.tryParse(limitText),
        },
      });
      await _load();
    }, success: 'Saved');
  }

  Future<void> _addBlock() async {
    final added = await showAppDialog<bool>(
      id: 'admin-regions.phone-block-add',
      context: context,
      builder: (_) => _AddBlockDialog(iso: widget.iso, dial: '${_rule?['dial_code'] ?? ''}'),
    );
    if (added == true) await _load();
  }

  Future<void> _removeBlock(Map<String, dynamic> b) async {
    await runAdminAction(context, () async {
      await ref.read(supabaseProvider).rpc('admin_phone_block_remove', params: {'p_id': b['id']});
      await _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rule = _rule;
    final edit = widget.canEdit;
    final dial = '${rule?['dial_code'] ?? ''}';
    Widget numberField(String key, TextEditingController c, String label, {String? hint}) => TextField(
          key: ValueKey('phone-rule-$key'),
          controller: c,
          enabled: edit,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: label, hintText: hint),
        );
    return Scaffold(
      appBar: AppBar(title: Text('${widget.name} · Phone numbers')),
      body: rule == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
            )
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text(
                'Only sign-in codes, sign-up and sign-in follow these rules. Other messages to these numbers '
                '(rides, deliveries, support) are sent as before.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(child: Text('Mobile numbers', style: t.textTheme.titleSmall)),
                      if (edit)
                        TextButton.icon(
                          key: const ValueKey('phone-rule-fill'),
                          onPressed: _fillFromData,
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: const Text('Fill from phone number data'),
                        ),
                    ]),
                    Text('Dial code $dial. Digits after the dial code, without a leading 0.', style: t.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: numberField('min', _min, 'Shortest')),
                      const SizedBox(width: 12),
                      Expanded(child: numberField('max', _max, 'Longest')),
                    ]),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('phone-rule-prefixes'),
                      controller: _prefixes,
                      enabled: edit,
                      decoration: const InputDecoration(
                        labelText: 'Mobile numbers start with',
                        hintText: 'e.g. 1 (Malaysia: 01...)',
                        helperText: 'Separate with commas. Empty: any first digits.',
                      ),
                    ),
                    SwitchListTile(
                      key: const ValueKey('phone-rule-mobile-only'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Mobile numbers only'),
                      subtitle: const Text('No sign-in codes to landlines.'),
                      value: _mobileOnly,
                      onChanged: edit ? (v) => setState(() => _mobileOnly = v) : null,
                    ),
                  ]),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Numbers from ${widget.name}', style: t.textTheme.titleSmall),
                    const SizedBox(height: 12),
                    SegmentedButton<PhoneAccess>(
                      key: const ValueKey('phone-rule-access'),
                      segments: [
                        for (final a in PhoneAccess.values)
                          ButtonSegment(
                            value: a,
                            label: FittedBox(fit: BoxFit.scaleDown, child: Text(a.label, maxLines: 1)),
                          ),
                      ],
                      selected: {_access},
                      showSelectedIcon: false,
                      onSelectionChanged: edit ? (s) => _setAccess(s.first) : null,
                    ),
                    const SizedBox(height: 8),
                    Text(_access.help, style: t.textTheme.bodySmall),
                    if (edit) ...[
                      const SizedBox(height: 4),
                      Text('${_stats['people'] ?? 0} accounts use numbers from ${widget.name}.', style: t.textTheme.bodySmall),
                    ],
                  ]),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Daily code limit', style: t.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    numberField('limit', _limit, 'Codes per day to these numbers', hint: 'Empty: no limit'),
                    const SizedBox(height: 8),
                    _LimitBar(today: (_stats['codesToday'] as num?)?.toInt() ?? 0, limit: int.tryParse(_limit.text.trim())),
                    const SizedBox(height: 8),
                    Text(
                      'Stops a flood of fake sign-ups running up the SMS bill. At the limit new numbers from '
                      '${widget.name} get "Too many sign-ups right now"; people with an account still get theirs. '
                      'Admins get a push at 80%. The day is Malaysian time.',
                      style: t.textTheme.bodySmall,
                    ),
                  ]),
                ),
              ),
              if (edit)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: BusyButton.filled(key: const ValueKey('phone-rule-save'), onPressed: _save, child: const Text('Save')),
                ),
              if (edit)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Expanded(child: Text('Blocked numbers', style: t.textTheme.titleSmall)),
                        TextButton.icon(
                          key: const ValueKey('phone-block-add'),
                          onPressed: _addBlock,
                          icon: const Icon(Icons.add),
                          label: const Text('Add'),
                        ),
                      ]),
                      Text(
                        'Numbers that start with some digits, a range, or one number. They can\'t sign up or sign in.',
                        style: t.textTheme.bodySmall,
                      ),
                      if (_blocks.isEmpty)
                        const Padding(padding: EdgeInsets.only(top: 12), child: Text('None'))
                      else
                        for (final b in _blocks)
                          ListTile(
                            key: ValueKey('phone-block-${b['id']}'),
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.block),
                            title: Text(phoneBlockLabel(b, dial)),
                            subtitle: (b['note'] ?? '').toString().isEmpty ? null : Text('${b['note']}'),
                            trailing: BusyIconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _removeBlock(b),
                            ),
                          ),
                    ]),
                  ),
                ),
            ]),
    );
  }
}

/// How a blocked-number row reads: "Starts with +60 1150", "+60 123400000 to
/// +60 123499999", "+60 198765432".
String phoneBlockLabel(Map<String, dynamic> b, String dial) => switch (b['kind']) {
      'prefix' => 'Starts with $dial ${b['value_from']}',
      'range' => '$dial ${b['value_from']} to $dial ${b['value_to']}',
      _ => '$dial ${b['value_from']}',
    };

class _LimitBar extends StatelessWidget {
  const _LimitBar({required this.today, required this.limit});
  final int today;
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final l = limit;
    if (l == null || l <= 0) return Text('Today: $today codes', style: t.textTheme.bodySmall);
    final share = (today / l).clamp(0.0, 1.0);
    final hot = share >= 0.8;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Today: $today of $l codes${hot ? ' · admins alerted' : ''}', style: t.textTheme.bodySmall),
      const SizedBox(height: 4),
      LinearProgressIndicator(
        value: share,
        minHeight: 6,
        borderRadius: BorderRadius.circular(3),
        color: hot ? t.colorScheme.error : null,
      ),
    ]);
  }
}

/// Adds a blocked number: by first digits, a range or the exact number.
class _AddBlockDialog extends ConsumerStatefulWidget {
  const _AddBlockDialog({required this.iso, required this.dial});
  final String iso;
  final String dial;

  @override
  ConsumerState<_AddBlockDialog> createState() => _AddBlockDialogState();
}

class _AddBlockDialogState extends ConsumerState<_AddBlockDialog> {
  String _kind = 'prefix';
  final _from = TextEditingController(), _to = TextEditingController(), _note = TextEditingController();

  @override
  void dispose() {
    for (final c in [_from, _to, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _add() async {
    String digits(String s) => s.replaceAll(RegExp(r'\D'), '').replaceFirst(RegExp(r'^0+'), '');
    final from = digits(_from.text), to = digits(_to.text);
    if (from.isEmpty || (_kind == 'range' && (to.length != from.length || to.compareTo(from) < 0))) {
      showInfo(context, _kind == 'range'
          ? 'Enter a range with the same number of digits, the lower number first.'
          : 'Enter the digits after ${widget.dial}.');
      return;
    }
    final ok = await runAdminAction(context, () async {
      await ref.read(supabaseProvider).rpc('admin_phone_block_add', params: {
        'p_iso': widget.iso,
        'p_kind': _kind,
        'p_from': from,
        'p_to': _kind == 'range' ? to : null,
        'p_note': _note.text.trim(),
      });
    });
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final hint = 'Digits after ${widget.dial}, e.g. ${widget.dial == '+60' ? '1150' : '123'}';
    return AlertDialog(
      title: const Text('Block numbers'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<String>(
            key: const ValueKey('phone-block-kind'),
            segments: const [
              ButtonSegment(value: 'prefix', label: Text('Starts with')),
              ButtonSegment(value: 'range', label: Text('Range')),
              ButtonSegment(value: 'number', label: Text('Number')),
            ],
            selected: {_kind},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('phone-block-from'),
            controller: _from,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: switch (_kind) { 'prefix' => 'Starts with', 'range' => 'From', _ => 'Number' },
              prefixText: '${widget.dial} ',
              hintText: hint,
            ),
          ),
          if (_kind == 'range') ...[
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('phone-block-to'),
              controller: _to,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'To', prefixText: '${widget.dial} '),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('phone-block-note'),
            controller: _note,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'Why these are blocked'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        BusyButton.filled(key: const ValueKey('phone-block-save'), onPressed: _add, child: const Text('Block')),
      ],
    );
  }
}

/// [row]'s ISO code when it is a country with one (values.isoCode, 0291).
String? countryIsoOf(RegionRow row) {
  if (row.level != RegionLevel.country) return null;
  final iso = '${row.entry?.values['isoCode'] ?? ''}'.toUpperCase();
  return RegExp(r'^[A-Z]{2}$').hasMatch(iso) ? iso : null;
}
