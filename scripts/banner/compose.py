# 🐱 Compose the README banner: night background, stars, steam, the Blender-rendered
# 🐱 mochi frames and the title, then encode docs/media/banner.gif with ffmpeg.
#
# 🐱 Usage: python3 scripts/banner/compose.py FRAMES_DIR OUT.gif [--work DIR]
# 🐱 Needs Pillow + numpy, SF Pro (Display/Text) in /Library/Fonts and ffmpeg.

import argparse
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from timing import FPS, LOOP, heat, smooth  # noqa: E402

W, H = 1280, 560

TITLE = "OMOCHI AI"
PILL = "Free, open-source macOS app"
SUB_LIGHT = "All your AI agents in one place — "
SUB_BOLD = "linked into one team"

FONT_DISPLAY_BOLD = "/Library/Fonts/SF-Pro-Display-Bold.otf"
FONT_TEXT = "/Library/Fonts/SF-Pro-Text-Regular.otf"
FONT_TEXT_BOLD = "/Library/Fonts/SF-Pro-Text-Semibold.otf"
FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"

LEFT = 88
# 🐱 lift the rendered mochi in the frame (same as a vertical lens shift on the camera)
MOCHI_DY = -55


# 🐱 ---------- static layers ----------
def background():
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    img = np.empty((H, W, 3), np.float32)
    img[:] = (5, 5, 7)
    # 🐱 faint haze behind the title, and a cooler one behind the mochi
    g1 = np.exp(-(((xx - 330) / 430) ** 2 + ((yy - 285) / 220) ** 2))
    g2 = np.exp(-(((xx - 950) / 330) ** 2 + ((yy - 300) / 260) ** 2))
    img += g1[..., None] * np.array([7, 7, 8], np.float32)
    img += g2[..., None] * np.array([4, 4, 6], np.float32)

    # 🐱 stars: mostly single faint pixels, a few soft brighter ones
    rng = np.random.default_rng(11)
    n = 240
    sx = rng.integers(0, W, n)
    sy = rng.integers(0, H, n)
    b = (rng.uniform(0.0, 1.0, n) ** 3.2) * 150 + 14
    stars = Image.new("L", (W, H), 0)
    px = stars.load()
    for x, y, v in zip(sx, sy, b):
        px[int(x), int(y)] = int(min(255, v))
    soft = stars.filter(ImageFilter.GaussianBlur(0.9))
    s = np.asarray(stars, np.float32) * 0.75 + np.asarray(soft, np.float32) * 1.6
    img += s[..., None] * np.array([0.92, 0.94, 1.0], np.float32)
    return img


def periodic_noise(h, w, beta, seed):
    """🐱 1/f noise from an inverse FFT: it tiles seamlessly in both directions."""
    rng = np.random.default_rng(seed)
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    f = np.sqrt(fx ** 2 + fy ** 2)
    f[0, 0] = 1.0
    spec = (rng.normal(size=(h, w)) + 1j * rng.normal(size=(h, w))) / f ** beta
    spec[0, 0] = 0
    n = np.real(np.fft.ifft2(spec))
    return (n - n.mean()) / n.std()


