// App Page Settings in the app (see core/page_styles.dart): the admin's
// values for every page, sheet and modal, applied as each one opens.
//
// Every sheet, modal and pushed page goes through [showAppSheet],
// [showAppDialog], [showAppGeneralDialog] or [AppPageRoute] with an `id`, so
// it is listed in App Page Settings (page_inventory.g.dart) and takes its
// values; router pages take theirs from [PageStyleHost]. A value nobody set
// leaves the app's own look.
import 'package:flutter/material.dart';

import '../core/page_inventory.g.dart';
import '../core/page_styles.dart';
import 'web_overlay_back.dart';

/// The admin's values for everything below, and the page they are on.
class PageStyleScope extends InheritedWidget {
  const PageStyleScope({super.key, required this.styles, this.page, required super.child});

  final PageStyles styles;

  /// The surface id of the page this is on (`route:/`, `page:<id>`).
  final String? page;

  static PageStyleScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PageStyleScope>();

  @override
  bool updateShouldNotify(PageStyleScope old) => old.styles != styles || old.page != page;
}

/// The kind of surface [id] names.
SurfaceKind surfaceKindOf(String id) => id.startsWith('sheet:')
    ? SurfaceKind.sheet
    : id.startsWith('modal:')
    ? SurfaceKind.modal
    : SurfaceKind.page;

/// One surface's values as the app reads them.
class SurfaceStyle {
  const SurfaceStyle(this.styles, this.id, this.kind);

  final PageStyles styles;
  final String id;
  final SurfaceKind kind;

  /// [id]'s values under [context]'s [PageStyleScope].
  factory SurfaceStyle.of(BuildContext context, String id) =>
      SurfaceStyle(PageStyleScope.maybeOf(context)?.styles ?? PageStyles.none, id, surfaceKindOf(id));

  /// The values of the page [context] is on (the app-wide ones off a page).
  factory SurfaceStyle.ofPage(BuildContext context) {
    final scope = PageStyleScope.maybeOf(context);
    return SurfaceStyle(scope?.styles ?? PageStyles.none, scope?.page ?? appSurface, SurfaceKind.page);
  }

  List<StyleToken> get tokens => [...tokensFor(kind), ...?elementTokens[id]];

  StyleToken token(String key) => tokenNamed(tokens, key);

  /// Whether the admin set [key] here or app-wide.
  bool isSet(String key) => styles.isSet(id, kind, key);

  double number(String key) => styles.number(id, kind, token(key));

  /// [key] when the admin set it; null keeps the app's own value.
  double? setNumber(String key) => isSet(key) ? number(key) : null;

  bool toggle(String key) => styles.toggle(id, kind, token(key));

  Color? color(String key, Brightness b) => styles.color(id, kind, token(key), b);

  /// [key]'s colour when the admin set it; null keeps the app's own.
  Color? setColor(String key, Brightness b) => isSet(key) ? color(key, b) : null;
}

