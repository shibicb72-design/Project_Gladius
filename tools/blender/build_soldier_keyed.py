"""M2 AN2 items 3 and 5: hand-keyed third-person clips on the soldier's own 22-bone rig, authored in Blender.

    blender.cmd -b --factory-startup --python tools/blender/build_soldier_keyed.py -- [--out=<repo-relative .glb>]
        [--only=<clip,clip>] [--preview=<dir under build/an2/preview>] [--no-mesh]

Writes assets/generated/characters/soldier_keyed.glb: the armature "Armature" (gladius_bl.soldier_armature(), the same
22 bones and identity rests as soldier.glb, soldier_clips.glb and the runtime skeleton) with one action per clip and
nothing else (no mesh, no material). Looping clips are named <clip>_Loop (Godot loops them and drops the suffix).
Built from scratch: no source clip, manifest derived_from "".

How a clip is authored (CLIPS below): a pose table, one row per key time. A row only lists what changes; every
channel is a number (pelvis position and turn, spine / chest / head turns in degrees about the bone's own X, Y, Z as
data/anim.json says, hand and foot TARGETS in metres with their orientation and an elbow / knee pole). Each channel is
interpolated with a monotone cubic (flat at holds and at the ends of one-shots, periodic over a loop seam), so moves
ease in and out and never overshoot a key; overshoot and settle are keys of their own. Every frame (30 fps) the arms
and legs are solved two-bone onto their targets (in the clip's frame, the chest frame or the gun's), so a planted
foot or a hand on a rung stays exactly where it is put. The right hand IS the gun (the runtime mounts the rifle on the
RightHand bone with an identity turn): a "gun" row (grip point, barrel direction, top direction) places it, and the
left hand goes to that gun's foregrip (data/art_soldier.json soldier.gun default), where the runtime's left-hand IK
puts it too, so the clip agrees with the IK instead of fighting it.

Conventions (the item-2 file's): pose-bone quaternions = Godot bone-local rotations (identity rests); Hips and Neck
are roots with position keys. The cover clips keep the Neck at rest (CoverAnim puts it on the head hitbox); the
other clips carry the Neck on the chest top (SoldierPose blends them whole-body, the helmet follows the body).

Prints one KEYED_CLIP line per clip (length, IK miss, arm clearance against the torso, lowest mesh point, wall
clearance for cover clips, rung slip for the ladder) and one KEYED_CLIPS summary line; records the file in
tools/blender/manifest.json. --preview=<dir>: side and front strips (10 frames) of the near mesh posed by every clip,
with a stand-in wall, ladder rungs or ledge, under build/an2/preview/<dir>/.
"""

import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gladius_bl as gbl  # noqa: E402
import soldier_data  # noqa: E402
import build_soldier_clips as bsc  # noqa: E402

OUT = "assets/generated/characters/soldier_keyed.glb"
SCRATCH = "build/an2/scratch/soldier_keyed_only.glb"
ME = "tools/blender/build_soldier_keyed.py"
FPS = gbl.FPS
SIDES = ("Left", "Right")
MISSES = {}  # per limb, the worst IK miss (m) of the clip being baked (reported, then cleared)


# --- small maths --------------------------------------------------------------------------------------------------------
def V(v):
    return Vector((float(v[0]), float(v[1]), float(v[2])))


def E(deg):
    """Godot Quaternion.from_euler (order YXZ: Y * X * Z) of degrees."""
    x, y, z = (math.radians(float(a)) for a in deg)
    return (Quaternion((0.0, 1.0, 0.0), y) @ Quaternion((1.0, 0.0, 0.0), x) @ Quaternion((0.0, 0.0, 1.0), z)).normalized()


def look(fwd, up):
    """The rotation whose -Z is fwd and whose +Y is as close to up as it can be (the gun frame: barrel -Z, top +Y)."""
    z = -V(fwd).normalized()
    x = V(up).cross(z).normalized()
    y = z.cross(x)
    return Matrix(((x.x, y.x, z.x), (x.y, y.y, z.y), (x.z, y.z, z.z))).to_quaternion().normalized()


def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def mono_cubic(ts, vs, loop):
    """Monotone cubic Hermite (Fritsch-Carlson) through (ts, vs); flat at the ends of a one-shot, periodic over a loop."""
    n = len(ts)
    if n == 1:
        return lambda t: vs[0]
    h = [ts[i + 1] - ts[i] for i in range(n - 1)]
    d = [(vs[i + 1] - vs[i]) / h[i] for i in range(n - 1)]

    def harmonic(d0, d1, h0, h1):
        if d0 * d1 <= 0.0:
            return 0.0
        return 3.0 * (h0 + h1) / ((2.0 * h1 + h0) / d0 + (h1 + 2.0 * h0) / d1)

    m = [0.0] * n
    for i in range(1, n - 1):
        m[i] = harmonic(d[i - 1], d[i], h[i - 1], h[i])
    if loop and n > 2:
        m[0] = m[n - 1] = harmonic(d[n - 2], d[0], h[n - 2], h[0])

    def f(t):
        if t <= ts[0]:
            return vs[0]
        if t >= ts[-1]:
            return vs[-1]
        i = 0
        while i < n - 2 and t > ts[i + 1]:
            i += 1
        u = (t - ts[i]) / h[i]
        h00 = 2 * u ** 3 - 3 * u ** 2 + 1
        h10 = u ** 3 - 2 * u ** 2 + u
        h01 = -2 * u ** 3 + 3 * u ** 2
        h11 = u ** 3 - u ** 2
        return h00 * vs[i] + h10 * h[i] * m[i] + h01 * vs[i + 1] + h11 * h[i] * m[i + 1]
    return f


def flatten(d, prefix="", out=None):
    out = {} if out is None else out
    for k, v in d.items():
        p = prefix + k
        if isinstance(v, dict):
            flatten(v, p + ".", out)
        elif isinstance(v, (list, tuple)):
            for i, x in enumerate(v):
                out[p + "." + str(i)] = float(x)
        else:
            out[p] = float(v)
    return out


def unflatten(flat):
    out = {}
    for path, value in flat.items():
        parts = path.split(".")
        node = out
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        node[parts[-1]] = value
    return _lists(out)


def _lists(node):
    if not isinstance(node, dict):
        return node
    if node and all(k.isdigit() for k in node):
        return [node[str(i)] for i in range(len(node))]
    return {k: _lists(v) for k, v in node.items()}


