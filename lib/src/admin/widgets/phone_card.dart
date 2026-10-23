// The Phone card on the admin User and Partner pages: one tab per phone the
// account signed in on, newest first, with the device, the get.ride app and
// the battery and network at its last report; and [PhoneFacts], the short
// version in God View's details.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_version.dart' show AppVersionRule;
import '../../core/date_order.dart';
import '../../core/god_view.dart' show godViewAge;
import '../../core/phone_details.dart';
import '../../data/app_version_repository.dart' show appVersionRulesProvider;
import '../admin_access.dart';
import '../admin_providers.dart';
import '../phone_details_data.dart';

/// The Session History page, which this card links to.
const _sessionHistoryPage = 'admin-session-history';

enum _Tone { ok, warn, bad }

Color _toneColor(_Tone tone, ThemeData t) {
  final dark = t.brightness == Brightness.dark;
  return switch (tone) {
    _Tone.ok => dark ? const Color(0xFF5FD38F) : const Color(0xFF1F8A4C),
    _Tone.warn => dark ? const Color(0xFFF2B25C) : const Color(0xFFA86400),
    _Tone.bad => dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E),
  };
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.tone);
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final c = _toneColor(tone, Theme.of(context));
    return Container(
      key: ValueKey('phone-pill-$text'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(99)),
      child: Text(text, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

/// A value with its pills after it, wrapping on a narrow screen.
Widget _value(String? text, [List<Widget> pills = const []]) => Wrap(
  spacing: 6,
  runSpacing: 2,
  crossAxisAlignment: WrapCrossAlignment.center,
  children: [Text(text ?? 'Not known'), ...pills],
);

Widget _yesNo(bool? v, String yes, String no) =>
    v == null ? const Text('Not known') : _Pill(v ? yes : no, v ? _Tone.ok : _Tone.bad);

List<Widget> _appPills(PhoneAppStatus s, {bool short = false}) => switch (s) {
  PhoneAppStatus.latest => short ? const [] : const [_Pill('Latest', _Tone.ok)],
  PhoneAppStatus.behind => [_Pill(short ? 'Old' : 'Update available', _Tone.warn)],
  PhoneAppStatus.unknown => const [],
};

List<Widget> _batteryPills(PhoneDetails p) => [if (p.batteryLow) const _Pill('Low', _Tone.warn)];

/// One label and its value.
class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.labelWidth = 120});
  final String label;
  final Widget value;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: labelWidth, child: Text(label, style: TextStyle(color: muted))),
        Expanded(child: value),
      ]),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.rows);
  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      ...rows,
    ]);
  }
}

/// Admin → User / Partner: the account's phones. [profileId] is the login
/// (`profiles.id`, a partner's `auth_user_id`).
class PhoneCard extends ConsumerStatefulWidget {
  const PhoneCard({super.key, required this.profileId});
  final String profileId;

  @override
  ConsumerState<PhoneCard> createState() => _PhoneCardState();
}

