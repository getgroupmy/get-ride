#!/usr/bin/env python3
"""The light and dark app icons, from assets/branding/icon.png (the GET.ride
wordmark on a transparent background). Run after `dart run
flutter_launcher_icons`, which makes the Android, web, macOS and Windows
icons; this adds what it can't:

  * iOS: one 1024 icon in three appearances (iOS 18+ picks by the home
    screen's mode): white behind the wordmark, black in dark mode, and a
    grey wordmark on black for tinted icons. Older iOS shows the white one.
  * Android: the adaptive icon's background turns black in dark mode
    (res/values-night/colors.xml).
  * Web: "G." in blue as the favicon, favicon.png on white and
    favicon-dark.png on black, which index.html picks by the browser's
    colour scheme.

    python3 scripts/app_icons.py
"""
import json
import os

from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "assets/branding/icon.png")
IOS = os.path.join(ROOT, "ios/Runner/Assets.xcassets/AppIcon.appiconset")
WHITE, BLACK = (255, 255, 255, 255), (0, 0, 0, 255)


def on(bg, logo, size, frac=None):
    canvas = Image.new("RGBA", (size, size), bg)
    if frac is None:  # as drawn: the wordmark keeps its place on the square
        canvas.alpha_composite(logo.resize((size, size), Image.LANCZOS))
        return canvas
    mark = logo.crop(logo.getbbox())
    w = int(size * frac)
    h = round(mark.height * w / mark.width)
    canvas.alpha_composite(mark.resize((w, h), Image.LANCZOS), ((size - w) // 2, (size - h) // 2))
    return canvas


def g_dot(logo):
    """ "G." for small sizes: the wordmark's own G and full stop, side by side
    on the same baseline, with the gap the wordmark leaves before its stop."""
    a = logo.split()[3]
    top, bottom = 400, 556
    g = logo.crop((75, top, 210, bottom))
    dot = logo.crop((490, top, 521, bottom))
    gap = 14
    out = Image.new("RGBA", (g.width + gap + dot.width, bottom - top), (0, 0, 0, 0))
    out.alpha_composite(g, (0, 0))
    out.alpha_composite(dot, (g.width + gap, 0))
    return out


def grey(logo):
    """The wordmark in light grey, keeping its shape: what iOS tints."""
    alpha = logo.split()[3]
    out = Image.new("RGBA", logo.size, (235, 235, 235, 0))
    out.putalpha(alpha)
    return out


def main():
    logo = Image.open(SRC).convert("RGBA")

    # iOS: a single-size icon set, light / dark / tinted.
    for name in os.listdir(IOS):
        if name.endswith(".png"):
            os.remove(os.path.join(IOS, name))
    icons = {
        "Icon-App-1024x1024@1x.png": on(WHITE, logo, 1024),
        "Icon-App-Dark-1024x1024@1x.png": on(BLACK, logo, 1024),
        "Icon-App-Tinted-1024x1024@1x.png": on(BLACK, grey(logo), 1024),
    }
    for name, image in icons.items():
        image.convert("RGB").save(os.path.join(IOS, name))  # App Store icons carry no alpha
    entry = {"idiom": "universal", "platform": "ios", "size": "1024x1024"}
    contents = {
        "images": [
            {**entry, "filename": "Icon-App-1024x1024@1x.png"},
            {**entry, "filename": "Icon-App-Dark-1024x1024@1x.png",
             "appearances": [{"appearance": "luminosity", "value": "dark"}]},
            {**entry, "filename": "Icon-App-Tinted-1024x1024@1x.png",
             "appearances": [{"appearance": "luminosity", "value": "tinted"}]},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(IOS, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")

    # Android: black behind the adaptive icon in dark mode.
    night = os.path.join(ROOT, "android/app/src/main/res/values-night/colors.xml")
    with open(night, "w") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
                '    <color name="ic_launcher_background">#000000</color>\n</resources>\n')

    # Web: "G." in blue as the tab icon, for each colour scheme.
    mark = g_dot(logo)
    on(WHITE, mark, 64, 0.78).convert("RGB").save(os.path.join(ROOT, "web/favicon.png"))
    on(BLACK, mark, 64, 0.78).convert("RGB").save(os.path.join(ROOT, "web/favicon-dark.png"))


if __name__ == "__main__":
    main()
