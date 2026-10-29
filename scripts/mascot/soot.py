"""Soot: a squat, plush soot-sprite with a dark oval face, for Notch Companion.

One rounded head/body volume with a slight pear belly, two small round ears,
short mitten arms and wide oval feet, all covered in short charcoal fur grown
by a geometry-nodes groom (real Cycles hair curves that ride every object
transform, so they motion-blur with the rig). The face is a smooth near-black
oval almost flush with the fur; the app draws the live eyes on it.

Signature: on the popup stage Soot hangs on a windowsill (the stage's bottom
edge). A holdout plane hides the lower body; the mittens grip over the edge in
front of it, so they may overhang the island by a few points.

    scripts/render-mascot.sh soot --turnaround --eyes
    scripts/render-mascot.sh soot --preview idle,stage-idle --eyes
"""

import bpy
import bmesh
import math
import os
import sys
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mascot_kit as kit  # noqa: E402
from mascot_kit import pulse, smoothstep, spring  # noqa: E402

ID = "soot"
EYE_UNIT = 0.0135

FACE_Z = 0.62        # face centre height at rest
FACE_W, FACE_H = 0.262, 0.178   # half extents of the hairless oval
BODY_Z0, BODY_Z1 = 0.05, 0.87   # skin bottom and crown
GROW_Z = FACE_Z      # emerge inflates around the face centre

# Windowsill: the stage's bottom edge, in world units. Stage clips scale Soot
# up and place it so head and shoulders fill the frame above this edge.
SILL_Z = 0.24
SILL_Y = -0.70
STAGE_SCALE = 1.75
LEDGE = (0.0, SILL_Y, SILL_Z)
MITTEN = 0.19  # shoulder to mitten centre at rest

# ---------------------------------------------------------------- materials


def build_materials():
    m = {}
    skin, shader = kit.material("Soot skin", kit.rgba(0.07, 0.068, 0.072), rough=0.85,
                                **{"Sheen Weight": 0.6, "Sheen Roughness": 0.5})
    m["skin"] = skin

    # Satin, not glass: dim broad reflections so the white eyes stay the only marks.
    face, shader = kit.material("Soot face", kit.rgba(0.012, 0.012, 0.014), rough=0.66,
                                **{"Specular IOR Level": 0.12})
    kit.micro_bump(face, shader, scale=90, strength=0.01)
    m["face"] = face

    fur = bpy.data.materials.new("Soot fur")
    try:
        fur.use_nodes = True
    except AttributeError:
        pass
    nodes, links = fur.node_tree.nodes, fur.node_tree.links
    hair = nodes["Principled BSDF"]
    for key, value in (("Roughness", 0.55), ("Specular IOR Level", 0.35), ("Sheen Weight", 0.0)):
        hair.inputs[key].default_value = value
    info = nodes.new("ShaderNodeHairInfo")
    ramp = nodes.new("ShaderNodeValToRGB")
    # Darker roots, subtly lighter tips.
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (0.010, 0.010, 0.011, 1)
    ramp.color_ramp.elements[1].position = 1.0
    ramp.color_ramp.elements[1].color = (0.045, 0.044, 0.046, 1)
    links.new(info.outputs["Intercept"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], hair.inputs["Base Color"])
    m["fur"] = fur
    return m


# ---------------------------------------------------------------- fur groom


def fur_group():
    """Mesh in, mesh plus groomed hair curves out. Reads the mesh's `fur`
    vertex group (density) and `comb` vector attribute (lie direction)."""
    ng = bpy.data.node_groups.new("Soot fur", "GeometryNodeTree")
    io = ng.interface
    io.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    io.new_socket("Surface", in_out="INPUT", socket_type="NodeSocketObject")
    for name, kind, value in (("Density", "NodeSocketFloat", 20000.0), ("Length", "NodeSocketFloat", 0.04),
                              ("Radius", "NodeSocketFloat", 0.0022), ("Fluff", "NodeSocketFloat", 1.0),
                              ("Sway", "NodeSocketVector", None), ("Seed", "NodeSocketInt", 0),
                              ("Material", "NodeSocketMaterial", None)):
        socket = io.new_socket(name, in_out="INPUT", socket_type=kind)
        if value is not None:
            socket.default_value = value
    io.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    N, L = ng.nodes, ng.links
    gi, go = N.new("NodeGroupInput"), N.new("NodeGroupOutput")

    def node(kind, **props):
        n = N.new(kind)
        for k, v in props.items():
            setattr(n, k, v)
        return n

    def attr(name, kind="FLOAT_VECTOR"):
        n = node("GeometryNodeInputNamedAttribute", data_type=kind)
        n.inputs["Name"].default_value = name
        return n.outputs["Attribute"]

    def vmath(op, a, b=None, scale=None):
        n = node("ShaderNodeVectorMath", operation=op)
        L.new(a, n.inputs[0])
        if b is not None:
            if isinstance(b, (tuple, list)):
                n.inputs[1].default_value = b
            else:
                L.new(b, n.inputs[1])
        if scale is not None:
            if isinstance(scale, (int, float)):
                n.inputs["Scale"].default_value = scale
            else:
                L.new(scale, n.inputs["Scale"])
        return n.outputs[0]

    def math_(op, a, b=None, c=None):
        n = node("ShaderNodeMath", operation=op)
        for i, v in enumerate((a, b, c)):
            if v is None:
                continue
            if isinstance(v, (int, float)):
                n.inputs[i].default_value = v
            else:
                L.new(v, n.inputs[i])
        return n.outputs[0]

    # Hair lives on its own Curves object (Cycles renders only those as hair),
    # parented to the surface with an identity offset so both share a space.
    surface = node("GeometryNodeObjectInfo", transform_space="ORIGINAL")
    L.new(gi.outputs["Surface"], surface.inputs["Object"])
    dist = node("GeometryNodeDistributePointsOnFaces", distribute_method="RANDOM")
    L.new(surface.outputs["Geometry"], dist.inputs["Mesh"])
    L.new(math_("MULTIPLY", gi.outputs["Density"], attr("fur", "FLOAT")), dist.inputs["Density"])
    L.new(gi.outputs["Seed"], dist.inputs["Seed"])

    points = dist.outputs["Points"]
    for name, kind, value in (("fn", "FLOAT_VECTOR", dist.outputs["Normal"]),):
        store = node("GeometryNodeStoreNamedAttribute", data_type=kind, domain="POINT")
        store.inputs["Name"].default_value = name
        L.new(points, store.inputs["Geometry"])
        L.new(value, store.inputs["Value"])
        points = store.outputs["Geometry"]
    jitter = node("FunctionNodeRandomValue", data_type="FLOAT_VECTOR")
    jitter.inputs["Min"].default_value = (-1, -1, -1)
    jitter.inputs["Max"].default_value = (1, 1, 1)
    length = node("FunctionNodeRandomValue", data_type="FLOAT")
    length.inputs["Min"].default_value = 0.65
    length.inputs["Max"].default_value = 1.15
    for name, kind, value in (("fj", "FLOAT_VECTOR", jitter.outputs[0]), ("fl", "FLOAT", length.outputs[0])):
        store = node("GeometryNodeStoreNamedAttribute", data_type=kind, domain="POINT")
        store.inputs["Name"].default_value = name
        L.new(points, store.inputs["Geometry"])
        L.new(value, store.inputs["Value"])
        points = store.outputs["Geometry"]

    line = node("GeometryNodeCurvePrimitiveLine")
    line.inputs["End"].default_value = (0, 0, 1)
    resample = node("GeometryNodeResampleCurve")
    resample.inputs["Count"].default_value = 4
    L.new(line.outputs[0], resample.inputs["Curve"])
    instances = node("GeometryNodeInstanceOnPoints")
    L.new(points, instances.inputs["Points"])
    L.new(resample.outputs[0], instances.inputs["Instance"])
    realize = node("GeometryNodeRealizeInstances")
    L.new(instances.outputs[0], realize.inputs[0])

    u = node("GeometryNodeSplineParameter").outputs["Factor"]
    position = node("GeometryNodeInputPosition").outputs[0]
    lift = node("ShaderNodeCombineXYZ")
    L.new(u, lift.inputs["Z"])
    root = vmath("SUBTRACT", position, lift.outputs[0])
    # Straight out at the root, bending into the comb toward the tip.
    stand = vmath("SCALE", attr("fn"), scale=math_("MULTIPLY", u, 0.62))
    lie = vmath("SCALE", attr("comb"), scale=math_("MULTIPLY", u, math_("MULTIPLY_ADD", u, 0.55, 0.3)))
    frizz = vmath("SCALE", attr("fj"), scale=math_("MULTIPLY", u, 0.17))
    sway = vmath("SCALE", gi.outputs["Sway"], scale=math_("MULTIPLY", u, u))
    direction = vmath("ADD", vmath("ADD", stand, lie), vmath("ADD", frizz, sway))
    reach = math_("MULTIPLY", math_("MULTIPLY", gi.outputs["Length"], gi.outputs["Fluff"]), attr("fl", "FLOAT"))
    set_position = node("GeometryNodeSetPosition")
    L.new(realize.outputs[0], set_position.inputs["Geometry"])
    L.new(vmath("ADD", root, vmath("SCALE", direction, scale=reach)), set_position.inputs["Position"])

    radius = node("GeometryNodeSetCurveRadius")
    L.new(set_position.outputs[0], radius.inputs["Curve"])
    L.new(math_("MULTIPLY", gi.outputs["Radius"], math_("MULTIPLY_ADD", u, -0.75, 1.0)), radius.inputs["Radius"])
    set_material = node("GeometryNodeSetMaterial")
    L.new(radius.outputs[0], set_material.inputs["Geometry"])
    L.new(gi.outputs["Material"], set_material.inputs["Material"])

    L.new(set_material.outputs[0], go.inputs[0])
    return ng