def deep_merge(base, over):
    out = json.loads(json.dumps(base))
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = json.loads(json.dumps(v))
    return out


# --- the rig --------------------------------------------------------------------------------------------------------------
class KRig:
    """The soldier's rests (soldier_data.rest_table(): the runtime's own) and forward kinematics; the interface
    build_soldier_clips.MeshCheck and write_action use (bones, rest, local, fk)."""

    def __init__(self):
        self.rows = soldier_data.rest_table()
        self.bones = [b for b, _p, _a in self.rows]
        self.parent = {b: p for b, p, _a in self.rows}
        self.rest = {b: Vector(a) for b, _p, a in self.rows}
        self.local = {b: (self.rest[b] - self.rest[p]) if p else self.rest[b].copy() for b, p, _a in self.rows}

    def fk(self, loc, hips, neck):
        grot, gpos = {}, {}
        for b in self.bones:
            p = self.parent[b]
            if not p:
                grot[b] = loc[b]
                gpos[b] = hips.copy() if b == "Hips" else neck.copy()
            else:
                grot[b] = grot[p] @ loc[b]
                gpos[b] = gpos[p] + grot[p] @ self.local[b]
        return grot, gpos


def frame_rot(a, h, a2, h2):
    """The rotation taking direction a to a2 and the axis h (made normal to a) to h2 (made normal to a2)."""
    h = (h - a * h.dot(a)).normalized()
    h2 = (h2 - a2 * h2.dot(a2)).normalized()
    m1 = Matrix((h, a, h.cross(a))).transposed()
    m2 = Matrix((h2, a2, h2.cross(a2))).transposed()
    return (m2 @ m1.transposed()).to_quaternion().normalized()


def two_bone(rig, loc, parent_q, root, names, target, pole, end_q):
    """Solves upper/mid/end onto target (global), bending toward pole; end bone global rotation end_q.
    Writes the three local rotations; returns the miss (m) when the target is out of reach."""
    upper, mid, end = names
    a_v, b_v = rig.local[mid], rig.local[end]
    a, b = a_v.length, b_v.length
    to = target - root
    dist = max(abs(a - b) + 1e-4, min(a + b - 1e-4, to.length))
    dirn = to.normalized()
    bend = pole - dirn * pole.dot(dirn)
    if bend.length < 1e-6:
        bend = parent_q @ Vector((0.0, 0.0, -1.0))
    bend.normalize()
    along = (a * a + dist * dist - b * b) / (2.0 * dist)
    elbow = root + dirn * along + bend * math.sqrt(max(a * a - along * along, 0.0))
    tip = root + dirn * dist
    # No free roll: each bone's hinge axis (its rest X, -X for the knee: the elbow bends about +X, the knee about -X)
    # is laid on the bend plane's normal, so the twist is continuous from frame to frame (a minimal-arc turn flips).
    hinge = bend.cross(dirn).normalized()
    rest_h = Vector((-1.0, 0.0, 0.0)) if "Leg" in upper else Vector((1.0, 0.0, 0.0))
    ru = frame_rot(a_v.normalized(), rest_h, (elbow - root).normalized(), hinge)
    rm = frame_rot(b_v.normalized(), rest_h, (tip - elbow).normalized(), hinge)
    loc[upper] = (parent_q.inverted() @ ru).normalized()
    loc[mid] = (ru.inverted() @ rm).normalized()
    loc[end] = (rm.inverted() @ end_q).normalized()
    return (tip - target).length


class Gun:
    def __init__(self):
        art = gbl.read_json("data/art_soldier.json")["soldier"]["gun"]
        g = art["weapons"][art["default"]]
        s = float(g["scale"])
        self.grip_to_fore = (V(g["foregrip_m"]) - V(g["grip_m"])) * s
        self.grip_to_muzzle = (V(g["muzzle_m"]) - V(g["grip_m"])) * s if "muzzle_m" in g else Vector((0.0, 0.1, -0.7))


def solve_frame(rig, gun, P, clip):
    """One frame: the pose row P (interpolated numbers) -> {"loc", "hips", "neck"} + the IK miss."""
    loc = {b: Quaternion() for b in rig.bones}
    hips = V(P["hips"])
    hq = E(P.get("hrot", (0, 0, 0)))
    loc["Hips"] = hq
    loc["Spine"] = E(P.get("spine", (0, 0, 0)))
    loc["Chest"] = E(P.get("chest", (0, 0, 0)))
    spine_q = hq @ loc["Spine"]
    spine_p = hips + hq @ rig.local["Spine"]
    chest_q = spine_q @ loc["Chest"]
    chest_p = spine_p + spine_q @ rig.local["Chest"]
    if clip.get("carry_neck"):
        neck = chest_p + chest_q @ (rig.rest["Neck"] - rig.rest["Chest"])
        loc["Neck"] = (chest_q @ E(P.get("neck", (0, 0, 0)))).normalized()
    else:
        neck = rig.rest["Neck"] + V(P.get("neck_at", (0, 0, 0)))
        loc["Neck"] = E(P.get("neck", (0, 0, 0)))
    loc["Head"] = E(P.get("head", (0, 0, 0)))
    frames = {"world": (Vector(), Quaternion()), "chest": (chest_p, chest_q), "hips": (hips, hq)}

    def place(frame, at, q, pole):
        o, r = frames[frame]
        return o + r @ V(at), (r @ q).normalized(), r @ V(pole)

    miss = 0.0
    targets = {}
    if "gun" in P:
        g = P["gun"]
        at, q, pole = place(clip.get("gun_frame", "chest"), g["at"], look(g["dir"], g["up"]), g.get("pole", (1, -1, 0.5)))
        targets["Right"] = (at, q, pole)
        if clip.get("left_on_gun", True) and "Left" not in P.get("hand", {}):
            lpole = V(g.get("lpole", (-1, -1, 0.3)))
            targets["Left"] = (at + q @ gun.grip_to_fore, (q @ E(P.get("lgrip", (0, 0, 100)))).normalized(),
                               frames[clip.get("gun_frame", "chest")][1] @ lpole)
    for side, h in P.get("hand", {}).items():
        targets[side] = place(clip.get("hand_frame", {}).get(side, "world"), h["at"], E(h.get("rot", (0, 0, 0))), h.get("pole", (0, -1, 0)))
    for side in SIDES:
        root = chest_p + chest_q @ rig.local[side + "UpperArm"]
        names = (side + "UpperArm", side + "ForeArm", side + "Hand")
        if side in targets:
            at, q, pole = targets[side]
            m = two_bone(rig, loc, chest_q, root, names, at, pole, q)
            if m > 0.005:
                MISSES[side + "Arm"] = max(MISSES.get(side + "Arm", 0.0), m)
            miss = max(miss, m)
        else:
            arm = P.get("arm", {}).get(side, {})
            for n in names:
                loc[n] = E(arm.get(n[len(side):], (0, 0, 0)))
        fing = P.get("fingers", {}).get(side)
        if fing is not None:
            loc[side + "Fingers"] = E(fing)
    for side in SIDES:
        f = P.get("foot", {}).get(side)
        names = (side + "UpperLeg", side + "LowerLeg", side + "Foot")
        if f is not None:
            root = hips + hq @ rig.local[side + "UpperLeg"]
            m = two_bone(rig, loc, hq, root, names, V(f["at"]), V(f.get("pole", (0, 0, -1))), E(f.get("rot", (0, 0, 0))))
            if m > 0.005:
                MISSES[side + "Leg"] = max(MISSES.get(side + "Leg", 0.0), m)
            miss = max(miss, m)
        else:
            leg = P.get("leg", {}).get(side, {})
            for n in names:
                loc[n] = E(leg.get(n[len(side):], (0, 0, 0)))
        toes = P.get("toes", {}).get(side)
        if toes is not None:
            loc[side + "Toes"] = E(toes)
    # forward-kinematics check of the solve (the FK the game and the previews run)
    _gr, gp = rig.fk(loc, hips, neck)
    for side, (at, _q, _p) in targets.items():
        m = (gp[side + "Hand"] - at).length
        if m > 0.005:
            MISSES[side + "Arm(fk)"] = max(MISSES.get(side + "Arm(fk)", 0.0), m)
    for side in SIDES:
        f = P.get("foot", {}).get(side)
        if f is not None:
            m = (gp[side + "Foot"] - V(f["at"])).length
            if m > 0.005:
                MISSES[side + "Leg(fk)"] = max(MISSES.get(side + "Leg(fk)", 0.0), m)
    return {"loc": loc, "hips": hips, "neck": neck}, miss


