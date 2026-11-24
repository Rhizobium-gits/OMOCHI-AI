# 🐱 Blender scene for the README banner: a realistic round mochi (marumochi)
# 🐱 that puffs up as it warms and deflates again, in a seamless loop.
#
# 🐱 Usage (Blender 4.x, headless):
# 🐱   /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
# 🐱     -P scripts/banner/mochi_scene.py -- OUT_DIR [--frames 0-79] [--samples 80] [--scale 100]
# 🐱 Writes OUT_DIR/mochi_0000.png ... (RGBA, transparent background, 1280x560 at --scale 100).
# 🐱 About 15-20 s a frame on an M3 (Metal). Rendering one frame per Blender process and
# 🐱 retrying any missing frame is the most robust (Blender occasionally aborts on exit).
# 🐱 Then run scripts/banner/compose.py to add the background, stars, steam and text.

import math
import os
import sys

import bpy
from mathutils import Vector

# 🐱 ---------- arguments ----------
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT_DIR = argv[0] if argv else "/tmp/mochi"
FRAMES = (0, 79)
SAMPLES = 80
SCALE = 100
i = 1
while i < len(argv):
    if argv[i] == "--frames":
        a, b = argv[i + 1].split("-")
        FRAMES = (int(a), int(b))
        i += 2
    elif argv[i] == "--samples":
        SAMPLES = int(argv[i + 1])
        i += 2
    elif argv[i] == "--scale":
        SCALE = int(argv[i + 1])
        i += 2
    else:
        i += 1

# 🐱 timing curves are shared with compose.py (steam, warm haze); the mochi itself with mochi_assets.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from timing import FPS, LOOP, heat, jiggle, puff  # noqa: E402
import mochi_model  # noqa: E402

scene = mochi_model.reset_scene()
scene.frame_start, scene.frame_end = FRAMES
scene.render.fps = FPS

mochi, kp, rough_val = mochi_model.build_mochi()
mesh = mochi.data
mat = mesh.materials[0]
warm = mochi_model.add_lights(scene)
mochi_model.set_world(scene)

# 🐱 ---------- camera ----------
cam_d = bpy.data.cameras.new("Cam")
cam_d.lens = 85
cam_d.sensor_width = 36
cam = bpy.data.objects.new("Cam", cam_d)
scene.collection.objects.link(cam)
scene.camera = cam
elev = math.radians(17)
dist = 16.0
cam.location = (0, -dist * math.cos(elev), dist * math.sin(elev) + 0.62)
cam.rotation_euler = (Vector((0, 0, 0.62)) - cam.location).to_track_quat("-Z", "Y").to_euler()
# 🐱 put the mochi in the right half of a 1280x560 frame
cam_d.shift_x = -0.24
cam_d.shift_y = 0.0

# 🐱 ---------- per-frame animation ----------
for f in range(FRAMES[0], FRAMES[1] + 1):
    p = puff(f)
    j = jiggle(f)
    h = heat(f)
    ph = 2 * math.pi * (f % LOOP) / LOOP
    kp.value = p
    kp.keyframe_insert("value", frame=f)
    sx = 1 + j
    sz = 1 / (sx * sx)
    mochi.scale = (sx, sx, sz)
    mochi.location = (0, 0, 0.05 * math.sin(ph))
    mochi.rotation_euler = (math.radians(2.0 * math.sin(ph + 1.0)), math.radians(1.5 * math.sin(ph)), math.radians(-18 + 10 * math.sin(ph)))
    mochi.keyframe_insert("scale", frame=f)
    mochi.keyframe_insert("location", frame=f)
    mochi.keyframe_insert("rotation_euler", frame=f)
    warm.data.energy = 30 + 330 * h
    warm.data.keyframe_insert("energy", frame=f)
    rough_val.outputs[0].default_value = 0.42 - 0.16 * min(1.0, max(0.0, p))
    rough_val.outputs[0].keyframe_insert("default_value", frame=f)

for obj in (mochi, warm.data, mat.node_tree):
    ad = obj.animation_data if hasattr(obj, "animation_data") else None
    if ad and ad.action:
        for fc in ad.action.fcurves:
            for k in fc.keyframe_points:
                k.interpolation = "LINEAR"
if mesh.shape_keys.animation_data and mesh.shape_keys.animation_data.action:
    for fc in mesh.shape_keys.animation_data.action.fcurves:
        for k in fc.keyframe_points:
            k.interpolation = "LINEAR"

# 🐱 ---------- render settings ----------
mochi_model.render_settings(scene, 1280, 560, SCALE, SAMPLES, f"{OUT_DIR}/mochi_")

bpy.ops.render.render(animation=True)
