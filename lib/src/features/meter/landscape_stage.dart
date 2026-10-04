import 'package:flutter/widgets.dart';

import '../../core/landscape_stage.dart';

/// Hands [child] a landscape box whatever shape the glass is (Expo
/// `FixedLandscapeStage`). On a landscape viewport it is a plain passthrough,
/// so a device whose orientation lock worked pays nothing; on a portrait one
/// the content is turned a quarter turn, with the size and safe-area insets
/// it reads from [MediaQuery] turned to match.
class LandscapeStage extends StatelessWidget {
  const LandscapeStage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final mq = MediaQuery.of(context);
      final stage = resolveLandscapeStage(constraints.biggest, mq.padding);
      if (stage.quarterTurns == 0) return child;
      return RotatedBox(
        quarterTurns: stage.quarterTurns,
        child: MediaQuery(
          data: mq.copyWith(size: stage.size, padding: stage.padding, viewPadding: stage.padding),
          child: child,
        ),
      );
    });
  }
}