FUR = {}
# Review-only knob: `--fur 0.3` grows fewer strands for quick, light previews.
FUR_DENSITY = float(kit.arg("--fur", "1"))


def add_fur(obj, group, fur_mat, density, length, radius=0.0022, seed=0):
    hair = kit.link(bpy.data.objects.new(f"{obj.name} fur", bpy.data.hair_curves.new(f"{obj.name} fur")), obj)
    hair.data.materials.append(fur_mat)
    mod = hair.modifiers.new("Fur", "NODES")
    mod.node_group = group
    ids = {item.name: item.identifier for item in group.interface.items_tree if item.item_type == "SOCKET" and item.in_out == "INPUT"}
    for key, value in (("Surface", obj), ("Density", density * FUR_DENSITY), ("Length", length), ("Radius", radius), ("Seed", seed), ("Material", fur_mat)):
        getattr(mod.properties.inputs, ids[key]).value = value
    inputs = {key: getattr(mod.properties.inputs, socket) for key, socket in ids.items()}
    inputs["_length"] = length
    FUR[obj.name] = (hair, inputs)
    return mod


def groom(obj, comb_fn, density_fn=None):
    """Bakes per-vertex lie direction (`comb`, tangent) and density (`fur`)."""
    mesh = obj.data
    mesh.update()
    group = obj.vertex_groups.new(name="fur")
    comb = mesh.attributes.new("comb", "FLOAT_VECTOR", "POINT")
    for v in mesh.vertices:
        n = v.normal
        want = Vector(comb_fn(v.co, n))
        tangent = want - n * want.dot(n)
        if tangent.length < 1e-4:
            tangent = n.orthogonal()
        comb.data[v.index].vector = tangent.normalized()
        group.add([v.index], density_fn(v.co, n) if density_fn else 1.0, "REPLACE")


# ---------------------------------------------------------------- geometry


