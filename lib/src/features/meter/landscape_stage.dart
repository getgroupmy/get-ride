import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/landscape_stage.dart';

/// Hands [child] a landscape box whatever shape the glass is (Expo
/// `FixedLandscapeStage`). On a landscape viewport it is a plain passthrough,
/// so a device whose orientation lock worked pays nothing; on a portrait one
/// the content is turned a quarter turn, with the size and safe-area insets
/// it reads from [MediaQuery] turned to match.
///
/// A browser can't lock the orientation, so on the web a portrait phone is
/// first asked to turn sideways ([showRotateHint]); "Continue anyway" shows
/// the turned page as before.
class LandscapeStage extends StatefulWidget {
  const LandscapeStage({super.key, required this.child, this.showRotateHint = kIsWeb});

  final Widget child;
  final bool showRotateHint;

  @override
  State<LandscapeStage> createState() => _LandscapeStageState();
}

class _LandscapeStageState extends State<LandscapeStage> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final mq = MediaQuery.of(context);
      final stage = resolveLandscapeStage(constraints.biggest, mq.padding);
      if (stage.quarterTurns == 0) return widget.child;
      if (widget.showRotateHint && !_dismissed) {
        return RotateHint(onContinue: () => setState(() => _dismissed = true));
      }
      return RotatedBox(
        quarterTurns: stage.quarterTurns,
        child: MediaQuery(
          data: mq.copyWith(size: stage.size, padding: stage.padding, viewPadding: stage.padding),
          child: widget.child,
        ),
      );
    });
  }
}

/// "Turn your phone sideways": the meter is laid out for landscape.
class RotateHint extends StatelessWidget {
  const RotateHint({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      key: const ValueKey('meter-rotate-hint'),
      color: t.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.screen_rotation, size: 64, color: t.colorScheme.primary),
                const SizedBox(height: 16),
                Text('Turn your phone sideways', textAlign: TextAlign.center, style: t.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'The meter is laid out for landscape. Turn off rotation lock if the page does not turn.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                TextButton(
                  key: const ValueKey('meter-rotate-continue'),
                  onPressed: onContinue,
                  child: const Text('Continue anyway'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
