// What a stand admin, stand staff or fleet owner does on sign-in before their
// role opens (migration 0281), one step at a time: their PIN (the usual Set
// your PIN page), a live selfie (again on a new phone), their MyKad or
// passport, then "Waiting for approval" until the ID is approved. The server
// decides what is left (dispatch_my_checks) and holds the role shut; these
// pages only show it. User mode keeps working throughout.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/meterapp/pick_image.dart';
import '../../core/signin_checks.dart';
import '../../data/auth_repository.dart';
import '../../data/identity_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/live_selfie.dart';
import '../../widgets/live_selfie/on_device.dart' as on_device;
import '../../widgets/page_style_host.dart';

typedef TakeSelfie = Future<LiveSelfie?> Function(BuildContext context);
typedef PickIdPhoto = Future<PickedImage?> Function(BuildContext context);
typedef ReadCard = Future<CardRead?> Function(Uint8List bytes);

/// The steps, where the role would be: shown by /dispatch while it is shut.
class SignInStepsView extends ConsumerWidget {
  const SignInStepsView({
    super.key,
    required this.checks,
    this.takeSelfie = takeLiveSelfie,
    this.pickPhoto = pickDocumentImage,
    this.readCard = on_device.readCardPhoto,
  });

  final DispatchChecks checks;
  final TakeSelfie takeSelfie;
  final PickIdPhoto pickPhoto;
  final ReadCard readCard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final role = roleWord(checks.kinds);
    final left = checks.daysLeft(DateTime.now());
    final step = checks.step;
    final body = switch (step) {
      SignInStep.pin => _StepCard(
        icon: Icons.pin_outlined,
        title: 'Set your PIN',
        text: 'Choose the 6-digit PIN you sign in with.',
        child: FilledButton(
          key: const ValueKey('step-pin'),
          onPressed: () {
            AuthRepository.pinSetupPending = true;
            context.go('/login/set-pin');
          },
          child: const Text('Set your PIN'),
        ),
      ),
      SignInStep.selfie => _SelfieStep(checks: checks, takeSelfie: takeSelfie),
      SignInStep.id => IdUploadForm(checks: checks, pickPhoto: pickPhoto, readCard: readCard),
      SignInStep.pending || SignInStep.done => WaitingForApproval(checks: checks),
    };
    return ListView(
      key: const ValueKey('signin-steps'),
      padding: const EdgeInsets.all(16),
      children: [
        ResponsiveCenter(
          maxWidth: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (checks.paused)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _Banner(
                    key: const ValueKey('steps-paused'),
                    icon: Icons.pause_circle_outline,
                    color: t.colorScheme.error,
                    text: 'Your $role role is paused: not verified. Finish the steps below to open it.',
                  ),
                )
              else if (step != SignInStep.pending)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    left == null
                        ? 'Before you use your $role role'
                        : 'Before you use your $role role. ${left == 1 ? '1 day' : '$left days'} left to finish.',
                    style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
              body,
              const SizedBox(height: 16),
              if (step != SignInStep.pending) _UserModeButton(filled: false),
            ],
          ),
        ),
      ],
    );
  }
}

class _UserModeButton extends StatelessWidget {
  const _UserModeButton({required this.filled});
  final bool filled;

  @override
  Widget build(BuildContext context) {
    void go() => context.go('/');
    const label = Text('Go to user mode');
    return filled
        ? FilledButton(key: const ValueKey('go-user-mode'), onPressed: go, child: label)
        : TextButton(key: const ValueKey('go-user-mode'), onPressed: go, child: label);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurface))),
        ],
      ),
    ),
  );
}

/// The admin's reason, when the last one was turned down.
class RejectedBanner extends StatelessWidget {
  const RejectedBanner({super.key, required this.what, required this.reason});
  final String what;
  final String reason;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: _Banner(
      key: const ValueKey('step-rejected'),
      icon: Icons.error_outline,
      color: Theme.of(context).colorScheme.error,
      text: "Your $what wasn't accepted: $reason",
    ),
  );
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.icon, required this.title, required this.text, required this.child, this.top});
  final IconData icon;
  final String title;
  final String text;
  final Widget child;
  final Widget? top;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?top,
            Row(
              children: [
                Icon(icon, color: t.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: t.textTheme.titleLarge)),
              ],
            ),
            const SizedBox(height: 8),
            Text(text, style: t.textTheme.bodyMedium),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

// ---- The selfie ---------------------------------------------------------------------------------

class _SelfieStep extends ConsumerStatefulWidget {
  const _SelfieStep({required this.checks, required this.takeSelfie});
  final DispatchChecks checks;
  final TakeSelfie takeSelfie;

