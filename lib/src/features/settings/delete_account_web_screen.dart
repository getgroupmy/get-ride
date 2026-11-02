// getride.my/delete-account (migration 0334): the public page where anyone
// asks for their GET.ride account and its data to be deleted, without the
// app. Google Play links to it. No sign-in needed to open it.
//
// Two ways: Sign in and delete (the usual SMS sign-in, then 0194's delete,
// at once), or Request by phone (a texted code, then the grace days). The
// page never says whether a number has an account: the same words follow
// "Text me a code" for every number, and a wrong code reads the same as a
// number with no account.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../config.dart';
import '../../core/account_deletion.dart';
import '../../core/account_deletion_web.dart';
import '../../core/auth_utils.dart';
import '../../core/dial_countries.dart';
import '../../data/account_deletion_repository.dart';
import '../../data/auth_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/dial_country_picker.dart';

/// The server's retention and grace days; the defaults when it can't be reached.
final accountDeletionInfoProvider = FutureProvider.autoDispose<AccountDeletionInfo>((ref) async {
  try {
    return await ref.watch(accountDeletionRepositoryProvider).publicInfo();
  } catch (_) {
    return const AccountDeletionInfo();
  }
});

enum DeletionWay { signIn, phone }

enum _Step { phone, code, review, done }

/// Side by side from this width; one above the other below it.
const deletionWaysRowWidth = 640.0;

class DeleteAccountWebScreen extends ConsumerStatefulWidget {
  const DeleteAccountWebScreen({super.key, this.initialWay = DeletionWay.signIn});
  final DeletionWay initialWay;

  @override
  ConsumerState<DeleteAccountWebScreen> createState() => _DeleteAccountWebScreenState();
}

class _DeleteAccountWebScreenState extends ConsumerState<DeleteAccountWebScreen> {
  late var _way = widget.initialWay;
  var _step = _Step.phone;
  DialCountry _country = dialCountryFor(AppConfig.defaultDialCode);
  final _number = TextEditingController();
  final _code = TextEditingController();
  final _reason = TextEditingController();
  String? _phone;
  String? _error;
  bool _busy = false;
  AccountDeletionCheck? _check;
  DateTime? _deleteAfter;

  @override
  void dispose() {
    _number.dispose();
    _code.dispose();
    _reason.dispose();
    super.dispose();
  }

  String? get _reasonText => _reason.text.trim().isEmpty ? null : _reason.text.trim();

