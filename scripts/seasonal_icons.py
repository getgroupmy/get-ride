#!/usr/bin/env python3
"""The other home-screen icons a phone can switch to (lib/src/core/app_icons.dart):
seasonal artwork around the GET.ride wordmark, the double-date sales and two
brand marks, each drawn for light and dark mode. The standard icon stays
scripts/app_icons.py's.

  * iOS: an AppIcon-<id> icon set per icon, light / dark / tinted, listed in
    the Runner target's ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
  * Android: an adaptive icon per icon, its artwork in drawable-nodpi and
    drawable-night-nodpi, with a light square for Android 7 (no adaptive
    icons, no dark mode); AndroidManifest.xml has an activity-alias each.
  * Flutter: small previews for Settings → App icon, light and dark.

    python3 scripts/seasonal_icons.py [--preview sheet.png]

Needs Pillow and the Roboto fonts Flutter ships (FLUTTER_ROOT, or flutter on
the PATH).
"""
import json
import math
import os
import random
import re
import shutil
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageOps

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BRANDING = os.path.join(ROOT, "assets/branding")
IOS = os.path.join(ROOT, "ios/Runner/Assets.xcassets")
RES = os.path.join(ROOT, "android/app/src/main/res")
PREVIEWS = os.path.join(ROOT, "assets/app_icons")
S = 1024
WHITE, GOLD = (255, 255, 255, 255), (245, 200, 80, 255)
NIGHT = (12, 12, 16)


def fonts():
    flutter = os.environ.get("FLUTTER_ROOT")
    if not flutter and shutil.which("flutter"):
        flutter = os.path.dirname(os.path.dirname(os.path.realpath(shutil.which("flutter"))))
    for root in (flutter, "/opt/flutter"):
        path = root and os.path.join(root, "bin/cache/artifacts/material_fonts")
        if path and os.path.exists(os.path.join(path, "Roboto-Black.ttf")):
            return path
    sys.exit("Roboto not found: set FLUTTER_ROOT")


FONTS = fonts()


def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def luminance(c):
    return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255


class Art:
    """One icon being drawn: light, or its dark-mode version, where the
    background sinks to near black in the same hue and dark ink turns light
    (the light background's own colour)."""

    def __init__(self, bg, dark, ink=WHITE):
        self.dark = dark
        self.light_bg = bg
        self.bg = tuple(round(c * 0.24 + n * 0.76) for c, n in zip(bg[:3], NIGHT)) + (255,) if dark else bg
        self.ink = ink if not dark or luminance(ink) > 0.5 else bg
        self.im = Image.new("RGBA", (S, S), self.bg)
        self.d = ImageDraw.Draw(self.im)


# The wordmark, from the standard icon.
_logo = Image.open(os.path.join(BRANDING, "icon.png")).convert("RGBA")
_word = _logo.split()[3].crop(_logo.split()[3].getbbox())


def mark(alpha, color, width):
    a = alpha.resize((width, round(alpha.height * width / alpha.width)), Image.LANCZOS)
    layer = Image.new("RGBA", a.size, color)
    layer.putalpha(a)
    return layer