def bake(rig, gun, clip):
    """The clip's keys -> one frame per 1/30 s (the last frame of a loop equals the first)."""
    loop = bool(clip.get("loop"))
    rows, merged = [], {}
    for key in clip["keys"]:
        merged = deep_merge(merged, {k: v for k, v in key.items() if k != "t"})
        rows.append((float(key["t"]), flatten(merged)))
    length = float(clip["length"])
    if loop and abs(rows[-1][0] - length) > 1e-6:
        rows.append((length, dict(rows[0][1])))
    channels = sorted(set().union(*[set(r[1]) for r in rows]))
    curves = {}
    for c in channels:
        ts, vs, last = [], [], None
        for t, flat in rows:
            last = flat.get(c, last)
            if last is None:
                continue
            ts.append(t)
            vs.append(last)
        curves[c] = mono_cubic(ts, vs, loop)
    n = int(round(length * FPS))
    frames, worst = [], 0.0
    for f in range(n + 1):
        t = min(length, f / float(FPS))
        P = unflatten({c: curves[c](t) for c in channels})
        fr, miss = solve_frame(rig, gun, P, clip)
        frames.append(fr)
        worst = max(worst, miss)
    if loop:
        frames[n] = bsc.copy_frame(frames[0])
    return frames, worst


def mirror(rig, frames):
    """The left-right mirror image (x -> -x): Left and Right bones swap, rotations mirror in the YZ plane."""
    out = []
    for fr in frames:
        loc = {}
        for b in rig.bones:
            src = b.replace("Left", "#").replace("Right", "Left").replace("#", "Right")
            q = fr["loc"][src]
            loc[b] = Quaternion((q.w, q.x, -q.y, -q.z))
        out.append({"loc": loc, "hips": Vector((-fr["hips"].x, fr["hips"].y, fr["hips"].z)),
                    "neck": Vector((-fr["neck"].x, fr["neck"].y, fr["neck"].z))})
    return out


# --- authoring ------------------------------------------------------------------------------------------------------------
def cfg():
    c = soldier_data.config()["keyed"]
    cover = gbl.read_json("data/cover.json")
    return c, cover


AIMED = {"at": [0.17, -0.25, -0.30], "dir": [0.0, 0.0, -1.0], "up": [0.0, 1.0, 0.0], "pole": [1, -1, 0.6], "lpole": [-1, -1.2, 0]}
LOW_READY = {"at": [0.12, -0.22, -0.17], "dir": [-0.6, -0.25, -1.0], "up": [0.0, 1.0, -0.1], "pole": [1, -1, 0.6], "lpole": [-1, -1.2, 0]}
PORT = {"at": [0.07, -0.31, -0.25], "dir": [-0.45, 1.0, -0.12], "up": [0.18, 0.12, -1.0], "pole": [1, -1, 0.9], "lpole": [-1, -1.4, 0.4]}
STAND_FEET = {"Left": {"at": [-0.135, 0.09, -0.06], "rot": [0, 6, 0], "pole": [-0.1, 0, -1]},
              "Right": {"at": [0.135, 0.09, -0.06], "rot": [0, -6, 0], "pole": [0.1, 0, -1]}}
NEUTRAL = {"hips": [0.0, 0.955, 0.0], "hrot": [0, 0, 0], "spine": [0, 0, 0], "chest": [0, 0, 0], "head": [0, 0, 0],
           "gun": LOW_READY, "foot": STAND_FEET}

# Behind high cover, wall on the left and behind (side +1; CoverAnim faces the model along the wall, turned out by
# hug_out_deg): back and left shoulder on the wall, weight on the wall-side leg, the rifle upright at port arms.
HUG_HIGH = {"hips": [-0.05, 0.935, 0.035], "hrot": [2, 6, 3], "spine": [1, -4, 4], "chest": [0, -5, 2], "head": [-3, -14, -2],
            "gun": PORT, "foot": {"Left": {"at": [-0.175, 0.09, 0.02], "rot": [0, 14, 0], "pole": [-0.2, 0, -1]},
                                  "Right": {"at": [0.16, 0.09, -0.12], "rot": [0, -16, 0], "pole": [0.3, 0, -1]}}}
HUG_HIGH_IN = {"hips": [-0.05, 0.939, 0.035], "chest": [-1.4, -5, 2]}  # breath in: the chest lifts, the pelvis rises

