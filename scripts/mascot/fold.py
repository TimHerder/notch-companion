"""Fold: a squat origami figure in warm ivory art paper, for Notch Companion.

A gently peaked, faceted hood (with a folded-back brim) frames a near-black,
gently curved face insert; the hood runs into a short back cape over a
rhombic torso whose base is folded into four little feet. Two short
triangular sleeves hang from hinges at the shoulders. Every part is a planar
paper panel with a hairline bevel, so all motion is hinge rotation: sleeves
fold and flip, the hood nods and pops, the body leans and hops.

Signature: the emerge unfolds Fold from a flat packet around the eyes. A dark
paper diamond opens behind the eyes, the torso swings down from where it lay
folded flat behind it, the hood flap rises over the top to its peak, the
sleeves flip out, and Fold settles with a small paper bounce onto idle.

    scripts/render-mascot.sh fold --turnaround --eyes --size 512
    scripts/render-mascot.sh fold --preview emerge,idle --eyes
"""

import bpy
import bmesh
import math
import os
import sys
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mascot_kit as kit  # noqa: E402
from mascot_kit import ease_in_out, pulse, smoothstep, spring  # noqa: E402

ID = "fold"
EYE_UNIT = 0.0115

FACE = Vector((0.0, -0.17, 0.63))     # eye anchor, a little recessed in the opening
NECK = Vector((0.0, 0.0, 0.5))        # head pivot (nods, sway, pop)
HOOD_HINGE = Vector((0.0, 0.385, 0.44))  # hood's back rim: the emerge flap hinge
TORSO_HINGE = Vector((0.0, -0.02, 0.5))  # torso folds up behind the face here
CARD = Vector((0.0, -0.13, 0.64))     # emerge diamond hinge (vertical diagonal)

# ---------------------------------------------------------------- materials


def build_materials():
    m = {}
    paper, shader = kit.material("Ivory paper", kit.rgba(0.83, 0.79, 0.70), rough=0.9,
                                 **{"Specular IOR Level": 0.28, "Sheen Weight": 0.25,
                                    "Sheen Roughness": 0.6, "Subsurface Weight": 0.04,
                                    "Subsurface Scale": 0.01})
    nodes, links = paper.node_tree.nodes, paper.node_tree.links
    # Faint mottling and stretched fibres: felt at 512 px, quiet at 76 px.
    coords = nodes.new("ShaderNodeTexCoord")
    mottle = nodes.new("ShaderNodeTexNoise")
    mottle.inputs["Scale"].default_value = 9.0
    mottle.inputs["Detail"].default_value = 3
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = kit.rgba(0.80, 0.765, 0.68)
    ramp.color_ramp.elements[1].color = kit.rgba(0.86, 0.825, 0.745)
    links.new(coords.outputs["Object"], mottle.inputs["Vector"])
    links.new(mottle.outputs["Fac"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], shader.inputs["Base Color"])
    fibre_map = nodes.new("ShaderNodeMapping")
    fibre_map.inputs["Scale"].default_value = (1.0, 1.0, 7.0)
    fibres = nodes.new("ShaderNodeTexNoise")
    fibres.inputs["Scale"].default_value = 140.0
    fibres.inputs["Detail"].default_value = 8
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.05
    bump.inputs["Distance"].default_value = 0.0015
    links.new(coords.outputs["Object"], fibre_map.inputs["Vector"])
    links.new(fibre_map.outputs["Vector"], fibres.inputs["Vector"])
    links.new(fibres.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], shader.inputs["Normal"])
    m["paper"] = paper

    # Matte black card, a touch of sheen so the curve still reads.
    face, shader = kit.material("Face insert", kit.rgba(0.018, 0.018, 0.02), rough=0.62,
                                **{"Specular IOR Level": 0.25, "Sheen Weight": 0.15})
    kit.micro_bump(face, shader, scale=120, strength=0.015)
    m["face"] = face
    return m


# ---------------------------------------------------------------- geometry

PIVOTS = {}  # name -> rest world location, so meshes can be built in world space


def pivot(name, parent, world):
    obj = kit.empty(name, parent)
    base = PIVOTS.get(parent.name, Vector()) if parent else Vector()
    obj.location = Vector(world) - base
    PIVOTS[name] = Vector(world)
    return obj


