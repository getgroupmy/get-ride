import 'package:flutter/widgets.dart';

import '../core/window_class.dart';

/// Diagnostic only: compiled in when `--dart-define=DUO_DEBUG=true`, off in
/// every normal build. Shows the exact geometry iOS hands the Flutter view —
/// the window size, orientation, safe-area insets and any display features —
/// so a Duo layout question (e.g. a black strip on one edge) can be read off
/// the device instead of guessed from a screenshot.
const bool kDuoGeometryDebug = bool.fromEnvironment('DUO_DEBUG');

/// Wraps [child], painting a compact geometry readout on top when
/// [kDuoGeometryDebug] is on; otherwise returns [child] untouched.
class DuoGeometryOverlay extends StatelessWidget {
  const DuoGeometryOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kDuoGeometryDebug) return child;
    final mq = MediaQuery.of(context);
    final m = windowMetricsOf(mq.size, mq.displayFeatures);
    String e(EdgeInsets p) => 'L${p.left.toStringAsFixed(0)} '
        'T${p.top.toStringAsFixed(0)} '
        'R${p.right.toStringAsFixed(0)} '
        'B${p.bottom.toStringAsFixed(0)}';
    final lines = <String>[
      'size ${mq.size.width.toStringAsFixed(0)} x ${mq.size.height.toStringAsFixed(0)}  dpr ${mq.devicePixelRatio}',
      'orientation ${mq.orientation.name}',
      'padding    ${e(mq.padding)}',
      'viewPadding ${e(mq.viewPadding)}',
      'viewInsets ${e(mq.viewInsets)}',
      'widthClass ${m.widthClass.name}  heightClass ${m.heightClass.name}',
      'displayFeatures ${mq.displayFeatures.length}',
      for (final f in mq.displayFeatures)
        '  ${f.type.name}/${f.state.name} '
            '${f.bounds.left.toStringAsFixed(0)},${f.bounds.top.toStringAsFixed(0)} '
            '${f.bounds.width.toStringAsFixed(0)}x${f.bounds.height.toStringAsFixed(0)}',
    ];
    return Stack(
      children: [
        child,
        Positioned(
          left: 8,
          bottom: 8,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.all(8),
              color: const Color(0xCC000000),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Color(0xFF66FF99),
                  fontSize: 11,
                  height: 1.35,
                  fontFamily: 'monospace',
                  decoration: TextDecoration.none,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final l in lines) Text(l)],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