# Behind low cover: down on the left knee, the right foot planted, back rounded under the lowered helmet (the head
# hitbox sits at cover.json crouch_head_y_m: the torso folds forward to put the chest top under it), rifle upright.
HUG_LOW = {"hips": [0.0, 0.36, 0.36], "hrot": [-48, 8, 0], "spine": [-14, -4, 3], "chest": [-12, -6, 0], "head": [-4, -12, 0],
           "gun": {"at": [0.08, -0.15, -0.25], "dir": [-0.3, 0.42, 0.92], "up": [0.1, 1.0, -0.08], "pole": [1, 0, 0.5], "lpole": [-1, 0, 0.5]},
           "foot": {"Left": {"at": [-0.16, 0.17, 0.56], "rot": [-55, 4, 0], "pole": [0, -0.3, -1]},
                    "Right": {"at": [0.17, 0.09, -0.12], "rot": [0, -10, 0], "pole": [0.3, 0.6, -1]}},
           "toes": {"Left": [55, 0, 0]}, "neck_at": [0.0, -0.9, 0.0]}  # the Neck where CoverAnim puts it (head hitbox 0.85)
HUG_LOW_IN = {"hips": [0.0, 0.364, 0.36], "chest": [-13.2, -6, 0]}

# Leaning out round the right edge (the aimed layer owns the chest and arms at runtime; the gun row is for the preview):
# the right foot steps out, the hips sway back against the lean, the spine leans out.
LEAN = {"hips": [-0.03, 0.935, 0.0], "hrot": [0, -4, -3], "spine": [-2, -2, -8], "chest": [0, 0, 0], "head": [0, 0, 0], "gun": LOW_READY,
        "foot": {"Left": {"at": [-0.16, 0.09, 0.08], "rot": [0, 10, 0], "pole": [-0.1, 0, -1]},
                 "Right": {"at": [0.30, 0.09, -0.12], "rot": [0, -20, 0], "pole": [0.4, 0, -1]}}}

# Risen to fire from cover (standing, square, the right foot back): the stance under the aimed layer.
RISE = {"hips": [0.0, 0.935, 0.02], "hrot": [-3, -10, 0], "spine": [-3, 6, 0], "chest": [-2, 4, 0], "head": [0, 0, 0], "gun": LOW_READY,
        "foot": {"Left": {"at": [-0.15, 0.09, -0.11], "rot": [0, 8, 0], "pole": [-0.1, 0, -1]},
                 "Right": {"at": [0.17, 0.09, 0.10], "rot": [0, -25, 0], "pole": [0.2, 0, -1]}}}


def cover_clips(cover):
    out = []
    out.append({"name": "cover_hug_high", "loop": True, "length": 3.0, "wall": True, "keys": [
        dict(t=0.0, **HUG_HIGH),
        {"t": 1.0, "head": [-3, -22, -2]},
        {"t": 1.5, **HUG_HIGH_IN},
        {"t": 2.3, "head": [-3, -10, -2], "hips": [-0.05, 0.936, 0.035], "chest": [-0.6, -5, 2]},
        dict(t=3.0, **HUG_HIGH)]})
    out.append({"name": "cover_hug_low", "loop": True, "length": 3.0, "wall": True, "low": True, "keys": [
        dict(t=0.0, **HUG_LOW),
        {"t": 1.2, **HUG_LOW_IN, "head": [-4, -20, 0]},
        {"t": 2.2, "hips": [0.0, 0.362, 0.36], "chest": [-12.5, -6, 0], "head": [-4, -8, 0]},
        dict(t=3.0, **HUG_LOW)]})
    out.append({"name": "cover_lean_right", "loop": True, "length": 2.0, "keys": [
        dict(t=0.0, **LEAN),
        {"t": 1.0, "spine": [-2, -2, -9], "hips": [-0.032, 0.932, 0.0]},
        dict(t=2.0, **LEAN)]})
    out.append({"name": "cover_rise", "loop": True, "length": 2.0, "mirror": False, "keys": [
        dict(t=0.0, **RISE),
        {"t": 1.0, "hips": [0.005, 0.932, 0.02], "spine": [-3.5, 6, 0]},
        dict(t=2.0, **RISE)]})
    # From standing free to the hug: a dip (anticipation), the right foot steps, the shoulder meets the wall
    # (the pelvis overshoots into it) and settles. CoverAnim plays it over cover.json enter_s.
    out.append({"name": "cover_enter", "length": 0.5, "wall": True, "keys": [
        dict(t=0.0, **NEUTRAL),
        {"t": 0.13, "hips": [0.02, 0.91, -0.02], "spine": [-4, 0, 0], "hrot": [0, 3, 0],
         "foot": {"Right": {"at": [0.15, 0.16, -0.11], "rot": [-15, -8, 0]}}},
        {"t": 0.33, "hips": [-0.07, 0.932, 0.045], "hrot": [3, 7, 4], "spine": [1, -4, 5], "chest": [0, -5, 2],
         "head": [-3, -10, -2], "gun": PORT, "foot": HUG_HIGH["foot"]},
        dict(t=0.5, **HUG_HIGH)]})
    # From the hug back out: load into the wall, push off (the pelvis overshoots away from it), the left foot steps in.
    out.append({"name": "cover_exit", "length": 0.5, "wall": True, "keys": [
        dict(t=0.0, **HUG_HIGH),
        {"t": 0.13, "hips": [-0.075, 0.925, 0.05], "spine": [0, -2, 6]},
        {"t": 0.33, "hips": [0.04, 0.95, -0.03], "hrot": [0, 0, -2], "spine": [-2, 0, 0], "chest": [0, 0, 0], "head": [0, 0, 0],
         "gun": LOW_READY, "foot": {"Left": {"at": [-0.14, 0.13, -0.08], "rot": [-10, 6, 0]}, "Right": STAND_FEET["Right"]}},
        dict(t=0.5, **NEUTRAL)]})
    return out


