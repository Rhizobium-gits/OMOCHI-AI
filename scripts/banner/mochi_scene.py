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

# 🐱 timing curves are shared with compose.py (steam, warm haze)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from timing import FPS, LOOP, heat, jiggle, puff  # noqa: E402

# 🐱 ---------- scene reset ----------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.frame_start, scene.frame_end = FRAMES
scene.render.fps = FPS

# 🐱 ---------- mochi mesh ----------
bpy.ops.mesh.primitive_uv_sphere_add(segments=160, ring_count=80, radius=1.0)
mochi = bpy.context.active_object
mochi.name = "Mochi"
mesh = mochi.data
unit = [v.co.copy() for v in mesh.vertices]


def wobble_r(phi):
    # 🐱 hand-rounded mochi is never a perfect circle
    return 1 + 0.018 * math.sin(2 * phi + 0.6) + 0.012 * math.sin(3 * phi + 2.1) + 0.006 * math.sin(5 * phi + 0.3)


def shape(p, a, c_top, n_top, c_bot, n_bot, dome, bulge, sag):
    x, y, z = p
    z = max(-1.0, min(1.0, z))
    st = math.sqrt(max(0.0, 1 - z * z))
    phi = math.atan2(y, x)
    top = z >= 0
    n = n_top if top else n_bot
    r = a * wobble_r(phi) * (st ** n)
    zz = (c_top if top else -c_bot) * (abs(z) ** n)
    X, Y = r * math.cos(phi), r * math.sin(phi)
    rr = min(1.0, (r / a) ** 2)
    if top:
        # 🐱 domed top, an off-centre bulge where the crust gave way, and a soft sag at the rim
        zz += dome * (1 - rr)
        d2 = (X - 0.16) ** 2 + (Y + 0.12) ** 2
        zz += bulge * math.exp(-d2 / 0.9) * (abs(z) ** 0.35)
        zz -= sag * rr * rr * abs(z)
    else:
        # 🐱 bottom is flat but slightly lifted at the centre (it rested on a board)
        zz += 0.025 * (1 - rr)
    return Vector((X, Y, zz))


REST = dict(a=1.0, c_top=0.36, n_top=0.70, c_bot=0.19, n_bot=0.42, dome=0.07, bulge=0.0, sag=0.02)
PUFF = dict(a=1.09, c_top=0.78, n_top=0.84, c_bot=0.24, n_bot=0.50, dome=0.04, bulge=0.22, sag=0.0)

for v, p in zip(mesh.vertices, unit):
    v.co = shape(p, **REST)

mochi.shape_key_add(name="Basis")
kp = mochi.shape_key_add(name="Puff")
for i, p in enumerate(unit):
    kp.data[i].co = shape(p, **PUFF)

bpy.ops.object.shade_smooth()
sub = mochi.modifiers.new("Subsurf", "SUBSURF")
sub.levels = 1
sub.render_levels = 2

# 🐱 ---------- mochi material ----------
mat = bpy.data.materials.new("Mochi")
mat.use_nodes = True
nt = mat.node_tree
nodes, links = nt.nodes, nt.links
nodes.clear()
out = nodes.new("ShaderNodeOutputMaterial")
bsdf = nodes.new("ShaderNodeBsdfPrincipled")
links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
bsdf.subsurface_method = "RANDOM_WALK"
bsdf.inputs["Subsurface Weight"].default_value = 1.0
bsdf.inputs["Subsurface Radius"].default_value = (0.9, 0.75, 0.55)
bsdf.inputs["Subsurface Scale"].default_value = 0.35
bsdf.inputs["Specular IOR Level"].default_value = 0.45
bsdf.inputs["Sheen Weight"].default_value = 0.35
bsdf.inputs["Sheen Roughness"].default_value = 0.6
bsdf.inputs["Sheen Tint"].default_value = (1, 1, 1, 1)

texco = nodes.new("ShaderNodeTexCoord")

# 🐱 colour: off-white rice with faint uneven patches
n_col = nodes.new("ShaderNodeTexNoise")
n_col.inputs["Scale"].default_value = 2.2
n_col.inputs["Detail"].default_value = 4
links.new(texco.outputs["Object"], n_col.inputs["Vector"])
ramp = nodes.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].position = 0.35
ramp.color_ramp.elements[0].color = (0.83, 0.80, 0.73, 1)
ramp.color_ramp.elements[1].position = 0.7
ramp.color_ramp.elements[1].color = (0.92, 0.91, 0.87, 1)
links.new(n_col.outputs["Fac"], ramp.inputs["Fac"])

# 🐱 starch powder: matte, slightly whiter patches over a soft sheen
n_pow = nodes.new("ShaderNodeTexNoise")
n_pow.inputs["Scale"].default_value = 6.0
n_pow.inputs["Detail"].default_value = 8
n_pow.inputs["Roughness"].default_value = 0.65
links.new(texco.outputs["Object"], n_pow.inputs["Vector"])
pow_ramp = nodes.new("ShaderNodeValToRGB")
pow_ramp.color_ramp.elements[0].position = 0.45
pow_ramp.color_ramp.elements[1].position = 0.62
links.new(n_pow.outputs["Fac"], pow_ramp.inputs["Fac"])
powder = pow_ramp.outputs["Color"]

