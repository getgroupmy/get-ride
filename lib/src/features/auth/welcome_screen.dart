// The first page after the splash, laid out as inDrive's: the logo, two
// slides about the app, then "Continue with passkey" (where passkeys are
// on, migration 0179) and "Continue with phone", and the terms. get.ride's
// own logo, colours and drawings.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../../core/auth_utils.dart' show signInAddress;
import '../../data/app_display_repository.dart';
import '../../data/session_guard.dart';
import '../../widgets/common.dart';
import '../../widgets/in_app_page.dart';
import 'passkey_sign_in_button.dart';

class _Slide {
  const _Slide(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}

const _slides = [
  _Slide(Icons.handshake_outlined, 'Your app for fair rides', 'Choose the ride and the price that suit you'),
  _Slide(
    Icons.verified_user_outlined,
    'Your safety comes first',
    'Only verified drivers.\nChoose yours by rating and more',
  ),
];

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  final _pages = PageController();
  int _page = 0;
  Timer? _auto;
  late final TapGestureRecognizer _terms = TapGestureRecognizer()
    ..onTap = () => openInApp(context, AppConfig.termsUrl, title: 'Terms of Use');
  late final TapGestureRecognizer _privacy = TapGestureRecognizer()
    ..onTap = () => openInApp(context, AppConfig.privacyUrl, title: 'Privacy Policy');

  @override
  void initState() {
    super.initState();
    // The slides turn by themselves, and by swiping.
    _auto = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_pages.hasClients) return;
      final next = (_page + 1) % _slides.length;
      unawaited(_pages.animateToPage(next, duration: const Duration(milliseconds: 400), curve: Curves.easeInOut));
    });
  }

  @override
  void dispose() {
    _auto?.cancel();
    _pages.dispose();
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final showLogo = ref.watch(appDisplayProvider).value?.showSignInLogo ?? true;
    final passkeys = ref.watch(passkeyOfferedHereProvider).value == true;
    final big = const Size.fromHeight(58);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    final label = t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);
    final muted = t.colorScheme.onSurfaceVariant;
    final page = Scaffold(
      key: const ValueKey('welcome'),
      body: SafeArea(
        child: ResponsiveCenter(
          maxWidth: 480,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 48,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (showLogo) const BrandMark(key: ValueKey('sign-in-logo'), size: 28),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        key: const ValueKey('phone-diagnostics'),
                        tooltip: 'Connection diagnostics',
                        icon: Icon(Icons.network_check, color: muted),
                        onPressed: () => context.push('/diagnostics'),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                // A mouse can drag the slides too (desktop web), not only a finger.
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
                  child: PageView(
                    key: const ValueKey('welcome-slides'),
                    controller: _pages,
                    onPageChanged: (i) => setState(() => _page = i),
                    children: [for (final s in _slides) _SlideView(s)],
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Each dot opens its slide.
                  for (var i = 0; i < _slides.length; i++)
                    Semantics(
                      button: true,
                      selected: i == _page,
                      label: 'Slide ${i + 1} of ${_slides.length}',
                      child: InkWell(
                        key: ValueKey('welcome-dot-$i'),
                        customBorder: const CircleBorder(),
                        onTap: () => unawaited(
                          _pages.animateToPage(i, duration: const Duration(milliseconds: 400), curve: Curves.easeInOut),
                        ),
                        // A 44 × 44 target around the 8 pt dot.
                        child: SizedBox.square(
                          dimension: 44,
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i == _page ? t.colorScheme.onSurface : t.colorScheme.outlineVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SignedOutElsewhereNote(),
              if (passkeys) ...[const PasskeySignInButton(), const SizedBox(height: 12)],
              FilledButton(
                key: const ValueKey('continue-with-phone'),
                // The primary action, always: the theme's filled button, as
                // Next and Sign in (a grey tonal one beside an outlined
                // passkey button read as disabled).
                style: FilledButton.styleFrom(minimumSize: big, shape: shape, textStyle: label),
                onPressed: () {
                  signedOutElsewhere.value = false;
                  // The page asked for before sign-in rides along (`to`).
                  context.push(signInAddress('/login/phone'));
                },
                child: const Text('Continue with phone'),
              ),
              const SizedBox(height: 16),
              Text.rich(
                key: const ValueKey('welcome-terms'),
                TextSpan(
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                  children: [
                    const TextSpan(text: 'Joining our app means you agree with our '),
                    TextSpan(
                      text: 'Terms of Use',
                      style: const TextStyle(decoration: TextDecoration.underline),
                      recognizer: _terms,
                    ),
                    const TextSpan(text: ' and '),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: const TextStyle(decoration: TextDecoration.underline),
                      recognizer: _privacy,
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
    // No app bar to set the status bar: its icons follow the theme. The
    // Left and Right keys move the slides (a keyboard on the web/desktop).
    return ThemedStatusBar(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _slideBy(1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _slideBy(-1),
        },
        child: Focus(autofocus: true, child: page),
      ),
    );
  }

  /// The next (1) or previous (-1) slide, if there is one.
  void _slideBy(int step) {
    final to = _page + step;
    if (to < 0 || to >= _slides.length || !_pages.hasClients) return;
    unawaited(_pages.animateToPage(to, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut));
  }
}

/// One slide: a drawing in the brand colour, a bold line and a short one.
class _SlideView extends StatelessWidget {
  const _SlideView(this.slide);
  final _Slide slide;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const brand = Color(0xFF2DABE2); // the logo's blue (app.dart brandAccent)
    return LayoutBuilder(
      builder: (context, box) {
        final art = (box.maxHeight * 0.5).clamp(120.0, 280.0);
        // A phone on its side leaves the slide too little height for the
        // drawing: the words come first.
        final showArt = box.maxHeight >= 240;
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (showArt) ...[
            SizedBox.square(
              dimension: art,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Transform.rotate(
                    angle: -0.2,
                    child: Container(
                      width: art * 0.9,
                      height: art * 0.78,
                      decoration: BoxDecoration(
                        color: brand.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(art * 0.16),
                      ),
                    ),
                  ),
                  Container(
                    width: art * 0.62,
                    height: art * 0.62,
                    decoration: BoxDecoration(
                      color: t.colorScheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: t.colorScheme.onSurface, width: 3),
                    ),
                    child: Icon(slide.icon, size: art * 0.34, color: t.colorScheme.onSurface),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            ],
            Text(
              slide.title,
              textAlign: TextAlign.center,
              style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(slide.body, textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
            // Kept for the app's first screen, as before.
            const SizedBox(height: 4),
            if (slide == _slides.first)
              Text(
                'Your ride, your way.',
                style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
              ),
          ],
        )),
        );
      },
    );
  }
}