def ladder_clips(c):
    """ladder_up: the body rises cycle_m per cycle; in the clip's frame (the pawn's feet on the climb line, the rungs
    climb_offset_m ahead) the rungs move down at that rate. Each hand and foot holds its rung for half a cycle (moving
    down with it) and moves up cycle_m in the other half, opposite hand and foot together (right hand + left foot,
    then left hand + right foot). Rungs sit at multiples of rung_m at time 0."""
    lad = c["ladder"]
    D, s, L = float(lad["cycle_m"]), float(lad["rung_m"]), 1.0
    z_rung = -(float(lad["climb_offset_m"]) - 0.04)
    hand_z, foot_z = z_rung + 0.02, z_rung + 0.06
    # stance start heights (a rung at that phase): right hand 1.35 at p .5, left hand 1.5 at p 0,
    # right foot 0.3 at p 0, left foot 0.45 at p .5 (soles on the rung top: ankle 0.105 above the rung).
    # The whole climber sits one rung (0.3 m) lower than the first trial, so the body is near the pawn's capsule and the
    # top step starts from a body just over the ledge (at the ladder's foot the lowest foot dips 4 cm for an instant).
    limbs = {"hand_R": (0.5, 1.35), "hand_L": (0.0, 1.50), "foot_R": (0.0, 0.30), "foot_L": (0.5, 0.45)}

    def limb_y(name, p):
        start, top = limbs[name]
        q = (p - start) % 1.0
        if q < 0.5:  # stance: on the rung, moving down with it
            return top - D * q / L, 0.0, 0.0
        u = (q - 0.5) / 0.5  # swing: from the low end back up to the next rung
        e = smooth(u)
        return top - D * 0.5 + D * 0.5 * e, math.sin(math.pi * u), u

    keys = []
    n = int(round(L * FPS))
    for f in range(n + 1):
        p = f / float(n)
        row = {"t": p * L}
        hy = {}
        for side, tag in (("Right", "R"), ("Left", "L")):
            y, arc, u = limb_y("hand_" + tag, p)
            hy[side] = (y, arc)
            x = 0.17 if tag == "R" else -0.17
            row.setdefault("hand", {})[side] = {"at": [x, y + 0.03, hand_z + 0.10 * arc], "rot": [72 - 20 * arc, 0, 0],
                                                "pole": [0.6 if tag == "R" else -0.6, -1.0, 0.6]}
            fy, farc, _fu = limb_y("foot_" + tag, p)
            fx = 0.13 if tag == "R" else -0.13
            row.setdefault("foot", {})[side] = {"at": [fx, fy + 0.105 + 0.03 * farc, foot_z + 0.13 * farc],
                                                "rot": [-25 * farc, 0, 0], "pole": [0.7 if tag == "R" else -0.7, 0.2, -0.7]}
        # the body follows the reaching hand: a small roll and yaw toward it, a bob at twice the step rate
        reach = (hy["Left"][0] - hy["Right"][0]) / (D * 0.5)  # +1 left hand high .. -1 right hand high
        row["hips"] = [0.015 * reach, 0.75 + 0.012 * math.cos(4 * math.pi * p), -0.09]
        row["hrot"] = [-4, 3 * reach, 2 * reach]
        row["spine"] = [-4, 2 * reach, 2 * reach]
        row["chest"] = [-2, 2 * reach, 1.5 * reach]
        row["head"] = [14 + 3 * math.cos(4 * math.pi * p), 6 * reach, 0]
        keys.append(row)
    up = {"name": "ladder_up", "loop": True, "length": L, "carry_neck": True, "ladder": True, "no_gun": True, "keys": keys}
    # Start on the nominal ladder's exit phase. The live handoff covers the variation from
    # different climb speeds and the last rendered frame falling between baked samples.
    props = gbl.read_json("data/props.json")["ladder"]
    exit_height = float(props["look_size"][1]) - float(props["rail_above_m"]) + float(props["top_rise_m"])
    exit_key = round((exit_height / D % 1.0) * n)
    cu = V(lad["top_catchup_m"])
    k0 = json.loads(json.dumps(keys[exit_key]))
    k0["t"] = 0.0
    for side in ("Right", "Left"):
        k0["hand"][side]["at"] = list(V(k0["hand"][side]["at"]) + cu)
        k0["foot"][side]["at"] = list(V(k0["foot"][side]["at"]) + cu)
    k0["hips"] = list(V(k0["hips"]) + cu)
    edge_z = cu.z - float(lad["climb_offset_m"])
    top = {"name": "ladder_top", "length": 0.8, "carry_neck": True, "ledge": edge_z, "no_gun": True, "keys": [
        k0,
        {"t": 0.22, "hips": [0.02, 0.98 + cu.y, cu.z - 0.25], "hrot": [-26, 0, 0], "spine": [-10, 0, 0], "chest": [-6, 0, 0], "head": [-6, 0, 0],
         "hand": {"Right": {"at": [0.265, 0.92, edge_z + 0.03], "rot": [150, 0, 0], "pole": [1, 0.2, 1]},
                  "Left": {"at": [-0.265, 0.92, edge_z + 0.03], "rot": [150, 0, 0], "pole": [-1, 0.2, 1]}},
         "foot": {"Right": {"at": [0.14, 0.42, edge_z - 0.02], "rot": [-10, 0, 0], "pole": [0.2, 0.6, -1]}}},
        {"t": 0.45, "hips": [0.03, 1.0, cu.z - 0.85], "hrot": [-14, 0, 0], "spine": [-6, 0, 0], "chest": [-4, 0, 0],
         "foot": {"Right": {"at": [0.14, 0.09, edge_z - 0.30], "rot": [0, -4, 0], "pole": [0.2, 0, -1]},
                  "Left": {"at": [-0.13, 0.30, edge_z - 0.05], "rot": [-20, 0, 0], "pole": [-0.2, 0.4, -1]}},
         "hand": {"Right": {"at": [0.33, 0.92, cu.z - 0.80], "rot": [40, 0, 0], "pole": [1, -0.3, 1]},
                  "Left": {"at": [-0.33, 0.92, cu.z - 0.80], "rot": [40, 0, 0], "pole": [-1, -0.3, 1]}}},
        {"t": 0.62, "hips": [0.01, 0.97, 0.12], "hrot": [-5, 0, 0], "spine": [-2, 0, 0], "chest": [0, 0, 0], "head": [0, 0, 0],
         "foot": {"Left": {"at": [-0.135, 0.12, 0.0], "rot": [-8, 6, 0]}},
         "hand": {"Right": {"at": [0.38, 0.86, -0.04], "rot": [10, 0, 0], "pole": [1, 0, 1]}, "Left": {"at": [-0.38, 0.86, -0.04], "rot": [10, 0, 0], "pole": [-1, 0, 1]}}},
        {"t": 0.8, "hips": [0.0, 0.955, 0.0], "hrot": [0, 0, 0], "foot": STAND_FEET,
         "hand": {"Right": {"at": [0.39, 0.82, -0.07], "rot": [0, 0, 0]}, "Left": {"at": [-0.39, 0.82, -0.07], "rot": [0, 0, 0]}}}]}
    return [up, top]