def paper_mesh(name, verts, faces, parent, mat, thickness=0.0, bevel=0.0045, closed=False, rim_mat=None,
               outward=None):
    """Flat-shaded planar panels with hairline bevels, built in world space. Sheet
    normals point along `outward` (a direction) so solidify grows behind them."""
    origin = PIVOTS.get(parent.name, Vector())
    bm = bmesh.new()
    bv = [bm.verts.new(Vector(v) - origin) for v in verts]
    for f in faces:
        face = bm.faces.new([bv[i] for i in f])
        if outward is not None:
            face.normal_update()
            if face.normal.dot(outward(face.calc_center_median() + origin)) < 0:
                face.normal_flip()
    if closed:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    obj = kit.mesh_object(name, bm, parent, mat, smooth=False, subdivisions=0)
    if thickness:
        mod = obj.modifiers.new("Solidify", "SOLIDIFY")
        mod.thickness = thickness
        mod.offset = -1.0
        mod.use_even_offset = True
        if rim_mat:
            obj.data.materials.append(rim_mat)
            mod.material_offset = 1
            mod.material_offset_rim = 1
    if bevel:
        mod = obj.modifiers.new("Bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 2
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(25)
    return obj


def mirror(v):
    return Vector((-v[0], v[1], v[2]))


def plane_point(a, b, c, x, z, lift=0.0, toward=(0, -1, 0)):
    """The point on plane abc at (x, z), lifted along its normal on the `toward` side."""
    a, b, c = Vector(a), Vector(b), Vector(c)
    n = (b - a).cross(c - a).normalized()
    if n.dot(Vector(toward)) < 0:
        n = -n
    # Solve n.(p - a) = 0 for p.y.
    y = a.y - (n.x * (x - a.x) + n.z * (z - a.z)) / n.y
    return Vector((x, y, z)) + n * lift


# Torso: a rhombic tent, front ridge to back ridge, folded under into four feet.
FC_T, SL_T, BC_T = Vector((0, -0.215, 0.43)), Vector((-0.29, 0.0, 0.54)), Vector((0, 0.30, 0.52))
FC_H, SL_H, BC_H = Vector((0, -0.30, 0.13)), Vector((-0.395, 0.02, 0.085)), Vector((0, 0.41, 0.12))
FL_F, BL_F = Vector((-0.2, -0.205, 0.0)), Vector((-0.2, 0.275, 0.0))
# Hood: a faceted peak with an open front, rim just outside the torso top.
PEAK = Vector((0, 0.01, 1.0))
APEX = Vector((0, -0.25, 0.825))
FL_C, SL_C = Vector((-0.30, -0.23, 0.53)), Vector((-0.43, -0.04, 0.475))   # face corner, outer corner
BL_C, BC_C = Vector((-0.345, 0.27, 0.43)), Vector((0, 0.385, 0.44))


def build_torso(rig, m):
    tops = [FC_T, SL_T, BC_T, mirror(SL_T)]
    hems = [FC_H, SL_H, BC_H, mirror(SL_H)]
    feet = [FL_F, BL_F, mirror(BL_F), mirror(FL_F)]  # foot i sits between hem i and hem i+1
    # Each hem corner is tucked under into a recessed valley fold between two feet.
    valleys = [Vector((h.x * 0.62, h.y * 0.62, 0.03)) for h in hems]
    v = tops + hems + feet + valleys + [Vector((0, 0, 0.05)), Vector((0, 0, 0.52))]
    T, H, F, V, U, K = 0, 4, 8, 12, 16, 17
    faces = []
    for i in range(4):
        j = (i + 1) % 4
        faces += [(T + i, T + j, H + i) if i % 2 == 0 else (T + i, T + j, H + j),
                  (T + j, H + j, H + i) if i % 2 == 0 else (T + i, H + j, H + i)]
        faces.append((H + i, H + j, F + i))                       # base flap down to a foot
        faces += [(H + j, F + j, V + j), (H + j, V + j, F + i)]    # tucked valley under hem j
        faces += [(F + i, V + j, U), (V + j, F + j, U)]            # underside
        faces.append((T + i, K, T + j))                            # top cap, inside the hood
    rig.torso = paper_mesh("Torso", v, faces, rig.torso_hinge, m["paper"], closed=True)

    # Back cape: two panels over the back facets, from the hood rim to the hem.
    verts, faces = [], []
    for side in (-1, 1):
        f = (lambda p: p) if side < 0 else mirror
        tri = (f(SL_T), BC_T, BC_H)
        back = (side * 0.6, 1, 0)
        quad = [plane_point(*tri, x, z, 0.014, back) for x, z in
                ((f(SL_T).x * 1.03, 0.5), (0.0, 0.5), (0.0, 0.135), (f(SL_H).x * 0.99, 0.105))]
        i = len(verts)
        verts += quad
        faces.append((i, i + 1, i + 2, i + 3))
    rig.cape = paper_mesh("Cape", verts, faces, rig.torso_hinge, m["paper"], thickness=0.008,
                          outward=lambda c: c - Vector((0, 0, c.z)))


def build_hood(rig, m):
    centre = Vector((0, 0.03, 0.62))
    v = [PEAK, APEX, FL_C, SL_C, BL_C, BC_C, mirror(BL_C), mirror(SL_C), mirror(FL_C)]
    faces = [(0, i, i + 1) for i in range(1, 8)] + [(0, 8, 1)]
    rig.hood = paper_mesh("Hood", v, faces, rig.hood_hinge, m["paper"], thickness=0.014,
                          outward=lambda c: c - centre)

    # Folded-back brim: a strip lying on each front roof facet along the opening.
    verts, faces = [], []
    width = 0.055
    for f in ((lambda p: p), mirror):
        corner = f(FL_C)
        inner_apex = APEX + (PEAK - APEX).normalized() * width * 1.3
        inner_corner = corner + (PEAK - corner).normalized() * width
        n = (PEAK - APEX).cross(corner - APEX).normalized()
        if n.dot(APEX - centre) < 0:
            n = -n
        i = len(verts)
        verts += [p + n * 0.004 for p in (APEX, corner, inner_corner, inner_apex)]
        faces.append((i, i + 1, i + 2, i + 3))
    rig.brim = paper_mesh("Hood brim", verts, faces, rig.hood_hinge, m["paper"], thickness=0.008,
                          outward=lambda c: c - centre)


HOOD_PLANES = None


def inside_hood(p, margin):
    return inside(p, HOOD_PLANES, margin)


def inside(p, planes, margin):
    """Pulls a point inside every plane (a, b, c, outward normal)."""
    q = Vector(p)
    for a, b, c, outward in planes:
        n = outward
        dist = n.dot(q - a)
        if dist > -margin:
            q -= n * (dist + margin)
    return q


def build_face(rig, m):
    global HOOD_PLANES
    centre = PIVOTS["Insert"]
    # Outward plane normals of the closed hood facets (the front is open).
    planes = []
    tris = [(PEAK, FL_C, SL_C), (PEAK, SL_C, BL_C), (PEAK, BL_C, BC_C)]
    tris += [tuple(mirror(p) for p in t) for t in tris]
    for a, b, c in tris:
        n = (b - a).cross(c - a).normalized()
        if n.dot(a - Vector((0, 0.05, 0.6))) < 0:
            n = -n
        planes.append((a, b, c, n))
    # The front-left/right roof facets only exist above the opening; include them so
    # the dome stays under the brow.
    for a, b, c in [(PEAK, APEX, FL_C), (PEAK, mirror(FL_C), APEX)]:
        n = (b - a).cross(c - a).normalized()
        if n.dot(a - Vector((0, 0.05, 0.6))) < 0:
            n = -n
        planes.append((a, b, c, n))
    HOOD_PLANES = planes
    body = []
    for a, b, c in [(SL_T, FC_T, FC_H), (FC_T, mirror(SL_T), FC_H), (SL_T, BC_T, BC_H), (BC_T, mirror(SL_T), BC_H)]:
        n = (b - a).cross(c - a).normalized()
        if n.dot(a - Vector((0, 0, 0.3))) < 0:
            n = -n
        body.append((a, b, c, n))

    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=48, v_segments=32, radius=1.0)
    for vert in bm.verts:
        x, y, z = vert.co
        p = Vector((x * 0.30, y * 0.15 - 0.02, z * 0.29)) + Vector((0, 0, centre.z))
        if p.z > 0.6 or p.y > -0.05:
            p = inside_hood(p, 0.02)
        if p.z < 0.6:
            p = inside(p, body, 0.012)
        vert.co = p - centre
    rig.insert = kit.mesh_object("Face insert", bm, rig.insert_pivot, m["face"], smooth=True, subdivisions=1)

    # Emerge diamond: two half-diamond cards hinged on the vertical diagonal,
    # dark on the front, ivory on the back and edges.
    rig.card, rig.card_meshes = [], []
    for side in (-1, 1):
        hinge = pivot(f"Card {'L' if side < 0 else 'R'}", rig.head, CARD)
        w, h = 0.27, 0.27
        v = [CARD + Vector((0, 0, h)), CARD + Vector((side * w, 0, 0)), CARD + Vector((0, 0, -h))]
        card = paper_mesh(f"Diamond {'L' if side < 0 else 'R'}", v, [(0, 1, 2)], hinge, m["face"],
                          thickness=0.005, bevel=0.0, rim_mat=m["paper"], outward=lambda c: Vector((0, -1, 0)))
        rig.card.append(hinge)
        rig.card_meshes.append(card)