def wordmark(art, width=760, y=470):
    m = mark(_word, art.ink, width)
    art.im.alpha_composite(m, ((S - m.width) // 2, y))


# Motifs.
def star(d, cx, cy, r, fill, points=5, inner=0.45, rot=-90):
    pts = []
    for i in range(points * 2):
        rr = r if i % 2 == 0 else r * inner
        a = math.radians(rot + i * 180 / points)
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    d.polygon(pts, fill=fill)


def sparkle(d, x, y, r, c):
    k = r * 0.25
    d.polygon([(x, y - r), (x + k, y - k), (x + r, y), (x + k, y + k), (x, y + r), (x - k, y + k), (x - r, y), (x - k, y - k)],
              fill=c)


def crescent(d, cx, cy, r, c, bg, off=0.38):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)
    d.ellipse([cx - r + r * off, cy - r * 1.1, cx + r + r * off, cy + r * 0.9], fill=bg)


def lantern(d, cx, cy, w, h, body, gold):
    d.rectangle([cx - w * .28, cy - h / 2 - 18, cx + w * .28, cy - h / 2 + 6], fill=gold)
    d.ellipse([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], fill=body)
    for k in (-.25, 0, .25):
        d.arc([cx - w / 2 + abs(k) * w * .9, cy - h / 2, cx + w / 2 - abs(k) * w * .9, cy + h / 2], 90,
              270 if k <= 0 else 90, fill=gold, width=5)
    d.rectangle([cx - w * .28, cy + h / 2 - 6, cx + w * .28, cy + h / 2 + 18], fill=gold)
    for k in (-14, 0, 14):
        d.line([(cx + k, cy + h / 2 + 18), (cx + k, cy + h / 2 + 90)], fill=gold, width=5)
    d.line([(cx, cy - h / 2 - 18), (cx, cy - h / 2 - 90)], fill=gold, width=5)


def blossom(d, x, y, petal, mid):
    for k in range(5):
        a = math.radians(k * 72 - 90)
        px, py = x + 34 * math.cos(a), y + 34 * math.sin(a)
        d.ellipse([px - 26, py - 26, px + 26, py + 26], fill=petal)
    d.ellipse([x - 14, y - 14, x + 14, y + 14], fill=mid)


def ketupat(d, cx, cy, r, c1, c2):
    d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], fill=c1)
    for i in range(1, 4):
        t = i / 4
        d.line([(cx - r + r * t, cy - r * t), (cx + r * t, cy + r - r * t)], fill=c2, width=10)
        d.line([(cx + r - r * t, cy - r * t), (cx - r * t, cy + r - r * t)], fill=c2, width=10)
    d.line([(cx, cy - r), (cx - 20, cy - r - 70)], fill=c1, width=8)
    d.line([(cx, cy - r), (cx + 20, cy - r - 70)], fill=c1, width=8)


def diya(d, cx, cy, s, lamp, flame, inner):
    d.chord([cx - s, cy - s * .55, cx + s, cy + s * .75], 0, 180, fill=lamp)
    d.polygon([(cx - s, cy + .1 * s), (cx - s * 1.25, cy - s * .15), (cx - s * .8, cy + .1 * s)], fill=lamp)
    d.ellipse([cx - s * .22, cy - s * 1.15, cx + s * .22, cy - s * .05], fill=flame)
    d.ellipse([cx - s * .1, cy - s * .75, cx + s * .1, cy - s * .2], fill=inner)


def snowflake(d, cx, cy, r, c, w=6):
    for k in range(6):
        a = math.radians(k * 60)
        d.line([(cx, cy), (cx + r * math.cos(a), cy + r * math.sin(a))], fill=c, width=w)
        bx, by = cx + r * .55 * math.cos(a), cy + r * .55 * math.sin(a)
        for s in (-1, 1):
            b = a + s * math.radians(40)
            d.line([(bx, by), (bx + r * .3 * math.cos(b), by + r * .3 * math.sin(b))], fill=c, width=w)


def burst(d, cx, cy, r, c, n=14):
    for k in range(n):
        a = math.radians(k * 360 / n)
        x, y = cx + r * math.cos(a), cy + r * math.sin(a)
        d.line([(cx + r * .3 * math.cos(a), cy + r * .3 * math.sin(a)), (x, y)], fill=c, width=7)
        d.ellipse([x - 7, y - 7, x + 7, y + 7], fill=c)


def pelita(d, cx, cy, s, body, flame):
    d.rounded_rectangle([cx - s * .35, cy - s * .2, cx + s * .35, cy + s * .5], radius=8, fill=body)
    d.rectangle([cx - s * .05, cy - s * .45, cx + s * .05, cy - s * .2], fill=body)
    d.ellipse([cx - s * .12, cy - s * .85, cx + s * .12, cy - s * .4], fill=flame)


def grain(d, x, y, s, c, rot=0):
    a = math.radians(rot - 90)
    tx, ty = x + math.cos(a) * s, y + math.sin(a) * s
    d.line([(x, y), (tx, ty)], fill=c, width=6)
    for i in range(1, 7):
        t = i / 7.5
        px, py = x + (tx - x) * t, y + (ty - y) * t
        for side in (-1, 1):
            b = a + side * math.radians(35)
            ex, ey = px + math.cos(b) * 22, py + math.sin(b) * 22
            d.ellipse([ex - 9, ey - 14, ex + 9, ey + 14], fill=c)