  void _pickWay(DeletionWay way) {
    if (_busy || way == _way) return;
    setState(() {
      _way = way;
      _step = _Step.phone;
      _error = null;
      _code.clear();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on PostgrestException catch (e) {
      final wait = parseRateLimitSeconds(e.message);
      if (mounted) setState(() => _error = wait != null ? rateLimitMessage(wait) : errorText(e));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() => _run(() async {
    final phone = composePhone(_country.dialCode, _number.text);
    if (phone.replaceAll(RegExp(r'\D'), '').length < 8) {
      throw StateError('Enter your mobile number.');
    }
    if (_way == DeletionWay.signIn) {
      // Any refusal reads the same as a code sent: nothing tells whether
      // the number has an account.
      try {
        await ref.read(authRepositoryProvider).sendOtp(phone, createUser: false);
      } catch (_) {}
    } else {
      await ref.read(accountDeletionRepositoryProvider).requestCode(phone);
    }
    if (!mounted) return;
    setState(() {
      _phone = phone;
      _step = _Step.code;
      _code.clear();
    });
  });

  Future<void> _confirmCode(String code) => _run(() async {
    final phone = _phone ?? '';
    if (_way == DeletionWay.phone) {
      final result = await ref.read(accountDeletionRepositoryProvider).confirmRequest(phone, code, reason: _reasonText);
      final problem = deletionRequestProblem(result);
      if (problem != null) {
        _code.clear();
        throw StateError(problem);
      }
      if (!mounted) return;
      setState(() {
        _deleteAfter = deletionRequestDeleteAfter(result);
        _step = _Step.done;
      });
      return;
    }
    try {
      await ref.read(authRepositoryProvider).verifyOtp(phone, code);
    } catch (_) {
      _code.clear();
      throw StateError(deletionRequestProblem(const {'error': 'wrong_code'})!);
    }
    AuthRepository.offerPasskeyAfterSignIn = false;
    final check = await ref.read(accountDeletionRepositoryProvider).check();
    if (!mounted) return;
    setState(() {
      _check = check;
      _step = _Step.review;
    });
  });

  Future<void> _deleteNow() => _run(() async {
    final repo = ref.read(accountDeletionRepositoryProvider);
    final problem = await repo.deleteFromWeb(reason: _reasonText);
    if (problem != null) throw StateError(problem);
    await repo.signOutHere();
    if (!mounted) return;
    setState(() {
      _deleteAfter = null;
      _step = _Step.done;
    });
  });

  /// Signed in to delete, then changed their mind: signed out again here.
  Future<void> _keep() => _run(() async {
    await ref.read(accountDeletionRepositoryProvider).signOutHere();
    if (!mounted) return;
    setState(() {
      _step = _Step.phone;
      _check = null;
      _code.clear();
    });
    showInfo(context, 'Your account is kept. You have been signed out of this page.');
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final info = ref.watch(accountDeletionInfoProvider).value ?? const AccountDeletionInfo();
    final muted = mutedTextColor(t);
    return Scaffold(
      appBar: AppBar(title: const Text('Delete your account')),
      body: SingleChildScrollView(
        child: ResponsiveCenter(
          maxWidth: 820,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Delete your GET.ride account',
                key: const ValueKey('delete-web-title'),
                style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'GET.ride is a ride-hailing app made by $deletionPageDeveloper. On this page you can ask us to '
                'delete your GET.ride account and the data that goes with it, without the app.',
                key: const ValueKey('delete-web-developer'),
                style: t.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              _retention(t, info),
              const SizedBox(height: 20),
              Text('Choose how', style: t.textTheme.titleMedium),
              const SizedBox(height: 8),
              _ways(t),
              const SizedBox(height: 16),
              _flowCard(t, info),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('delete-web-in-app'),
                  onPressed: _busy ? null : () => context.go(deletionPageInAppPath),
                  icon: const Icon(Icons.manage_accounts_outlined),
                  label: const Text('Already signed in to GET.ride here? Delete it in your account settings'),
                ),
              ),
              const SizedBox(height: 16),
              for (final s in deletionPageSections(info)) _section(t, s),
              const SizedBox(height: 8),
              Text('Questions', style: t.textTheme.titleMedium),
              const SizedBox(height: 4),
              SelectableText(
                'Write to $deletionPageContact. If you can\'t receive texts on your number any more, write to us '
                'from the email on your account, or tell us the number and when you last used GET.ride.',
                style: t.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// How long the account is kept, and why: said plainly, before anything is asked.
  Widget _retention(ThemeData t, AccountDeletionInfo info) => Card(
    key: const ValueKey('delete-web-retention'),
    margin: EdgeInsets.zero,
    color: t.colorScheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('How long we keep your data, and why', style: t.textTheme.titleMedium),
          const SizedBox(height: 6),
          for (final p in deletionRetentionStatement(info))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(p, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurface)),
            ),
        ],
      ),
    ),
  );

  Widget _ways(ThemeData t) => LayoutBuilder(
    builder: (context, c) {
      final cards = [
        _WayCard(
          key: const ValueKey('delete-way-sign-in'),
          icon: Icons.login,
          title: 'Sign in and delete',
          text: 'Sign in with your number and a texted code. Your account is deleted straight away.',
          selected: _way == DeletionWay.signIn,
          onTap: () => _pickWay(DeletionWay.signIn),
        ),
        _WayCard(
          key: const ValueKey('delete-way-phone'),
          icon: Icons.sms_outlined,
          title: 'Request by phone',
          text: 'Can\'t sign in? Confirm your number with a texted code and we delete the account for you.',
          selected: _way == DeletionWay.phone,
          onTap: () => _pickWay(DeletionWay.phone),
        ),
      ];
      if (c.maxWidth >= deletionWaysRowWidth) {
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: cards[0]),
              const SizedBox(width: 12),
              Expanded(child: cards[1]),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [cards[0], const SizedBox(height: 8), cards[1]],
      );
    },
  );

  Widget _flowCard(ThemeData t, AccountDeletionInfo info) {
    final steps = _way == DeletionWay.signIn ? signInDeleteSteps : phoneRequestSteps(info);
    return Card(
      key: const ValueKey('delete-web-flow'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_step != _Step.done) ...[
              Text('Steps', style: t.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${i + 1}. ${steps[i]}', style: t.textTheme.bodyMedium),
                ),
              const SizedBox(height: 12),
            ],
            ...switch (_step) {
              _Step.phone => _phoneStep(t),
              _Step.code => _codeStep(t, info),
              _Step.review => _reviewStep(t),
              _Step.done => _doneStep(t, info),
            },
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  key: const ValueKey('delete-web-error'),
                  style: TextStyle(color: t.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _phoneStep(ThemeData t) => [
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DialCountryButton(
          country: _country,
          height: 56,
          onPressed: _busy
              ? null
              : () async {
                  final picked = await showDialCountryPicker(context, selected: _country);
                  if (picked != null && mounted) setState(() => _country = picked);
                },
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            key: const ValueKey('delete-web-phone'),
            controller: _number,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\s-]'))],
            decoration: const InputDecoration(labelText: 'Mobile number'),
            onSubmitted: (_) => _sendCode(),
          ),
        ),
      ],
    ),
    const SizedBox(height: 12),
    FilledButton(
      key: const ValueKey('delete-web-send'),
      onPressed: _busy ? null : _sendCode,
      child: const Text('Text me a code'),
    ),
  ];

  List<Widget> _codeStep(ThemeData t, AccountDeletionInfo info) => [
    Text(
      deletionCodeSentText(_phone ?? ''),
      key: const ValueKey('delete-web-code-sent'),
      style: t.textTheme.bodyMedium,
    ),
    const SizedBox(height: 12),
    if (_way == DeletionWay.phone) ...[
      TextField(
        key: const ValueKey('delete-web-reason'),
        controller: _reason,
        maxLength: 300,
        decoration: const InputDecoration(labelText: 'Why are you leaving? (optional)'),
      ),
      const SizedBox(height: 4),
    ],
    CodeField(
      key: const ValueKey('delete-web-code'),
      controller: _code,
      length: 6,
      autofocus: false,
      onCompleted: _confirmCode,
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        TextButton.icon(
          key: const ValueKey('delete-web-resend'),
          onPressed: _busy ? null : _sendCode,
          icon: const Icon(Icons.refresh),
          label: const Text('Send a new code'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _step = _Step.phone;
                  _error = null;
                }),
          child: const Text('Change number'),
        ),
      ],
    ),
  ];

  List<Widget> _reviewStep(ThemeData t) {
    final c = _check ?? const AccountDeletionCheck();
    return [
      Text('You are signed in as ${_phone ?? ''}.', style: t.textTheme.titleSmall),
      const SizedBox(height: 8),
      for (final line in accountDeletionEffects(c))
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 10),
                child: Icon(Icons.circle, size: 8, color: t.colorScheme.onSurfaceVariant),
              ),
              Expanded(child: Text(line, style: t.textTheme.bodyMedium)),
            ],
          ),
        ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('delete-web-reason'),
        controller: _reason,
        maxLength: 300,
        decoration: const InputDecoration(labelText: 'Why are you leaving? (optional)'),
      ),
      if (c.activeRide)
        Card(
          key: const ValueKey('delete-web-active-ride'),
          color: t.colorScheme.errorContainer,
          margin: const EdgeInsets.only(top: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'You have a ride under way. You can delete your account once it ends.',
              style: TextStyle(color: t.colorScheme.onErrorContainer),
            ),
          ),
        ),
      const SizedBox(height: 12),
      FilledButton(
        key: const ValueKey('delete-web-delete'),
        style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError),
        onPressed: c.activeRide || _busy ? null : _deleteNow,
        child: const Text('Delete my account'),
      ),
      TextButton(
        key: const ValueKey('delete-web-keep'),
        onPressed: _busy ? null : _keep,
        child: const Text('Keep my account'),
      ),
    ];
  }

  List<Widget> _doneStep(ThemeData t, AccountDeletionInfo info) {
    final after = _deleteAfter;
    final byPhone = _way == DeletionWay.phone && after != null && after.isAfter(DateTime.now());
    return [
      Icon(Icons.check_circle_outline, size: 40, color: t.colorScheme.primary),
      const SizedBox(height: 8),
      Text(
        byPhone ? 'Request received' : 'Your account has been deleted',
        key: const ValueKey('delete-web-done'),
        textAlign: TextAlign.center,
        style: t.textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      Text(
        byPhone
            ? 'Your GET.ride account will be deleted on ${_dateLong(after)}. We have signed it out on every device. '
                  'Changed your mind? Sign in to GET.ride again before then and the request is cancelled.'
            : 'Thank you for riding with GET.ride. Your personal details are wiped after '
                  '${dayCount(info.retentionDays)}, as set out below.',
        textAlign: TextAlign.center,
        style: t.textTheme.bodyMedium,
      ),
    ];
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "9 Nov 2026".
String _dateLong(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

class _WayCard extends StatelessWidget {
  const _WayCard({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? s.secondaryContainer : s.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? s.primary : s.outlineVariant, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: selected ? s.onSecondaryContainer : s.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: t.textTheme.titleSmall?.copyWith(
                          color: selected ? s.onSecondaryContainer : s.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        text,
                        style: t.textTheme.bodySmall?.copyWith(
                          color: selected ? s.onSecondaryContainer : s.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: selected ? s.primary : s.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _section(ThemeData t, DeletionPageSection s) => Padding(
  padding: const EdgeInsets.only(bottom: 16),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(s.title, style: t.textTheme.titleMedium),
      if (s.intro != null) ...[const SizedBox(height: 4), Text(s.intro!, style: t.textTheme.bodyMedium)],
      const SizedBox(height: 4),
      for (final line in s.lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7, right: 10),
                child: Icon(Icons.circle, size: 6, color: t.colorScheme.onSurfaceVariant),
              ),
              Expanded(child: Text(line, style: t.textTheme.bodyMedium)),
            ],
          ),
        ),
    ],
  ),
);
