import 'package:flutter/material.dart';
import 'net_image.dart';

/// Every side menu's look (the user's, the driver's and the admin's), taken
/// from the reference menu: a charcoal panel in either theme, grey outline
/// icons beside white labels, thin dividers, and the app's own accent on
/// the buttons at the foot.
abstract final class SideMenuStyle {
  static const background = Color(0xFF242424);
  static const divider = Color(0xFF555555);
  static const icon = Color(0xFF9498A4);
  static const text = Colors.white;
  static const muted = Color(0xFFB8B7B2);
  static const star = Color(0xFFF09E3B);
  /// The buttons: the app's theme accent (its brand blue, as "Find a
  /// driver"), not a colour of the menu's own.
  static const button = Color(0xFF2DABE2);
  static const onButton = Colors.white;

  /// A row the admin menu has open.
  static const selected = Color(0xFF333333);

  /// Share of the screen the panel takes, at most [maxWidth].
  static const widthFraction = 0.8;
  static const maxWidth = 360.0;

  static double widthFor(double screen) => (screen * widthFraction).clamp(0, maxWidth).toDouble();
}

/// The menu's colours for the app's theme: the charcoal panel in dark mode,
/// a white one in light mode (as the Expo app's light menu), with the
/// accent button and gold stars the same in both.
class SideMenuColors {
  const SideMenuColors({
    required this.background,
    required this.divider,
    required this.icon,
    required this.text,
    required this.muted,
    required this.selected,
  });

  final Color background, divider, icon, text, muted, selected;

  static const dark = SideMenuColors(
    background: SideMenuStyle.background,
    divider: SideMenuStyle.divider,
    icon: SideMenuStyle.icon,
    text: SideMenuStyle.text,
    muted: SideMenuStyle.muted,
    selected: SideMenuStyle.selected,
  );

  static const light = SideMenuColors(
    background: Colors.white,
    divider: Color(0xFFE6E6E6),
    icon: Color(0xFF8A8F99),
    text: Color(0xFF111111),
    muted: Color(0xFF6B6F78),
    selected: Color(0xFFF6F4EF),
  );

  static SideMenuColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// One menu row: the grey outline icon and the white label.
class SideMenuRow extends StatelessWidget {
  const SideMenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.trailing,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// In place of the usual colours (sign out in red).
  final Color? color;
  final Widget? trailing;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = SideMenuColors.of(context);
    return Material(
    color: selected ? c.selected : Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(19, 8, 16, 8),
        child: Row(
          children: [
            Icon(icon, size: 24, color: color ?? c.icon),
            const SizedBox(width: 13),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, height: 1.2, color: color ?? c.text),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    ),
  );
  }
}

/// The person at the top of a menu: avatar, name, and a line under it (the
/// stars, or what the menu is for), with a chevron when it opens a page.
class SideMenuHeader extends StatelessWidget {
  const SideMenuHeader({super.key, required this.name, this.avatarUrl, this.subtitle, this.onTap});

  final String name;
  final String? avatarUrl;
  final Widget? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = SideMenuColors.of(context);
    return InkWell(
    key: const ValueKey('menu-profile'),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 16, 18),
      child: Row(
        children: [
          NetAvatar(
            url: avatarUrl,
            radius: 22,
            backgroundColor: c.selected,
            fallback: Icon(Icons.sentiment_satisfied_alt, size: 28, color: c.icon),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: c.text),
                ),
                if (subtitle != null) ...[const SizedBox(height: 4), subtitle!],
              ],
            ),
          ),
          if (onTap != null) Icon(Icons.chevron_right, color: c.text),
        ],
      ),
    ),
  );
  }
}

/// Five stars and the figure, as under the name.
class SideMenuStars extends StatelessWidget {
  const SideMenuStars({super.key, required this.rating});
  final double rating;

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('menu-rating'),
    children: [
      for (var i = 1; i <= 5; i++)
        Icon(
          i <= rating.round() ? Icons.star_rounded : Icons.star_outline_rounded,
          size: 16,
          color: SideMenuStyle.star,
        ),
      const SizedBox(width: 8),
      Text(rating.toStringAsFixed(1), style: TextStyle(fontSize: 14, color: SideMenuColors.of(context).muted)),
    ],
  );
}

/// A side menu's frame: the header, a divider, the rows, a divider, then
/// the accent button and whatever goes under it, on the charcoal panel.
class SideMenuFrame extends StatelessWidget {
  const SideMenuFrame({
    super.key,
    this.header,
    required this.rows,
    this.buttonLabel,
    this.buttonKey,
    this.onButton,
    this.footer = const [],
  });

  final Widget? header;
  final List<Widget> rows;
  final String? buttonLabel;
  final Key? buttonKey;
  final VoidCallback? onButton;

  /// Under the button: the admin panel link, the social links.
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final c = SideMenuColors.of(context);
    final line = Divider(height: 1, thickness: 1, color: c.divider);
    return Material(
      color: c.background,
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            if (header != null) ...[header!, line],
            Expanded(
              child: ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: rows),
            ),
            line,
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Column(
                children: [
                  if (buttonLabel != null)
                    FilledButton(
                      key: buttonKey,
                      style: FilledButton.styleFrom(
                        backgroundColor: SideMenuStyle.button,
                        foregroundColor: SideMenuStyle.onButton,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                      ),
                      onPressed: onButton,
                      child: Text(buttonLabel!),
                    ),
                  ...footer,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// TikTok, Facebook and Instagram, at the foot of the user and driver menus.
class SideMenuSocialLinks extends StatelessWidget {
  const SideMenuSocialLinks({super.key});

  @override
  Widget build(BuildContext context) {
    final text = SideMenuColors.of(context).text;
    Widget link(String name, Widget icon) => Tooltip(
      message: 'GET.ride on $name',
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 17), child: icon),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Row(
        key: const ValueKey('menu-social'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          link('TikTok', Icon(Icons.tiktok, size: 28, color: text)),
          // The plain "f", as the reference draws it (Material's is in a disc).
          link(
            'Facebook',
            SizedBox.square(
              dimension: 28,
              child: Center(
                child: Text(
                  'f',
                  style: TextStyle(fontSize: 32, height: 1, fontWeight: FontWeight.w900, color: text),
                ),
              ),
            ),
          ),
          link('Instagram', CustomPaint(size: const Size.square(25), painter: _InstagramGlyph(text))),
        ],
      ),
    );
  }
}

/// Instagram's camera outline: a rounded square, a lens and a dot (Material
/// icons have no Instagram).
class _InstagramGlyph extends CustomPainter {
  const _InstagramGlyph(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.09;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.06, w * 0.06, w * 0.88, w * 0.88), Radius.circular(w * 0.26)),
      line,
    );
    canvas.drawCircle(Offset(w / 2, w / 2), w * 0.2, line);
    canvas.drawCircle(Offset(w * 0.74, w * 0.26), w * 0.055, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_InstagramGlyph old) => old.color != color;
}