def motif_band(d, y, c1, c2):
    for i in range(0, S, 64):
        d.polygon([(i, y), (i + 32, y - 32), (i + 64, y), (i + 32, y + 32)], fill=c1)
        d.polygon([(i + 16, y), (i + 32, y - 16), (i + 48, y), (i + 32, y + 16)], fill=c2)


def feather(d, cx, cy, s, rot):
    a = math.radians(rot)
    ux, uy = math.cos(a), math.sin(a)
    d.line([(cx, cy), (cx + ux * s, cy + uy * s)], fill=(30, 110, 70, 255), width=6)
    ex, ey = cx + ux * s * .78, cy + uy * s * .78
    for rr, col in [(s * .26, (20, 140, 120, 255)), (s * .17, (40, 90, 200, 255)), (s * .09, (20, 30, 90, 255))]:
        d.ellipse([ex - rr, ey - rr * 1.25, ex + rr, ey + rr * 1.25], fill=col)


def mooncake(d, cx, cy, r):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(196, 132, 52, 255))
    d.ellipse([cx - r * .8, cy - r * .8, cx + r * .8, cy + r * .8], outline=(150, 92, 30, 255), width=6)
    for k in range(8):
        a = math.radians(k * 45)
        x, y = cx + r * .55 * math.cos(a), cy + r * .55 * math.sin(a)
        d.ellipse([x - 9, y - 9, x + 9, y + 9], fill=(150, 92, 30, 255))


def umbrella(d, cx, cy, s, c, rib):
    d.pieslice([cx - s, cy - s, cx + s, cy + s], 180, 360, fill=c)
    for k in (-1, 0, 1):
        d.arc([cx + k * s * .66 - s * .34, cy - s * .2, cx + k * s * .66 + s * .34, cy + s * .2], 180, 360, fill=rib, width=12)
    d.line([(cx, cy), (cx, cy + s * 1.1)], fill=rib, width=12)
    d.arc([cx, cy + s * .9, cx + s * .4, cy + s * 1.3], 0, 180, fill=rib, width=12)


# The icons. Each draws onto an Art (light or dark) and returns it.
def chinese_new_year(dark):
    a = Art((200, 16, 46, 255), dark, ink=(255, 214, 90, 255))
    for x, y, w, h in [(230, 260, 210, 190), (800, 230, 170, 150)]:
        lantern(a.d, x, y, w, h, (235, 45, 45, 255), (255, 200, 60, 255))
    for x, y in [(150, 820), (880, 860), (520, 860)]:
        blossom(a.d, x, y, (255, 182, 193, 255), (255, 200, 60, 255))
    wordmark(a)
    return a


def ramadan(dark):
    a = Art((22, 38, 84, 255), dark)
    crescent(a.d, 230, 240, 110, GOLD, a.bg)
    star(a.d, 330, 170, 30, GOLD)
    pelita(a.d, 790, 300, 150, (230, 170, 60, 255), (255, 230, 140, 255))
    for x in (120, 512, 900):
        star(a.d, x, 860, 14, (255, 230, 150, 255))
    wordmark(a)
    return a


def hari_raya(dark):
    a = Art((0, 104, 71, 255), dark)
    for x, y, r in [(230, 250, 120), (800, 230, 95)]:
        ketupat(a.d, x, y, r, (240, 200, 80, 255), a.bg)
    a.d.arc([700, 700, 960, 960], 40, 300, fill=(240, 200, 80, 255), width=24)
    wordmark(a)
    return a


def deepavali(dark):
    a = Art((88, 24, 120, 255), dark)
    for x, y, s in [(230, 300, 110), (800, 300, 90)]:
        diya(a.d, x, y, s, (240, 140, 40, 255), (255, 215, 80, 255), (255, 250, 220, 255))
    for k in range(16):
        t = math.radians(k * 22.5)
        x, y = 512 + 300 * math.cos(t), 840 + 120 * math.sin(t)
        a.d.ellipse([x - 12, y - 12, x + 12, y + 12], fill=(255, 200, 80, 255))
    wordmark(a)
    return a