def action_clips():
    stand = dict(NEUTRAL)
    door = {"name": "door_open", "length": 0.6, "carry_neck": True, "keys": [
        dict(t=0.0, **stand),
        {"t": 0.16, "chest": [0, 8, 0], "spine": [0, 4, 0], "head": [0, 6, 0],
         "hand": {"Left": {"at": [-0.20, 1.30, -0.42], "rot": [165, -10, 0], "pole": [-1, -0.6, 0.2]}}},
        {"t": 0.30, "chest": [-8, -2, 0], "spine": [-4, -2, 0], "hips": [0.0, 0.95, -0.03], "head": [-2, 0, 0],
         "hand": {"Left": {"at": [-0.17, 1.30, -0.54], "rot": [172, -6, 0]}}},
        {"t": 0.40, "chest": [-5, 0, 0], "spine": [-3, 0, 0], "hand": {"Left": {"at": [-0.18, 1.30, -0.50]}}},
        dict(t=0.6, **stand)]}
    door["keys"][-1]["hand"] = {"Left": {"at": [-0.02, 1.16, -0.48], "rot": [80, 0, 90], "pole": [-1, -1.2, 0]}}
    door["left_on_gun"] = False
    chest = {"name": "chest_open", "length": 1.0, "carry_neck": True, "keys": [
        dict(t=0.0, **stand, hand={"Right": {"at": [0.38, 0.86, -0.08], "rot": [10, 0, 0], "pole": [1, 0, 1]},
                                   "Left": {"at": [-0.38, 0.86, -0.08], "rot": [10, 0, 0], "pole": [-1, 0, 1]}}),
        {"t": 0.25, "hips": [0.0, 0.70, 0.10], "hrot": [-28, 0, 0], "spine": [-14, 0, 0], "chest": [-8, 0, 0], "head": [18, 0, 0],
         "foot": {"Left": {"at": [-0.16, 0.09, -0.06], "rot": [0, 10, 0], "pole": [-0.3, 0, -1]}, "Right": {"at": [0.16, 0.09, -0.06], "rot": [0, -10, 0], "pole": [0.3, 0, -1]}},
         "hand": {"Right": {"at": [0.20, 0.62, -0.45], "rot": [70, 0, 0], "pole": [1, 0.3, 0.3]}, "Left": {"at": [-0.20, 0.62, -0.45], "rot": [70, 0, 0], "pole": [-1, 0.3, 0.3]}}},
        {"t": 0.42, "hips": [0.0, 0.68, 0.11], "hand": {"Right": {"at": [0.20, 0.58, -0.46]}, "Left": {"at": [-0.20, 0.58, -0.46]}}},
        {"t": 0.68, "hips": [0.0, 0.82, 0.06], "hrot": [-14, 0, 0], "spine": [-6, 0, 0], "chest": [-2, 0, 0], "head": [10, 0, 0],
         "hand": {"Right": {"at": [0.20, 0.92, -0.54], "rot": [120, 0, 0]}, "Left": {"at": [-0.20, 0.92, -0.54], "rot": [120, 0, 0]}}},
        {"t": 0.82, "hips": [0.0, 0.92, 0.02], "hrot": [-4, 0, 0], "spine": [-2, 0, 0], "chest": [1, 0, 0], "head": [4, 0, 0],
         "hand": {"Right": {"at": [0.22, 1.10, -0.52], "rot": [160, 0, 0]}, "Left": {"at": [-0.22, 1.10, -0.52], "rot": [160, 0, 0]}}},
        {"t": 1.0, "hips": [0.0, 0.955, 0.0], "hrot": [0, 0, 0], "spine": [0, 0, 0], "chest": [0, 0, 0], "head": [0, 0, 0], "foot": STAND_FEET,
         "hand": {"Right": {"at": [0.38, 0.86, -0.08], "rot": [10, 0, 0]}, "Left": {"at": [-0.38, 0.86, -0.08], "rot": [10, 0, 0]}}}]}
    chest["left_on_gun"] = False
    chest["no_gun"] = True
    for k in chest["keys"]:
        k.pop("gun", None)
    pick = {"name": "pickup_ground", "length": 0.7, "carry_neck": True, "left_on_gun": False, "keys": [
        dict(t=0.0, **stand, hand={"Left": {"at": [-0.02, 1.16, -0.48], "rot": [80, 0, 90], "pole": [-1, -1.2, 0]}}),
        {"t": 0.10, "hips": [0.02, 0.965, 0.0], "hrot": [0, -4, 0], "head": [-8, 6, 0]},
        {"t": 0.32, "hips": [0.04, 0.50, 0.16], "hrot": [-38, 6, -3], "spine": [-22, 4, 4], "chest": [-14, 4, 6], "head": [30, 8, 0],
         "gun": {"at": [0.17, -0.30, -0.20], "dir": [0.1, -0.55, -1.0], "up": [0.0, 1.0, -0.4]},
         "foot": {"Left": {"at": [-0.17, 0.09, -0.20], "rot": [0, 10, 0], "pole": [-0.3, 0.2, -1]}, "Right": {"at": [0.16, 0.09, 0.06], "rot": [0, -12, 0], "pole": [0.3, 0, -1]}},
         "hand": {"Left": {"at": [-0.24, 0.30, -0.40], "rot": [70, 0, -10], "pole": [-1, 0.3, 0.4]}},
         "fingers": {"Left": [0, 0, 0]}},
        {"t": 0.40, "hips": [0.04, 0.49, 0.16], "hand": {"Left": {"at": [-0.24, 0.29, -0.41]}}, "fingers": {"Left": [0, 0, 0]}},
        {"t": 0.55, "hips": [0.02, 0.86, 0.06], "hrot": [-10, 2, 0], "spine": [-5, 2, 0], "chest": [-2, 2, 0], "head": [6, 2, 0],
         "hand": {"Left": {"at": [-0.28, 0.98, -0.20], "rot": [40, 0, 0], "pole": [-1, -0.5, 0.5]}}},
        {"t": 0.7, "hips": [0.0, 0.955, 0.0], "hrot": [0, 0, 0], "spine": [0, 0, 0], "chest": [0, 0, 0], "head": [0, 0, 0],
         "gun": LOW_READY, "foot": STAND_FEET, "hand": {"Left": {"at": [-0.02, 1.16, -0.48], "rot": [80, 0, 90]}}}]}
    return [door, chest, pick]