# Sleeves: folded triangles lying on the front-side facets, hinged at the top.
SLEEVE_TOP = (-0.285, 0.515)
SLEEVE_OUT = (-0.42, 0.265)
SLEEVE_IN = (-0.205, 0.285)


def build_sleeves(rig, m):
    rig.sleeves = {}
    for side in (-1, 1):
        f = (lambda p: p) if side < 0 else mirror
        tri = (f(SL_T), FC_T, FC_H)

        def on(xz, lift):
            return plane_point(*tri, -side * xz[0], xz[1], lift)

        top = on(SLEEVE_TOP, 0.03)
        out = on(SLEEVE_OUT, 0.03) + Vector((0, 0.03, 0))  # wraps the side corner a little
        inn = on(SLEEVE_IN, 0.024)
        mid = (out + inn) * 0.5 + Vector((0, -0.035, 0.0))
        hinge = pivot(f"Sleeve {'L' if side < 0 else 'R'}", rig.torso_hinge, top)
        centre = Vector((0, 0.05, 0.35))
        paper_mesh(f"Sleeve {'L' if side < 0 else 'R'}", [top, out, mid, inn], [(0, 1, 2), (0, 2, 3)],
                   hinge, m["paper"], thickness=0.012, outward=lambda c: c - centre)
        rig.sleeves[side] = hinge