def christmas(dark):
    a = Art((14, 60, 46, 255), dark)
    for x, y, r in [(200, 230, 90), (840, 260, 70), (160, 820, 60), (860, 840, 90), (520, 900, 40)]:
        snowflake(a.d, x, y, r, (255, 255, 255, 230))
    star(a.d, 512, 250, 95, (255, 205, 70, 255))
    wordmark(a)
    return a


def new_year(dark):
    a = Art((15, 18, 45, 255), dark)
    for x, y, r, c in [(230, 230, 120, (255, 90, 130, 255)), (790, 200, 100, GOLD), (520, 140, 70, (110, 220, 255, 255)),
                       (180, 880, 60, GOLD), (850, 860, 80, (255, 90, 130, 255))]:
        burst(a.d, x, y, r, c)
    wordmark(a)
    return a


def merdeka(dark):
    # Stripes and a crescent and star, in the flag's colours: not the flag.
    a = Art((1, 0, 102, 255), dark)
    red = (204, 0, 1, 255) if not dark else (150, 0, 10, 255)
    for i in range(7):
        y = 640 + i * 56
        a.d.rectangle([0, y, S, y + 28], fill=red)
        a.d.rectangle([0, y + 28, S, y + 56], fill=WHITE if not dark else (200, 200, 210, 255))
    a.d.ellipse([110, 120, 330, 340], fill=(255, 204, 0, 255))
    a.d.ellipse([160, 120, 360, 330], fill=a.bg)
    star(a.d, 380, 230, 80, (255, 204, 0, 255), points=14, inner=.5)
    wordmark(a, y=420)
    return a


def harvest(dark):
    a = Art((40, 90, 50, 255), dark)
    for x, rot in [(380, -25), (512, 0), (644, 25)]:
        grain(a.d, x, 360, 260, GOLD, rot)
    motif_band(a.d, 900, (230, 60, 40, 255), (20, 20, 20, 255))
    wordmark(a)
    return a


def thaipusam(dark):
    a = Art((250, 200, 60, 255), dark, ink=(120, 30, 20, 255))
    for rot in range(-150, -20, 26):
        feather(a.d, 512, 380, 300, rot)
    a.d.rectangle([0, 360, S, 380], fill=a.bg)
    wordmark(a)
    return a


def mid_autumn(dark):
    a = Art((24, 30, 72, 255), dark)
    a.d.ellipse([620, 90, 900, 370], fill=(255, 226, 140, 255))
    lantern(a.d, 220, 250, 170, 150, (230, 60, 60, 255), GOLD)
    for x in (330, 700):
        mooncake(a.d, x, 860, 70)
    wordmark(a)
    return a


def monsoon(dark):
    a = Art((90, 120, 150, 255), dark)
    umbrella(a.d, 512, 270, 170, (255, 200, 60, 255), (30, 40, 70, 255) if not dark else (200, 210, 230, 255))
    rnd = random.Random(7)
    for _ in range(40):
        x = rnd.randrange(40, S - 40)
        y = rnd.choice([rnd.randrange(60, 440), rnd.randrange(700, 980)])
        a.d.line([(x, y), (x - 12, y + 40)], fill=(200, 230, 255, 255), width=5)
    wordmark(a)
    return a


def payday(dark):
    a = Art((14, 120, 80, 255), dark)
    rm = font("Roboto-Bold.ttf", 40)
    for x, y, rot in [(300, 230, -12), (520, 210, 6), (740, 240, 14)]:
        note = Image.new("RGBA", (300, 150), (0, 0, 0, 0))
        nd = ImageDraw.Draw(note)
        nd.rounded_rectangle([0, 0, 299, 149], radius=16, fill=(120, 200, 140, 255), outline=WHITE, width=6)
        nd.ellipse([110, 35, 190, 115], outline=WHITE, width=6)
        nd.text((128, 42), "RM", fill=WHITE, font=rm)
        note = note.rotate(rot, expand=True, resample=Image.BICUBIC)
        a.im.alpha_composite(note, (int(x - note.width / 2), int(y - note.height / 2)))
    for x in (200, 400, 620, 830):
        a.d.ellipse([x - 48, 850, x + 48, 946], fill=GOLD)
        a.d.ellipse([x - 30, 868, x + 30, 928], outline=(200, 150, 40, 255), width=6)
    wordmark(a)
    return a


