# 🐱 Turn the Blender renders from mochi_assets.py into the app's files:
# 🐱   icon_raw.png        -> Resources/AppIcon.png (1024, black, warm glow under the mochi)
# 🐱   level_<name>.png    -> Resources/mochi/mochi-<name>.png (the realistic avatar's sprites)
#
# 🐱 The sprites use the pixel mochi's canvas (MochiSprite: 15 x 12 cells, the body stands on the
# 🐱 bottom edge of row 10) at 32 px a cell, so the realistic and pixel styles share one layout.
#
# 🐱 Usage: python3 scripts/banner/sprites.py RENDER_DIR [--repo .]

import argparse
import os

import numpy as np
from PIL import Image

CELL = 32
COLS, ROWS = 15, 12
FLOOR_Y = 11 * CELL          # 🐱 bottom edge of row 10, from the top
CENTER_X = COLS * CELL / 2
REST_WIDTH = 13 * CELL       # 🐱 the resting mochi is as wide as the pixel one (13 cells)
LEVELS = ["flat", "rest", "puff1", "puff2", "puff3"]


def body_box(im):
    a = np.asarray(im)[..., 3]
    ys, xs = np.where(a > 128)
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1


def sprites(src, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    ims = {n: Image.open(os.path.join(src, f"level_{n}.png")).convert("RGBA") for n in LEVELS}
    x0, _, x1, _ = body_box(ims["rest"])
    k = REST_WIDTH / (x1 - x0)
    for n, im in ims.items():
        big = im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS)
        bx0, by0, bx1, by1 = body_box(big)
        canvas = Image.new("RGBA", (COLS * CELL, ROWS * CELL), (0, 0, 0, 0))
        dx = round(CENTER_X - (bx0 + bx1) / 2)
        dy = FLOOR_Y - by1
        canvas.alpha_composite(big, (dx, dy)) if dx >= 0 and dy >= 0 else canvas.paste(big, (dx, dy), big)
        path = os.path.join(out_dir, f"mochi-{n}.png")
        canvas.save(path, optimize=True)
        cb = body_box(canvas)
        print(f"{path}: body x {cb[0]}..{cb[2]} y {cb[1]}..{cb[3]} ({(cb[2] - cb[0]) / CELL:.1f} x {(cb[3] - cb[1]) / CELL:.1f} cells)")


def icon(src, out):
    raw = Image.open(os.path.join(src, "icon_raw.png")).convert("RGBA")
    S = raw.width
    x0, y0, x1, y1 = body_box(raw)
    cx, bottom = (x0 + x1) / 2, y1
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    bg = np.zeros((S, S, 3), np.float32)
    # 🐱 night black, a touch lighter in the middle
    bg += (np.exp(-(((xx - S / 2) / (S * 0.55)) ** 2 + ((yy - S * 0.45) / (S * 0.5)) ** 2)) * 14)[..., None]
    # 🐱 the warmth it sits over
    w = (x1 - x0)
    glow = np.exp(-(((xx - cx) / (w * 0.5)) ** 2 + ((yy - bottom + 6) / (S * 0.05)) ** 2))
    bg += glow[..., None] * np.array([120, 52, 18], np.float32) * 0.55
    base = Image.fromarray(np.clip(bg, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    base.alpha_composite(raw)
    base.convert("RGB").save(out, optimize=True)
    print(f"{out}: mochi {(x1 - x0) / S:.0%} of the width")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("renders")
    ap.add_argument("--repo", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    ap.add_argument("--only", choices=["icon", "sprites"])
    a = ap.parse_args()
    if a.only in (None, "sprites"):
        sprites(a.renders, os.path.join(a.repo, "Resources", "mochi"))
    if a.only in (None, "icon"):
        icon(a.renders, os.path.join(a.repo, "Resources", "AppIcon.png"))


if __name__ == "__main__":
    main()