# 🐱 colour: base rice tone, powder lifts it towards white
col_mix = nodes.new("ShaderNodeMix")
col_mix.data_type = "RGBA"
links.new(powder, col_mix.inputs["Factor"])
links.new(ramp.outputs["Color"], col_mix.inputs[6])
col_mix.inputs[7].default_value = (0.97, 0.965, 0.95, 1)
links.new(col_mix.outputs[2], bsdf.inputs["Base Color"])

# 🐱 roughness: skin is satiny (shinier when stretched, driven per frame), powder is matte
rough_val = nodes.new("ShaderNodeValue")
rough_val.name = "RoughBase"
rough_val.outputs[0].default_value = 0.42
r_mix = nodes.new("ShaderNodeMix")
r_mix.data_type = "FLOAT"
links.new(powder, r_mix.inputs["Factor"])
links.new(rough_val.outputs[0], r_mix.inputs[2])
r_mix.inputs[3].default_value = 0.85
links.new(r_mix.outputs[0], bsdf.inputs["Roughness"])

# 🐱 surface: soft lumps, tiny air pits, fine grain
n_big = nodes.new("ShaderNodeTexNoise")
n_big.inputs["Scale"].default_value = 2.8
n_big.inputs["Detail"].default_value = 5
n_big.inputs["Roughness"].default_value = 0.5
links.new(texco.outputs["Object"], n_big.inputs["Vector"])
bump1 = nodes.new("ShaderNodeBump")
bump1.inputs["Strength"].default_value = 0.22
bump1.inputs["Distance"].default_value = 0.06
links.new(n_big.outputs["Fac"], bump1.inputs["Height"])

vor = nodes.new("ShaderNodeTexVoronoi")
vor.feature = "F1"
vor.inputs["Scale"].default_value = 26
vor.inputs["Randomness"].default_value = 1.0
links.new(texco.outputs["Object"], vor.inputs["Vector"])
pits = nodes.new("ShaderNodeMath")
pits.operation = "SMOOTH_MIN"
pits.inputs[1].default_value = 0.12
pits.inputs[2].default_value = 0.08
links.new(vor.outputs["Distance"], pits.inputs[0])
bump2 = nodes.new("ShaderNodeBump")
bump2.inputs["Strength"].default_value = 0.35
bump2.inputs["Distance"].default_value = 0.01
links.new(pits.outputs[0], bump2.inputs["Height"])
links.new(bump1.outputs["Normal"], bump2.inputs["Normal"])

n_fine = nodes.new("ShaderNodeTexNoise")
n_fine.inputs["Scale"].default_value = 140
n_fine.inputs["Detail"].default_value = 2
links.new(texco.outputs["Object"], n_fine.inputs["Vector"])
bump3 = nodes.new("ShaderNodeBump")
bump3.inputs["Strength"].default_value = 0.12
bump3.inputs["Distance"].default_value = 0.003
links.new(n_fine.outputs["Fac"], bump3.inputs["Height"])
links.new(bump2.outputs["Normal"], bump3.inputs["Normal"])
links.new(bump3.outputs["Normal"], bsdf.inputs["Normal"])

mochi.data.materials.append(mat)


# 🐱 ---------- lights ----------
def area(name, loc, target, power, color, size):
    ld = bpy.data.lights.new(name, "AREA")
    ld.energy = power
    ld.color = color
    ld.size = size
    lo = bpy.data.objects.new(name, ld)
    scene.collection.objects.link(lo)
    lo.location = loc
    d = Vector(target) - Vector(loc)
    lo.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    return lo


area("Key", (-3.0, -3.6, 4.4), (0, 0, 0.3), 900, (1.0, 0.97, 0.93), 1.6)
area("Fill", (4.0, -2.5, 1.2), (0, 0, 0.3), 35, (0.86, 0.9, 1.0), 4.0)
area("Rim", (1.6, 4.5, 2.8), (0, 0, 0.4), 900, (1.0, 1.0, 1.0), 2.0)
area("RimL", (-3.8, 3.0, 1.0), (0, 0, 0.2), 220, (0.9, 0.93, 1.0), 2.0)
warm = area("Warm", (0.0, -0.3, -1.6), (0, 0, 0), 0, (1.0, 0.42, 0.12), 2.2)

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
wn = world.node_tree.nodes
wn.clear()
bg = wn.new("ShaderNodeBackground")
bg.inputs["Color"].default_value = (0.012, 0.012, 0.016, 1)
bg.inputs["Strength"].default_value = 1.0
world.node_tree.links.new(bg.outputs["Background"], wn.new("ShaderNodeOutputWorld").inputs["Surface"])

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
r = scene.render
r.engine = "CYCLES"
r.resolution_x, r.resolution_y = 1280, 560
r.resolution_percentage = SCALE
r.film_transparent = True
r.image_settings.file_format = "PNG"
r.image_settings.color_mode = "RGBA"
r.filepath = f"{OUT_DIR}/mochi_"
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Base Contrast"

cy = scene.cycles
cy.samples = SAMPLES
cy.use_adaptive_sampling = True
cy.adaptive_threshold = 0.02
cy.use_denoising = True
cy.denoiser = "OPENIMAGEDENOISE"
cy.max_bounces = 8
cy.diffuse_bounces = 3
cy.glossy_bounces = 3
cy.transmission_bounces = 4
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    cy.device = "GPU"
except Exception as e:  # 🐱 fall back to CPU
    print("GPU setup failed:", e)

bpy.ops.render.render(animation=True)