class _PhoneCardState extends ConsumerState<PhoneCard> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final load = ref.watch(phoneDetailsProvider(widget.profileId));
    final rules = ref.watch(appVersionRulesProvider).value ?? const [];
    final canHistory = ref.watch(pageAccessProvider(_sessionHistoryPage)) != AccessLevel.none;
    final v = load.value;
    final phones = v?.phones ?? const <PhoneDetails>[];
    final tab = _tab < phones.length ? _tab : 0;
    final labels = phoneTabLabels(phones);
    return Card(
      key: const ValueKey('phone-card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('Phone', style: t.textTheme.titleSmall),
            for (var i = 0; i < phones.length; i++)
              ChoiceChip(
                key: ValueKey('phone-tab-$i'),
                label: Text(labels[i]),
                selected: i == tab,
                onSelected: (_) => setState(() => _tab = i),
              ),
          ]),
          const SizedBox(height: 8),
          if (v == null)
            const LinearProgressIndicator()
          else if (v.failed)
            Text('Phone details not available right now.', key: const ValueKey('phone-failed'), style: TextStyle(color: muted))
          else if (phones.isEmpty)
            Text('No phone details yet', key: const ValueKey('phone-none'), style: TextStyle(color: muted))
          else
            _PhoneBody(key: ValueKey('phone-body-$tab'), phone: phones[tab], rules: rules),
          if (canHistory)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TextButton.icon(
                key: const ValueKey('phone-session-history'),
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                icon: const Icon(Icons.history, size: 18),
                label: const Text('Session history (every sign-in and app open)'),
                onPressed: () => context.push(
                  '/admin/m/session-history?q=${Uri.encodeQueryComponent(widget.profileId)}',
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class _PhoneBody extends StatelessWidget {
  const _PhoneBody({super.key, required this.phone, required this.rules});
  final PhoneDetails phone;
  final List<AppVersionRule> rules;

  @override
  Widget build(BuildContext context) {
    final p = phone;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final now = DateTime.now().toUtc();
    final groups = [
      _Group('Device', [
        _Row('Model', Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(p.modelLine),
          if (p.modelCode case final code?) Text('($code)', style: TextStyle(color: muted, fontSize: 12)),
        ])),
        _Row('System', Text(p.systemLabel)),
        _Row('Real phone', Text(p.physicalLabel)),
        _Row('Screen', Text(p.screenLabel ?? 'Not known')),
        _Row('Storage', Text(p.storageLabel ?? 'Not known')),
        _Row('Language', Text(p.languageLabel ?? 'Not known')),
      ]),
      _Group('get.ride app', [
        _Row('Version', _value(p.appLabel, _appPills(p.appStatus(rules)))),
        _Row('Location', _value(p.locationLabel, [
          if (p.location == PhoneLocationAccess.always && p.locationServiceOn != false)
            const _Pill('OK', _Tone.ok)
          else if (p.locationNeedsAlways)
            const _Pill('Needs Always', _Tone.warn),
        ])),
        _Row('Background', _yesNo(p.backgroundTracking, 'Tracking on', 'Off')),
        _Row('Notifications', _yesNo(p.notifications, 'Allowed', 'Blocked')),
        _Row('Last seen', Text(p.lastSeen == null ? 'Not known' : godViewAge(p.lastSeen, now))),
        _Row('First seen', Text(formatDateForUser(p.firstSeen?.toLocal()))),
      ]),
      _Group('Battery & network (at last report)', [
        _Row('Battery', _value(p.batteryLabel, _batteryPills(p))),
        _Row('Network', Text(p.networkLabel ?? 'Not known')),
        _Row('Operator', Text(p.operatorLabel ?? 'Not known')),
        _Row('IP area', Text(p.ipAreaLabel ?? 'Not known')),
      ]),
    ];
    return LayoutBuilder(builder: (context, c) {
      final two = c.maxWidth >= 640;
      final w = two ? (c.maxWidth - 16) / 2 : c.maxWidth;
      return Wrap(spacing: 16, runSpacing: 12, children: [
        for (final g in groups) SizedBox(width: w, child: g),
      ]);
    });
  }
}

/// God View's details: the newest phone in a few rows, labelled as the
/// panel's own facts ([labelWidth]). Nothing while loading or unreadable.
/// [update] sits beside the last report's age (God View's Update, 0282),
/// [updateNote] under it.
class PhoneFacts extends ConsumerWidget {
  const PhoneFacts({
    super.key,
    required this.profileId,
    required this.now,
    this.labelWidth = 80,
    this.update,
    this.updateNote,
  });
  final String profileId;
  final DateTime now;
  final double labelWidth;
  final Widget? update;
  final Widget? updateNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final v = ref.watch(phoneDetailsProvider(profileId)).value;
    if (v == null || v.failed) return const SizedBox.shrink();
    if (v.phones.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('No phone details yet', key: const ValueKey('god-view-phone-none'), style: TextStyle(color: muted)),
            ),
            ?update,
          ]),
          ?updateNote,
        ]),
      );
    }
    final p = v.phones.first;
    final rules = ref.watch(appVersionRulesProvider).value ?? const [];
    Widget row(String k, Widget value) => _Row(k, value, labelWidth: labelWidth);
    return Column(
      key: const ValueKey('god-view-phone-facts'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('Device', Text(p.summaryLine)),
        row('App', _value(p.appLabel, _appPills(p.appStatus(rules), short: true))),
        row('Battery', _value(p.batteryLabel, _batteryPills(p))),
        row('Network', Text(p.networkSummary ?? 'Not known')),
        row('Location', _value(p.locationLabel, [
          if (p.backgroundTracking == false) const _Pill('No background', _Tone.warn),
        ])),
        row('Alerts', _yesNo(p.notifications, 'Allowed', 'Blocked')),
        if (p.reportedAt != null || update != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              Expanded(
                child: Text(
                  p.reportedAt == null ? 'No report from the phone yet.' : "From the phone's last report, ${godViewAge(p.reportedAt, now)}.",
                  key: const ValueKey('god-view-phone-report'),
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
              ?update,
            ]),
          ),
        ?updateNote,
      ],
    );
  }
}