def build():
    m = build_materials()
    rig = kit.Rig()
    rig.root = pivot("Root", None, (0, 0, 0))
    rig.pop = pivot("Pop", rig.root, FACE)
    rig.squash = pivot("Squash", rig.pop, (0, 0, 0))
    rig.lean = pivot("Lean", rig.squash, (0, 0, 0))
    rig.torso_hinge = pivot("Torso hinge", rig.lean, TORSO_HINGE)
    rig.head = pivot("Head", rig.lean, NECK)
    rig.hood_hinge = pivot("Hood hinge", rig.head, HOOD_HINGE)
    rig.insert_pivot = pivot("Insert", rig.head, (0, 0.0, 0.62))
    build_torso(rig, m)
    build_hood(rig, m)
    build_face(rig, m)
    build_sleeves(rig, m)
    rig.face = pivot("Face", rig.head, FACE)
    kit.preview_eyes(rig, lift=0.045)
    rig.keyed = [rig.root, rig.pop, rig.squash, rig.lean, rig.torso_hinge, rig.head, rig.hood_hinge,
                 rig.insert_pivot, *rig.card, *rig.sleeves.values()]
    return rig


def stage(scene, camera):
    # Pale paper blows out under the default rig; keep the planes legible.
    energy = {"Key": 155, "Fill": 28, "Rim left": 110, "Rim right": 90, "Strip": 22, "Under": 8}
    for name, value in energy.items():
        bpy.data.objects[name].data.energy = value
    bpy.data.objects["Rim right"].data.color = (1.0, 0.97, 0.92)


# ---------------------------------------------------------------- poses
#
# Paper does not stretch, so motion is mostly hinge rotation: folds snap fast
# and settle with a small under-damped flutter. Squash stays within a few
# percent (a fold compressing), always volume-preserving in apply_pose.

