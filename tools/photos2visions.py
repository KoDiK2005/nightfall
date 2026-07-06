#!/usr/bin/env python3
"""Turn ordinary photos into NIGHTFALL hallucination "screamers".

Reads every image in  photos/  and writes a game-ready PNG into
assets/visions/  — the folder the engine flashes on screen when the
player's sanity (РАССУДОК) collapses.

By default each photo gets a horror grade: cropped to fill the screen,
crushed to a blood-red duotone with hard contrast, a heavy vignette and
film grain. Pass --raw to skip the grade and just convert the format.

Requires Pillow:  pip install Pillow
"""
import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageOps, ImageEnhance, ImageChops
except ImportError:
    sys.exit("Pillow не установлен. Поставь его:  pip install Pillow")

# must match SCREEN_W / SCREEN_H in src/main.c
SCREEN_W, SCREEN_H = 1024, 576
EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff"}

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "photos"
OUT_DIR = ROOT / "assets" / "visions"


def _lut(dark, light):
    """256-entry lerp from dark colour (shadows) to light colour (highlights)."""
    r = [round(dark[0] + (light[0] - dark[0]) * i / 255) for i in range(256)]
    g = [round(dark[1] + (light[1] - dark[1]) * i / 255) for i in range(256)]
    b = [round(dark[2] + (light[2] - dark[2]) * i / 255) for i in range(256)]
    return r, g, b


def horror_grade(img, intensity):
    """Blood-red, high-contrast, vignetted, grainy nightmare version."""
    w, h = img.size

    # luminance, stretched and crushed so faces jump out of the black
    lum = ImageOps.grayscale(img)
    lum = ImageOps.autocontrast(lum, cutoff=2)
    lum = ImageEnhance.Contrast(lum).enhance(1.0 + 0.6 * intensity)
    lum = ImageEnhance.Brightness(lum).enhance(1.0 - 0.20 * intensity)

    # map shadows -> near-black, highlights -> arterial red
    lr, lg, lb = _lut((6, 1, 1), (205, 34, 26))
    graded = Image.merge("RGB", (lum.point(lr), lum.point(lg), lum.point(lb)))
    # keep a little of the original so it doesn't read as a flat filter
    graded = Image.blend(img.convert("RGB"), graded, 0.55 + 0.45 * intensity)

    # vignette: radial gradient (0 centre -> 255 corners) darkens the edges
    grad = Image.radial_gradient("L").resize((w, h))
    strength = 0.85 * intensity
    mask = grad.point(lambda p: 255 - int(p * strength))
    graded = ImageChops.multiply(graded, Image.merge("RGB", (mask, mask, mask)))

    # film grain
    noise = Image.effect_noise((w, h), 26).convert("L")
    noise_rgb = Image.merge("RGB", (noise, noise, noise))
    graded = Image.blend(graded, ImageChops.overlay(graded, noise_rgb),
                         0.18 * intensity)
    return graded


def convert(path, raw, intensity):
    img = Image.open(path)
    img = ImageOps.exif_transpose(img)          # honour phone orientation

    if raw:
        # keep transparency (good for "faces out of the dark"); just fit + format
        img = img.convert("RGBA")
        img.thumbnail((SCREEN_W, SCREEN_H), Image.LANCZOS)
    else:
        img = img.convert("RGB")
        img = ImageOps.fit(img, (SCREEN_W, SCREEN_H), Image.LANCZOS)  # fill screen
        img = horror_grade(img, intensity)

    out = OUT_DIR / (path.stem + ".png")
    # PNG default is 8-bit, non-interlaced — exactly what the engine reads
    img.save(out, "PNG", optimize=True)
    return out


def main():
    ap = argparse.ArgumentParser(description="Photos -> NIGHTFALL screamers")
    ap.add_argument("--raw", action="store_true",
                    help="no horror grade, just convert format (keeps alpha)")
    ap.add_argument("--intensity", type=float, default=1.0,
                    help="horror effect strength 0..1 (default 1.0)")
    args = ap.parse_args()
    intensity = max(0.0, min(1.0, args.intensity))

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    photos = sorted(p for p in SRC_DIR.iterdir()
                    if p.is_file() and p.suffix.lower() in EXTS)
    if not photos:
        sys.exit(f"В {SRC_DIR} нет фото. Кинь туда картинки и запусти снова.")

    done = 0
    for p in photos:
        try:
            out = convert(p, args.raw, intensity)
            print(f"  {p.name}  ->  {out.relative_to(ROOT)}")
            done += 1
        except Exception as e:                  # noqa: BLE001 — report and continue
            print(f"  ! {p.name}: {e}", file=sys.stderr)

    print(f"\nГотово: {done}/{len(photos)} скримеров в {OUT_DIR.relative_to(ROOT)}")
    if done:
        print("Запусти игру (mingw32-make run) и теряй рассудок.")


if __name__ == "__main__":
    main()