def body_bmesh():
    """Squat gumdrop with a slight pear belly and a soft, flat-ish base."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=96, v_segments=64, radius=1.0)
    height = BODY_Z1 - BODY_Z0
    for v in bm.verts:
        x, y, z = v.co
        lat = math.asin(max(-1.0, min(1.0, z)))
        h = math.hypot(x, y)
        dx, dy = (x / h, y / h) if h > 1e-9 else (0.0, 0.0)
        # Rounder crown, fuller and flatter underside.
        sz = math.copysign(abs(math.sin(lat)) ** (0.95 if lat > 0 else 0.62), lat)
        sr = abs(math.cos(lat)) ** (0.85 if lat > 0 else 0.55)
        k = 0.5 + 0.5 * sz  # 0 base .. 1 crown
        pear = 1.0 + 0.10 * (0.42 - k) - 0.06 * max(0.0, k - 0.75) ** 2 * 4
        half_w, half_d = 0.355 * pear, 0.315 * pear
        # The belly sits a touch forward; the back stays rounded.
        belly = -0.025 * math.exp(-((k - 0.33) / 0.25) ** 2) if dy < 0 else 0.0
        if dy < 0:  # a squarer, flatter front carries the shallow face
            n = 2.0 + 0.9 * math.exp(-((k - 0.68) / 0.28) ** 2)
            dx, dy = math.copysign(abs(dx) ** (2 / n), dx), -abs(dy) ** (2 / n)
        v.co = Vector((half_w * sr * dx, half_d * sr * dy + belly * sr, BODY_Z0 + height * k))
    return bm


def ellipsoid(rx, ry, rz, u=48, v=32):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=u, v_segments=v, radius=1.0)
    bmesh.ops.scale(bm, vec=(rx, ry, rz), verts=bm.verts)
    return bm


def foot_bmesh():
    """Short, wide oval with a flat sole."""
    bm = ellipsoid(0.105, 0.135, 0.07)
    for v in bm.verts:
        if v.co.z < -0.02:
            v.co.z = -0.02 - (-(v.co.z) - 0.02) * 0.25
    return bm


def flat_mesh(name, bm, parent, mat, smooth=True):
    obj = kit.mesh_object(name, bm, parent, mat, smooth=smooth, subdivisions=0)
    return obj


def build():
    m = build_materials()
    group = fur_group()
    rig = kit.Rig()
    rig.root = kit.empty("Root")
    rig.inflate = kit.empty("Inflate", rig.root, (0, -0.25, GROW_Z))
    rig.squash = kit.empty("Squash", rig.inflate, (0, 0.25, -GROW_Z))
    rig.lean = kit.empty("Lean", rig.squash, (0, 0, 0.18))
    body = flat_mesh("Body", body_bmesh(), rig.lean, m["skin"])
    body.location = (0, 0, -0.18)
    rig.body = body

    def body_comb(co, n):
        want = Vector((0, 0.15, -1.0))
        # Groom away from the face opening.
        rel = Vector((co.x / FACE_W, 0, (co.z - FACE_Z) / FACE_H))
        d = rel.length
        if n.y < 0.2 and d > 1e-6:
            pull = math.exp(-max(0.0, d - 1.0) * 2.2) * (1.0 if n.y < 0 else 0.4)
            want += Vector((rel.x / d, 0, rel.z / d)) * 2.2 * pull
        if co.z > 0.72:
            want += Vector((0, 1.2, 0)) * smoothstep((co.z - 0.72) / 0.12)
        return want

    def body_density(co, n):
        if n.y > 0:
            return 1.0
        rel = math.hypot(co.x / (FACE_W + 0.012), (co.z - FACE_Z) / (FACE_H + 0.012))
        return smoothstep((rel - 1.0) / 0.12)

    groom(body, body_comb, body_density)
    add_fur(body, group, m["fur"], 34000, 0.033, seed=1)

    depsgraph = bpy.context.evaluated_depsgraph_get()
    bvh = BVHTree.FromObject(body, depsgraph, deform=False)

    # The face: a shallow, almost flush oval lifted to the fur's surface.
    face = kit.squircle_grid(FACE_W, FACE_H, 2.35, 30)
    for v in face.verts:  # flatter lower edge, like the concept
        if v.co.z < 0:
            v.co.z *= 0.94
    # Sits just inside the fur on the body's flattened front: almost flush.
    kit.project_onto(face, bvh, FACE_Z, 0.006)
    face_obj = kit.mesh_object("Face", face, body, m["face"], subdivisions=2)
    kit.solidify(face_obj, 0.008, 1.0)
    hit, normal, _, _ = bvh.ray_cast(Vector((0, -2, FACE_Z)), Vector((0, 1, 0)))
    rig.face = kit.empty("Face anchor", body, hit + normal * 0.016)
    rig.face.rotation_euler = Vector((0, -1, 0)).rotation_difference(normal).to_euler()
    kit.preview_eyes(rig)

    # Ears: small round pads on the crown, rooted inside the fur.
    rig.ears = {}
    for side in (-1, 1):
        pivot = kit.empty(f"Ear pivot {side}", body, (side * 0.235, 0.03, 0.74))
        pivot.rotation_euler = (0, side * math.radians(24), 0)
        ear = flat_mesh(f"Ear {side}", ellipsoid(0.07, 0.042, 0.066, 32, 20), pivot, m["skin"])
        ear.location = (0, 0, 0.085)
        groom(ear, lambda co, n: (0, 0.2, 1.0) if co.z > -0.02 else (0, 0, -1))
        add_fur(ear, group, m["fur"], 30000, 0.026, 0.0018, seed=10 + side)
        rig.ears[side] = pivot

    # Mitten arms hang from the shoulders; quaternion aim keeps blur clean.
    rig.arms, rig.arm_mesh, rig.mittens = {}, {}, {}
    for side in (-1, 1):
        shoulder = kit.empty(f"Shoulder {side}", body, (side * 0.31, -0.06, 0.46))
        shoulder.rotation_mode = "QUATERNION"
        # The arm stretches; the mitten rides its end unscaled, so a long
        # reach (climbing onto the sill) never thins or smears the mitten.
        arm = flat_mesh(f"Arm {side}", kit.capsule(0.066, 0.2, 32), shoulder, m["skin"])
        groom(arm, lambda co, n: (0, 0, -1))
        add_fur(arm, group, m["fur"], 26000, 0.03, 0.002, seed=20 + side)
        mitten = flat_mesh(f"Mitten {side}", ellipsoid(0.082, 0.074, 0.084, 32, 20), shoulder, m["skin"])
        mitten.location = (0, 0, -MITTEN)
        groom(mitten, lambda co, n: (0, 0, -1))
        add_fur(mitten, group, m["fur"], 26000, 0.03, 0.002, seed=40 + side)
        rig.arms[side] = shoulder
        rig.arm_mesh[side] = arm
        rig.mittens[side] = mitten

    # Feet stay under the inflate so they grow with the body.
    rig.feet = {}
    for side in (-1, 1):
        foot = flat_mesh(f"Foot {side}", foot_bmesh(), rig.inflate, m["skin"])
        foot.location = (side * 0.18, -0.09 + 0.25, -GROW_Z + 0.055)
        foot.rotation_euler = (0, 0, side * -0.16)
        groom(foot, lambda co, n: (0, -0.6, -1.0), lambda co, n: 0.0 if n.z < -0.6 else 1.0)
        add_fur(foot, group, m["fur"], 26000, 0.028, 0.002, seed=30 + side)
        rig.feet[side] = foot

    # The windowsill: a holdout block whose front top edge is the stage's
    # bottom edge. Soot hangs behind it; anything inside or behind it vanishes,
    # anything in front (the gripping mittens) stays. Parked away elsewhere.
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=(6, 3, 4), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(0, 1.5, -2), verts=bm.verts)
    sill = kit.mesh_object("Sill holdout", bm, None, None, smooth=False, subdivisions=0)
    sill.is_holdout = True
    sill.visible_shadow = False
    sill.visible_diffuse = sill.visible_glossy = sill.visible_transmission = False
    rig.sill = sill

    rig.shoulder_rest = {side: rig.arms[side].location.copy() for side in rig.arms}
    rig.last_q = {}
    rig.keyed = [rig.root, rig.inflate, rig.squash, rig.lean, sill,
                 *rig.ears.values(), *rig.feet.values(), *rig.arms.values(),
                 *rig.arm_mesh.values(), *rig.mittens.values()]
    return rig


def stage(scene, camera):
    # A black plush needs softer, more grazing rims than porcelain did.
    lights = {o.name: o for o in scene.objects if o.type == "LIGHT"}
    lights["Rim left"].data.energy = 230
    lights["Rim right"].data.energy = 210
    lights["Rim left"].location = (-1.9, 0.9, 1.3)
    lights["Rim right"].location = (1.95, 0.85, 1.2)
    for name in ("Rim left", "Rim right"):
        obj = lights[name]
        obj.rotation_euler = (Vector((0, 0, 0.6)) - obj.location).to_track_quat("-Z", "Y").to_euler()
    lights["Key"].data.energy = 260
    lights["Rim right"].data.color = (0.95, 0.97, 1.0)
    scene.cycles_curves.shape = "THICK"
    scene.cycles_curves.subdivisions = 2


# ---------------------------------------------------------------- poses
#
# A pose is a plain dict. Arms aim in body space (x screen-right, y away from
# the camera, z up); `_l` is the screen-left limb. A grip (x, y, z, weight)
# pulls a mitten onto a world point (the sill) and blends with the free aim.

FPS = kit.FPS
END = lambda length: length - 1 / FPS  # time of a clip's last rendered frame

ARM_REST = {-1: (-0.5, -0.12, -1.0), 1: (0.5, -0.12, -1.0)}
REST = dict(x=0.0, y=0.0, z=0.0, scale=1.0, yaw=0.0, rpitch=0.0, grow=1.0, sq=1.0, lean=0.0, pitch=0.0,
            ear_l=0.0, ear_r=0.0, ear_droop=0.0, ear_pop=1.0,
            arm_l=ARM_REST[-1], arm_r=ARM_REST[1], stretch_l=1.0, stretch_r=1.0,
            grip_l=(0.0, 0.0, 0.0, 0.0), grip_r=(0.0, 0.0, 0.0, 0.0), shoulder_fwd=0.0,
            foot_l=0.0, foot_r=0.0, fluff=1.0, sill=False)


def mix(a, b, k):
    """Blends two poses; k=0 gives a, k=1 gives b."""
    if k <= 0:
        return dict(a)
    if k >= 1:
        return dict(b)
    out = {}
    for key, va in a.items():
        vb = b[key]
        if isinstance(va, bool):
            out[key] = vb if k > 0.5 else va
        elif isinstance(va, tuple):
            out[key] = tuple(x + (y - x) * k for x, y in zip(va, vb))
        else:
            out[key] = va + (vb - va) * k
    return out


def finish(p, target, t, length, span=0.3):
    """Eases the last `span` seconds onto `target` so the final frame equals it."""
    return mix(p, target, smoothstep((t - (END(length) - span)) / span))


def lerp3(a, b, k):
    return tuple(x + (y - x) * k for x, y in zip(a, b))


def swing(direction, angle):
    """Rotates an aim about the body's y axis (raise/lower sideways)."""
    x, y, z = direction
    c, s = math.cos(angle), math.sin(angle)
    return (x * c + z * s, y, -x * s + z * c)


