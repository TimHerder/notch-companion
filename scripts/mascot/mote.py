"""Mote, the default Notch Companion mascot: a plump near-black satin ghost.

One continuous body (dome, belly and a short thick tail that curls to the
character's right, viewer-left) swept along a bent spine, two blunt paddle
flippers and a blank face for the app's live eyes. The tail is skinned to a
small bone chain so it can trail, flick and hook; everything else rides a
stack of empties (float, inflate around the eyes, lean, squash).

Signature: on the popup stage Mote phases up through the island's bottom edge
(stage-emerge). A holdout in the body's own shader cuts everything behind a
plane through the edge and the camera, so the cut is the straight island edge;
a faint shimmer band marks the crossing, and the tail hooks over the border
(let out in front of the edge) before it flicks free.

    scripts/render-mascot.sh mote --turnaround --eyes --size 512
    scripts/render-mascot.sh mote --preview idle,done --eyes
    scripts/render-mascot.sh mote
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mascot_kit as kit  # noqa: E402

ID = "mote"
EYE_UNIT = 0.0145          # pair spans 0.26, about 2/5 of the body's width
GROUND_Z = 0.0             # where its shadow would fall, just under the tail tip
FACE_Z = 0.66              # eye centre height
CENTRE_Z = 0.56            # lean and squash pivot
TAU = 2 * math.pi
FPS = kit.FPS

# Spine in the front plane (x, z), crown to tail tip, and the half-width and
# half-depth along it (fractions of its length). Shaped against the concept.
SPINE = [(0.0, 1.05), (0.008, 0.82), (0.012, 0.58), (-0.005, 0.38), (-0.095, 0.205), (-0.21, 0.105), (-0.335, 0.08)]
WIDTH = [(0.0, 0.29), (0.25, 0.338), (0.45, 0.365), (0.6, 0.34), (0.7, 0.27), (0.8, 0.175), (0.9, 0.105), (1.0, 0.068)]
DEPTH = [(0.0, 0.235), (0.25, 0.245), (0.45, 0.245), (0.6, 0.225), (0.7, 0.185), (0.8, 0.125), (0.9, 0.082), (1.0, 0.055)]
TOP_CAP = 0.36
TIP_CAP = 0.06
RINGS, SEGMENTS = 84, 48
TAIL_START = 0.62          # spine fraction where the tail chain begins
N_TAIL = 4

FLIP_REST = 0.6            # neutral flipper angle out from straight down
FLIP_LEN, FLIP_R0, FLIP_R1, FLIP_FLAT = 0.33, 0.062, 0.094, 0.8
SHOULDER = (0.285, 0.03, 0.56)

CAMERA_TARGET_Z = 0.62     # default scale, framed higher so a 16 pt overhang fits


# ---------------------------------------------------------------- curves


def catmull(points, steps=60):
    """A Catmull-Rom polyline through points (tuples), ends extrapolated."""
    pts = [tuple(2 * a - b for a, b in zip(points[0], points[1]))] + list(points)
    pts.append(tuple(2 * a - b for a, b in zip(points[-1], points[-2])))
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for j in range(steps):
            t = j / steps
            out.append(tuple(0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t
                                    + (-a + 3 * b - 3 * c + d) * t ** 3) for a, b, c, d in zip(p0, p1, p2, p3)))
    out.append(points[-1])
    return out


def profile(table, u):
    """Catmull-Rom through (u, value) knots, for a smooth width along the spine."""
    us = [k[0] for k in table]
    i = max(0, min(len(table) - 2, sum(1 for x in us if x <= u) - 1))
    v = [k[1] for k in table]
    v0 = v[i - 1] if i > 0 else 2 * v[0] - v[1]
    v3 = v[i + 2] if i + 2 < len(v) else 2 * v[-1] - v[-2]
    t = (u - us[i]) / (us[i + 1] - us[i])
    a, b, c, d = v0, v[i], v[i + 1], v3
    return 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t ** 3)


class Spine:
    def __init__(self):
        self.points = [Vector((x, 0.0, z)) for x, z in catmull(SPINE)]
        self.lengths = [0.0]
        for a, b in zip(self.points, self.points[1:]):
            self.lengths.append(self.lengths[-1] + (b - a).length)
        self.length = self.lengths[-1]

    def at(self, s):
        """Point and unit tangent at arc length s."""
        s = min(max(s, 0.0), self.length)
        i = 0
        while i < len(self.lengths) - 2 and self.lengths[i + 1] < s:
            i += 1
        a, b = self.points[i], self.points[i + 1]
        k = (s - self.lengths[i]) / max(1e-9, self.lengths[i + 1] - self.lengths[i])
        return a.lerp(b, k), (b - a).normalized()


def cap(x):
    x = min(max(x, 0.0), 1.0)
    return math.sqrt(1 - (1 - x) ** 2)


# ---------------------------------------------------------------- model


def body_mesh(spine):
    """Rings swept along the spine; returns the bmesh and each vertex's arc length."""
    L = spine.length
    bm = bmesh.new()
    arc = []
    top = bm.verts.new(spine.at(0)[0])
    arc.append(0.0)
    rings = []
    for i in range(1, RINGS):
        s = L * (1 - math.cos(math.pi * i / RINGS)) / 2
        centre, tangent = spine.at(s)
        normal = Vector((-tangent.z, 0.0, tangent.x))
        u = s / L
        shape = cap(s / TOP_CAP) * cap((L - s) / TIP_CAP)
        a, b = profile(WIDTH, u) * shape, profile(DEPTH, u) * shape
        ring = []
        for j in range(SEGMENTS):
            phi = TAU * j / SEGMENTS
            ring.append(bm.verts.new(centre + normal * (a * math.cos(phi)) + Vector((0, b * math.sin(phi), 0))))
            arc.append(s)
        rings.append(ring)
    bottom = bm.verts.new(spine.at(L)[0])
    arc.append(L)
    for j in range(SEGMENTS):
        k = (j + 1) % SEGMENTS
        bm.faces.new((top, rings[0][k], rings[0][j]))
        bm.faces.new((bottom, rings[-1][j], rings[-1][k]))
        for r in range(len(rings) - 1):
            bm.faces.new((rings[r][j], rings[r][k], rings[r + 1][k], rings[r + 1][j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm, arc


def flipper_mesh():
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=32, v_segments=20, radius=1.0)
    for v in bm.verts:
        x, y, z = v.co
        t = (1 - z) / 2  # 0 at the root, 1 at the paddle's end
        r = FLIP_R0 + (FLIP_R1 - FLIP_R0) * kit.smoothstep(t * 1.3)
        v.co = Vector((x * r, y * r * FLIP_FLAT, -t * FLIP_LEN))
    return bm


def body_material(rig):
    mat, shader = kit.material(
        "Mote satin graphite", kit.rgba(0.085, 0.085, 0.09), rough=0.6,
        **{"Specular IOR Level": 0.3, "Sheen Weight": 0.4, "Sheen Roughness": 0.35,
           "Sheen Tint": (0.78, 0.84, 0.92, 1.0)})
    kit.micro_bump(mat, shader, scale=520, strength=0.022)
    nodes, links = mat.node_tree.nodes, mat.node_tree.links

    # Phase shimmer: a cool band where the body crosses the stage edge's plane.
    # Object colour R = amount (keyed, zero outside stage-emerge), G = noise time.
    geo = nodes.new("ShaderNodeNewGeometry")
    info = nodes.new("ShaderNodeObjectInfo")
    split = nodes.new("ShaderNodeSeparateColor")
    links.new(info.outputs["Color"], split.inputs["Color"])
    offset = nodes.new("ShaderNodeVectorMath")
    offset.operation = "SUBTRACT"
    links.new(geo.outputs["Position"], offset.inputs[0])
    dist = nodes.new("ShaderNodeVectorMath")
    dist.operation = "DOT_PRODUCT"
    links.new(offset.outputs["Vector"], dist.inputs[0])
    rig.plane_nodes = (offset, dist)

    def math_node(op, a, b=None):
        node = nodes.new("ShaderNodeMath")
        node.operation = op
        for index, value in enumerate((a, b)):
            if value is None:
                continue
            if isinstance(value, (int, float)):
                node.inputs[index].default_value = value
            else:
                links.new(value, node.inputs[index])
        return node.outputs[0]

    d = dist.outputs["Value"]
    band = math_node("EXPONENT", math_node("MULTIPLY", math_node("POWER", math_node("DIVIDE", math_node("SUBTRACT", d, 0.012), 0.022), 2), -1))
    # Colour B = how far the tail is let out in front of the edge (hooking over it).
    tail = nodes.new("ShaderNodeAttribute")
    tail.attribute_name = "tailness"
    exempt = math_node("MULTIPLY", tail.outputs["Fac"], split.outputs["Blue"])
    inside = math_node("SUBTRACT", 1.0, exempt)
    amount = math_node("MULTIPLY", split.outputs["Red"], inside)
    noise = nodes.new("ShaderNodeTexNoise")
    noise.noise_dimensions = "4D"
    noise.inputs["Scale"].default_value = 34
    noise.inputs["Detail"].default_value = 2
    links.new(geo.outputs["Position"], noise.inputs["Vector"])
    links.new(split.outputs["Green"], noise.inputs["W"])
    sparkle = nodes.new("ShaderNodeMapRange")
    sparkle.inputs["From Min"].default_value = 0.38
    sparkle.inputs["From Max"].default_value = 0.72
    sparkle.inputs["To Min"].default_value = 0.25
    sparkle.inputs["To Max"].default_value = 1.6
    links.new(noise.outputs["Fac"], sparkle.inputs["Value"])
    glow = math_node("MULTIPLY", math_node("MULTIPLY", band, amount), sparkle.outputs["Result"])
    shader.inputs["Emission Color"].default_value = kit.rgba(0.74, 0.84, 1.0)
    links.new(math_node("MULTIPLY", glow, 2.2), shader.inputs["Emission Strength"])

    # Just above the edge the body thins out, as if still half inside the wall.
    thin = nodes.new("ShaderNodeMapRange")
    thin.inputs["From Min"].default_value = 0.0
    thin.inputs["From Max"].default_value = 0.09
    thin.inputs["To Min"].default_value = 0.55
    thin.inputs["To Max"].default_value = 0.0
    links.new(d, thin.inputs["Value"])
    fade = math_node("MULTIPLY", thin.outputs["Result"], amount)
    clear = nodes.new("ShaderNodeBsdfTransparent")
    mix = nodes.new("ShaderNodeMixShader")
    links.new(fade, mix.inputs["Fac"])
    links.new(shader.outputs["BSDF"], mix.inputs[1])
    links.new(clear.outputs["BSDF"], mix.inputs[2])

    # The ledge holdout: in ledge clips (alpha = 1) everything behind the edge's
    # plane is cut out, except the tail while it hooks over the edge. The plane
    # passes through the camera, so the cut is the straight stage edge.
    below = math_node("LESS_THAN", d, 0.0)
    hide = math_node("MULTIPLY", math_node("MULTIPLY", below, info.outputs["Alpha"]), inside)
    holdout = nodes.new("ShaderNodeHoldout")
    cut = nodes.new("ShaderNodeMixShader")
    links.new(hide, cut.inputs["Fac"])
    links.new(mix.outputs["Shader"], cut.inputs[1])
    links.new(holdout.outputs["Holdout"], cut.inputs[2])
    output = next(n for n in nodes if n.type == "OUTPUT_MATERIAL")
    links.new(cut.outputs["Shader"], output.inputs["Surface"])
    return mat


def build():
    rig = kit.Rig()
    spine = Spine()
    L = spine.length

    rig.root = kit.empty("Float")
    rig.inflate = kit.empty("Inflate", rig.root, (0, 0, FACE_Z))
    rig.lean = kit.empty("Lean", rig.inflate, (0, 0, CENTRE_Z - FACE_Z))
    rig.squash = kit.empty("Squash", rig.lean)
    for obj in (rig.root, rig.inflate, rig.lean, rig.squash):
        obj.rotation_mode = "XYZ"

    # Armature: a still body bone and a four-bone tail chain along the spine.
    arm_data = bpy.data.armatures.new("Mote rig")
    arm = kit.link(bpy.data.objects.new("Mote rig", arm_data), rig.squash)
    arm.location = (0, 0, -CENTRE_Z)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    body_bone = arm_data.edit_bones.new("body")
    body_bone.head = spine.at(TAIL_START * L)[0]
    body_bone.tail = spine.at(0.15 * L)[0]
    joints = [TAIL_START * L + (L - TAIL_START * L) * k / N_TAIL for k in range(N_TAIL + 1)]
    parent = body_bone
    names = []
    for k in range(N_TAIL):
        bone = arm_data.edit_bones.new(f"tail{k}")
        bone.head = spine.at(joints[k])[0]
        bone.tail = spine.at(joints[k + 1])[0]
        bone.align_roll(Vector((0, -1, 0)))  # local Z toward the camera: curl in the front plane
        bone.parent = parent
        bone.use_connect = k > 0
        bone.inherit_scale = "NONE"  # each bone stretches on its own
        parent = bone
        names.append(bone.name)
    bpy.ops.object.mode_set(mode="OBJECT")
    rig.arm = arm
    rig.tail = [arm.pose.bones[name] for name in names]
    for pb in rig.tail:
        pb.rotation_mode = "XYZ"

    mat = body_material(rig)
    bm, arc = body_mesh(spine)
    body = kit.mesh_object("Mote body", bm, arm, mat, subdivisions=0)
    groups = {name: body.vertex_groups.new(name=name) for name in ["body"] + names}
    centres = [joints[0] - 0.1] + [(joints[k] + joints[k + 1]) / 2 for k in range(N_TAIL)]
    bones = ["body"] + names
    for index, s in enumerate(arc):
        if s <= centres[0]:
            groups["body"].add([index], 1.0, "REPLACE")
            continue
        if s >= centres[-1]:
            groups[bones[-1]].add([index], 1.0, "REPLACE")
            continue
        k = max(i for i in range(len(centres)) if centres[i] <= s)
        w = kit.smoothstep((s - centres[k]) / (centres[k + 1] - centres[k]))
        groups[bones[k]].add([index], 1 - w, "REPLACE")
        groups[bones[k + 1]].add([index], w, "REPLACE")
    tailness = body.data.color_attributes.new("tailness", "FLOAT_COLOR", "POINT")
    for index, s in enumerate(arc):
        k = kit.smoothstep((s / L - 0.7) / 0.1)
        tailness.data[index].color = (k, k, k, 1.0)
    skin = body.modifiers.new("Armature", "ARMATURE")
    skin.object = arm
    sub = body.modifiers.new("Subdivision", "SUBSURF")
    sub.levels = sub.render_levels = 2
    rig.body = body

    rig.flippers = {}
    for side in (-1, 1):
        shoulder = kit.empty(f"Shoulder {'L' if side < 0 else 'R'}", arm,
                             (side * SHOULDER[0], SHOULDER[1], SHOULDER[2]))
        shoulder.rotation_mode = "XYZ"
        kit.mesh_object(f"Flipper {'L' if side < 0 else 'R'}", flipper_mesh(), shoulder, mat)
        rig.flippers[side] = shoulder

    # The face: where the live eyes sit, on the front surface at eye height.
    depsgraph = bpy.context.evaluated_depsgraph_get()
    bvh = BVHTree.FromObject(body.evaluated_get(depsgraph), depsgraph)
    hit, _, _, _ = bvh.ray_cast(Vector((0, -2, FACE_Z)), Vector((0, 1, 0)))
    rig.face = kit.empty("Face", arm, (0, hit.y - 0.004, FACE_Z))
    rig.inflate.location = (0, hit.y, FACE_Z)
    rig.lean.location = (0, -hit.y, CENTRE_Z - FACE_Z)
    kit.preview_eyes(rig)

    rig.keyed = [rig.root, rig.inflate, rig.lean, rig.squash, *rig.flippers.values()]
    global RIG
    RIG = rig  # stage() places the edge plane once the camera exists
    return rig


RIG = None


def stage(scene, camera):
    """Solves the stage edge 10 pt below the ground, where the base clips put the
    island's bottom, and aims the holdout plane through it and the camera."""
    bpy.context.view_layer.update()
    ground = kit.project(scene, camera, Vector((0, 0, GROUND_Z))).y
    target = round(ground, 4) + 10 / 150
    lo, hi = -1.0, 0.5
    for _ in range(60):
        mid = (lo + hi) / 2
        if kit.project(scene, camera, Vector((0, 0, mid))).y > target:
            lo = mid
        else:
            hi = mid
    edge = Vector((0, 0, (lo + hi) / 2))
    for name, clip in CLIPS.items():
        if clip.ledge is not None:
            CLIPS[name] = clip._replace(ledge=tuple(edge))
    away = (edge - camera.matrix_world.translation).normalized()
    normal = Vector((1, 0, 0)).cross(away).normalized()
    if normal.z < 0:
        normal = -normal
    offset, dist = RIG.plane_nodes
    offset.inputs[1].default_value = edge
    dist.inputs[1].default_value = normal


# ---------------------------------------------------------------- poses


def rest():
    return dict(x=0.0, z=0.0, yaw=0.0, pitch=0.0, roll=0.0, inflate=1.0, squash=1.0,
                fl=0.0, fr=0.0, sl=0.0, sr=0.0, twl=0.0, twr=0.0,
                curl=[0.0] * N_TAIL, fwd=[0.0] * N_TAIL, stretch=[1.0] * N_TAIL,
                shimmer=0.0, glint=0.0, hook=0.0, ledge=0.0)


def mix(a, b, k):
    return {key: ([x + (y - x) * k for x, y in zip(a[key], b[key])] if isinstance(a[key], list)
                  else a[key] + (b[key] - a[key]) * k) for key in a}


def wag(amp, phase, lag=0.7, grow=(0.35, 0.6, 0.85, 1.0)):
    """A wave travelling down the tail, growing toward the tip."""
    return [amp * g * math.sin(phase - i * lag) for i, g in enumerate(grow)]


def spread(amount):
    """Curls the tail up (positive) by opening its root and rolling its tip, so
    it never folds into the body; droops it (negative) from the root."""
    grow = (-0.3, 0.05, 0.45, 0.6) if amount > 0 else (0.12, 0.24, 0.32, 0.32)
    return [amount * g for g in grow]


def plus(a, b):
    return [x + y for x, y in zip(a, b)]


def last(seconds):
    return (round(seconds * FPS) - 1) / FPS


def window(t, a, b, c, d):
    """Rises over [a, b], falls over [c, d]."""
    return kit.smoothstep((t - a) / (b - a)) * (1 - kit.smoothstep((t - c) / (d - c)))


def settle(p, t, seconds, loop, loop_seconds, start, turns=0):
    """Hands over to the loop's own clock so the last frame is exactly its frame 0
    (plus whole turns of roll, which look the same and keep blur unwound)."""
    end = last(seconds)
    target = loop(t - end, loop_seconds)
    target["roll"] += TAU * turns
    return mix(p, target, kit.smoothstep((t - start) / (end - start)))


IDLE_S, WORK_S, WAIT_S, SAD_S = 3.0, 1.6, 1.75, 3.6


def idle(t, seconds):
    """Hovering: a slow buoyant bob and breath; flippers and tail answer late."""
    p = rest()
    ph = TAU * t / seconds
    p["z"] = 0.022 * math.sin(ph)
    p["x"] = 0.006 * math.sin(ph + 1.3)
    p["squash"] = 1 + 0.016 * math.sin(ph + 0.5)
    p["roll"] = math.radians(1.6) * math.sin(ph - 0.6)
    p["fl"] = 0.035 + 0.09 * math.sin(ph - 1.1)
    p["fr"] = 0.035 + 0.09 * math.sin(ph - 1.35)
    p["sl"] = p["sr"] = 0.05 * math.sin(ph - 1.6)
    p["curl"] = wag(0.09, ph - 1.2)
    p["fwd"] = wag(0.05, ph - 1.9)
    return p


def work(t, seconds):
    """Busy: leans in and bustles side to side, flippers paddling, tail wagging."""
    p = rest()
    ph = TAU * t / seconds
    p["pitch"] = math.radians(8) + math.radians(2) * math.sin(2 * ph - 0.5)
    p["z"] = 0.012 + 0.016 * math.sin(2 * ph)
    p["x"] = 0.016 * math.sin(ph)
    p["roll"] = -math.radians(4) * math.sin(ph - 0.35)
    p["yaw"] = math.radians(5) * math.sin(ph - 0.2)
    p["squash"] = 1 + 0.03 * math.sin(2 * ph - 0.6)
    p["sl"] = -0.55 + 0.5 * math.sin(4 * ph)
    p["sr"] = -0.55 + 0.5 * math.sin(4 * ph + math.pi)
    p["fl"] = 0.32 + 0.16 * math.sin(4 * ph + 1.4)
    p["fr"] = 0.32 + 0.16 * math.sin(4 * ph + 1.4 + math.pi)
    p["twl"] = 0.25 * math.sin(4 * ph + 0.6)
    p["twr"] = 0.25 * math.sin(4 * ph + 0.6 + math.pi)
    p["curl"] = plus(spread(0.25), wag(0.2, 2 * ph - 0.8))
    p["fwd"] = wag(0.08, ph - 1.0)
    return p


def wave(t, seconds):
    """Hello: a dip, the screen-right flipper swings up and waves, the body counters."""
    p = idle(t, IDLE_S)
    up = window(t, 0.16, 0.48, 1.55, 1.95)
    waving = up * math.sin(TAU * max(0.0, t - 0.48) / 0.4)
    dip = math.sin(math.pi * min(1, t / 0.32)) if t < 0.32 else 0.0
    p["z"] += -0.025 * dip + 0.035 * window(t, 0.2, 0.55, 1.5, 2.0)
    p["squash"] += -0.05 * dip + 0.03 * window(t, 0.25, 0.5, 0.6, 0.9) + 0.012 * waving
    p["fr"] += 2.05 * up + 0.32 * waving
    p["twr"] += 0.35 * up
    p["sr"] += -0.25 * up
    p["fl"] += -0.12 * up + 0.05 * math.sin(TAU * max(0.0, t - 0.6) / 0.4) * up
    p["roll"] += -math.radians(7) * up - math.radians(1.5) * up * math.sin(TAU * max(0.0, t - 0.55) / 0.4)
    p["pitch"] += math.radians(3) * up
    p["yaw"] += math.radians(4) * up
    p["curl"] = plus(p["curl"], plus(spread(0.35 * up), wag(0.16 * up, TAU * max(0.0, t - 0.62) / 0.4)))
    return settle(p, t, seconds, idle, IDLE_S, 1.75)


def wait(t, seconds):
    """Asking: eager double bobs with lifted flippers and a tail flick."""
    p = idle(t, seconds)
    hop = lambda start: math.sin(math.pi * min(1, max(0, (t - start) / 0.3))) if start <= t <= start + 0.3 else 0.0
    rise = hop(0.06) + 0.75 * hop(0.42)
    crouch = kit.pulse(t, 0.0, 0.12) + kit.pulse(t, 0.34, 0.12)
    p["z"] += 0.05 * rise
    p["squash"] += 0.05 * rise - 0.05 * crouch
    lift = kit.pulse(t, 0.08, 0.44) + 0.7 * kit.pulse(t, 0.44, 0.44)
    p["fl"] += 0.42 * lift
    p["fr"] += 0.42 * lift
    p["sl"] += -0.2 * lift
    p["sr"] += -0.2 * lift
    p["pitch"] += math.radians(4) * lift
    p["curl"] = plus(p["curl"], wag(0.28 * kit.pulse(t, 0.1, 1.0), TAU * (t - 0.1) / 0.5))
    return p


def done(t, seconds):
    """Celebrates: a crouch, one swooping counter-clockwise loop with the tail
    trailing and flippers up, a stretched 'ta-da', then a floaty settle."""
    p = idle(t, IDLE_S)
    crouch = window(t, 0.0, 0.22, 0.26, 0.4)
    p["z"] += -0.04 * crouch
    p["squash"] += -0.12 * crouch
    p["sl"] += 0.3 * crouch
    p["sr"] += 0.3 * crouch
    p["fl"] += -0.25 * crouch
    p["fr"] += -0.25 * crouch
    p["curl"] = plus(p["curl"], spread(0.3 * crouch))

    a, b = 0.28, 1.1
    theta = TAU * kit.ease_in_out((t - a) / (b - a))
    speed = math.sin(math.pi * min(1.0, max(0.0, (t - a) / (b - a))))
    r = 0.1
    lift = window(t, 0.26, 0.6, 1.45, 2.2)
    p["x"] += r * math.sin(theta)
    p["z"] += r * (1 - math.cos(theta)) + 0.05 * lift
    p["roll"] += -theta
    tada = window(t, 1.02, 1.2, 1.38, 1.65)
    p["squash"] += 0.08 * speed + 0.09 * tada - 0.05 * window(t, 1.62, 1.78, 1.82, 2.1)
    p["curl"] = plus(p["curl"], plus(spread(0.35 * speed - 0.15 * tada), wag(0.12 * speed + 0.1 * tada, TAU * t / 0.42)))
    raised = window(t, 0.3, 0.55, 1.55, 2.2)
    flutter = math.sin(TAU * max(0.0, t - 1.1) / 0.2) * window(t, 1.1, 1.2, 1.45, 1.65)
    p["fl"] += 1.5 * raised + 0.2 * flutter
    p["fr"] += 1.5 * raised - 0.2 * flutter
    p["sl"] += -0.25 * raised
    p["sr"] += -0.25 * raised
    p["twl"] += 0.3 * raised
    p["twr"] += 0.3 * raised
    return settle(p, t, seconds, idle, IDLE_S, 1.85, turns=-1)


SAD = dict(z=-0.065, squash=0.92, pitch=math.radians(6), fl=-0.12, fr=-0.12)


def sad(t, seconds):
    """Low and slow: drifts side to side, leaning into it, tail trailing."""
    p = rest()
    ph = TAU * t / seconds
    p["x"] = 0.045 * math.sin(ph)
    p["z"] = SAD["z"] + 0.012 * math.sin(2 * ph + 0.8)
    p["squash"] = SAD["squash"] + 0.012 * math.sin(2 * ph)
    p["pitch"] = SAD["pitch"] + math.radians(1.2) * math.sin(2 * ph + 0.4)
    p["roll"] = math.radians(4.5) * math.cos(ph - 0.3)
    p["yaw"] = math.radians(6) * math.cos(ph - 0.2)
    p["fl"] = SAD["fl"] + 0.06 * math.sin(ph - 1.6)
    p["fr"] = SAD["fr"] - 0.06 * math.sin(ph - 1.6)
    p["sl"] = p["sr"] = 0.12
    p["curl"] = plus(spread(-0.35), wag(0.16, ph - 2.0, lag=0.5))
    return p


def fail(t, seconds):
    """A startled shiver that runs down to the tail, then a sigh and a slump."""
    p = idle(t, IDLE_S)
    jolt = window(t, 0.0, 0.08, 0.1, 0.3)
    shiver = window(t, 0.06, 0.14, 0.6, 0.95)
    # Shiver periods span three to four frames so 24 fps does not alias them away.
    buzz = math.sin(TAU * t / 0.125)
    p["squash"] += 0.06 * jolt + 0.03 * shiver * math.sin(TAU * t / 0.16)
    p["z"] += 0.02 * jolt
    p["x"] += 0.022 * shiver * buzz
    p["roll"] += math.radians(4) * shiver * math.sin(TAU * t / 0.125 + 1.6)
    p["fl"] += 0.35 * jolt + 0.15 * shiver * math.sin(TAU * t / 0.14 + 0.5)
    p["fr"] += 0.35 * jolt + 0.15 * shiver * math.sin(TAU * t / 0.14 + 2.0)
    p["curl"] = plus(p["curl"], wag(0.25 * shiver, TAU * t / 0.16, lag=1.1))
    sigh = window(t, 1.0, 1.25, 1.3, 1.6)
    p["squash"] += 0.035 * sigh
    p["z"] += 0.012 * sigh
    return settle(p, t, seconds, sad, SAD_S, 0.85)


def emerge(t, seconds):
    """Condenses around the eyes: a twist of smoke that inflates, squashes,
    pops the flippers out and last of all lets the tail out with a flick."""
    p = idle(0.0, IDLE_S)
    grow = kit.spring(t, 0.5, 0.5)
    p["inflate"] = 0.05 + 0.95 * grow
    s = max(0.0, t - 0.1)
    p["squash"] = 1 + 0.16 * math.exp(-6 * s) * math.cos(TAU * s / 0.42)
    p["roll"] = math.radians(28) * math.exp(-5.5 * t) * math.cos(TAU * t / 0.9)
    tuck = 1 - kit.spring(t - 0.22, 0.42, 0.4)
    p["fl"] += -0.45 * tuck
    p["fr"] += -0.45 * tuck
    out = kit.spring(t - 0.42, 0.38, 0.38)
    p["stretch"] = [0.75 + 0.25 * out] * N_TAIL
    p["curl"] = plus(p["curl"], spread(-0.8 * (1 - out)))  # a hanging wisp that flicks to the side
    return settle(p, t, seconds, idle, IDLE_S, 0.75)


def stage_emerge(t, seconds):
    """Phase through: rises up through the stage edge, streamlined, with a
    shimmer where it crosses; the tail comes out last, hooks down over the
    edge for a beat, then flicks free and Mote bobs up into its hover."""
    p = idle(0.0, IDLE_S)
    p["ledge"] = 1.0
    hold_z = -0.16
    x = min(1.0, t / 0.62)
    rise = 1 - (1 - x) ** 3
    release = kit.spring(t - 0.92, 0.45, 0.5)
    p["z"] = -1.25 + (hold_z + 1.25) * rise - hold_z * release
    speed = 3 * (1 - x) ** 2 if t < 0.62 else 0.0
    p["squash"] = 1 + 0.035 * speed - 0.03 * window(t, 0.6, 0.7, 0.75, 0.9) + 0.04 * kit.pulse(t, 0.9, 0.35)
    p["shimmer"] = 1 - kit.smoothstep((t - 0.5) / 0.3)
    p["glint"] = 3 * t
    streamline = 1 - kit.spring(t - 0.58, 0.4, 0.42)
    p["fl"] += -0.35 * streamline
    p["fr"] += -0.35 * streamline
    p["sl"] += 0.35 * streamline
    p["sr"] += 0.35 * streamline
    # The tail: let out in front of the edge, hanging down with its tip hooked,
    # stretched while the body pulls up, then whipped free.
    hook = window(t, 0.4, 0.62, 0.9, 1.05)
    p["hook"] = window(t, 0.38, 0.55, 0.98, 1.1)
    flick = kit.pulse(t, 0.95, 0.4)
    p["curl"] = plus(p["curl"], plus([-0.45 * hook, -0.5 * hook, 0.45 * hook, 1.3 * hook], spread(1.1 * flick)))
    p["stretch"] = [1 + 0.34 * hook + 0.1 * flick] * N_TAIL
    p["fwd"] = plus(p["fwd"], [0.12 * hook, 0.1 * hook, 0.0, -0.1 * hook])
    p["roll"] += math.radians(4) * window(t, 0.55, 0.7, 0.85, 1.0) - math.radians(5) * kit.pulse(t, 0.95, 0.4)
    return settle(p, t, seconds, idle, IDLE_S, 1.2)


CLIPS = {
    "emerge": kit.Clip(emerge, 1.1, False),
    "idle": kit.Clip(idle, IDLE_S, True),
    "work": kit.Clip(work, WORK_S, True),
    "done": kit.Clip(done, 2.6, False),
    "wave": kit.Clip(wave, 2.2, False),
    "wait": kit.Clip(wait, WAIT_S, True),
    "fail": kit.Clip(fail, 2.0, False),
    "sad": kit.Clip(sad, SAD_S, True),
    # Ledge solved in stage(); the placeholder only marks it as a ledge clip.
    "stage-emerge": kit.Clip(stage_emerge, 1.7, False, (0.0, 0.0, 0.0)),
}


def apply_pose(rig, p):
    rig.root.location = (p["x"], 0, p["z"])
    rig.inflate.scale = (p["inflate"],) * 3
    rig.lean.rotation_euler = (p["pitch"], p["roll"], p["yaw"])
    s = max(0.3, p["squash"])
    side = 1 / math.sqrt(s)
    rig.squash.scale = (side, side, s)
    rig.flippers[-1].rotation_euler = (p["sl"], FLIP_REST + p["fl"], -p["twl"])
    rig.flippers[1].rotation_euler = (p["sr"], -(FLIP_REST + p["fr"]), p["twr"])
    for pb, curl, fwd, stretch in zip(rig.tail, p["curl"], p["fwd"], p["stretch"]):
        pb.rotation_euler = (fwd, 0, -curl)
        pb.scale = (1, stretch, 1)
    rig.body.color = (p["shimmer"], p["glint"], p["hook"], p["ledge"])


def keyframe(rig):
    for pb in rig.tail:
        pb.keyframe_insert("rotation_euler")
        pb.keyframe_insert("scale")
    rig.body.keyframe_insert("color")


# ---------------------------------------------------------------- checks


def same(a, b, tol=1e-6):
    for key in a:
        va, vb = (a[key], b[key]) if isinstance(a[key], list) else ([a[key]], [b[key]])
        for x, y in zip(va, vb):
            d = x - y
            if key == "roll":
                d = (d + math.pi) % TAU - math.pi
            if key == "ledge":
                continue
            if abs(d) > tol:
                return False
    return True


def check():
    """The app hard-cuts between these, so they must meet exactly."""
    def end(name):
        clip = CLIPS[name]
        return clip.function(last(clip.seconds), clip.seconds)

    def start(name):
        clip = CLIPS[name]
        return clip.function(0.0, clip.seconds)

    pairs = [("emerge", "idle"), ("stage-emerge", "idle"), ("done", "idle"), ("wave", "idle"),
             ("wave", "wait"), ("fail", "sad")]
    for a, b in pairs:
        assert same(end(a), start(b)), f"{a} does not end on {b} frame 0"
    for name in ("done", "wave", "fail"):
        assert same(start(name), start("idle")), f"{name} does not start on idle frame 0"
    for name, clip in CLIPS.items():
        if clip.loops:
            assert same(clip.function(clip.seconds, clip.seconds), start(name)), f"{name} does not close"


check()
kit.run(sys.modules[__name__])
