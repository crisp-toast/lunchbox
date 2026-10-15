# Tessel hero: a pile of colored glass "windows" shattered upward by an invisible
# force, at full speed, then easing into extreme slow motion, ending sharp.
#
#   Blender -b --python glass_break.py -- OUT_DIR FRAMES RES_PERCENT SAMPLES [ENGINE] [SAVE.blend]
#   FRAMES: "all" or a comma list like "0,7,25,74"; ENGINE: cycles (default) or eevee
import bmesh
import bpy
import math
import os
import random
import sys
from mathutils import Euler, Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if len(argv) > 0 else "/tmp/glass"
FRAMES = argv[1] if len(argv) > 1 else "0,9,30,119"
RES = int(argv[2]) if len(argv) > 2 else 50
SAMPLES = int(argv[3]) if len(argv) > 3 else 32
ENGINE = argv[4] if len(argv) > 4 else "cycles"
SAVE = argv[5] if len(argv) > 5 else None

random.seed(7)
FPS = 30
LAST = 74  # 75 frames, 2.5 seconds; the page then holds the last one

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------- Render ----------
scene.render.engine = "CYCLES" if ENGINE == "cycles" else "BLENDER_EEVEE"
if ENGINE != "cycles":
    try:
        scene.eevee.taa_render_samples = SAMPLES
        scene.eevee.use_raytracing = True
    except Exception:
        pass
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "METAL"
# Background kernel optimization has crashed Blender mid-render on Metal; the plain kernels are fine.
try:
    prefs.kernel_optimization_level = "OFF"
except Exception:
    pass
prefs.get_devices()
for d in prefs.devices:
    d.use = True
scene.cycles.device = "GPU"
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 10
scene.cycles.transmission_bounces = 10
scene.cycles.adaptive_threshold = 0.02
scene.cycles.glossy_bounces = 6
scene.cycles.transparent_max_bounces = 16
scene.cycles.caustics_reflective = False
scene.cycles.caustics_refractive = False
scene.render.resolution_x = 1920
scene.render.resolution_y = 1080
scene.render.resolution_percentage = RES
scene.render.fps = FPS
scene.render.use_motion_blur = True
scene.render.motion_blur_shutter = 0.5
scene.render.image_settings.file_format = "PNG"
scene.view_settings.view_transform = "AgX"
for look in ("AgX - Medium High Contrast", "Medium High Contrast"):
    try:
        scene.view_settings.look = look
        break
    except TypeError:
        pass
scene.frame_start, scene.frame_end = 0, LAST

# ---------- World: near black ----------
world = bpy.data.worlds.new("World")
scene.world = world
try:
    world.use_nodes = True
except Exception:
    pass
bg = world.node_tree.nodes.get("Background")
bg.inputs[0].default_value = (0.003, 0.003, 0.004, 1)
bg.inputs[1].default_value = 1.0


def emission_material(name, color, strength):
    m = bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*color, 1)
    em.inputs["Strength"].default_value = strength
    nt.links.new(em.outputs[0], out.inputs[0])
    return m, nt, em


# ---------- Backlight: a soft glow behind the pile so colored glass lights up ----------
bpy.ops.mesh.primitive_plane_add(size=1, location=(0, 5.5, 0.4), rotation=(math.radians(90), 0, 0))
back = bpy.context.object
back.scale = (36, 22, 1)
m, nt, em = emission_material("Backlight", (0.86, 0.88, 0.92), 1.0)
tex = nt.nodes.new("ShaderNodeTexCoord")
grad = nt.nodes.new("ShaderNodeTexGradient")
grad.gradient_type = "SPHERICAL"
mapping = nt.nodes.new("ShaderNodeMapping")
mapping.inputs["Scale"].default_value = (2.6, 4.2, 1)
ramp = nt.nodes.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].position = 0.0
ramp.color_ramp.elements[0].color = (0.55, 0.55, 0.55, 1)
ramp.color_ramp.elements[1].position = 0.9
ramp.color_ramp.elements[1].color = (1, 1, 1, 1)
nt.links.new(tex.outputs["Generated"], mapping.inputs["Vector"])
mapping.inputs["Location"].default_value = (-0.5 * 2.6 + 0.5 * 2.6, 0, 0)
nt.links.new(tex.outputs["Object"], mapping.inputs["Vector"])
nt.links.new(mapping.outputs[0], grad.inputs[0])
nt.links.new(grad.outputs["Fac"], ramp.inputs[0])
mult = nt.nodes.new("ShaderNodeMath")
mult.operation = "MULTIPLY"
mult.inputs[1].default_value = 1.75
nt.links.new(ramp.outputs["Color"], mult.inputs[0])
nt.links.new(mult.outputs[0], em.inputs["Strength"])
back.data.materials.append(m)
back.visible_shadow = False

# ---------- Lights ----------
def area(name, loc, target, power, size, color=(1, 1, 1)):
    data = bpy.data.lights.new(name, "AREA")
    data.energy = power
    data.size = size
    data.color = color
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.location = loc
    direction = Vector(target) - Vector(loc)
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    return obj