def text_layer():
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # 🐱 pill
    mono = ImageFont.truetype(FONT_MONO, 15)
    try:
        mono.set_variation_by_axes([400])
    except Exception:
        pass
    track = 1.2
    pill_w = sum(mono.getlength(c) + track for c in PILL) - track + 34
    x0, y0, ph = LEFT, 175, 31
    d.rounded_rectangle((x0, y0, x0 + pill_w, y0 + ph), radius=ph // 2, fill=(13, 13, 16, 255), outline=(60, 60, 66, 255), width=1)
    x = x0 + 17
    for c in PILL:
        d.text((x, y0 + ph / 2), c, font=mono, fill=(196, 196, 202, 255), anchor="lm")
        x += mono.getlength(c) + track

    # 🐱 title: silver gradient with a soft glow
    title_font = ImageFont.truetype(FONT_DISPLAY_BOLD, 112)
    tracking = -2.5
    mask = Image.new("L", (W, H), 0)
    md = ImageDraw.Draw(mask)
    baseline = 326
    for i, c in enumerate(TITLE):
        # 🐱 prefix length keeps the font's kerning, tracking tightens it like the old banner
        x = LEFT - 4 + title_font.getlength(TITLE[:i]) + tracking * i
        md.text((x, baseline), c, font=title_font, fill=255, anchor="ls")
    bbox = mask.getbbox()
    top, bot = bbox[1], bbox[3]
    yy = np.arange(H, dtype=np.float32)[:, None]
    t = np.clip((yy - top) / max(1, bot - top), 0, 1)
    c_top = np.array([246, 246, 248], np.float32)
    c_bot = np.array([146, 150, 164], np.float32)
    grad = c_top + (c_bot - c_top) * (t ** 1.1)[..., None]
    grad = np.broadcast_to(grad, (H, W, 3)).astype(np.uint8)
    glow = mask.filter(ImageFilter.GaussianBlur(22))
    glow_rgba = Image.new("RGBA", (W, H), (210, 212, 222, 0))
    glow_rgba.putalpha(glow.point(lambda v: int(v * 0.30)))
    layer.alpha_composite(glow_rgba)
    title_rgba = Image.fromarray(grad, "RGB").convert("RGBA")
    title_rgba.putalpha(mask)
    layer.alpha_composite(title_rgba)

    # 🐱 subtitle: what the app is for, in one line
    f_light = ImageFont.truetype(FONT_TEXT, 22)
    f_bold = ImageFont.truetype(FONT_TEXT_BOLD, 22)
    y = 382
    d = ImageDraw.Draw(layer)
    d.text((LEFT, y), SUB_LIGHT, font=f_light, fill=(160, 161, 170, 255), anchor="ls")
    x = LEFT + f_light.getlength(SUB_LIGHT)
    d.text((x, y), SUB_BOLD, font=f_bold, fill=(244, 244, 246, 255), anchor="ls")
    end = x + f_bold.getlength(SUB_BOLD)
    print(f"subtitle ends at x={end:.0f}")
    return layer


# 🐱 ---------- per-frame layers ----------
def mochi_extent(alpha):
    rows = np.where(alpha.max(axis=1) > 128)[0]
    cols = np.where(alpha.max(axis=0) > 128)[0]
    return rows[0], rows[-1], (cols[0] + cols[-1]) / 2, cols[-1] - cols[0]


class Steam:
    """🐱 steam puffs born on the top of the mochi while it is hot.

    Each puff rises, sways, spreads and fades; its age is taken modulo LOOP so the
    loop is seamless. A scrolling periodic noise breaks the puffs into wisps.
    """

    SH, SW = 384, 384

    def __init__(self, n=110, seed=21):
        rng = np.random.default_rng(seed)
        self.t0 = rng.uniform(0, LOOP, n)
        self.u = rng.uniform(-0.24, 0.24, n)
        self.v = rng.uniform(1.5, 2.6, n)
        self.life = rng.uniform(26, 42, n)
        self.sway = rng.uniform(4, 14, n)
        self.phase = rng.uniform(0, 2 * np.pi, n)
        self.r0 = rng.uniform(4, 8, n)
        self.grow = rng.uniform(0.35, 0.7, n)
        self.drift = rng.uniform(-0.25, 0.35, n)
        self.noise = periodic_noise(self.SH, self.SW, 1.8, 3)

    @staticmethod
    def strength(f):
        return smooth((heat(f) - 0.5) / 0.5)

    @staticmethod
    def linger(f):
        """🐱 steam thins out once the mochi starts to sag, and is gone before the next swell."""
        f = f % LOOP
        if f < 12:
            return 0.0
        return 1.0 - smooth((f - 50) / 12)

    def layer(self, f, extents):
        top_now = extents(f)[0]
        g = self.linger(f)
        if g <= 0.001:
            return None
        yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
        dens = np.zeros((H, W), np.float32)
        for i in range(len(self.t0)):
            age = (f - self.t0[i]) % LOOP
            if age > self.life[i]:
                continue
            born = int(round(f - age)) % LOOP
            k = self.strength(born)
            if k <= 0.01:
                continue
            top, _, cx, width = extents(born)
            life = self.life[i]
            x = cx + self.u[i] * width + self.sway[i] * np.sin(age * 0.16 + self.phase[i]) + self.drift[i] * age
            # 🐱 a swelling mochi pushes its steam up; a sagging one leaves it behind
            y = min(top, top_now) + 10 - self.v[i] * age
            r = self.r0[i] + self.grow[i] * age
            fade = smooth(age / 7) * (1 - smooth((age - 0.35 * life) / (0.65 * life)))
            w = 0.13 * k * fade * g
            if w <= 0.002:
                continue
            x0, x1 = int(max(0, x - 3 * r)), int(min(W, x + 3 * r))
            y0, y1 = int(max(0, y - 7 * r)), int(min(H, y + 7 * r))
            if x0 >= x1 or y0 >= y1:
                continue
            gx = (xx[y0:y1, x0:x1] - x) / r
            gy = (yy[y0:y1, x0:x1] - y) / (2.4 * r)
            dens[y0:y1, x0:x1] += w * np.exp(-(gx * gx + gy * gy))
        if dens.max() <= 0.001:
            return None
        shift = f * self.SH / LOOP
        ny = (yy * 0.4 + shift).astype(np.int32) % self.SH
        nx = (xx * 1.7).astype(np.int32) % self.SW
        tex = np.clip(self.noise[ny, nx] * 0.6 + 0.45, 0, 1) ** 2.0
        alpha = np.clip(dens * (0.08 + 1.7 * tex), 0, 0.36)
        # 🐱 soften the stretched noise so the wisps have no stair steps
        a8 = Image.fromarray((alpha * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(1.8))
        out = Image.new("RGBA", (W, H), (244, 245, 248, 0))
        out.putalpha(a8)
        return out


def warm_haze(f, cx, bottom, width):
    h = heat(f)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    g = np.exp(-(((xx - cx) / (width * 0.46)) ** 2 + ((yy - bottom + 4) / 26) ** 2))
    a = np.clip(g * (0.03 + 0.15 * h), 0, 1)
    out = np.zeros((H, W, 4), np.float32)
    out[..., :3] = (255, 128, 52)
    out[..., 3] = a * 255
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("out")
    ap.add_argument("--work", default=None)
    ap.add_argument("--only", type=int, default=None, help="compose a single frame to PNG (preview)")
    args = ap.parse_args()

    work = args.work or tempfile.mkdtemp(prefix="banner_")
    os.makedirs(work, exist_ok=True)
    bg = Image.fromarray(np.clip(background(), 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    text = text_layer()
    steam = Steam()

    def load(f):
        raw = Image.open(os.path.join(args.frames, f"mochi_{f:04d}.png")).convert("RGBA")
        mochi = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        mochi.paste(raw, (0, MOCHI_DY))
        return mochi

    # 🐱 top / bottom / centre / width of the mochi in every frame (steam is born where the top was)
    ext = {}
    for f in range(LOOP):
        p = os.path.join(args.frames, f"mochi_{f:04d}.png")
        if os.path.exists(p):
            ext[f] = mochi_extent(np.asarray(load(f))[..., 3])

    frames = [args.only] if args.only is not None else range(LOOP)
    for f in frames:
        mochi = load(f)
        top, bottom, cx, width = ext[f]
        frame = bg.copy()
        frame.alpha_composite(warm_haze(f, cx, bottom, width))
        s = steam.layer(f, lambda b: ext.get(b, ext[f]))
        if s is not None:
            frame.alpha_composite(s)
        frame.alpha_composite(mochi)
        frame.alpha_composite(text)
        path = os.path.join(work, f"comp_{f:04d}.png")
        frame.convert("RGB").save(path)
        if args.only is not None:
            frame.convert("RGB").save(args.out)
            return

    vf = (
        "split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];"
        "[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle"
    )
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-framerate", str(FPS), "-i", os.path.join(work, "comp_%04d.png"),
         "-vf", vf, "-loop", "0", args.out],
        check=True,
    )
    print("wrote", args.out, os.path.getsize(args.out) // 1024, "KB")


if __name__ == "__main__":
    main()