def twitch(t, start, size=1.0):
    """An ear flick: a quick snap back and a smaller rebound."""
    return size * (0.55 * pulse(t, start, 0.13) - 0.25 * pulse(t, start + 0.13, 0.16))


# ------------------------------------------------ base clips (standing)


def idle(t, length):
    p = dict(REST)
    breath = math.sin(2 * math.pi * t / (length / 2))
    p["sq"] = 1 + 0.016 * breath
    p["fluff"] = 1 + 0.025 * breath
    p["lean"] = 0.014 * math.sin(2 * math.pi * t / length)
    p["arm_l"] = swing(ARM_REST[-1], -0.04 * breath)
    p["arm_r"] = swing(ARM_REST[1], 0.04 * breath)
    p["ear_r"] = -twitch(t, 1.05, 0.7)
    p["ear_l"] = -twitch(t, 2.2, 0.45)
    p["ear_droop"] = 0.03 * breath
    return p


def work(t, length):
    """Kneads with both paws in front of the belly, bouncing on each press."""
    p = dict(REST)
    beat = math.sin(2 * math.pi * t / (length / 2))
    press_l, press_r = max(0.0, beat) ** 1.4, max(0.0, -beat) ** 1.4
    p["shoulder_fwd"] = 0.35
    for side, key, press, other in ((-1, "_l", press_l, press_r), (1, "_r", press_r, press_l)):
        base = (side * 0.2, -0.9, -0.55)
        p["arm" + key] = lerp3(base, (side * 0.16, -1.0, -1.0), press)
        p["arm" + key] = lerp3(p["arm" + key], (side * 0.24, -0.9, -0.15), 0.6 * other)
        p["stretch" + key] = 1 + 0.12 * press - 0.06 * other
        p["foot" + key] = 0.012 * other
    p["sq"] = 1 - 0.032 * (press_l + press_r) + 0.012
    p["z"] = 0.012 * (1 - press_l - press_r)
    p["lean"] = 0.04 * (press_r - press_l)
    p["pitch"] = 0.07 + 0.02 * (press_l + press_r)
    p["ear_droop"] = -0.08
    p["ear_l"] = 0.12 * press_l
    p["ear_r"] = 0.12 * press_r
    return p


def wave(t, length):
    """Bobs up, raises the screen-right mitten and waves, then settles."""
    p = idle(0, IDLE)
    up = smoothstep((t - 0.1) / 0.3) * (1 - smoothstep((t - 1.5) / 0.4))
    wag = math.sin(2 * math.pi * max(0.0, t - 0.4) / 0.4) * smoothstep((t - 0.3) / 0.15) * up
    p["sq"] = 1 - 0.06 * pulse(t, 0.0, 0.2) + 0.04 * pulse(t, 0.15, 0.35) + 0.01 * wag
    p["z"] = 0.03 * pulse(t, 0.15, 0.35)
    p["arm_r"] = swing(lerp3(ARM_REST[1], (0.55, -0.15, 0.9), up), 0.42 * wag)
    p["stretch_r"] = 1 + 0.06 * up
    p["arm_l"] = swing(ARM_REST[-1], -0.12 * up)
    p["lean"] = 0.06 * up + 0.018 * wag
    p["ear_droop"] = -0.12 * up
    p["ear_r"] = 0.1 * wag
    return finish(p, idle(0, IDLE), t, length, 0.25)


