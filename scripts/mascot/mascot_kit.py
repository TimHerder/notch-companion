"""Shared Blender pipeline for the Notch Companion mascots.

Each character lives in its own script, scripts/mascot/<id>.py, which models,
rigs and poses the body and ends with `kit.run(sys.modules[__name__])`. The kit
stages the camera and lights, keys every clip one frame at a time (so loops
close exactly), renders transparent frames, packs them into WebP sprite sheets
and writes <id>.json with per-frame face anchors. The app draws the live white
eyes with those anchors, so production sprites always have a blank face.

    scripts/render-mascot.sh mote                       # every clip into Resources/Mascot
    scripts/render-mascot.sh mote --preview done --eyes  # review stills + contact sheet
    scripts/render-mascot.sh mote --turnaround --eyes    # front, 3/4, side, rear

Character module contract
    ID            output prefix ("mote", "fold", "soot")
    EYE_UNIT      one eye-drawing unit in Blender units (the app's pair spans 18)
    CLIPS         {name: kit.Clip(function, seconds, loops, ledge=None)}; must
                  include REQUIRED, and may add "stage-<name>" variants that the
                  app plays on the popup stage instead of <name>
    build()       -> kit.Rig with
                    face          an empty at the face centre: local +X is screen
                                  right at rest, +Z up, -Y out of the face
                    keyed         objects whose location/rotation/scale are keyed
                    preview_eyes  optional; rendered only with --eyes
    apply_pose(rig, pose)        pose = function(t, seconds), any dict
    keyframe(rig)                optional: extra keys (shape keys, visibility...)
    stage(scene, camera)         optional: adjust the default lights and world
    CAMERA_TARGET_Z, FRAME_HEIGHT, GROUND_Z   optional framing overrides

A clip's `ledge` is a world point on the front top edge of a holdout the body
hides behind (the popup's bottom edge). The manifest records its projected
height so the app can line that edge up with the island's bottom.
"""

import bpy
import bmesh
import json
import math
import os
import sys
from collections import namedtuple
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view
import numpy as np

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def arg(name, default=None):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = arg("--out", os.path.join(ROOT, "Sources", "NotchCompanion", "Resources", "Mascot"))
WORK = arg("--work", os.path.join(ROOT, "build", "mascot"))
PREVIEW = arg("--preview")
TURNAROUND = "--turnaround" in ARGS
ONLY = arg("--clips")
SIZE = int(arg("--size", "288"))
SAMPLES = int(arg("--samples", "32" if PREVIEW or TURNAROUND else "96"))
FPS = 24
COLUMNS = 8
REQUIRED = ("emerge", "idle", "work", "done", "wave", "wait", "fail", "sad")
# Set from the character before build(); helpers size the preview eyes with it.
EYE_UNIT = 0.0145

Clip = namedtuple("Clip", "function seconds loops ledge", defaults=(None,))


class Rig:
    def __init__(self):
        self.face = None
        self.keyed = []
        self.preview_eyes = []


# ---------------------------------------------------------------- utilities


def lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def rgba(r, g, b, a=1.0):
    return (lin(r), lin(g), lin(b), a)


