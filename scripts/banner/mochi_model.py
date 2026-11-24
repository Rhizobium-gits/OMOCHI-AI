# 🐱 The realistic round mochi (marumochi) shared by every Blender render:
# 🐱 the README banner (mochi_scene.py), the app icon and the realistic avatar's
# 🐱 sprites (mochi_assets.py). Import it from a script run with Blender -P.

import math

import bpy
from mathutils import Vector

# 🐱 resting marumochi and the fully puffed one (the "Puff" shape key)
REST = dict(a=1.0, c_top=0.36, n_top=0.70, c_bot=0.19, n_bot=0.42, dome=0.07, bulge=0.0, sag=0.02)
PUFF = dict(a=1.09, c_top=0.78, n_top=0.84, c_bot=0.24, n_bot=0.50, dome=0.04, bulge=0.22, sag=0.0)


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    return bpy.context.scene


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


def build_mochi():
    """🐱 Returns (object, puff shape key, roughness value node)."""
    bpy.ops.mesh.primitive_uv_sphere_add(segments=160, ring_count=80, radius=1.0)
    mochi = bpy.context.active_object
    mochi.name = "Mochi"
    mesh = mochi.data
    unit = [v.co.copy() for v in mesh.vertices]
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

    mat, rough_val = build_material()
    mochi.data.materials.append(mat)
    return mochi, kp, rough_val


def build_material():
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

    # 🐱 roughness: skin is satiny (shinier when stretched), powder is matte
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
    return mat, rough_val


def area(scene, name, loc, target, power, color, size):
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


def add_lights(scene):
    """🐱 Key / fill / two rims, and a warm light underneath (energy 0 until a script turns it up)."""
    area(scene, "Key", (-3.0, -3.6, 4.4), (0, 0, 0.3), 900, (1.0, 0.97, 0.93), 1.6)
    area(scene, "Fill", (4.0, -2.5, 1.2), (0, 0, 0.3), 35, (0.86, 0.9, 1.0), 4.0)
    area(scene, "Rim", (1.6, 4.5, 2.8), (0, 0, 0.4), 900, (1.0, 1.0, 1.0), 2.0)
    area(scene, "RimL", (-3.8, 3.0, 1.0), (0, 0, 0.2), 220, (0.9, 0.93, 1.0), 2.0)
    return area(scene, "Warm", (0.0, -0.3, -1.6), (0, 0, 0), 0, (1.0, 0.42, 0.12), 2.2)


def set_world(scene, color=(0.012, 0.012, 0.016)):
    world = bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    wn = world.node_tree.nodes
    wn.clear()
    bg = wn.new("ShaderNodeBackground")
    bg.inputs["Color"].default_value = (*color, 1)
    bg.inputs["Strength"].default_value = 1.0
    world.node_tree.links.new(bg.outputs["Background"], wn.new("ShaderNodeOutputWorld").inputs["Surface"])


def render_settings(scene, width, height, scale, samples, filepath):
    """🐱 Cycles on the Mac's GPU (Metal), transparent background, PNG RGBA."""
    r = scene.render
    r.engine = "CYCLES"
    r.resolution_x, r.resolution_y = width, height
    r.resolution_percentage = scale
    r.film_transparent = True
    r.image_settings.file_format = "PNG"
    r.image_settings.color_mode = "RGBA"
    r.filepath = filepath
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Base Contrast"

    cy = scene.cycles
    cy.samples = samples
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