REST = dict(x=0.0, hop=0.0, yaw=0.0, pop=1.0, squash=1.0, pitch=0.0, roll=0.0,
            head_pitch=0.0, head_roll=0.0, head_lift=0.0, hood=0.0, torso=0.0, insert=1.0,
            card=-math.pi / 2,
            raise_l=0.0, raise_r=0.0, fold_l=0.0, fold_r=0.0)
IDLE_SECONDS = 3.0
SAD = dict(squash=0.955, pitch=math.radians(3), head_pitch=math.radians(12), hood=math.radians(1),
           raise_l=-math.radians(9), raise_r=-math.radians(9), fold_l=math.radians(14), fold_r=math.radians(14))
D = math.radians


def snap(t, period=0.26, damping=0.5):
    """A paper fold snapping into place: fast, one small overshoot."""
    return spring(t, damping, period)


def quiet(t, end, length=0.3):
    """1 until `end - length`, then eases to exactly 0 at `end` (forces clips to land on idle)."""
    return 1 - smoothstep((t - (end - length)) / length)


def blend(a, b, k):
    return {key: a[key] + (b[key] - a[key]) * k if isinstance(a[key], float) else a[key] for key in a}


def tap(t, start, rise=0.06, hold=0.08, fall=0.12):
    """A crisp fold-and-return: snaps in, holds, eases back."""
    x = t - start
    return smoothstep(x / rise) * (1 - smoothstep((x - rise - hold) / fall))


def idle(t, length):
    p = dict(REST)
    phase = 2 * math.pi * t / length
    p["squash"] = 1 + 0.011 * math.sin(phase)
    p["head_pitch"] = -D(0.9) * math.sin(phase)
    # The hood tip sways a little with the breath.
    p["head_roll"] = D(1.3) * math.sin(phase)
    p["raise_l"] = p["raise_r"] = D(2.0) * math.sin(phase)
    # One small paper flick of a sleeve per loop.
    p["fold_r"] = D(10) * tap(t, 1.85, 0.05, 0.05, 0.16)
    p["raise_r"] += D(4) * tap(t, 1.83, 0.05, 0.05, 0.2)
    return p


BASE = idle(0, IDLE_SECONDS)
assert BASE == REST  # every entry clip lands on idle frame 0 by returning to REST


def emerge(t, length):
    """Unfolds from a flat packet: diamond opens, hood rises, body drops, sleeves flip."""
    p = dict(BASE)
    end = quiet(t, length, 0.22)
    p["pop"] = 0.62 + 0.38 * snap(t, 0.2, 0.55)
    # The dark diamond opens like a card, then folds away into the head once framed.
    p["card"] = D(70) * (1 - snap(t, 0.2, 0.6)) - D(90) * smoothstep((t - 0.66) / 0.16)
    p["insert"] = 0.3 + 0.7 * smoothstep((t - 0.12) / 0.3)
    # The hood flap lies folded back, then rises over the top to its peak.
    p["hood"] = -D(160) * (1 - snap(t - 0.1, 0.42, 0.42)) * end
    # The torso lies folded flat behind the diamond, then swings down to the ground.
    p["torso"] = D(96) * (1 - snap(t - 0.34, 0.34, 0.66)) * end
    # Sleeves start folded up under the hood and flip out, left then right.
    p["fold_l"] = -D(160) * (1 - snap(t - 0.5, 0.3, 0.45)) * end
    p["fold_r"] = -D(160) * (1 - snap(t - 0.56, 0.3, 0.45)) * end
    # Landing on the base: a crisp compression, then a little paper bounce.
    land = t - 0.5
    p["squash"] = 1 - (0.07 * math.exp(-7 * land) * math.cos(2 * math.pi * land / 0.32) if land > 0 else 0) * end
    p["head_lift"] = 0.025 * pulse(t, 0.28, 0.3) * end
    p["head_pitch"] = -D(5) * pulse(t, 0.25, 0.4) * end
    return p