  @override
  ConsumerState<_SelfieStep> createState() => _SelfieStepState();
}

class _SelfieStepState extends ConsumerState<_SelfieStep> {
  bool _busy = false;

  Future<void> _take() async {
    final selfie = await widget.takeSelfie(context);
    if (selfie == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(identityRepositoryProvider).sendSelfie(selfie, recheck: widget.checks.recheckOnly);
      ref.invalidate(dispatchChecksProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.checks;
    final rejected = c.selfie.state == RecordState.rejected ? c.selfie.rejection : null;
    return _StepCard(
      icon: Icons.face_outlined,
      title: c.recheckOnly ? 'New phone: take a selfie' : 'Take a selfie',
      text: c.recheckOnly
          ? "You're signed in on a phone we haven't seen before. Take a selfie to show it's you."
          : 'A live photo of you, with the front camera. You will be asked to blink or turn your head.',
      top: rejected == null ? null : RejectedBanner(what: 'photo', reason: rejected),
      child: BusyButton.filled(
        key: const ValueKey('step-selfie'),
        onPressed: _busy ? null : _take,
        icon: const Icon(Icons.photo_camera_front_outlined),
        child: Text(_busy ? 'Sending' : 'Open camera'),
      ),
    );
  }
}

// ---- The ID -------------------------------------------------------------------------------------

/// MyKad or passport, front and back, and a passport's expiry date (read off
/// it where the phone can). Also the "new ID" page before one runs out.
class IdUploadForm extends ConsumerStatefulWidget {
  const IdUploadForm({
    super.key,
    required this.checks,
    this.pickPhoto = pickDocumentImage,
    this.readCard = on_device.readCardPhoto,
    this.onSent,
  });

  final DispatchChecks checks;
  final PickIdPhoto pickPhoto;
  final ReadCard readCard;
  final VoidCallback? onSent;

  @override
  ConsumerState<IdUploadForm> createState() => _IdUploadFormState();
}

class _IdUploadFormState extends ConsumerState<IdUploadForm> {
  String _type = 'mykad';
  PickedImage? _front, _back;
  CardRead? _read;
  final _expiry = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _expiry.dispose();
    super.dispose();
  }

  Future<void> _pick(bool front) async {
    final photo = await widget.pickPhoto(context);
    if (photo == null || !mounted) return;
    setState(() {
      if (front) {
        _front = photo;
      } else {
        _back = photo;
      }
      _error = null;
    });
    if (!front) return;
    final read = await widget.readCard(photo.bytes);
    if (!mounted || read == null) return;
    setState(() {
      _read = read;
      if (read.expiry != null && _expiry.text.trim().isEmpty) {
        _expiry.text = read.expiry!.toIso8601String().split('T').first;
      }
      // A passport's machine lines say so.
      if (read.expiry != null) _type = 'passport';
    });
  }

  Future<void> _send() async {
    final expiry = _expiry.text.trim();
    String? problem;
    if (_front == null || _back == null) problem = 'Add a photo of the front and the back.';
    if (problem == null && _type == 'passport' && expiry.isEmpty) problem = "Add the passport's expiry date.";
    final day = DateTime.tryParse(expiry);
    if (problem == null && day != null && day.isBefore(DateUtils.dateOnly(DateTime.now()))) {
      problem = 'This ID has run out. Use one that is still valid.';
    }
    setState(() => _error = problem);
    if (problem != null) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(identityRepositoryProvider)
          .sendId(docType: _type, front: _front!.bytes, back: _back!.bytes, expiry: expiry, read: _read);
      ref.invalidate(dispatchChecksProvider);
      widget.onSent?.call();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _slot(String label, PickedImage? photo, bool front) {
    final t = Theme.of(context);
    return Expanded(
      child: InkWell(
        key: ValueKey(front ? 'id-front' : 'id-back'),
        borderRadius: BorderRadius.circular(12),
        onTap: _busy ? null : () => _pick(front),
        child: Container(
          height: 120,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: photo == null ? t.colorScheme.outline : t.colorScheme.primary),
            color: t.colorScheme.surfaceContainerHighest,
          ),
          clipBehavior: Clip.antiAlias,
          child: photo == null
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_a_photo_outlined, color: t.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 6),
                    Text(label, style: t.textTheme.bodyMedium),
                  ],
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(photo.bytes, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Container(
                        color: t.colorScheme.inverseSurface,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Text(label, style: TextStyle(color: t.colorScheme.onInverseSurface)),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = widget.checks;
    final rejected = switch (c.id.state) {
      RecordState.rejected || RecordState.renew => c.id.rejection,
      _ => null,
    };
    final renew = c.id.state == RecordState.renew;
    final expired = c.id.state == RecordState.expired;
    final read = _read;
    final today = DateUtils.dateOnly(DateTime.now());
    return _StepCard(
      icon: Icons.badge_outlined,
      title: renew || expired ? 'Upload a new ID' : 'Upload your ID',
      text: renew && c.id.expiry != null
          ? 'Your ID runs out on ${formatDateForUser(c.id.expiry)}. Send a new one so your role keeps working.'
          : expired
          ? 'Your ID has run out. Send one that is still valid.'
          : 'Your MyKad or passport: a clear photo of the front and the back.',
      top: rejected == null ? null : RejectedBanner(what: 'ID', reason: rejected),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            key: const ValueKey('id-type'),
            segments: const [
              ButtonSegment(value: 'mykad', label: Text('MyKad')),
              ButtonSegment(value: 'passport', label: Text('Passport')),
            ],
            selected: {_type},
            onSelectionChanged: _busy ? null : (v) => setState(() => _type = v.first),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _slot('Front', _front, true),
              const SizedBox(width: 12),
              _slot('Back', _back, false),
            ],
          ),
          if (read != null && (read.name != null || read.ic != null)) ...[
            const SizedBox(height: 10),
            Text(
              'Read from the card: ${[read.name, read.ic].whereType<String>().join(' · ')}',
              key: const ValueKey('id-read'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
          if (_type == 'passport') ...[
            const SizedBox(height: 12),
            DateBoxesField(
              key: const ValueKey('id-expiry'),
              label: 'Expiry date',
              controller: _expiry,
              isRequired: true,
              firstDate: today,
              lastDate: DateTime(today.year + 20, 12, 31),
              afterLastText: 'Check the year.',
              beforeFirstText: 'This passport has run out.',
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, key: const ValueKey('id-error'), style: TextStyle(color: t.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          BusyButton.filled(
            key: const ValueKey('id-send'),
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.upload_outlined),
            child: Text(_busy ? 'Sending' : 'Send for review'),
          ),
        ],
      ),
    );
  }
}

// ---- Waiting ------------------------------------------------------------------------------------

/// "Waiting for approval": what was sent and where it stands, and the way
/// back to the rider app.
class WaitingForApproval extends StatelessWidget {
  const WaitingForApproval({super.key, required this.checks});
  final DispatchChecks checks;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      key: const ValueKey('waiting-approval'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.hourglass_top_outlined, color: t.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Waiting for approval', style: t.textTheme.titleLarge)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'We check your ID, usually within a day. Your ${roleWord(checks.kinds)} role opens once it is '
                  'approved, and we let you know.',
                  style: t.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                for (final l in waitingLines(checks))
                  ListTile(
                    key: ValueKey('waiting-${l.label}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      l.done ? Icons.check_circle_outline : Icons.schedule_outlined,
                      color: l.done ? Colors.green : t.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(l.label),
                    trailing: Text(l.state, style: t.textTheme.bodyMedium),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const _UserModeButton(filled: true),
      ],
    );
  }
}

/// The new ID page, opened from the reminder before one runs out.
Future<void> openRenewIdPage(BuildContext context, DispatchChecks checks) => Navigator.of(context).push<void>(
  AppPageRoute(
    id: 'dispatch.renew-id',
    builder: (ctx) => Scaffold(
      appBar: AppBar(title: const Text('New ID')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 560,
            child: IdUploadForm(checks: checks, onSent: () => Navigator.of(ctx).pop()),
          ),
        ],
      ),
    ),
  ),
);

/// The ID expiries already told about in this run of the app: the popup
/// opens once per expiry, not on every visit to the role's pages.
final _renewIdShown = <String>{};

/// While the ID runs out soon: a popup over the role's own pages, with an
/// (x) and Upload new ID, once per run of the app. Draws nothing itself.
class RenewIdNotice extends StatefulWidget {
  const RenewIdNotice({super.key, required this.checks});
  final DispatchChecks checks;

  @override
  State<RenewIdNotice> createState() => _RenewIdNoticeState();
}

class _RenewIdNoticeState extends State<RenewIdNotice> {
  @override
  void initState() {
    super.initState();
    final checks = widget.checks;
    if (!_renewIdShown.add('${checks.id.expiry}')) return;
    final when = checks.id.expiry == null ? 'soon' : 'on ${formatDateForUser(checks.id.expiry)}';
    unawaited(showAppNotice(
      id: 'notice.dispatch-renew-id',
      context: context,
      key: const ValueKey('renew-id'),
      title: 'Your ID runs out $when',
      message: 'Send a new one so you can keep working.',
      actionLabel: 'Upload new ID',
      onAction: () {
        if (mounted) openRenewIdPage(context, checks);
      },
    ));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