def smoothstep(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def ease_in_out(x):
    x = min(1.0, max(0.0, x))
    return 0.5 - 0.5 * math.cos(math.pi * x)


def spring(t, damping=0.42, period=0.42):
    """Under-damped step response: 0 at t<=0, overshoots, settles at 1."""
    if t <= 0:
        return 0.0
    w = 2 * math.pi / period
    wd = w * math.sqrt(1 - damping * damping)
    return 1 - math.exp(-damping * w * t) * (math.cos(wd * t) + damping * w / wd * math.sin(wd * t))


def pulse(t, start, length):
    """A smooth 0→1→0 bump over [start, start+length]."""
    x = (t - start) / length
    return math.sin(math.pi * x) ** 2 if 0 <= x <= 1 else 0.0


def link(obj, parent=None, collection=None):
    (collection or bpy.context.scene.collection).objects.link(obj)
    if parent:
        obj.parent = parent
    return obj


def empty(name, parent=None, location=(0, 0, 0)):
    obj = bpy.data.objects.new(name, None)
    obj.empty_display_size = 0.05
    obj.location = location
    return link(obj, parent)


def mesh_object(name, bm, parent=None, material=None, smooth=True, subdivisions=2):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    if smooth:
        for poly in mesh.polygons:
            poly.use_smooth = True
    obj = link(bpy.data.objects.new(name, mesh), parent)
    if material:
        obj.data.materials.append(material)
    if subdivisions:
        sub = obj.modifiers.new("Subdivision", "SUBSURF")
        sub.levels = subdivisions
        sub.render_levels = subdivisions
    return obj


# ---------------------------------------------------------------- materials


def material(name, base, rough=0.5, **inputs):
    mat = bpy.data.materials.new(name)
    try:
        mat.use_nodes = True
    except AttributeError:
        pass
    shader = mat.node_tree.nodes["Principled BSDF"]
    shader.inputs["Base Color"].default_value = base
    shader.inputs["Roughness"].default_value = rough
    for key, value in inputs.items():
        shader.inputs[key].default_value = value
    return mat, shader


def micro_bump(mat, shader, scale=180.0, strength=0.035):
    """Fine tactile grain from noise."""
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = 6
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = strength
    bump.inputs["Distance"].default_value = 0.002
    links.new(noise.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], shader.inputs["Normal"])


# ---------------------------------------------------------------- geometry


def squircle_grid(half_w, half_h, n=3.6, steps=28):
    """A quad grid filling a superellipse, so subdivision keeps clean edges."""
    bm = bmesh.new()
    grid = {}
    for i in range(steps + 1):
        for j in range(steps + 1):
            u, v = -1 + 2 * i / steps, -1 + 2 * j / steps
            if max(abs(u), abs(v)) < 1e-9:
                p = (0.0, 0.0)
            else:
                theta = math.atan2(v, u)
                c, s = abs(math.cos(theta)), abs(math.sin(theta))
                k = (1.0 / (c ** n + s ** n) ** (1.0 / n)) * max(c, s)
                p = (u * k, v * k)
            grid[i, j] = bm.verts.new((p[0] * half_w, 0.0, p[1] * half_h))
    for i in range(steps):
        for j in range(steps):
            bm.faces.new((grid[i, j], grid[i + 1, j], grid[i + 1, j + 1], grid[i, j + 1]))
    return bm


def project_onto(bm, bvh, centre_z, lift):
    """Wrap a flat front-facing grid onto a body's front, lifted along normals."""
    for v in bm.verts:
        hit, normal, _, _ = bvh.ray_cast(Vector((v.co.x, -2.0, v.co.z + centre_z)), Vector((0, 1, 0)))
        if hit is None:
            raise RuntimeError("Grid missed the body")
        v.co = hit + normal * lift