def wait(t, length):
    """Eager bounces, ears perked, the way a puppy waits for a ball."""
    p = idle(0, IDLE)
    hop1 = (t - 0.16) / 0.3
    hop2 = (t - 0.62) / 0.24
    air = 0.06 * 4 * hop1 * (1 - hop1) if 0 <= hop1 <= 1 else 0.0
    air += 0.032 * 4 * hop2 * (1 - hop2) if 0 <= hop2 <= 1 else 0.0
    p["z"] = air
    crouch = pulse(t, 0.0, 0.2) + pulse(t, 0.42, 0.22) + 0.6 * pulse(t, 0.84, 0.22)
    lift = pulse(t, 0.14, 0.18) + 0.7 * pulse(t, 0.6, 0.14)
    p["sq"] = 1 - 0.07 * crouch + 0.06 * lift + 0.01 * math.sin(2 * math.pi * t / length)
    flap = air / 0.06
    p["arm_l"] = swing(ARM_REST[-1], -0.55 * flap)
    p["arm_r"] = swing(ARM_REST[1], 0.55 * flap)
    perk = smoothstep(t / 0.2) * (1 - smoothstep((t - 1.4) / 0.3))
    p["ear_droop"] = -0.16 * perk
    p["ear_pop"] = 1 + 0.06 * perk
    p["foot_l"] = p["foot_r"] = 0.02 * flap
    p["ear_r"] = -twitch(t, 1.2, 0.5)
    return finish(p, idle(0, IDLE), t, length, 0.2)


def done(t, length):
    """Crouch, a happy hop with both arms flung up, a bouncy landing."""
    p = idle(0, IDLE)
    up_arm = {-1: (-0.62, -0.1, 0.85), 1: (0.62, -0.1, 0.85)}
    down_arm = {-1: (-0.35, 0.35, -1.0), 1: (0.35, 0.35, -1.0)}
    crouch = smoothstep(t / 0.22) * (1 - smoothstep((t - 0.22) / 0.07))
    k = (t - 0.27) / 0.5
    air = 0.24 * 4 * k * (1 - k) if 0 <= k <= 1 else 0.0
    k2 = (t - 0.95) / 0.26
    air += 0.05 * 4 * k2 * (1 - k2) if 0 <= k2 <= 1 else 0.0
    p["z"] = air
    land = max(0.0, t - 0.77)
    land2 = max(0.0, t - 1.21)
    p["sq"] = (1 - 0.15 * crouch + 0.13 * pulse(t, 0.22, 0.2)
               - (0.17 * math.exp(-7 * land) * math.cos(2 * math.pi * land / 0.36) if t > 0.77 else 0.0)
               - (0.05 * math.exp(-8 * land2) * math.cos(2 * math.pi * land2 / 0.3) if t > 1.21 else 0.0))
    raised = smoothstep((t - 0.2) / 0.16) * (1 - smoothstep((t - 1.75) / 0.45))
    joy = math.sin(2 * math.pi * max(0.0, t - 0.8) / 0.32) * smoothstep((t - 0.8) / 0.1) * raised
    for side, key in ((-1, "_l"), (1, "_r")):
        arm = lerp3(ARM_REST[side], down_arm[side], crouch)
        arm = lerp3(arm, up_arm[side], raised)
        p["arm" + key] = swing(arm, side * 0.18 * joy)
        p["foot" + key] = 0.05 * smoothstep(air / 0.12)
    p["lean"] = 0.05 * joy
    p["pitch"] = 0.06 * crouch - 0.05 * smoothstep(air / 0.2)
    p["ear_droop"] = 0.12 * crouch - 0.1 * raised
    p["fluff"] = 1 + 0.2 * math.exp(-4 * land) * (1 if t > 0.77 else 0) + 0.06 * crouch
    return finish(p, idle(0, IDLE), t, length, 0.3)


SAD = dict(sq=0.92, pitch=0.13, ear_droop=0.55, fluff=0.9,
           arm_l=(-0.22, -0.18, -1.0), arm_r=(0.22, -0.18, -1.0), stretch_l=1.07, stretch_r=1.07)


def sad(t, length):
    p = dict(REST)
    p.update(SAD)
    sigh = math.sin(2 * math.pi * t / length)
    p["sq"] = SAD["sq"] + 0.012 * sigh
    p["pitch"] = SAD["pitch"] - 0.015 * sigh
    p["ear_droop"] = SAD["ear_droop"] + 0.04 * sigh
    p["lean"] = 0.01 * math.sin(2 * math.pi * t / length + 0.8) - 0.01 * math.sin(0.8)
    return p


def fail(t, length):
    """A frightened shiver, fur bristling, then a heavy slump."""
    p = idle(0, IDLE)
    shake = 1 - smoothstep((t - 0.35) / 0.45)
    p["x"] = 0.011 * math.sin(2 * math.pi * 13 * t) * shake * smoothstep(t / 0.06)
    p["lean"] = 0.035 * math.sin(2 * math.pi * 9 * t + 1) * shake * smoothstep(t / 0.06)
    p["sq"] = 1 - 0.05 * smoothstep(t / 0.1) * shake + 0.008 * math.sin(2 * math.pi * 17 * t) * shake
    p["fluff"] = 1 + 0.3 * smoothstep(t / 0.08) * shake
    p["ear_droop"] = 0.35 * smoothstep(t / 0.1)
    p["arm_l"] = swing(ARM_REST[-1], 0.25 * shake)  # mittens clutched in
    p["arm_r"] = swing(ARM_REST[1], -0.25 * shake)
    slump = smoothstep((t - 0.75) / 0.6)
    target = sad(0, SAD_LENGTH)
    p = mix(p, target, slump)
    p["sq"] -= 0.035 * pulse(t, 1.2, 0.55)  # a sigh as it settles
    return finish(p, target, t, length, 0.2)


def emerge(t, length):
    """Poofs out of the eyes like a soot puff: fur first, ears pop, feet plant."""
    p = idle(0, IDLE)
    p["grow"] = 0.04 + 0.96 * spring(t, 0.5, 0.44)
    p["fluff"] = 1 + 0.9 * math.exp(-5 * t)
    settle = max(0.0, t - 0.32)
    p["sq"] = 1 + 0.1 * (1 - smoothstep(t / 0.32)) - (0.11 * math.exp(-6 * settle) * math.cos(2 * math.pi * settle / 0.4) if t > 0.32 else 0)
    p["ear_pop"] = max(0.0, spring(t - 0.3, 0.32, 0.3))
    unfurl = max(0.0, spring(t - 0.12, 0.42, 0.4))
    p["arm_l"] = lerp3((-0.9, -0.2, 0.5), ARM_REST[-1], unfurl)
    p["arm_r"] = lerp3((0.9, -0.2, 0.5), ARM_REST[1], unfurl)
    p["foot_l"] = p["foot_r"] = 0.06 * (1 - smoothstep((t - 0.12) / 0.2))
    p["lean"] = 0.05 * math.exp(-5 * settle) * math.sin(2 * math.pi * settle / 0.5) if t > 0.32 else 0.0
    return finish(p, idle(0, IDLE), t, length, 0.18)