area("Key", (0, -3, 7), (0, 0, 0.3), 900, 7)
area("RimWarm", (-8, 2.5, 1.5), (0, 0, 0.3), 700, 4, (1.0, 0.82, 0.66))
area("RimCool", (8, 2.5, 2.0), (0, 0, 0.3), 700, 4, (0.68, 0.8, 1.0))
area("Fill", (0, -11, 1.5), (0, 0, 0.3), 120, 8)

# ---------- Camera ----------
cam_data = bpy.data.cameras.new("Camera")
cam_data.lens = 50
cam = bpy.data.objects.new("Camera", cam_data)
scene.collection.objects.link(cam)
cam.location = (0, -12.5, 0.2)
cam.rotation_euler = (Vector((0, 0, 0.45)) - cam.location).to_track_quat("-Z", "Y").to_euler()
scene.camera = cam

# ---------- Glass ----------
COLORS = {
    "coral": (1.0, 0.30, 0.20),
    "amber": (1.0, 0.62, 0.10),
    "mint": (0.10, 0.85, 0.58),
    "blue": (0.16, 0.40, 1.0),
    "violet": (0.55, 0.36, 1.0),
    "clear": (0.92, 0.94, 0.97),
}
materials = {}
for name, rgb in COLORS.items():
    mat = bpy.data.materials.new("Glass_" + name)
    try:
        mat.use_nodes = True
    except Exception:
        pass
    p = mat.node_tree.nodes.get("Principled BSDF")
    p.inputs["Base Color"].default_value = (*rgb, 1)
    p.inputs["Roughness"].default_value = 0.06
    p.inputs["IOR"].default_value = 1.47
    p.inputs["Transmission Weight"].default_value = 1.0
    materials[name] = mat


