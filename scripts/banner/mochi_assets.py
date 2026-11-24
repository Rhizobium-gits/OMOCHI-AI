# 🐱 Blender renders for the app (not the README): the app icon and the realistic avatar's sprites.
#
# 🐱 Usage (Blender 4.x, headless):
# 🐱   /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
# 🐱     -P scripts/banner/mochi_assets.py -- OUT_DIR [--only icon|sprites] [--samples 128]
# 🐱 Writes OUT_DIR/icon_raw.png (1024x1024) and OUT_DIR/level_<name>.png (640x512), all RGBA on transparent.
# 🐱 Then: python3 scripts/banner/sprites.py OUT_DIR   (icon -> Resources/AppIcon.png, sprites -> Resources/mochi/)

import math
import os
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT_DIR = argv[0] if argv else "/tmp/mochi-assets"
ONLY = None
SAMPLES = 128
i = 1
while i < len(argv):
    if argv[i] == "--only":
        ONLY = argv[i + 1]
        i += 2
    elif argv[i] == "--samples":
        SAMPLES = int(argv[i + 1])
        i += 2
    else:
        i += 1

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mochi_model  # noqa: E402

# 🐱 the avatar's shapes, matching the pixel mochi's puff levels (MochiSprite.widths):
# 🐱 name -> (puff shape key, sideways scale, height scale)
LEVELS = {
    "flat": (0.0, 1.12, 0.66),   # 🐱 puff -1: deflated, spread out sideways
    "rest": (0.0, 1.0, 1.0),     # 🐱 puff 0
    "puff1": (0.35, 1.0, 1.0),
    "puff2": (0.7, 1.0, 1.0),    # 🐱 completed
    "puff3": (1.0, 1.0, 1.0),
}

scene = mochi_model.reset_scene()
mochi, kp, rough_val = mochi_model.build_mochi()
warm = mochi_model.add_lights(scene)
mochi_model.set_world(scene)

cam_d = bpy.data.cameras.new("Cam")
cam = bpy.data.objects.new("Cam", cam_d)
scene.collection.objects.link(cam)
scene.camera = cam


def look(elev_deg, dist, target_z):
    e = math.radians(elev_deg)
    cam.location = (0, -dist * math.cos(e), dist * math.sin(e) + target_z)
    cam.rotation_euler = (Vector((0, 0, target_z)) - cam.location).to_track_quat("-Z", "Y").to_euler()


def render(path):
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


if ONLY in (None, "icon"):
    # 🐱 icon: the banner's mochi, a little puffed, warmed from below, seen from slightly above
    mochi_model.render_settings(scene, 1024, 1024, 100, SAMPLES, "")
    cam_d.type = "PERSP"
    cam_d.lens = 85
    cam_d.sensor_width = 36
    look(24, 7.4, 0.30)
    kp.value = 0.5
    rough_val.outputs[0].default_value = 0.42 - 0.16 * 0.5
    mochi.scale = (1, 1, 1)
    mochi.rotation_euler = (0, 0, math.radians(-18))
    warm.data.energy = 260
    render(os.path.join(OUT_DIR, "icon_raw.png"))

if ONLY in (None, "sprites"):
    # 🐱 sprites: straight-on orthographic view so every level shares one scale and one floor
    mochi_model.render_settings(scene, 640, 512, 100, SAMPLES, "")
    cam_d.type = "ORTHO"
    cam_d.ortho_scale = 3.2
    look(12, 20.0, 0.35)
    warm.data.energy = 0
    # 🐱 turn the crust's bulge to the back so the puffed top rises behind the face
    mochi.rotation_euler = (0, 0, math.radians(127))
    for name, (p, sxy, sz) in LEVELS.items():
        kp.value = p
        rough_val.outputs[0].default_value = 0.42 - 0.16 * p
        mochi.scale = (sxy, sxy, sz)
        render(os.path.join(OUT_DIR, f"level_{name}.png"))