# ------------------------------------------------ stage clips (windowsill)

PIVOT_M = Vector((0.0, -0.385, 0.38))  # the furred front at sill height, model space
STAGE_PITCH = 0.2
GRIP_X = 0.38


def hang(sink=0.0, rpitch=STAGE_PITCH, x=0.0, back=0.0):
    """Places Soot behind the sill: its front at sill height rests on the edge.
    `back` moves it away from the edge so a sunken face can't poke through."""
    pivot = Vector((x, SILL_Y + 0.03 + back, SILL_Z - sink))
    loc = pivot - Matrix.Rotation(rpitch, 3, "X") @ (PIVOT_M * STAGE_SCALE)
    p = dict(REST)
    p.update(x=loc.x, y=loc.y, z=loc.z, scale=STAGE_SCALE, rpitch=rpitch, sill=True, shoulder_fwd=1.0)
    p["grip_l"] = grip(-1)
    p["grip_r"] = grip(1)
    p["arm_l"], p["arm_r"] = (-0.3, -1.0, -0.4), (0.3, -1.0, -0.4)
    return p


def grip(side, dx=0.0, dy=0.0, dz=0.0, weight=1.0):
    return (side * GRIP_X + dx, SILL_Y + 0.01 + dy, SILL_Z + 0.065 + dz, weight)


def stage_idle(t, length):
    """Hangs on the sill, breathing; hidden legs kick now and then."""
    breath = math.sin(2 * math.pi * t / (length / 2))
    kick1, kick2 = pulse(t, 0.75, 0.24), pulse(t, 1.9, 0.24)
    p = hang(sink=0.012 * breath - 0.03 * (kick1 + kick2), rpitch=STAGE_PITCH + 0.01 * breath)
    p["sq"] = 1 + 0.012 * breath
    p["fluff"] = 1 + 0.025 * breath
    p["lean"] = 0.03 * (kick1 - kick2)
    p["ear_r"] = -twitch(t, 1.25, 0.7)
    p["ear_l"] = -twitch(t, 2.3, 0.5) - twitch(t, 0.35, 0.3)
    return p


def stage_work(t, length):
    """Drums its mittens on the sill, bobbing along."""
    beat = math.sin(2 * math.pi * t / (length / 2))
    lift_l, lift_r = max(0.0, beat) ** 1.3, max(0.0, -beat) ** 1.3
    p = hang(sink=-0.012 * (lift_l + lift_r) + 0.008, rpitch=STAGE_PITCH + 0.05 + 0.02 * (lift_l + lift_r))
    p["grip_l"] = grip(-1, dy=-0.02 * lift_l, dz=0.11 * lift_l)
    p["grip_r"] = grip(1, dy=-0.02 * lift_r, dz=0.11 * lift_r)
    p["lean"] = 0.035 * (lift_r - lift_l)
    p["sq"] = 1 - 0.02 * (1 - lift_l - lift_r)
    p["ear_droop"] = -0.06
    p["ear_l"], p["ear_r"] = 0.1 * lift_l, 0.1 * lift_r
    return p


def stage_wave(t, length):
    """Lets go with one mitten to wave; the other keeps its grip."""
    p = stage_idle(0, STAGE_IDLE)
    up = smoothstep((t - 0.12) / 0.3) * (1 - smoothstep((t - 1.45) / 0.35))
    wag = math.sin(2 * math.pi * max(0.0, t - 0.42) / 0.4) * smoothstep((t - 0.32) / 0.15) * up
    q = hang(sink=-0.05 * up + 0.012 * pulse(t, 0.0, 0.18), rpitch=STAGE_PITCH - 0.06 * up)
    for key in ("x", "y", "z", "rpitch"):
        p[key] = q[key]
    p["grip_r"] = grip(1, weight=1 - up)
    p["arm_r"] = swing((0.5, -0.4, 0.85), 0.4 * wag)
    p["stretch_r"] = 1 + 0.05 * up
    p["grip_l"] = grip(-1, dx=0.03 * up)
    p["lean"] = -0.07 * up + 0.02 * wag
    p["ear_droop"] = -0.12 * up
    p["ear_r"] = 0.1 * wag
    # The mitten pats back down onto the sill.
    p["sq"] = 1 - 0.03 * pulse(t, 1.75, 0.2)
    return finish(p, stage_idle(0, STAGE_IDLE), t, length, 0.25)


def stage_wait(t, length):
    """Eager: pulls itself up twice, chin raised, ears perked."""
    p = stage_idle(0, STAGE_IDLE)
    pull = pulse(t, 0.08, 0.36) + 0.65 * pulse(t, 0.5, 0.3)
    dip = pulse(t, 0.0, 0.14) + 0.5 * pulse(t, 0.4, 0.14)
    perk = smoothstep(t / 0.2) * (1 - smoothstep((t - 1.35) / 0.3))
    q = hang(sink=-0.07 * pull + 0.025 * dip, rpitch=STAGE_PITCH - 0.07 * perk)
    for key in ("x", "y", "z", "rpitch"):
        p[key] = q[key]
    p["sq"] = 1 + 0.05 * pull - 0.04 * dip + 0.01 * math.sin(2 * math.pi * t / length)
    p["ear_droop"] = -0.16 * perk
    p["ear_pop"] = 1 + 0.06 * perk
    p["ear_l"] = -twitch(t, 1.1, 0.4)
    return finish(p, stage_idle(0, STAGE_IDLE), t, length, 0.2)


