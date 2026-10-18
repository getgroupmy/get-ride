import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The app bar's back arrow for a page that can also be opened straight from
/// its address (a reload, a shared link), where there is no page below it:
/// pops when it can, else goes to [fallback], the page's parent.
class BackOrGoButton extends StatelessWidget {
  const BackOrGoButton({super.key, required this.fallback});

  final String fallback;

  @override
  Widget build(BuildContext context) => BackButton(
    key: const ValueKey('back-or-go'),
    onPressed: () {
      final router = GoRouter.maybeOf(context);
      if (router == null) {
        Navigator.of(context).maybePop();
      } else if (router.canPop()) {
        router.pop();
      } else {
        router.go(fallback);
      }
    },
  );
}