def work(t, length):
    """Leaning in, the sleeves fold quickly in turn, like folding something small."""
    p = dict(BASE)
    phase = 2 * math.pi * t / length
    p["pitch"] = D(6) + D(0.8) * math.sin(2 * phase)
    p["head_pitch"] = D(4)
    p["raise_l"] = p["raise_r"] = -D(4)
    beat = length / 4
    for k in range(4):
        start = k * beat
        f = max(tap(t, start), tap(t, start + length))
        side = "l" if k % 2 == 0 else "r"
        # The tip swings in across the chest and folds forward, then snaps back.
        p["fold_" + side] += D(34) * f
        p["raise_" + side] += -D(30) * f
        # Each fold nudges the head and sways the hood tip toward it.
        p["head_pitch"] += D(2.5) * f
        p["head_roll"] += (D(2.2) if side == "l" else -D(2.2)) * f
        p["squash"] -= 0.012 * f
    p["roll"] = D(1.2) * math.sin(phase)
    return p


def wave(t, length):
    """One sleeve snaps up and flutters a hello, then folds back down."""
    p = dict(BASE)
    up = snap(t - 0.14, 0.3, 0.5) * quiet(t, length - 0.12, 0.42)
    flap = math.sin(2 * math.pi * max(0.0, t - 0.4) / 0.42) * smoothstep((t - 0.36) / 0.12) * quiet(t, length - 0.5, 0.3)
    p["raise_r"] = D(138) * up + D(26) * flap * up
    p["fold_r"] = D(18) * math.sin(2 * math.pi * max(0.0, t - 0.47) / 0.42) * smoothstep((t - 0.4) / 0.15) * quiet(t, length - 0.5, 0.3)
    p["raise_l"] = -D(6) * up
    p["roll"] = -D(5) * up
    p["head_roll"] = D(8) * up + D(1.5) * flap
    p["hop"] = 0.025 * pulse(t, 0.08, 0.3)
    p["squash"] = 1 - 0.05 * pulse(t, 0.0, 0.16) + 0.03 * pulse(t, 0.12, 0.22)
    return p


def wait(t, length):
    """Eager: two quick little hops, then a held, attentive breath."""
    p = dict(BASE)
    for start in (0.1, 0.5):
        x = t - start
        crouch = pulse(t, start - 0.06, 0.14)
        air = math.sin(math.pi * x / 0.26) if 0 <= x <= 0.26 else 0.0
        land = pulse(t, start + 0.24, 0.16)
        p["hop"] += 0.05 * air
        p["squash"] += -0.05 * crouch + 0.025 * air - 0.04 * land
        p["raise_l"] += D(30) * air
        p["raise_r"] += D(30) * air
        # The sleeves trail the hop a beat: the paper flutters on landing.
        p["fold_l"] += D(14) * pulse(t, start + 0.18, 0.2)
        p["fold_r"] += D(14) * pulse(t, start + 0.2, 0.2)
        p["head_pitch"] += -D(3) * air + D(3) * land
    p["head_roll"] = D(1.5) * math.sin(2 * math.pi * t / length) * smoothstep((t - 0.8) / 0.2)
    return p


def done(t, length):
    """Crouch, a hop with a crisp twirl and a hood pop, sleeves up, happy settle."""
    p = dict(BASE)
    takeoff, land = 0.26, 0.78
    crouch = smoothstep(t / 0.2) * (1 - smoothstep((t - 0.2) / 0.06))
    p["squash"] = 1 - 0.12 * crouch
    p["head_pitch"] = D(5) * crouch
    p["raise_l"] = p["raise_r"] = -D(10) * crouch
    if takeoff <= t <= land:
        k = (t - takeoff) / (land - takeoff)
        p["hop"] = 0.22 * 4 * k * (1 - k)
        p["squash"] += 0.08 * math.exp(-10 * (t - takeoff))
    if t >= takeoff:  # stays at a full turn after landing, so motion blur never unwinds it
        p["yaw"] = 2 * math.pi * ease_in_out((t - takeoff - 0.03) / (land - takeoff - 0.1))
    after = t - land
    if after > 0:
        p["squash"] -= 0.1 * math.exp(-8 * after) * math.cos(2 * math.pi * after / 0.3)
        p["head_roll"] = D(5) * math.exp(-4 * after) * math.sin(2 * math.pi * after / 0.45)
    # Sleeves snap up as it leaves the ground and stay up, fluttering, then fold down.
    arms = snap(t - 0.22, 0.26, 0.5) * quiet(t, length - 0.15, 0.55)
    p["raise_l"] += D(118) * arms
    p["raise_r"] += D(118) * arms
    flutter = math.sin(2 * math.pi * max(0.0, t - 0.85) / 0.28) * smoothstep((t - 0.82) / 0.1) * quiet(t, length - 0.6, 0.3)
    p["fold_l"] += D(14) * flutter
    p["fold_r"] -= D(14) * flutter
    # Hood pop at the top of the hop: the head jumps up in its collar and springs back.
    pop = snap(t - 0.42, 0.22, 0.35) - snap(t - 0.56, 0.3, 0.45)
    p["head_lift"] = 0.045 * pop
    p["hood"] = -D(8) * pop
    p["squash"] = 1 + (p["squash"] - 1) * quiet(t, length, 0.25)
    p["head_roll"] *= quiet(t, length, 0.25)
    return p