def stage_done(t, length):
    """Springs up off the sill, arms flung high, and catches the edge again."""
    p = stage_idle(0, STAGE_IDLE)
    crouch = smoothstep(t / 0.2) * (1 - smoothstep((t - 0.2) / 0.07))
    k = (t - 0.25) / 0.6
    air = 0.22 * 4 * k * (1 - k) if 0 <= k <= 1 else 0.0
    q = hang(sink=0.03 * crouch - air, rpitch=STAGE_PITCH - 0.17 * smoothstep(air / 0.18))
    for key in ("x", "y", "z", "rpitch"):
        p[key] = q[key]
    release = smoothstep((t - 0.2) / 0.08) * (1 - smoothstep((t - 0.74) / 0.12))
    raised = smoothstep((t - 0.22) / 0.14) * (1 - smoothstep((t - 0.62) / 0.2))
    land = max(0.0, t - 0.86)
    joy = math.sin(2 * math.pi * max(0.0, t - 0.3) / 0.3) * raised
    for side, key in ((-1, "_l"), (1, "_r")):
        p["grip" + key] = grip(side, weight=1 - release)
        p["arm" + key] = swing(lerp3((side * 0.3, -1.0, -0.4), (side * 0.62, -0.25, 0.8), raised), side * 0.15 * joy)
    p["sq"] = (1 - 0.1 * crouch + 0.1 * pulse(t, 0.2, 0.25)
               - (0.1 * math.exp(-7 * land) * math.cos(2 * math.pi * land / 0.36) if t > 0.86 else 0.0))
    p["fluff"] = 1 + 0.18 * math.exp(-4 * land) * (1 if t > 0.86 else 0)
    p["ear_droop"] = 0.1 * crouch - 0.12 * raised
    p["lean"] = 0.04 * joy
    # A happy little bob on the sill before settling.
    bob = pulse(t, 1.2, 0.3)
    p["z"] += 0.03 * bob
    return finish(p, stage_idle(0, STAGE_IDLE), t, length, 0.3)


def stage_sad(t, length):
    """Sunk low and bowed, mittens hanging limp over the edge. (Chin-on-paws
    would put the mittens under the app's eyes, which always draw on top.)"""
    sigh = math.sin(2 * math.pi * t / length)
    p = hang(sink=0.07 + 0.01 * sigh, rpitch=STAGE_PITCH + 0.12 - 0.012 * sigh)
    p["grip_l"] = grip(-1, dx=0.02, dy=-0.04)
    p["grip_r"] = grip(1, dx=-0.02, dy=-0.04)
    p["sq"] = 0.95 + 0.01 * sigh
    p["fluff"] = 0.9
    p["ear_droop"] = 0.7 + 0.04 * sigh
    return p


def stage_fail(t, length):
    """Slips, shivers while clinging on, then sinks into a slump."""
    p = stage_idle(0, STAGE_IDLE)
    slip = spring(t - 0.08, 0.38, 0.32)
    shake = smoothstep((t - 0.1) / 0.08) * (1 - smoothstep((t - 0.6) / 0.4))
    q = hang(sink=0.1 * slip, rpitch=STAGE_PITCH + 0.02 * slip, back=0.05 * slip)
    for key in ("x", "y", "z", "rpitch"):
        p[key] = q[key]
    p["x"] += 0.012 * math.sin(2 * math.pi * 13 * t) * shake
    p["lean"] = 0.03 * math.sin(2 * math.pi * 9 * t + 1) * shake
    clutch = smoothstep((t - 0.06) / 0.1)
    p["grip_l"] = grip(-1, dy=-0.04 * clutch)
    p["grip_r"] = grip(1, dy=-0.04 * clutch)
    p["fluff"] = 1 + 0.3 * shake
    p["ear_droop"] = 0.4 * smoothstep((t - 0.05) / 0.12)
    p["sq"] = 1 + 0.01 * math.sin(2 * math.pi * 17 * t) * shake
    target = stage_sad(0, STAGE_SAD)
    return finish(p, target, t, length, 0.75)


def stage_emerge(t, length):
    """Climbs up from below: the mittens reach over the edge first and flop
    onto the sill, then Soot hauls itself up in two tugs and peeks over."""
    final = stage_idle(0, STAGE_IDLE)
    rise = smoothstep(t / 0.26)                 # mittens come up behind the edge
    over = smoothstep((t - 0.18) / 0.16)        # ...and forward over it
    plop = spring(t - 0.3, 0.38, 0.26)          # ...flopping down onto it
    tug1 = smoothstep((t - 0.48) / 0.28)
    tug2 = smoothstep((t - 0.92) / 0.24)
    sink = 1.12 - 0.6 * tug1 - 0.58 * tug2 + 0.04 * pulse(t, 0.76, 0.2) + 0.06 * (spring(t - 0.92, 0.35, 0.36) - tug2)
    q = hang(sink=sink, rpitch=STAGE_PITCH * tug2, back=0.12 * (1 - tug2))
    p = dict(final)
    for key in ("x", "y", "z", "rpitch"):
        p[key] = q[key]
    for side, key in ((-1, "_l"), (1, "_r")):
        height = max(-0.02, -0.4 * (1 - rise) + 0.12 * over * (1 - plop) + 0.03 * pulse(t, 0.5, 0.2))
        # Kept back while the arm still climbs from below, so it stays hidden.
        p["grip" + key] = grip(side, dx=-side * 0.04 * (1 - plop), dy=0.2 * (1 - over) + 0.13 * (1 - tug2), dz=height)
    p["sq"] = 1 + 0.07 * pulse(t, 0.5, 0.3) - 0.05 * pulse(t, 0.8, 0.16) + 0.07 * pulse(t, 0.92, 0.3)
    p["ear_pop"] = 0.7 + 0.3 * spring(t - 0.62, 0.3, 0.3)
    p["ear_droop"] = 0.3 * (1 - tug1)
    p["fluff"] = 1 + 0.1 * pulse(t, 0.95, 0.4)
    return finish(p, final, t, length, 0.3)


# ------------------------------------------------ follow-through

def crown(p):
    """Approximate world position of the top of the head, for follow-through."""
    s, h = p["scale"], 0.8 * p["sq"] * p["grow"]
    local = Vector((math.sin(p["lean"]) * h, -math.sin(p["pitch"]) * h, math.cos(p["lean"]) * h))
    local = Matrix.Rotation(p["rpitch"], 3, "X") @ local
    return Vector((p["x"], p["y"], p["z"])) + local * s


def lag(fn, t, length, loops, omega, zeta, dt=1 / 120, window=0.7):
    """How far a soft spring riding the crown trails it (world units): the
    response of x'' + 2ζωx' + ω²x = -a to the crown's acceleration history.
    Loops sample their own wrapped past, so they still close exactly."""
    steps = int(window / dt)
    times = [t - k * dt for k in range(-1, steps + 2)]
    times = [(u % length) if loops else min(max(u, 0.0), length) for u in times]
    points = [crown(fn(u, length)) for u in times]
    wd = omega * math.sqrt(1 - zeta * zeta)
    total = Vector((0, 0, 0))
    for k in range(1, steps + 1):
        accel = (points[k] - 2 * points[k + 1] + points[k + 2]) / (dt * dt)
        tau = k * dt
        total -= accel * (math.exp(-zeta * omega * tau) * math.sin(wd * tau) / wd) * dt
    return total