def capsule(radius, length, segments=24):
    """A capsule hanging down from the origin along -Z."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=segments // 2, radius=1.0)
    for v in bm.verts:
        z = v.co.z
        stretch = (length / 2 - radius) * (1 if z > 0 else -1)
        v.co = Vector((v.co.x * radius, v.co.y * radius, z * radius + stretch - length / 2))
    return bm


def solidify(obj, thickness, offset=0.0):
    mod = obj.modifiers.new("Solidify", "SOLIDIFY")
    mod.thickness = thickness
    mod.offset = offset
    mod.use_even_offset = True
    # Keep solidify ahead of subdivision so rims stay soft.
    while obj.modifiers.find("Solidify") > 0:
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_move_up(modifier="Solidify")
    return mod


def preview_eyes(rig, lift=0.004):
    """The app's neutral eyes (6 × 12 units, centres ±6, white 0.97) as flat
    emissive stadiums on the face, for review renders only."""
    mat, shader = material("Preview eyes", rgba(0.97, 0.97, 0.97), rough=1.0)
    shader.inputs["Emission Color"].default_value = rgba(0.97, 0.97, 0.97)
    shader.inputs["Emission Strength"].default_value = 1.2
    for side in (-1, 1):
        bm = bmesh.new()
        points = []
        for i in range(17):  # top half-circle, then bottom
            a = math.pi * i / 16
            points.append((3 * math.cos(a), 3 + 3 * math.sin(a)))
        for i in range(17):
            a = math.pi + math.pi * i / 16
            points.append((3 * math.cos(a), -3 + 3 * math.sin(a)))
        verts = [bm.verts.new((x * EYE_UNIT, 0, z * EYE_UNIT)) for x, z in points]
        bm.faces.new(verts)
        obj = mesh_object(f"Preview eye {'L' if side < 0 else 'R'}", bm, rig.face, mat, subdivisions=0)
        obj.location = (side * 6 * EYE_UNIT, -lift, 0)
        obj.visible_shadow = False
        rig.preview_eyes.append(obj)


# ---------------------------------------------------------------- staging


def build_stage(target_z=0.74, frame_height=1.84):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    try:
        if "--cpu" in ARGS:
            raise RuntimeError("--cpu requested")
        prefs.compute_device_type = "METAL"
        # Background kernel specialisation crashed Blender 5.2 while caching.
        prefs.kernel_optimization_level = "OFF"
        prefs.get_devices()
        for device in prefs.devices:
            device.use = True
        scene.cycles.device = "GPU"
    except Exception as error:  # CPU still renders, only slower.
        print("GPU unavailable:", error)
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = True
    scene.cycles.use_adaptive_sampling = True
    scene.cycles.max_bounces = 8
    scene.render.film_transparent = True
    scene.render.resolution_x = SIZE
    scene.render.resolution_y = SIZE
    scene.render.resolution_percentage = 100
    scene.render.fps = FPS
    scene.render.use_motion_blur = True
    scene.render.motion_blur_shutter = 0.45
    scene.render.filter_size = 1.2
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.view_settings.view_transform = "AgX"
    try:
        scene.view_settings.look = "AgX - Medium High Contrast"
    except TypeError:
        pass

    world = bpy.data.worlds.new("Studio")
    scene.world = world
    try:
        world.use_nodes = True
    except AttributeError:
        pass
    nodes, links = world.node_tree.nodes, world.node_tree.links
    background = nodes["Background"]
    gradient = nodes.new("ShaderNodeTexGradient")
    coords = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    mapping.inputs["Rotation"].default_value = (0, math.pi / 2, 0)
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.004, 0.005, 0.005, 1)
    ramp.color_ramp.elements[1].color = (0.06, 0.065, 0.06, 1)
    links.new(coords.outputs["Generated"], mapping.inputs["Vector"])
    links.new(mapping.outputs["Vector"], gradient.inputs["Vector"])
    links.new(gradient.outputs["Fac"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], background.inputs["Color"])
    background.inputs["Strength"].default_value = 1.0

    def area(name, location, target, power, size, color, size_y=None):
        light = bpy.data.lights.new(name, "AREA")
        light.energy = power
        light.color = color
        light.shape = "RECTANGLE"
        light.size = size
        light.size_y = size_y or size
        obj = link(bpy.data.objects.new(name, light))
        obj.location = location
        obj.rotation_euler = (Vector(target) - Vector(location)).to_track_quat("-Z", "Y").to_euler()
        return obj

    area("Key", (-1.9, -2.4, 2.6), (0, 0, 0.6), 200, 1.8, (1.0, 0.93, 0.84))
    area("Fill", (2.4, -2.6, 0.9), (0, 0, 0.5), 55, 2.2, (0.92, 0.97, 1.0))
    area("Rim left", (-1.5, 1.6, 1.3), (0, 0, 0.6), 420, 0.8, (0.93, 0.97, 1.0), 2.4)
    area("Rim right", (1.55, 1.5, 1.2), (0, 0, 0.6), 380, 0.8, (0.88, 1.0, 0.86), 2.4)
    area("Strip", (0, -1.2, 2.4), (0, 0, 0.7), 70, 1.6, (1, 1, 1), 0.18)
    area("Under", (0, -1.4, -0.9), (0, 0, 0.3), 18, 1.5, (1.0, 0.86, 0.7))

    camera_data = bpy.data.cameras.new("Camera")
    camera_data.lens = 100
    camera = link(bpy.data.objects.new("Camera", camera_data))
    camera["target"] = (0, 0, target_z)
    camera["distance"] = frame_height / 2 / (18 / camera_data.lens)
    orbit(camera, 0)
    scene.camera = camera
    return scene, camera


def orbit(camera, yaw, elevation=math.radians(7)):
    """Places the camera around its target; yaw 0 looks at the face."""
    target = Vector(camera["target"])
    offset = Vector((math.sin(yaw) * math.cos(elevation), -math.cos(yaw) * math.cos(elevation), math.sin(elevation)))
    camera.location = target + offset * camera["distance"]
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()


# ---------------------------------------------------------------- animation


def keyframe_transforms(objects):
    for obj in objects:
        obj.keyframe_insert("location")
        obj.keyframe_insert("rotation_euler")
        obj.keyframe_insert("scale")


def animate(character, rig, scene, names):
    """Lays the clips end to end, one key per frame plus a lead-in key for blur."""
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    ranges = {}
    frame = 1
    for name in names:
        clip = character.CLIPS[name]
        count = round(clip.seconds * FPS)
        # A key before and after each clip keeps motion blur continuous at the ends.
        for offset in range(-1, count + 1):
            t = offset / FPS
            t = t % clip.seconds if clip.loops else min(max(t, 0), clip.seconds)
            scene.frame_set(frame + offset)
            character.apply_pose(rig, clip.function(t, clip.seconds))
            keyframe_transforms(rig.keyed)
            if hasattr(character, "keyframe"):
                character.keyframe(rig)
        ranges[name] = (frame, count, clip)
        frame += count + 4
    return ranges


def project(scene, camera, point):
    co = world_to_camera_view(scene, camera, point)
    return Vector((co.x, 1 - co.y))


def anchors(rig, scene, camera, start, count):
    """Per frame: the face centre, one eye unit along its x and y-down axes
    (fractions of the frame, y-down) and how squarely it faces the camera."""
    rows = []
    for index in range(count):
        scene.frame_set(start + index)
        bpy.context.view_layer.update()
        matrix = rig.face.matrix_world
        centre = matrix.translation.copy()
        # Measured through the full matrix, so squash and stretch carry over.
        x_axis = matrix @ Vector((EYE_UNIT, 0, 0)) - centre
        up_axis = matrix @ Vector((0, 0, EYE_UNIT)) - centre
        c = project(scene, camera, centre)
        a = project(scene, camera, centre + x_axis) - c
        b = project(scene, camera, centre - up_axis) - c
        normal = (matrix.to_3x3() @ Vector((0, -1, 0))).normalized()
        facing = normal.dot((camera.matrix_world.translation - centre).normalized())
        rows.append([round(v, 5) for v in (c.x, c.y, a.x, a.y, b.x, b.y, facing)])
    return rows


# ---------------------------------------------------------------- images


def load_rgba(path):
    image = bpy.data.images.load(path)
    width, height = image.size
    pixels = np.empty(width * height * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    bpy.data.images.remove(image)
    return pixels.reshape(height, width, 4)  # bottom-up rows


def save_rgba(array, path, file_format="PNG"):
    height, width, _ = array.shape
    image = bpy.data.images.new(os.path.basename(path), width, height, alpha=True)
    image.alpha_mode = "STRAIGHT"
    image.pixels.foreach_set(array.astype(np.float32).ravel())
    image.filepath_raw = path
    image.file_format = file_format
    image.save(filepath=path, quality=90)
    bpy.data.images.remove(image)


def render_still(scene, path):
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def render_clip(scene, start, count, folder):
    os.makedirs(folder, exist_ok=True)
    for index in range(count):
        path = os.path.join(folder, f"{index:03d}.png")
        if "--resume" in ARGS and os.path.exists(path):
            continue
        scene.frame_set(start + index)
        render_still(scene, path)


def pack_sheet(folder, count, path):
    rows = math.ceil(count / COLUMNS)
    columns = min(COLUMNS, count)
    sheet = np.zeros((rows * SIZE, columns * SIZE, 4), dtype=np.float32)
    for index in range(count):
        row, column = divmod(index, COLUMNS)
        # Images are stored bottom-up: row 0 of the sheet is its top.
        y0 = (rows - 1 - row) * SIZE
        sheet[y0:y0 + SIZE, column * SIZE:(column + 1) * SIZE] = load_rgba(os.path.join(folder, f"{index:03d}.png"))
    save_rgba(sheet, path, "WEBP")


def contact(grid, path, backgrounds=((0.0, 0.0, 0.0),)):
    """Stills in rows, repeated over each background, for review."""
    tiles = [[load_rgba(p) for p in row] for row in grid]
    size = tiles[0][0].shape[0]
    columns = max(len(row) for row in tiles)
    bands = []
    for background in backgrounds:
        bg = np.array(background, dtype=np.float32)
        for row in tiles:
            band = np.ones((size, columns * size, 4), dtype=np.float32)
            band[..., :3] = bg
            for i, tile in enumerate(row):
                alpha = tile[..., 3:4]
                band[:, i * size:(i + 1) * size, :3] = tile[..., :3] * alpha + bg * (1 - alpha)
            bands.append(band)
    save_rgba(np.concatenate(bands[::-1], axis=0), path)  # bottom-up: first band on top
    print("CONTACT", path)


# ---------------------------------------------------------------- run


def run(character):
    global EYE_UNIT
    EYE_UNIT = character.EYE_UNIT
    missing = [name for name in REQUIRED if name not in character.CLIPS]
    if missing:
        raise SystemExit(f"{character.ID}: missing clips {missing}")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    rig = character.build()
    scene, camera = build_stage(getattr(character, "CAMERA_TARGET_Z", 0.74), getattr(character, "FRAME_HEIGHT", 1.84))
    if hasattr(character, "stage"):
        character.stage(scene, camera)
    show_eyes = "--eyes" in ARGS and bool(PREVIEW or TURNAROUND)
    for obj in rig.preview_eyes:
        obj.hide_render = not show_eyes

    names = list(character.CLIPS)
    selection = PREVIEW or ONLY
    if selection:
        names = [name for name in selection.split(",") if name in character.CLIPS] or names
    if TURNAROUND and "idle" not in names:
        names.append("idle")
    ranges = animate(character, rig, scene, names)
    if arg("--save"):
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(arg("--save")))

    if TURNAROUND:
        folder = os.path.join(WORK, "turnaround")
        os.makedirs(folder, exist_ok=True)
        scene.frame_set(ranges["idle"][0])
        paths = []
        for label, degrees in (("front", 0), ("three-quarter", 40), ("side", 90), ("rear", 180)):
            orbit(camera, math.radians(degrees))
            paths.append(render_still(scene, os.path.join(folder, f"{label}.png")))
        orbit(camera, 0)
        contact([paths], os.path.join(folder, "turnaround.png"), ((0.82, 0.82, 0.82), (0.0, 0.0, 0.0)))
        return

    if PREVIEW:
        # A few stills per clip for review, without touching the bundled assets.
        folder = os.path.join(WORK, "preview")
        os.makedirs(folder, exist_ok=True)
        grid = []
        for name in names:
            start, count, _ = ranges[name]
            row = []
            for index in sorted({0, count // 4, count // 2, 3 * count // 4, count - 1}):
                scene.frame_set(start + index)
                row.append(render_still(scene, os.path.join(folder, f"{name}-{index:03d}.png")))
            grid.append(row)
        contact(grid, os.path.join(folder, "contact.png"))
        return

    os.makedirs(OUT, exist_ok=True)
    manifest_path = os.path.join(OUT, f"{character.ID}.json")
    ground = project(scene, camera, Vector((0, 0, getattr(character, "GROUND_Z", -0.02)))).y
    manifest = {"size": SIZE, "fps": FPS, "eyeUnit": EYE_UNIT, "ground": round(ground, 4), "clips": {}}
    if ONLY and os.path.exists(manifest_path):
        with open(manifest_path) as handle:
            manifest["clips"] = json.load(handle).get("clips", {})
    anchors_only = "--anchors-only" in ARGS
    for name in names:
        start, count, clip = ranges[name]
        if not anchors_only:
            folder = os.path.join(WORK, "frames", name)
            render_clip(scene, start, count, folder)
            pack_sheet(folder, count, os.path.join(OUT, f"{character.ID}-{name}.webp"))
        entry = {"frames": count, "loops": clip.loops, "columns": min(COLUMNS, count),
                 "anchors": anchors(rig, scene, camera, start, count)}
        if clip.ledge is not None:
            entry["ledge"] = round(project(scene, camera, Vector(clip.ledge)).y, 4)
        manifest["clips"][name] = entry
        print("CLIP", name, count, "frames")
    with open(manifest_path, "w") as handle:
        json.dump(manifest, handle, separators=(",", ":"))
    print("DONE", manifest_path)