/// [base] with [s]'s values that are set.
ThemeData styledTheme(ThemeData base, SurfaceStyle s) {
  final b = base.brightness;
  var t = base;
  final icon = s.setNumber('iconSize');
  if (icon != null) t = t.copyWith(iconTheme: t.iconTheme.copyWith(size: icon));
  final buttonHeight = s.tokens.any((x) => x.key == 'buttonHeight') ? s.setNumber('buttonHeight') : null;
  final buttonRadius = s.setNumber('buttonRadius');
  if (buttonHeight != null || buttonRadius != null) {
    final shape = buttonRadius == null
        ? null
        : WidgetStatePropertyAll<OutlinedBorder>(RoundedRectangleBorder(borderRadius: BorderRadius.circular(buttonRadius)));
    final filled = ButtonStyle(
      minimumSize: buttonHeight == null ? null : WidgetStatePropertyAll(Size.fromHeight(buttonHeight)),
      shape: shape,
    );
    t = t.copyWith(
      filledButtonTheme: FilledButtonThemeData(style: filled.merge(t.filledButtonTheme.style)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: ButtonStyle(shape: shape).merge(t.outlinedButtonTheme.style)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: ButtonStyle(shape: shape).merge(t.elevatedButtonTheme.style)),
      textButtonTheme: s.kind == SurfaceKind.modal
          ? TextButtonThemeData(style: ButtonStyle(shape: shape).merge(t.textButtonTheme.style))
          : null,
    );
  }
  switch (s.kind) {
    case SurfaceKind.page:
      final bg = s.setColor('background', b);
      if (bg != null) t = t.copyWith(scaffoldBackgroundColor: bg);
      final bar = s.setColor('appBarColor', b);
      final title = s.setNumber('appBarTitleSize');
      if (bar != null || title != null) {
        t = t.copyWith(
          appBarTheme: t.appBarTheme.copyWith(
            backgroundColor: bar,
            titleTextStyle: title == null
                ? null
                : (t.appBarTheme.titleTextStyle ?? t.textTheme.titleLarge)?.copyWith(fontSize: title),
          ),
        );
      }
      final handle = s.setColor('handleColor', b);
      if (handle != null) t = t.copyWith(bottomSheetTheme: t.bottomSheetTheme.copyWith(dragHandleColor: handle));
      final card = s.setNumber('cardRadius');
      if (card != null) {
        final side = switch (t.cardTheme.shape) {
          RoundedRectangleBorder(:final side) => side,
          _ => BorderSide.none,
        };
        t = t.copyWith(
          cardTheme: t.cardTheme.copyWith(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(card), side: side),
          ),
        );
      }
      final input = s.setNumber('inputRadius');
      if (input != null) {
        t = t.copyWith(
          inputDecorationTheme: t.inputDecorationTheme.copyWith(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(input)),
          ),
        );
      }
    case SurfaceKind.modal:
      final radius = s.setNumber('cornerRadius');
      final bg = s.setColor('background', b);
      final title = s.setNumber('titleSize');
      if (radius != null || bg != null || title != null) {
        t = t.copyWith(
          dialogTheme: t.dialogTheme.copyWith(
            shape: radius == null ? null : RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
            backgroundColor: bg,
            titleTextStyle: title == null
                ? null
                : (t.dialogTheme.titleTextStyle ?? t.textTheme.headlineSmall)?.copyWith(fontSize: title),
          ),
        );
      }
    case SurfaceKind.sheet:
      break;
  }
  return t;
}

/// [child] under surface [id]'s values: its theme, its text size and, for a
/// page, the page id its items read theirs from.
class SurfaceFrame extends StatelessWidget {
  const SurfaceFrame({super.key, required this.id, this.styles, required this.child});

  final String id;

  /// The values as they were where it was opened (a sheet or modal's route
  /// may sit outside the [PageStyleScope]); null for the scope's.
  final PageStyles? styles;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = PageStyleScope.maybeOf(context);
    final styles = this.styles ?? scope?.styles ?? PageStyles.none;
    final s = SurfaceStyle(styles, id, surfaceKindOf(id));
    Widget out = Theme(data: styledTheme(Theme.of(context), s), child: child);
    final scale = s.setNumber('textScale');
    if (scale != null) {
      final mq = MediaQuery.of(context);
      out = MediaQuery(
        data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(100) / 100 * scale)),
        child: out,
      );
    }
    if (s.kind == SurfaceKind.page || this.styles != null) {
      out = PageStyleScope(styles: styles, page: s.kind == SurfaceKind.page ? id : scope?.page, child: out);
    }
    return out;
  }
}

/// Above the router's pages: [styles] for everything, and the values of the
/// page at [location] (its route pattern, `/ride/:id`).
class PageStyleHost extends StatelessWidget {
  const PageStyleHost({
    super.key,
    required this.styles,
    required this.location,
    required this.listenable,
    required this.child,
  });

  final PageStyles styles;
  final String Function() location;
  final Listenable listenable;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: listenable,
    builder: (_, child) {
      String path;
      try {
        path = location();
      } catch (_) {
        path = '';
      }
      return PageStyleScope(
        styles: styles,
        child: SurfaceFrame(id: path.isEmpty ? appSurface : 'route:$path', child: child!),
      );
    },
    child: child,
  );
}

/// The listed surface [id], if it is one.
SurfaceEntry? surfaceEntry(String id) {
  for (final s in pageInventory) {
    if (s.id == id) return s;
  }
  return null;
}

