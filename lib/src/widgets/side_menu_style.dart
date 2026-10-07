import 'package:flutter/material.dart';

/// Every side menu's look (the user's, the driver's and the admin's), taken
/// from the reference menu: a charcoal panel in either theme, grey outline
/// icons beside white labels, thin dividers, and a lime button at the foot.
abstract final class SideMenuStyle {
  static const background = Color(0xFF242424);
  static const divider = Color(0xFF555555);
  static const icon = Color(0xFF9498A4);
  static const text = Colors.white;
  static const muted = Color(0xFFB8B7B2);
  static const star = Color(0xFFF09E3B);
  static const button = Color(0xFFCBF052);
  static const onButton = Color(0xFF111111);

  /// A row the admin menu has open.
  static const selected = Color(0xFF333333);

  /// Share of the screen the panel takes, at most [maxWidth].
  static const widthFraction = 0.8;
  static const maxWidth = 360.0;

  static double widthFor(double screen) => (screen * widthFraction).clamp(0, maxWidth).toDouble();
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
  Widget build(BuildContext context) => Material(
    color: selected ? SideMenuStyle.selected : Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(19, 8, 16, 8),
        child: Row(
          children: [
            Icon(icon, size: 24, color: color ?? SideMenuStyle.icon),
            const SizedBox(width: 13),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, height: 1.2, color: color ?? SideMenuStyle.text),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    ),
  );
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
  Widget build(BuildContext context) => InkWell(
    key: const ValueKey('menu-profile'),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 16, 18),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: const Color(0xFF3A3A3A),
            backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
            child: avatarUrl == null
                ? const Icon(Icons.sentiment_satisfied_alt, size: 28, color: SideMenuStyle.icon)
                : null,
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
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: SideMenuStyle.text),
                ),
                if (subtitle != null) ...[const SizedBox(height: 4), subtitle!],
              ],
            ),
          ),
          if (onTap != null) const Icon(Icons.chevron_right, color: SideMenuStyle.text),
        ],
      ),
    ),
  );
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
      Text(rating.toStringAsFixed(1), style: const TextStyle(fontSize: 14, color: SideMenuStyle.muted)),
    ],
  );
}

/// A side menu's frame: the header, a divider, the rows, a divider, then
/// the lime button and whatever goes under it, on the charcoal panel.
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
    const line = Divider(height: 1, thickness: 1, color: SideMenuStyle.divider);
    return Material(
      color: SideMenuStyle.background,
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
          link('TikTok', const Icon(Icons.tiktok, size: 28, color: SideMenuStyle.text)),
          // The plain "f", as the reference draws it (Material's is in a disc).
          link(
            'Facebook',
            const SizedBox.square(
              dimension: 28,
              child: Center(
                child: Text(
                  'f',
                  style: TextStyle(fontSize: 32, height: 1, fontWeight: FontWeight.w900, color: SideMenuStyle.text),
                ),
              ),
            ),
          ),
          link('Instagram', const CustomPaint(size: Size.square(25), painter: _InstagramGlyph(SideMenuStyle.text))),
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