# --- checks -----------------------------------------------------------------------------------------------------------
def wall_plane(cover):
    out = math.radians(float(cover["animation"]["hug_out_deg"]))
    return Vector((math.cos(out), 0.0, -math.sin(out))), float(cover["wall_offset_m"])


def wall_clearance(check, frames, cover, low):
    """Smallest signed distance (m) of the posed mesh's arm/hand and gun-hand points from the wall plane (side +1);
    the whole mesh's too (the back and shoulder may touch: the gameplay test pins the right arm, the hands and gun)."""
    import numpy as np
    n, off = wall_plane(cover)
    nn = np.array([n.x, n.y, n.z])
    arms, body = 9.0, 9.0
    for fr in frames[::3]:
        Vt = check.verts(fr)
        d = Vt @ nn + off
        body = min(body, float(d[check.solid].min()))
        idx = np.concatenate([check.arm_v["Right"], check.arm_v["Left"]])
        arms = min(arms, float(d[idx].min()))
    return arms, body


def ladder_slip(rig, frames, c):
    """Max world drift (m) of each hand / ball point while it holds its rung (the rungs move down cycle_m per cycle)."""
    lad = c["ladder"]
    D = float(lad["cycle_m"])
    n = len(frames) - 1
    worst = 0.0
    for side in SIDES:
        for bone in (side + "Hand", side + "Foot"):
            ys = []
            for f, fr in enumerate(frames):
                _g, gp = rig.fk(fr["loc"], fr["hips"], fr["neck"])
                ys.append(gp[bone] + Vector((0.0, D * f / n, 0.0)))
            # stance frames: the half-cycle where the world point barely moves
            best = 9.0
            for start in range(n):
                seg = [ys[(start + k) % n] for k in range(n // 2 - 1)]
                drift = max((p - seg[0]).length for p in seg)
                best = min(best, drift)
            worst = max(worst, best)
    return worst


# --- previews ---------------------------------------------------------------------------------------------------------
def _box(name, size, at):
    """A box object (Godot size and centre)."""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=gbl.godot_to_blender(at))
    o = bpy.context.active_object
    o.name = name
    o.scale = (size[0], size[2], size[1])
    return o


def render_strips(check, rig, baked, specs, c, cover, out_dir, count):
    import numpy as np
    import build_soldier
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "VERTEX"
    scene.display.shading.show_backface_culling = True
    scene.display.shading.show_object_outline = True
    scene.display.shading.background_type = "VIEWPORT"
    scene.display.shading.background_color = (0.32, 0.33, 0.35)
    scene.view_settings.view_transform = "Standard"
    w, h = 360, 480
    scene.render.resolution_x = w
    scene.render.resolution_y = h
    scene.render.image_settings.file_format = "PNG"
    build_soldier._preview_colours(check.obj, check.design)
    bpy.ops.mesh.primitive_plane_add(size=6.0, location=(0.0, 0.0, -0.001))
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    os.makedirs(out_dir, exist_ok=True)
    tmp = os.path.join(out_dir, "_tile.png")
    written = []
    lad = c["ladder"]
    for spec in specs:
        name = spec["action"]
        frames = baked[name]
        props = []
        mirror_x = -1.0 if spec.get("mirrored") else 1.0
        if spec.get("wall"):
            n, off = wall_plane(cover)
            n = Vector((n.x * mirror_x, 0.0, n.z))
            centre = -n * (off + 0.05)
            height = 1.1 if spec.get("low") else 2.2
            o = _box("Wall", (3.0, height, 0.1), (centre.x, height * 0.5, centre.z))
            o.rotation_euler = (0.0, 0.0, math.atan2(n.x, n.z))  # Godot yaw about +Y = Blender turn about +Z
            props.append(o)
        rungs = []
        if spec.get("ladder"):
            for i in range(12):
                rungs.append(_box("Rung%d" % i, (0.46, 0.05, 0.05), (0.0, 0.0, -float(lad["climb_offset_m"]) + 0.04)))
        if spec.get("ledge") is not None:
            e = float(spec["ledge"])
            props.append(_box("Ledge", (2.0, 1.0, 2.0), (0.0, -0.5, e - 1.0)))
            for x in (-0.265, 0.265):
                props.append(_box("Rail", (0.07, 0.9, 0.08), (x, 0.45, e + 0.04)))
        if spec.get("ladder"):
            for x in (-0.265, 0.265):
                props.append(_box("Rail", (0.07, 4.0, 0.08), (x, 1.0, -float(lad["climb_offset_m"]) + 0.04)))
        gun_obj = None
        if not spec.get("no_gun"):
            # a stand-in for the rifle on the right hand (grip at the hand, barrel along -Z, stock behind)
            gun_obj = _box("Gun", (0.05, 0.11, 0.84), (0.0, 0.0, 0.0))
            props.append(gun_obj)
        nfr = len(frames)
        pick = [int(round(i * (nfr - 1) / float(count - 1))) for i in range(count)]
        xs = [fr["hips"].x for fr in frames]
        zs = [fr["hips"].z for fr in frames]
        cx, cz = 0.5 * (min(xs) + max(xs)), 0.5 * (min(zs) + max(zs))
        cam_data.ortho_scale = 2.4 + max(max(xs) - min(xs), max(zs) - min(zs))
        for view in ("side", "front"):
            strip = None
            for f in pick:
                if rungs:
                    t = f / float(nfr - 1)  # ladder_down is ladder_up reversed: its frame f is up's 1 - t
                    shift = float(lad["cycle_m"]) * ((1.0 - t) if spec.get("down") else t)
                    for i, r in enumerate(rungs):
                        y = float(lad["rung_m"]) * (i - 1) - shift
                        r.location = gbl.godot_to_blender((0.0, y, -float(lad["climb_offset_m"]) + 0.04))
                check.pose(frames[f])
                if gun_obj is not None:
                    gr, gp = rig.fk(frames[f]["loc"], frames[f]["hips"], frames[f]["neck"])
                    C = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))
                    centre = gp["RightHand"] + gr["RightHand"] @ Vector((0.0, 0.05, -0.26))
                    rot = (C @ gr["RightHand"].to_matrix() @ C.inverted()).to_4x4()
                    gun_obj.matrix_world = Matrix.Translation(C @ centre) @ rot @ Matrix.Diagonal((0.05, 0.84, 0.11, 1.0))
                target = Vector((cx, -cz, max(0.95, sum(fr["hips"].y for fr in frames) / nfr)))
                eye = target + (Vector((6.0, 0.0, 0.15)) if view == "side" else Vector((0.0, 6.0, 0.15)))
                build_soldier._look(cam, eye, target)
                scene.render.filepath = tmp
                bpy.ops.render.render(write_still=True)
                img = bpy.data.images.load(tmp)
                px = np.empty(w * h * 4, dtype=np.float32)
                img.pixels.foreach_get(px)
                bpy.data.images.remove(img)
                tile = px.reshape(h, w, 4)
                tile[:, :2, :3] = 0.15
                strip = tile if strip is None else np.concatenate([strip, tile], axis=1)
            out = bpy.data.images.new("strip", width=strip.shape[1], height=h, alpha=True)
            out.pixels.foreach_set(strip.ravel())
            path = os.path.join(out_dir, "%s_%s.png" % (name, view))
            out.filepath_raw = path
            out.file_format = "PNG"
            out.save()
            bpy.data.images.remove(out)
            written.append(path)
        for o in props + rungs:
            bpy.data.objects.remove(o, do_unlink=True)
    if os.path.exists(tmp):
        os.remove(tmp)
    return written