def dynamic(fn, loops, then=None):
    """Adds follow-through. An entry clip hands its springs over to the loop
    it cuts to, so the hard cut matches exactly."""
    def lags(t, length):
        # Slow and well damped: at 24 fps a springier fur flipped up (dark roots)
        # and down (light tips) every other frame, so the plush flickered.
        return {"fur_lag": tuple(lag(fn, t, length, loops, 2 * math.pi * 2.0, 0.6) * 0.2),
                "ear_lag": tuple(lag(fn, t, length, loops, 2 * math.pi * 3.0, 0.25))}

    def pose(t, length):
        p = fn(t, length)
        p.update(lags(t, length))
        if then is not None:
            loop_fn, loop_length = then
            target = dynamic(loop_fn, True)(0, loop_length)
            k = smoothstep((t - (END(length) - 0.35)) / 0.35)
            if loops:  # a loop that shares its first frame with another loop
                k = max(k, 1 - smoothstep(t / 0.25))
            for key in ("fur_lag", "ear_lag"):
                p[key] = lerp3(p[key], target[key], k)
        return p
    pose.__name__ = fn.__name__
    return pose


IDLE, SAD_LENGTH, STAGE_IDLE, STAGE_SAD = 3.0, 2.8, 2.8, 2.8


def clip(fn, seconds, loops, ledge=None, then=None):
    return kit.Clip(dynamic(fn, loops, then), seconds, loops, ledge)


CLIPS = {
    "emerge": clip(emerge, 1.2, False, then=(idle, IDLE)),
    "idle": clip(idle, IDLE, True),
    "work": clip(work, 1.2, True),
    "done": clip(done, 2.5, False, then=(idle, IDLE)),
    "wave": clip(wave, 2.2, False, then=(idle, IDLE)),
    "wait": clip(wait, 1.8, True, then=(idle, IDLE)),
    "fail": clip(fail, 2.2, False, then=(sad, SAD_LENGTH)),
    "sad": clip(sad, SAD_LENGTH, True),
    "stage-emerge": clip(stage_emerge, 1.7, False, LEDGE, (stage_idle, STAGE_IDLE)),
    "stage-idle": clip(stage_idle, STAGE_IDLE, True, LEDGE),
    "stage-work": clip(stage_work, 1.2, True, LEDGE),
    "stage-done": clip(stage_done, 2.0, False, LEDGE, (stage_idle, STAGE_IDLE)),
    "stage-wave": clip(stage_wave, 2.2, False, LEDGE, (stage_idle, STAGE_IDLE)),
    "stage-wait": clip(stage_wait, 1.8, True, LEDGE, (stage_idle, STAGE_IDLE)),
    "stage-fail": clip(stage_fail, 2.2, False, LEDGE, (stage_sad, STAGE_SAD)),
    "stage-sad": clip(stage_sad, STAGE_SAD, True, LEDGE),
}


# ------------------------------------------------ rig


def aim(rig, side, direction):
    q = Vector((0, 0, -1)).rotation_difference(Vector(direction).normalized())
    last = rig.last_q.get(side)
    if last is not None and last.dot(q) < 0:
        q.negate()  # stay in one hemisphere so keys interpolate the short way
    rig.last_q[side] = q.copy()
    return q


def apply_pose(rig, p):
    s = p["scale"]
    rig.root.location = (p["x"], p["y"], p["z"])
    rig.root.rotation_euler = (p["rpitch"], 0, p["yaw"])
    rig.root.scale = (s, s, s)
    rig.inflate.scale = (p["grow"],) * 3
    q = max(0.3, p["sq"])
    side = 1 / math.sqrt(q)
    rig.squash.scale = (side, side, q)
    rig.lean.rotation_euler = (p["pitch"], p["lean"], 0)
    ear_lag = Vector(p.get("ear_lag", (0, 0, 0))) / s
    for side_, key in ((-1, "ear_l"), (1, "ear_r")):
        ear = rig.ears[side_]
        flop = max(-0.5, min(0.5, 9.0 * ear_lag.z))
        ear.rotation_euler = (p[key] - 7.0 * ear_lag.y,
                              side_ * (math.radians(24) + p["ear_droop"] - flop) - 7.0 * ear_lag.x, 0)
        ear.scale = (max(1e-3, p["ear_pop"]),) * 3
    for side_, key in ((-1, "foot_l"), (1, "foot_r")):
        rig.feet[side_].location.z = -GROW_Z + 0.055 + p[key]
    rig.sill.location = (0, SILL_Y, SILL_Z) if p["sill"] else (0, SILL_Y, -60)
    for side_ in (-1, 1):
        rest_ = rig.shoulder_rest[side_]
        forward = Vector((side_ * 0.27, -0.2, 0.44))
        rig.arms[side_].location = rest_.lerp(forward, p["shoulder_fwd"])

    # Arms last: grips need the body's final placement.
    bpy.context.view_layer.update()
    to_body = rig.body.matrix_world.inverted()
    for side_, key in ((-1, "_l"), (1, "_r")):
        direction = Vector(p["arm" + key]).normalized()
        stretch = p["stretch" + key]
        gx, gy, gz, weight = p["grip" + key]
        if weight > 0:
            reach = to_body @ Vector((gx, gy, gz)) - rig.arms[side_].location
            direction = direction.lerp(reach.normalized(), weight).normalized()
            wanted = reach.length / MITTEN
            if not 0.5 <= wanted <= 3.2:
                print(f"GRIP CLAMP side {side_} stretch {wanted:.2f}")
            stretch += (min(3.2, max(0.5, wanted)) - stretch) * weight
        rig.arms[side_].rotation_quaternion = aim(rig, side_, direction)
        thin = 1 / math.sqrt(min(1.35, max(0.75, stretch)))
        rig.arm_mesh[side_].scale = (thin, thin, stretch)
        rig.mittens[side_].location = (0, 0, -MITTEN * stretch)

    bpy.context.view_layer.update()
    fur_lag = Vector(p.get("fur_lag", (0, 0, 0)))
    for obj, inputs in FUR.values():
        local = obj.matrix_world.to_3x3().inverted() @ fur_lag / inputs["_length"]
        if local.length > 1.1:
            local *= 1.1 / local.length
        inputs["Sway"].value = local
        inputs["Fluff"].value = p["fluff"]


def keyframe(rig):
    for shoulder in rig.arms.values():
        shoulder.keyframe_insert("rotation_quaternion")
    for obj, inputs in FUR.values():
        for name in ("Sway", "Fluff"):
            obj.keyframe_insert(inputs[name].path_from_id("value"))


kit.run(sys.modules[__name__])
