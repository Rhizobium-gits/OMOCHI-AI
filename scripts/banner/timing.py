# 🐱 Shared timing for the banner loop, used by mochi_scene.py (Blender) and compose.py.
# 🐱 Every curve is periodic over LOOP frames so the GIF loops without a seam.

import math

LOOP = 80  # 🐱 frames per loop (20 fps -> 4 s)
FPS = 20


def smooth(u):
    u = max(0.0, min(1.0, u))
    return u * u * (3 - 2 * u)


def smoother(u):
    u = max(0.0, min(1.0, u))
    return u * u * u * (u * (u * 6 - 15) + 10)


def puff(f):
    """🐱 0 = resting marumochi, 1 = fully puffed."""
    f = f % LOOP
    if f < 6:
        return 0.0
    if f < 42:  # 🐱 slow swell while it warms
        u = (f - 6) / 36
        return smoother(u) * (1 + 0.04 * math.sin(math.pi * u))
    if f < 54:  # 🐱 taut at the top, a tiny tremble
        return 1.0 + 0.012 * math.sin(2 * math.pi * (f - 42) / 6)
    if f < 66:  # 🐱 the air escapes: a quicker sag
        return 1.0 - smooth((f - 54) / 12)
    return 0.0


def jiggle(f):
    """🐱 damped wobble after it flops back down (> 0 = wider and flatter)."""
    f = f % LOOP
    d = f - 64 if f >= 64 else f + (LOOP - 64)
    if d < 0:
        return 0.0
    return 0.075 * math.exp(-d / 5.0) * math.sin(2 * math.pi * d / 7.5)


def heat(f):
    """🐱 warm glow from below: rises first, fades before it deflates."""
    f = f % LOOP
    if f < 30:
        return 0.12 + 0.88 * smooth(f / 30)
    if f < 50:
        return 1.0
    if f < 72:
        return 1.0 - 0.88 * smooth((f - 50) / 22)
    return 0.12
