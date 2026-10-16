"""App icon + Play feature graphic, from fonts only (no image assets).

Run from darb/:  python3 store/make-art.py
Writes the iOS AppIcon set, the Android mipmaps (legacy + adaptive foreground) and store/out/*.png.
Font: Tajawal (SIL OFL, Google Fonts), expected in ~/.local/share/fonts.
"""
import json
import os
from PIL import Image, ImageDraw, ImageFont

TEAL, WHITE = (15, 118, 110), (255, 255, 255)  # the app's seed colour (lib/main.dart)
FONT = os.path.expanduser("~/.local/share/fonts/Tajawal-ExtraBold.ttf")
FONT_R = os.path.expanduser("~/.local/share/fonts/Tajawal-Medium.ttf")
# The sign-in screen's mark: Icons.route_rounded (Material Icons, Apache 2.0), from the Flutter SDK.
ICONS = os.path.expanduser("~/FlutterSDK/flutter-3.35.7/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf")
ROUTE = chr(0xF0377)


def word(size, fit, bg=TEAL, alpha=False, text="درب", font=FONT):
    """`text` centred, its ink box at most `fit` of the canvas in both directions."""
    im = Image.new("RGBA" if alpha else "RGB", (size, size), (0, 0, 0, 0) if alpha else bg)
    d = ImageDraw.Draw(im)
    kw = {"direction": "rtl", "language": "ar"} if font == FONT else {}
    l, t, r, b = d.textbbox((0, 0), text, font=ImageFont.truetype(font, 100), **kw)
    f = ImageFont.truetype(font, int(100 * size * fit / max(r - l, b - t)))
    l, t, r, b = d.textbbox((0, 0), text, font=f, **kw)
    d.text(((size - (r - l)) / 2 - l, (size - (b - t)) / 2 - t), text, font=f, fill=WHITE, **kw)
    return im


def main():
    os.makedirs("store/out", exist_ok=True)
    icon = word(1024, 0.6, text=ROUTE, font=ICONS)  # iOS: square, no alpha; the system rounds the corners
    icon.save("store/out/icon-1024.png")
    icon.resize((512, 512), Image.LANCZOS).save("store/out/play-icon-512.png")

    ios = "app/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for i in json.load(open(f"{ios}/Contents.json"))["images"]:
        px = round(float(i["size"].split("x")[0]) * int(i["scale"][0]))
        icon.resize((px, px), Image.LANCZOS).save(f"{ios}/{i['filename']}")

    res = "app/android/app/src/main/res"
    fg = word(432, 0.45, alpha=True, text=ROUTE, font=ICONS)  # adaptive: 108 dp, text inside the 66 dp safe zone
    for name, dp in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}.items():
        icon.resize((round(48 * dp),) * 2, Image.LANCZOS).save(f"{res}/mipmap-{name}/ic_launcher.png")
        fg.resize((round(108 * dp),) * 2, Image.LANCZOS).save(f"{res}/mipmap-{name}/ic_launcher_foreground.png")

    for lang, tag in {"ar": "درب: مذاكرة يومية ذكية", "en": "Darb: smart daily practice"}.items():
        g = Image.new("RGB", (1024, 500), TEAL)  # Play: 24-bit, no alpha
        g.paste(word(180, 0.8, text=ROUTE, font=ICONS), (422, 20))
        g.paste(word(160, 0.8), (432, 190))
        d = ImageDraw.Draw(g)
        f = ImageFont.truetype(FONT_R, 54)
        kw = {"direction": "rtl", "language": "ar"} if lang == "ar" else {}
        l, t, r, b = d.textbbox((0, 0), tag, font=f, **kw)
        d.text(((1024 - (r - l)) / 2 - l, 390 - t), tag, font=f, fill=WHITE, **kw)
        g.save(f"store/out/feature-{lang}.png")


if __name__ == "__main__":
    main()