/// [showModalBottomSheet] for sheet [id] (listed in App Page Settings): its
/// curve, background, handle, height and dim as the admin set them, over
/// what the caller passed.
Future<T?> showAppSheet<T>({
  required String id,
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  double scrollControlDisabledMaxHeightRatio = 9.0 / 16.0,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool? requestFocus,
}) {
  final surface = 'sheet:$id';
  final s = SurfaceStyle.of(context, surface);
  final b = Theme.of(context).brightness;
  final radius = s.setNumber('topRadius');
  final dim = s.setNumber('dim');
  final tallest = s.setNumber('maxHeight');
  final screen = MediaQuery.sizeOf(context).height;
  // On the web the browser's Back closes it (web_overlay_back.dart).
  final back = OverlayRouteBack();
  return back.track(showModalBottomSheet<T>(
    context: context,
    builder: (_) => back.wrap(SurfaceFrame(id: surface, styles: s.styles, child: Builder(builder: builder))),
    backgroundColor: s.setColor('background', b) ?? backgroundColor,
    barrierLabel: barrierLabel,
    elevation: elevation,
    shape: radius == null ? shape : RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(radius))),
    clipBehavior: clipBehavior,
    constraints: tallest == null || tallest >= 100
        ? constraints
        : (constraints ?? const BoxConstraints()).copyWith(maxHeight: screen * tallest / 100),
    barrierColor: dim == null ? barrierColor : Colors.black.withValues(alpha: dim / 100),
    isScrollControlled: isScrollControlled,
    scrollControlDisabledMaxHeightRatio: scrollControlDisabledMaxHeightRatio,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: s.isSet('showHandle') ? s.toggle('showHandle') : showDragHandle,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    transitionAnimationController: transitionAnimationController,
    anchorPoint: anchorPoint,
    sheetAnimationStyle: sheetAnimationStyle,
    requestFocus: requestFocus,
  ));
}

/// [showDialog] for modal [id] (listed in App Page Settings): its curve,
/// colours, title and dim as the admin set them.
Future<T?> showAppDialog<T>({
  required String id,
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
  AnimationStyle? animationStyle,
}) {
  final surface = 'modal:$id';
  final s = SurfaceStyle.of(context, surface);
  final dim = s.setNumber('dim');
  final back = OverlayRouteBack();
  return back.track(showDialog<T>(
    context: context,
    builder: (_) => back.wrap(SurfaceFrame(id: surface, styles: s.styles, child: Builder(builder: builder))),
    barrierDismissible: barrierDismissible,
    barrierColor: dim == null ? barrierColor : Colors.black.withValues(alpha: dim / 100),
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    traversalEdgeBehavior: traversalEdgeBehavior,
    fullscreenDialog: fullscreenDialog,
    requestFocus: requestFocus,
    animationStyle: animationStyle,
  ));
}

/// [showGeneralDialog] for modal [id] (listed in App Page Settings).
Future<T?> showAppGeneralDialog<T extends Object?>({
  required String id,
  required BuildContext context,
  required RoutePageBuilder pageBuilder,
  bool barrierDismissible = false,
  String? barrierLabel,
  Color barrierColor = const Color(0x80000000),
  Duration transitionDuration = const Duration(milliseconds: 200),
  RouteTransitionsBuilder? transitionBuilder,
  bool useRootNavigator = true,
  bool fullscreenDialog = false,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  bool? requestFocus,
}) {
  final surface = 'modal:$id';
  final s = SurfaceStyle.of(context, surface);
  final dim = s.setNumber('dim');
  final back = OverlayRouteBack();
  return back.track(showGeneralDialog<T>(
    context: context,
    pageBuilder: (c, a, b) =>
        back.wrap(SurfaceFrame(id: surface, styles: s.styles, child: Builder(builder: (c) => pageBuilder(c, a, b)))),
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: dim == null ? barrierColor : Colors.black.withValues(alpha: dim / 100),
    transitionDuration: transitionDuration,
    transitionBuilder: transitionBuilder,
    useRootNavigator: useRootNavigator,
    fullscreenDialog: fullscreenDialog,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    requestFocus: requestFocus,
  ));
}

/// [MaterialPageRoute] for page [id] (listed in App Page Settings).
class AppPageRoute<T> extends MaterialPageRoute<T> {
  AppPageRoute({
    required this.id,
    required WidgetBuilder builder,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
    super.traversalEdgeBehavior,
    super.directionalTraversalEdgeBehavior,
  }) : super(builder: (_) => SurfaceFrame(id: 'page:$id', child: Builder(builder: builder)));

  final String id;
}