# --- main -------------------------------------------------------------------------------------------------------------
def main():
    a = gbl.args()
    c, cover = cfg()
    only = [x for x in str(a.get("only", "")).split(",") if x] if a.get("only") else []
    out = str(a.get("out", SCRATCH if only else OUT))
    gbl.reset_scene()
    rig = KRig()
    gun = Gun()
    arm = gbl.soldier_armature()
    arm.animation_data_create()
    use_mesh = not a.get("no-mesh")
    check = bsc.MeshCheck(rig, arm) if use_mesh else None
    clips = cover_clips(cover) + ladder_clips(c) + action_clips()
    clips = [cl for cl in clips if not only or cl["name"] in only]
    actions, specs = {}, []
    for clip in clips:
        MISSES.clear()
        frames, miss = bake(rig, gun, clip)
        if MISSES:
            print("KEYED_MISS %s %s" % (clip["name"], " ".join("%s=%.0fmm" % (k, v * 1000) for k, v in sorted(MISSES.items()))))
        loop = bool(clip.get("loop"))
        key = clip["name"] + ("_Loop" if loop else "")
        actions[key] = frames
        spec = dict(clip, action=key)
        specs.append(spec)
        line = "KEYED_CLIP %s len=%.3f frames=%d loop=%d ik_miss_mm=%.2f" % (clip["name"], float(clip["length"]), len(frames) - 1, int(loop), miss * 1000.0)
        if loop:
            rot, pos = bsc.seam(frames, 0, len(frames) - 1)
            step = bsc.seam(frames, len(frames) - 2, len(frames) - 1)
            other = max(bsc.seam(frames, i, i + 1)[0] for i in range(len(frames) - 2))
            line += " first_vs_last=%.3fdeg/%.2fmm seam_step=%.2fdeg/%.1fmm max_other_step=%.2fdeg" % (rot, pos, step[0], step[1], other)
        else:
            line += " max_step=%.2fdeg" % max(bsc.seam(frames, i, i + 1)[0] for i in range(len(frames) - 1))
        worst_bone, worst_step = "", 0.0
        for i in range(len(frames) - 1):
            for b in rig.bones:
                d = bsc.qangle_deg(frames[i]["loc"][b], frames[i + 1]["loc"][b])
                if d > worst_step:
                    worst_bone, worst_step = "%s@%d" % (b, i), d
        line += " step_bone=%s" % worst_bone
        if check is not None:
            ms = check.stats(frames)
            line += " arm_clear_m=%.3f min_y_m=%.3f" % (ms["arm_clear"], ms["min_y"])
            if clip.get("wall"):
                arms_w, body_w = wall_clearance(check, frames, cover, clip.get("low"))
                line += " wall_arms_m=%.3f wall_body_m=%.3f" % (arms_w, body_w)
        if clip.get("ladder"):
            line += " rung_slip_m=%.4f" % ladder_slip(rig, frames, c)
        print(line)
        if clip["name"].startswith("cover_") and clip.get("mirror", True):
            mname = clip["name"].replace("_right", "_left") if clip["name"].endswith("_right") else clip["name"] + "_l"
            mkey = mname + ("_Loop" if loop else "")
            actions[mkey] = mirror(rig, frames)
            specs.append(dict(clip, name=mname, action=mkey, mirrored=True))
            print("KEYED_CLIP %s mirror_of=%s" % (mname, clip["name"]))
        if clip["name"] == "ladder_up":
            down = [bsc.copy_frame(fr) for fr in reversed(frames)]
            actions["ladder_down_Loop"] = down
            specs.append(dict(clip, name="ladder_down", action="ladder_down_Loop", down=True))
            print("KEYED_CLIP ladder_down reverse_of=ladder_up len=%.3f" % float(clip["length"]))
    if check is not None:
        mesh = check.obj.data
        bpy.data.objects.remove(check.obj, do_unlink=True)
        bpy.data.meshes.remove(mesh, do_unlink=True)
        check = None
    for name in sorted(actions):
        bsc.write_action(rig, arm, name, actions[name])
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)
    bpy.context.scene.frame_set(0)
    path = gbl.export_glb(out)
    err_r, err_p = bsc.verify(path, rig, actions)
    s = gbl.summary(path)
    if out == OUT:
        gbl.update_manifest(out, ME, "")
    listed = " ".join("%s:%.3fs" % (k, v) for k, v in sorted(s["clips"].items()))
    print("KEYED_CLIPS out=%s clips=%d %s bones=%d triangles=%d bytes=%d sha256=%s readback_rot_err_deg=%.4f readback_pos_err_mm=%.3f" % (
        out, len(s["clips"]), listed, s["bones"], s["triangles"], s["bytes"], s["sha256"], err_r, err_p))
    if a.get("preview") and use_mesh:
        check = bsc.MeshCheck(rig, arm)
        out_dir = gbl.repo_path("build/an2/preview/" + str(a["preview"]))
        written = render_strips(check, rig, actions, specs, c, cover, out_dir, 10)
        print("KEYED_CLIPS_PREVIEW %d strips in %s" % (len(written), out_dir))


if __name__ == "__main__":
    main()
