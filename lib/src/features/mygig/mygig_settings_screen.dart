// myGiG settings (the driver's own, migration 0329): the fare (get.ride's,
// or their own when the admin allows it, within the admin's limits),
// luggage per size and free bags, coming to the pickup, busy times,
// waiting, the no-show and cancellation fees (registered passengers paying
// in the app only), how the price shows (the tax line, rounding up),
// blocked numbers, their myGiG plan and a live example. The server keeps
// every value within the admin's limits when it saves (mygig_save_prefs).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mygig.dart';
import '../../core/mygig_hire.dart';
import '../../data/mygig_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';

class MygigSettingsScreen extends ConsumerStatefulWidget {
  const MygigSettingsScreen({super.key});

  @override
  ConsumerState<MygigSettingsScreen> createState() => _MygigSettingsScreenState();
}

class _MygigSettingsScreenState extends ConsumerState<MygigSettingsScreen> {
  MygigPrefs? _prefs;
  List<String>? _blocked;

  void _set(String path, Object? v) => setState(() => _prefs = _prefs!.set(path, v));

  Future<void> _save() async {
    try {
      final saved = await ref.read(mygigRepositoryProvider).savePrefs(_prefs!);
      if (!mounted) return;
      setState(() => _prefs = saved);
      ref.invalidate(mygigConfigProvider);
      unawaited(showAppNotice(
        id: 'notice.mygig',
        context: context,
        kind: NoticeKind.success,
        title: 'Settings saved',
        message: 'Your myGiG settings are saved and used from your next myGiG ride.',
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _unblock(String digits) async {
    try {
      await ref.read(mygigRepositoryProvider).unblock(digits);
      if (mounted) setState(() => _blocked = [...?_blocked]..remove(digits));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(mygigConfigProvider(mygigAt(null, null)));
    return Scaffold(
      appBar: AppBar(title: const Text('myGiG settings')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(mygigConfigProvider),
        data: (c) {
          _prefs ??= c.prefs;
          _blocked ??= [...c.blocked];
          return _body(context, c, _prefs!);
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: BusyButton.filled(
            key: const ValueKey('mygig-settings-save'),
            icon: const Icon(Icons.check),
            onPressed: _prefs == null ? null : _save,
            child: const Text('Save'),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, MygigConfig c, MygigPrefs p) {
    final t = Theme.of(context);
    final s = c.settings;
    final lim = s.ownFareLimits;
    final ex = p.example(s, taxPct: c.taxPct, wholeFare: c.wholeFare);
    final small = t.textTheme.bodySmall;
    return ResponsiveCenter(
      maxWidth: 760,
      child: ListView(
        key: const ValueKey('mygig-settings'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text('Your own prices and display for myGiG rides. They apply to every myGiG ride you take, and passengers '
              'see them before they accept.', style: small),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              key: const ValueKey('mygig-plan'),
              leading: const Icon(Icons.verified_user_outlined),
              title: Text('Your myGiG plan: ${c.fee.text}'),
              subtitle: Text('${c.fee.own ? 'A rate get.ride set for you. ' : ''}${mygigPlanLine(c.fee, c.pass)}'),
            ),
          ),
          _section(t, Icons.payments_outlined, 'Fare'),
          if (s.allowOwnFare) ...[
            RadioGroup<bool>(
              groupValue: p.ownFare,
              onChanged: (v) => _set('ownFare', v ?? false),
              child: Column(children: [
                RadioListTile<bool>(
                  key: const ValueKey('mygig-fare-getride'),
                  value: false,
                  title: const Text('get.ride myGiG fare'),
                  subtitle: Text(s.fare.text),
                ),
                const RadioListTile<bool>(
                  key: ValueKey('mygig-fare-own'),
                  value: true,
                  title: Text('My own fare'),
                  subtitle: Text('Set your own prices below'),
                ),
              ]),
            ),
            if (p.ownFare) ...[
              _grid([
                _num('Base fare (RM)', p.fare.base, (v) => _set('fare', p.fare.copyWith(base: v).toJson()), key: 'fare-base'),
                _num('Per km (RM)', p.fare.perKm, (v) => _set('fare', p.fare.copyWith(perKm: v).toJson()), key: 'fare-km'),
                _num('Per minute (RM)', p.fare.perMin, (v) => _set('fare', p.fare.copyWith(perMin: v).toJson()), key: 'fare-min'),
                _num('Minimum fare (RM)', p.fare.min, (v) => _set('fare', p.fare.copyWith(min: v).toJson()), key: 'fare-least'),
              ]),
              Text('Allowed by get.ride: base up to ${mygigMoney(_d(lim['baseMax'], 10))}, per km '
                  '${mygigMoney(_d(lim['perKmMin'], 0.5))} to ${mygigMoney(_d(lim['perKmMax'], 2.5))}, per minute up to '
                  '${mygigMoney(_d(lim['perMinMax'], 1))}, minimum up to ${mygigMoney(_d(lim['minMax'], 20))}.', style: small),
            ],
          ] else
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('get.ride myGiG fare'),
              subtitle: Text('Your partner type uses the fare set by get.ride: ${s.fare.text}.'),
            ),
          _section(t, Icons.luggage_outlined, 'Luggage charges'),
          _grid([
            _num('Small, each (RM)', p.lug('small'), (v) => _set('lug.small', v), key: 'lug-small'),
            _num('Medium, each (RM)', p.lug('medium'), (v) => _set('lug.medium', v), key: 'lug-medium'),
            _num('Large, each (RM)', p.lug('large'), (v) => _set('lug.large', v), key: 'lug-large'),
            _num('Free bags', p.freeBags.toDouble(), (v) => _set('freeBags', v.round()), whole: true, key: 'lug-free'),
          ]),
          Text('Set a size to 0 to carry it free. Free bags are taken off the cheapest sizes first. At most '
              '${mygigMoney(s.maxPerBag)} a bag (set by get.ride).', style: small),
          _section(t, Icons.near_me_outlined, 'Coming to the pickup'),
          if (!s.approachAllowed)
            Text('get.ride doesn’t allow a charge for coming to the pickup here.', style: small)
          else ...[
            Text('When the pickup isn’t where you are, you can charge for driving there.', style: small),
            RadioGroup<String>(
              groupValue: p.approachMode,
              onChanged: (v) => _set('approach.mode', v ?? 'off'),
              child: const Column(children: [
                RadioListTile<String>(key: ValueKey('mygig-approach-off'), value: 'off', title: Text('No charge'),
                    subtitle: Text('Drive to the pickup for free')),
                RadioListTile<String>(key: ValueKey('mygig-approach-perkm'), value: 'perkm', title: Text('Per km'),
                    subtitle: Text('A price for each km you drive to the pickup')),
                RadioListTile<String>(key: ValueKey('mygig-approach-fixed'), value: 'fixed', title: Text('Fixed amount'),
                    subtitle: Text('One amount, whatever the distance')),
              ]),
            ),
            if (p.approachMode != 'off') ...[
              _grid([
                if (p.approachMode == 'perkm')
                  _num('Per km (RM)', p.approachPerKm, (v) => _set('approach.perKm', v), key: 'approach-km')
                else
                  _num('Amount (RM)', p.approachFixed, (v) => _set('approach.fixed', v), key: 'approach-fixed'),
                _num('Free for the first (km)', p.approachFreeKm, (v) => _set('approach.freeKm', v), key: 'approach-free'),
              ]),
              Text('Up to ${mygigMoney(s.approachMaxPerRide)} per ride (set by get.ride). You can switch it off for any ride '
                  'before you send it.', style: small),
            ],
          ],
          _switchSection(t, Icons.schedule, 'Busy times', p.busyOn && s.busyAllowed,
              s.busyAllowed ? (v) => _set('busy.on', v) : null, key: 'busy'),
          if (!s.busyAllowed)
            Text('get.ride has busy-time extras switched off here.', style: small)
          else if (p.busyOn) ...[
            _grid([
              _num('Night (%)', p.busyNight, (v) => _set('busy.night', v), key: 'busy-night'),
              _num('Peak (RM)', p.busyPeak, (v) => _set('busy.peak', v), key: 'busy-peak'),
              _num('Weekend (%)', p.busyWeekend, (v) => _set('busy.weekend', v), key: 'busy-weekend'),
            ]),
            Text('Night ${s.nightFrom} to ${s.nightTo}, peak ${s.peakFrom} to ${s.peakTo} (set by get.ride). Up to '
                '${_trim(s.busyMaxPct)}% or ${mygigMoney(s.busyMaxPeak)}.', style: small),
          ] else
            Text('Off: the same price all day.', style: small),
          _switchSection(t, Icons.hourglass_top, 'Waiting', p.waitOn, (v) => _set('wait.on', v), key: 'wait'),
          if (!p.waitOn)
            Text('Off: waiting is free.', style: small)
          else if (s.waitAllowOwn) ...[
            RadioGroup<bool>(
              groupValue: p.waitOwn,
              onChanged: (v) => _set('wait.own', v ?? false),
              child: Column(children: [
                RadioListTile<bool>(
                  key: const ValueKey('mygig-wait-getride'),
                  value: false,
                  title: const Text('get.ride waiting charge'),
                  subtitle: Text('${s.waitFreeMin} min free, then ${mygigMoney(s.waitPerMin)} a minute'),
                ),
                const RadioListTile<bool>(
                  key: ValueKey('mygig-wait-own'),
                  value: true,
                  title: Text('My own waiting charge'),
                  subtitle: Text('Set your own below'),
                ),
              ]),
            ),
            if (p.waitOwn) ...[
              _grid([
                _num('Free at the pickup (min)', p.waitFree.toDouble(), (v) => _set('wait.free', v.round()), whole: true,
                    key: 'wait-free'),
                _num('Then per minute (RM)', p.waitPerMin, (v) => _set('wait.perMin', v), key: 'wait-rate'),
              ]),
              Text('Allowed by get.ride: up to ${mygigMoney(s.waitMaxPerMin)} a minute.', style: small),
            ],
            Text('Every minute waited at a stop is charged too. Cash and link passengers pay it at the end with the fare.',
                style: small),
          ] else
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('get.ride waiting charge'),
              subtitle: Text('${s.waitFreeMin} min free, then ${mygigMoney(s.waitPerMin)} a minute.'),
            ),
          _switchSection(t, Icons.person_off_outlined, 'No-show fee', p.noShowOn && s.noShowOn,
              s.noShowOn ? (v) => _set('noShow.on', v) : null, key: 'noshow'),
          if (p.noShowOn && s.noShowOn) ...[
            _grid([_num('Fee (RM)', p.noShowAmount, (v) => _set('noShow.amount', v), key: 'noshow-fee')]),
            Text('Up to ${mygigMoney(s.noShowMax)} (set by get.ride).', style: small),
          ],
          _switchSection(t, Icons.event_busy_outlined, 'Cancellation fee', p.cancelOn && s.cancelOn,
              s.cancelOn ? (v) => _set('cancel.on', v) : null, key: 'cancel'),
          if (!s.cancelOn)
            Text('get.ride has cancellation fees switched off for myGiG.', style: small)
          else if (p.cancelOn) ...[
            _grid([_num('Fee (RM)', p.cancelAmount, (v) => _set('cancel.amount', v), key: 'cancel-fee')]),
            Text('When the passenger cancels more than ${s.cancelFreeMin} min after accepting. Up to '
                '${mygigMoney(s.cancelMax)} (set by get.ride).', style: small),
          ],
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Who can be charged these fees'),
              subtitle: const Text('Only registered passengers paying in the app (GET.wallet, Family or business). '
                  'Passengers without the app, or paying cash or by link, can’t be charged after the fact, so they never '
                  'get a cancellation or no-show fee.'),
            ),
          ),
          ..._hire(t, c, p),
          _section(t, Icons.block, 'Blocked numbers'),
          if (_blocked!.isEmpty)
            Text('No blocked numbers.', style: small)
          else
            for (final b in _blocked!)
              ListTile(
                key: ValueKey('mygig-blocked-$b'),
                title: Text(mygigPhoneText(b)),
                subtitle: const Text('No myGiG rides from this number'),
                trailing: BusyButton.text(onPressed: () => _unblock(b), child: const Text('Unblock')),
              ),
          _section(t, Icons.receipt_outlined, 'How the price shows'),
          SwitchListTile(
            key: const ValueKey('mygig-show-tax'),
            value: p.showTax,
            title: const Text('Show service tax as its own line'),
            subtitle: const Text('Off: one price that includes the tax. The tax is still charged and recorded.'),
            onChanged: (v) => _set('showTax', v),
          ),
          SwitchListTile(
            key: const ValueKey('mygig-round-up'),
            value: p.roundUp,
            title: const Text('Round up to whole ringgit'),
            subtitle: Text(p.roundUp ? 'RM16.37 shows as RM17' : 'Off: RM16.37 shows as RM16.37'),
            onChanged: (v) => _set('roundUp', v),
          ),
          Card(
            key: const ValueKey('mygig-example'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Example: a 6.6 km trip, about 16 min', style: small),
                _row('Fare', ex.fare),
                if (p.showTax && ex.tax > 0) _row(c.taxName ?? 'Service tax', ex.tax),
                if (ex.rounded > 0) _row('Rounded up', ex.rounded),
                if (!p.showTax && ex.tax > 0) Text('Price includes service tax', style: small),
                const Divider(),
                _row('Passenger pays', ex.total, bold: true),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  /// 0330: hire by time: the packages the driver offers, and get.ride's
  /// myGiG hire rates or their own (when the admin allows, within limits).
  List<Widget> _hire(ThemeData t, MygigConfig c, MygigPrefs p) {
    final hs = MygigHireSettings.of(c.settings.raw);
    if (!hs.hireEnabled) return const [];
    final hp = MygigHirePrefs.of(p.raw);
    final small = t.textTheme.bodySmall;
    final r = hp.rates;
    final lim = hs.ownLimits;
    void setHire(String key, Object? v, [String? sub]) {
      final hire = Map<String, dynamic>.from(hp.raw);
      if (sub == null) {
        hire[key] = v;
      } else {
        hire[key] = {...(hire[key] is Map ? Map<String, dynamic>.from(hire[key] as Map) : <String, dynamic>{}), sub: v};
      }
      _set('hire', hire);
    }
    String range(String k) {
      final lo = lim['${k}Min'], hi = lim['${k}Max'];
      return [if (lo is num && lo > 0) 'from ${mygigMoney(lo.toDouble())}', if (hi is num) 'up to ${mygigMoney(hi.toDouble())}']
          .join(' ');
    }
    return [
      _section(t, Icons.schedule, 'Hire by time'),
      Text('What you offer, and your rates. Passengers hire you by the hour, day, week or month.', style: small),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final k in MygigKind.values.where((k) => k.hire && hs.packageOn(k)))
          FilterChip(
            key: ValueKey('mygig-offer-${k.name}'),
            label: Text(k.label),
            selected: hp.offers(k),
            onSelected: (v) => setHire('offer', v, k.name),
          ),
      ]),
      if (hs.allowOwnRates) ...[
        RadioGroup<bool>(
          groupValue: hp.own,
          onChanged: (v) => setHire('own', v ?? false),
          child: Column(children: [
            RadioListTile<bool>(
              key: const ValueKey('mygig-hire-getride'),
              value: false,
              title: const Text('get.ride hire rates'),
              subtitle: Text(hs.rates.text),
            ),
            RadioListTile<bool>(
              key: const ValueKey('mygig-hire-own'),
              value: true,
              title: const Text('My own hire rates'),
              subtitle: const Text('Set them below'),
            ),
          ]),
        ),
        if (hp.own) ...[
          _grid([
            _num('Per hour (RM)', r.hour, (v) => setHire('rates', v, 'hour'), key: 'hire-hour'),
            _num('Per day, 10 h (RM)', r.day, (v) => setHire('rates', v, 'day'), key: 'hire-day'),
            _num('Per week, 5 days (RM)', r.week, (v) => setHire('rates', v, 'week'), key: 'hire-week'),
            _num('Per month (RM)', r.month, (v) => setHire('rates', v, 'month'), key: 'hire-month'),
            _num('Overtime per hour (RM)', r.overtime, (v) => setHire('rates', v, 'overtime'), key: 'hire-overtime'),
            _num('Overnight allowance (RM)', r.overnight, (v) => setHire('rates', v, 'overnight'), key: 'hire-overnight'),
          ]),
          const SizedBox(height: 6),
          Text(
            'Allowed by get.ride: an hour ${range('hour')}, a day ${range('day')}, a week ${range('week')}, '
            'a month ${range('month')}. km included, the extra km price and the limits are set by get.ride.',
            key: const ValueKey('mygig-hire-limits'),
            style: small,
          ),
        ],
      ] else
        Card(
          child: ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('get.ride hire rates'),
            subtitle: Text(hs.rates.text),
          ),
        ),
    ];
  }

  Widget _row(String l, double v, {bool bold = false}) => Row(children: [
    Expanded(child: Text(l, style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null)),
    Text(mygigMoney(v), style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
  ]);

  Widget _section(ThemeData t, IconData icon, String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 6),
    child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 8), Text(title, style: t.textTheme.titleMedium)]),
  );

  Widget _switchSection(ThemeData t, IconData icon, String title, bool on, ValueChanged<bool>? set, {required String key}) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: SwitchListTile(
          key: ValueKey('mygig-$key'),
          contentPadding: EdgeInsets.zero,
          secondary: Icon(icon),
          title: Text(title, style: t.textTheme.titleMedium),
          value: on,
          onChanged: set,
        ),
      );

  Widget _grid(List<Widget> fields) => LayoutBuilder(
    builder: (_, c) {
      final cols = c.maxWidth > 520 ? 3 : 2;
      final w = (c.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(spacing: 12, runSpacing: 12, children: [for (final f in fields) SizedBox(width: w, child: f)]);
    },
  );

  Widget _num(String label, double value, ValueChanged<double> set, {bool whole = false, required String key}) =>
      _NumField(key: ValueKey('mygig-num-$key'), label: label, value: value, whole: whole, onChanged: set);
}

double _d(Object? v, double f) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? f;
String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

class _NumField extends StatefulWidget {
  const _NumField({super.key, required this.label, required this.value, required this.onChanged, this.whole = false});
  final String label;
  final double value;
  final bool whole;
  final ValueChanged<double> onChanged;

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final _c = TextEditingController(text: widget.whole ? widget.value.round().toString() : widget.value.toStringAsFixed(2));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    keyboardType: TextInputType.numberWithOptions(decimal: !widget.whole),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(widget.whole ? r'[0-9]' : r'[0-9.]'))],
    decoration: InputDecoration(labelText: widget.label),
    onChanged: (v) {
      final n = double.tryParse(v);
      if (n != null && n >= 0) widget.onChanged(n);
    },
  );
}