SALE_COLOURS = {9: (200, 40, 40), 10: (120, 40, 120), 11: (255, 90, 20), 12: (200, 20, 40)}


def sale(n):
    def draw(dark):
        a = Art(SALE_COLOURS[n] + (255,), dark)
        label = f"{n}.{n}"
        f = font("Roboto-Black.ttf", 230 if n < 10 else 190)
        w = a.d.textlength(label, font=f)
        a.d.text(((S - w) / 2, 90), label, fill=WHITE, font=f)
        for x, y, r in [(120, 140, 40), (900, 120, 34), (110, 880, 34), (910, 900, 44), (512, 900, 26)]:
            sparkle(a.d, x, y, r, (255, 240, 170, 255))
        wordmark(a, width=640, y=560)
        return a
    return draw


def brand(source, width):
    """G. or GET. in the wordmark's blue, centred: white behind it, black
    in dark mode."""
    alpha = Image.open(os.path.join(BRANDING, source)).convert("RGBA").split()[3]
    alpha = alpha.crop(alpha.getbbox())

    def draw(dark):
        a = Art(WHITE, dark, ink=(0, 173, 239, 255))
        a.bg = (0, 0, 0, 255) if dark else WHITE
        a.im = Image.new("RGBA", (S, S), a.bg)
        m = mark(alpha, (0, 173, 239, 255), width)
        a.im.alpha_composite(m, ((S - m.width) // 2, (S - m.height) // 2))
        return a
    return draw


# id → artwork. The ids are the ones in lib/src/core/app_icons.dart.
ICONS = {
    "chinese_new_year": chinese_new_year,
    "ramadan": ramadan,
    "hari_raya": hari_raya,
    "deepavali": deepavali,
    "christmas": christmas,
    "new_year": new_year,
    "merdeka": merdeka,
    "harvest": harvest,
    "thaipusam": thaipusam,
    "mid_autumn": mid_autumn,
    "monsoon": monsoon,
    "payday": payday,
    "sale_9_9": sale(9),
    "sale_10_10": sale(10),
    "sale_11_11": sale(11),
    "sale_12_12": sale(12),
    "g_dot": brand("icon_g.png", 560),
    "get_dot": brand("icon_get.png", 780),
}


def tinted(image):
    """What iOS tints: the dark icon in grey, its marks bright on black (how
    far each pixel is from the background)."""
    rgb = image.convert("RGB")
    away = ImageChops.difference(rgb, Image.new("RGB", rgb.size, rgb.getpixel((2, 2))))
    grey = ImageOps.autocontrast(ImageOps.grayscale(away), cutoff=1)
    return Image.merge("RGB", (grey, grey, grey))


def flat(image, colors=256):
    """Flat artwork as a palette PNG: a fraction of the size, same look."""
    return image.convert("RGB").quantize(colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)


def write_ios(key, light, dark):
    folder = os.path.join(IOS, f"AppIcon-{key}.appiconset")
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    names = {"": light, "-Dark": dark, "-Tinted": tinted(dark)}
    for suffix, image in names.items():
        flat(image).save(os.path.join(folder, f"Icon{suffix}-1024.png"), optimize=True)
    entry = {"idiom": "universal", "platform": "ios", "size": "1024x1024"}
    contents = {
        "images": [
            {**entry, "filename": "Icon-1024.png"},
            {**entry, "filename": "Icon-Dark-1024.png", "appearances": [{"appearance": "luminosity", "value": "dark"}]},
            {**entry, "filename": "Icon-Tinted-1024.png",
             "appearances": [{"appearance": "luminosity", "value": "tinted"}]},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")


def write_xcode(keys):
    """Lists the icon sets as the Runner target's alternate icons, which
    Xcode builds into the app and its Info.plist (CFBundleAlternateIcons)."""
    path = os.path.join(ROOT, "ios/Runner.xcodeproj/project.pbxproj")
    with open(path) as f:
        text = f.read()
    names = " ".join(f"AppIcon-{k}" for k in keys)
    text = re.sub(r"\n\t+ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = [^;]*;", "", text)
    text, n = re.subn(r"(\n(\t+)ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;)",
                      lambda m: f'{m.group(1)}\n{m.group(2)}ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "{names}";',
                      text)
    if n != 3:
        sys.exit(f"Expected the Runner target's three configurations, found {n}")
    with open(path, "w") as f:
        f.write(text)


def android_art(image):
    """The adaptive icon's 108dp layer at xxxhdpi: the artwork in the 72dp
    the launcher shows, its background colour in the margin it may crop."""
    canvas = Image.new("RGB", (432, 432), image.getpixel((2, 2))[:3])
    canvas.paste(image.convert("RGB").resize((288, 288), Image.LANCZOS), (72, 72))
    return canvas


def write_android(key, light, dark):
    name = f"ic_alt_{key}"
    for folder, image in (("drawable-nodpi", light), ("drawable-night-nodpi", dark)):
        os.makedirs(os.path.join(RES, folder), exist_ok=True)
        android_art(image).save(os.path.join(RES, folder, f"{name}.webp"), quality=90, method=6)
    os.makedirs(os.path.join(RES, "mipmap-anydpi-v26"), exist_ok=True)
    with open(os.path.join(RES, "mipmap-anydpi-v26", f"{name}.xml"), "w") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                f'    <background android:drawable="@drawable/{name}"/>\n'
                '    <foreground android:drawable="@android:color/transparent"/>\n'
                '</adaptive-icon>\n')
    # Android 7: no adaptive icons, so a rounded square, light only.
    legacy = light.convert("RGBA").resize((192, 192), Image.LANCZOS)
    mask = Image.new("L", (192, 192), 0)
    ImageDraw.Draw(mask).rounded_rectangle([8, 8, 183, 183], radius=36, fill=255)
    out = Image.new("RGBA", (192, 192), (0, 0, 0, 0))
    out.paste(legacy.resize((176, 176), Image.LANCZOS), (8, 8), mask.crop((8, 8, 184, 184)))
    out.save(os.path.join(RES, "mipmap-xxxhdpi", f"{name}.png"), optimize=True)


def write_preview(key, light, dark):
    os.makedirs(PREVIEWS, exist_ok=True)
    for suffix, image in (("", light), ("_dark", dark)):
        image.convert("RGB").resize((192, 192), Image.LANCZOS).save(
            os.path.join(PREVIEWS, f"{key}{suffix}.webp"), quality=88, method=6)


def sheet(images, path):
    """Every icon, light over dark over tinted, rounded like a home screen."""
    t, pad = 150, 24
    keys = list(images)
    cols = 10
    rows = math.ceil(len(keys) / cols)
    w = cols * (t + pad) + pad
    out = Image.new("RGB", (w, rows * (3 * (t + 8) + pad) + pad), (238, 240, 244))
    mask = Image.new("L", (t, t), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, t - 1, t - 1], radius=int(t * .225), fill=255)
    for i, key in enumerate(keys):
        x = pad + (i % cols) * (t + pad)
        y = pad + (i // cols) * (3 * (t + 8) + pad)
        for j, image in enumerate(images[key]):
            out.paste(image.convert("RGB").resize((t, t), Image.LANCZOS), (x, y + j * (t + 8)), mask)
    out.save(path)


def main():
    images = {}
    for key, draw in ICONS.items():
        light, dark = draw(False).im, draw(True).im
        write_ios(key, light, dark)
        write_android(key, light, dark)
        write_preview(key, light, dark)
        images[key] = (light, dark, tinted(dark))
    write_xcode(ICONS)
    # The standard icon's previews, from the icon set app_icons.py writes.
    std = os.path.join(IOS, "AppIcon.appiconset")
    write_preview("standard", Image.open(os.path.join(std, "Icon-App-1024x1024@1x.png")),
                  Image.open(os.path.join(std, "Icon-App-Dark-1024x1024@1x.png")))
    if "--preview" in sys.argv:
        sheet(images, sys.argv[sys.argv.index("--preview") + 1])


if __name__ == "__main__":
    main()