def sad(t, length):
    p = dict(BASE)
    p.update(SAD)
    phase = 2 * math.pi * t / length
    p["squash"] += 0.008 * math.sin(phase)
    p["head_pitch"] += D(1.5) * math.sin(phase - 0.6) * math.sin(phase)
    p["head_roll"] = D(1.2) * math.sin(phase)
    return p


def fail(t, length):
    """A small flinch, then a restrained slump: the hood droops forward."""
    p = dict(BASE)
    flinch = tap(t, 0.0, 0.08, 0.14, 0.22)
    slump = smoothstep((t - 0.42) / 0.55)
    p = blend(p, sad(0, SAD_SECONDS), slump)
    p["raise_l"] += D(22) * flinch
    p["raise_r"] += D(22) * flinch
    p["head_lift"] += 0.02 * flinch
    p["squash"] += 0.03 * flinch
    # The hood keeps falling a touch past rest and settles: paper overshoot.
    droop = t - 0.95
    if droop > 0:
        p["head_pitch"] += D(3) * math.exp(-6 * droop) * math.sin(2 * math.pi * droop / 0.45)
    p["squash"] += 0.012 * pulse(t, 1.25, 0.6)
    p["head_pitch"] -= D(2) * pulse(t, 1.25, 0.6)
    p["head_pitch"] = sad(0, SAD_SECONDS)["head_pitch"] + (p["head_pitch"] - sad(0, SAD_SECONDS)["head_pitch"]) * quiet(t, length, 0.3)
    return p


SAD_SECONDS = 3.2
CLIPS = {
    "emerge": kit.Clip(emerge, 1.2, False),
    "idle": kit.Clip(idle, IDLE_SECONDS, True),
    "work": kit.Clip(work, 1.5, True),
    "done": kit.Clip(done, 2.4, False),
    "wave": kit.Clip(wave, 2.2, False),
    "wait": kit.Clip(wait, 1.75, True),
    "fail": kit.Clip(fail, 2.0, False),
    "sad": kit.Clip(sad, SAD_SECONDS, True),
}


def apply_pose(rig, p):
    rig.root.location = (p["x"], 0, p["hop"])
    rig.root.rotation_euler = (0, 0, p["yaw"])
    rig.pop.scale = (p["pop"],) * 3
    s = max(0.3, p["squash"])
    side = 1 / math.sqrt(s)
    rig.squash.scale = (side, side, s)
    rig.lean.rotation_euler = (p["pitch"], p["roll"], 0)
    rig.head.rotation_euler = (p["head_pitch"], p["head_roll"], 0)
    rig.head.location = NECK - PIVOTS["Lean"] + Vector((0, 0, p["head_lift"]))
    rig.hood_hinge.rotation_euler = (p["hood"], 0, 0)
    rig.torso_hinge.rotation_euler = (p["torso"], 0, 0)
    rig.insert_pivot.scale = (p["insert"],) * 3
    for i, side in enumerate((-1, 1)):
        rig.card[i].rotation_euler = (0, 0, -side * p["card"])
    # raise swings the tip out and up about the forward axis; fold flaps it towards the camera.
    rig.sleeves[-1].rotation_euler = (-p["fold_l"], p["raise_l"], 0)
    rig.sleeves[1].rotation_euler = (-p["fold_r"], -p["raise_r"], 0)


def keyframe(rig):
    hidden = abs(rig.card[0].rotation_euler.z) > math.radians(80)
    for card in rig.card_meshes:
        card.hide_render = hidden
        card.keyframe_insert("hide_render")


kit.run(sys.modules[__name__])