def rounded_rect(w, h, r, seg=6):
    pts = []
    corners = [(w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)]
    for cx, cy, start in corners:
        for k in range(seg + 1):
            a = math.radians(start + 90 * k / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def prism(bm, poly, t):
    bottom = [bm.verts.new((x, y, -t / 2)) for x, y in poly]
    top = [bm.verts.new((x, y, t / 2)) for x, y in poly]
    bm.faces.new(list(reversed(bottom)))
    bm.faces.new(top)
    n = len(poly)
    for k in range(n):
        bm.faces.new((bottom[k], bottom[(k + 1) % n], top[(k + 1) % n], top[k]))


def fracture(poly, t, seeds):
    """2D Voronoi cells of a flat prism: one bmesh per seed."""
    cells = []
    for i, s in enumerate(seeds):
        bm = bmesh.new()
        prism(bm, poly, t)
        for j, o in enumerate(seeds):
            if i == j:
                continue
            n = Vector((o[0] - s[0], o[1] - s[1], 0))
            if n.length < 1e-6:
                continue
            mid = Vector(((o[0] + s[0]) / 2, (o[1] + s[1]) / 2, 0))
            geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
            res = bmesh.ops.bisect_plane(bm, geom=geom, dist=1e-6, plane_co=mid, plane_no=n.normalized(), clear_outer=True)
            cut = [e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
            if cut:
                bmesh.ops.holes_fill(bm, edges=cut, sides=0)
            if not bm.verts:
                break
        if len(bm.verts) >= 6:
            cells.append(bm)
        else:
            bm.free()
    return cells


# The pile: overlapping window-shaped panes, a little askew, at different depths.
PANES = [
    # cx, cz, w, h, tilt (deg), depth y, color
    (-2.3, 0.9, 2.6, 1.7, -6, 0.55, "blue"),
    (2.2, 1.1, 2.8, 1.8, 5, 0.6, "violet"),
    (-0.4, 1.4, 3.0, 1.9, 2, 0.35, "mint"),
    (-2.6, -0.5, 2.4, 1.6, 4, 0.1, "amber"),
    (2.5, -0.4, 2.5, 1.7, -4, 0.15, "coral"),
    (0.3, 0.0, 3.2, 2.0, -3, -0.1, "clear"),
    (-1.1, -0.9, 2.6, 1.5, 7, -0.35, "coral"),
    (1.4, -0.8, 2.4, 1.6, -7, -0.4, "mint"),
    (0.0, 1.0, 2.2, 1.4, 9, -0.6, "amber"),
]
IMPACT = Vector((0.0, 1.4, -1.6))  # behind and below the middle
THICK = 0.04
GRAVITY = Vector((0, 0, -5.5))

shards = []  # (object, loc0, rot0, velocity, spin)
wholes = []  # intact panes, visible until the hit
for idx, (cx, cz, w, h, tilt, depth, color) in enumerate(PANES):
    rot = Euler((math.radians(90 + random.uniform(-3, 3)), math.radians(tilt), math.radians(random.uniform(-4, 4))))
    pane_m = Matrix.Translation((cx, depth, cz)) @ rot.to_matrix().to_4x4()
    inv = pane_m.inverted()
    poly = rounded_rect(w, h, 0.14)
    # Seeds: some anywhere, more near where the force comes through.
    hit = inv @ Vector((0, depth, cz - 0.4))
    seeds = []
    for _ in range(14):
        seeds.append((random.uniform(-w / 2, w / 2), random.uniform(-h / 2, h / 2)))
    for _ in range(12):
        x = max(-w / 2 + 0.02, min(w / 2 - 0.02, random.gauss(hit.x, 0.55)))
        y = max(-h / 2 + 0.02, min(h / 2 - 0.02, random.gauss(hit.y, 0.45)))
        seeds.append((x, y))
    for k, bm in enumerate(fracture(poly, THICK, seeds)):
        center = sum((v.co for v in bm.verts), Vector()) / len(bm.verts)
        for v in bm.verts:
            v.co -= center
        mesh = bpy.data.meshes.new(f"shard_{idx}_{k}")
        bm.to_mesh(mesh)
        bm.free()
        obj = bpy.data.objects.new(mesh.name, mesh)
        scene.collection.objects.link(obj)
        obj.data.materials.append(materials[color])
        bev = obj.modifiers.new("Bevel", "BEVEL")
        bev.width = 0.004
        bev.segments = 2
        bev.limit_method = "ANGLE"
        world_m = pane_m @ Matrix.Translation(center)
        loc0 = world_m.to_translation()
        rot0 = world_m.to_euler()
        # Up and out from the force, and toward the camera; the middle clears first.
        d = loc0 - IMPACT
        outward = Vector((d.x, 0, d.z)).normalized() if Vector((d.x, 0, d.z)).length > 1e-4 else Vector((0, 0, 1))
        speed = 5.2 / (1.0 + 0.3 * d.length) * random.uniform(0.75, 1.25)
        v = outward * speed + Vector((random.uniform(-0.5, 0.5), random.uniform(-1.8, -0.5), random.uniform(0.8, 1.8)))
        size = max(obj.dimensions.x, obj.dimensions.z, 0.05)
        spin = Vector((random.uniform(-1, 1), random.uniform(-1, 1), random.uniform(-1, 1))).normalized() * random.uniform(4, 11) / (0.6 + size)
        shards.append((obj, loc0, rot0, v, spin))
    # The whole pane, shown until the hit so no seams show beforehand.
    bm = bmesh.new()
    prism(bm, poly, THICK)
    whole_mesh = bpy.data.meshes.new(f"pane_{idx}")
    bm.to_mesh(whole_mesh)
    bm.free()
    whole = bpy.data.objects.new(whole_mesh.name, whole_mesh)
    scene.collection.objects.link(whole)
    whole.data.materials.append(materials[color])
    whole.matrix_world = pane_m
    wholes.append(whole)

# ---------- Time: still, a full-speed hit, then an ease into extreme slow motion ----------
HIT = 5  # the frame the force arrives


def rate(f):
    """Seconds of simulated time that pass during output frame f."""
    if f < HIT:
        return 0.0
    if f < HIT + 5:
        return 1.0 / FPS
    k = (f - HIT - 5) / 32.0
    if k < 1:
        return (0.025 + 0.975 * math.exp(-5.0 * k)) / FPS
    return 0.025 / FPS


sim = []
t = 0.0
for f in range(LAST + 1):
    sim.append(t)
    t += rate(f)

for obj, loc0, rot0, v, spin in shards:
    obj.animation_data_create()
    action = bpy.data.actions.new(obj.name + "_motion")
    obj.animation_data.action = action
    coords = {("location", i): [] for i in range(3)}
    coords.update({("rotation_euler", i): [] for i in range(3)})
    for f in range(LAST + 1):
        s = sim[f]
        loc = loc0 + v * s + 0.5 * GRAVITY * s * s
        rot = Vector(rot0) + spin * s
        for i in range(3):
            coords[("location", i)] += [f, loc[i]]
            coords[("rotation_euler", i)] += [f, rot[i]]
    for (path, i), values in coords.items():
        try:
            fc = action.fcurves.new(path, index=i)
        except Exception:
            fc = obj.animation_data.action.fcurve_ensure_for_datablock(obj, path, index=i)
        fc.keyframe_points.add(LAST + 1)
        fc.keyframe_points.foreach_set("co", values)
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
        fc.update()

def show_from(obj, frame, visible):
    """Hidden before `frame` and shown from it on (or the reverse)."""
    for f, hidden in ((frame - 1, visible), (frame, not visible)):
        obj.hide_render = hidden
        obj.hide_viewport = hidden
        obj.keyframe_insert("hide_render", frame=f)
        obj.keyframe_insert("hide_viewport", frame=f)


for whole in wholes:
    show_from(whole, HIT, False)
for obj, *_ in shards:
    show_from(obj, HIT, True)

print(f"[glass] {len(shards)} shards, simulated {sim[-1]:.3f}s over {LAST + 1} frames")

if SAVE:
    bpy.ops.wm.save_as_mainfile(filepath=SAVE)

# ---------- Render ----------
frames = range(LAST + 1) if FRAMES == "all" else [int(x) for x in FRAMES.split(",") if x.strip()]
os.makedirs(OUT, exist_ok=True)
for f in frames:
    scene.frame_set(f)
    scene.render.filepath = os.path.join(OUT, f"frame_{f:04d}.png")
    bpy.ops.render.render(write_still=True)
    print(f"[glass] rendered frame {f}")
