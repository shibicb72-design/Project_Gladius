"""M2 AN2 item 4b: first-person clips hand-keyed on a view rig, one .glb per weapon (action-only, no mesh).

    blender.cmd -b --factory-startup --python tools/blender/build_view_clips.py -- [--only=<id,...>]
        [--out-dir=<repo dir>] [--preview=<dir under the repo>]

Writes assets/generated/characters/view_clips_<id>.glb for pilum_br, sagittarii_rifle and gladius_lux: an armature
"ViewRig" in the first-person CAMERA frame (Godot axes: +x right, +y up, -z ahead; natural metres before the view
model's 0.45 scale) and one action per clip. The runtime (scripts/visual/view_motion.gd ViewMotion.ClipSet) samples
the actions and copies them onto the nodes the view model already has.

The rig (<= 50 bones; 37 for a gun, 35 for the blade):
  Weapon            root: the Weapon_<id> node in the camera (pivot) frame. Rest = camera.json hold pose.
  Cell, Charge      children of Weapon: the Cell / Charge nodes. Rest = art_soldier.json cell / charge rest.
  R_hand, L_hand    the RightArm / LeftArm nodes (the wrist). Children of Weapon, rest = art hands r / l placement;
                    the blade's free left hand (frame "view") is a root in the camera frame.
  R_<finger>_<s>    the 15 finger bones of each runtime arm skeleton (index/middle/ring/pinky/thumb _0.._2), the
  L_<finger>_<s>    runtime names with a side prefix; rests = ViewHands' rests (left = x mirror). Rest pose = the
                    data's hold pose (trigger / foregrip / blade / guard).
  R_elbow, L_elbow  roots, position only: the point the forearm aims at (ViewHands.aim_forearm), camera frame. Rest =
                    the data's elbow_view (or the weapon-frame elbow at the hold).
So frame 0 of every idle clip equals today's rest pose exactly and nothing shifts when the clips are switched on.

Clips (action names; "_Loop" ones arrive in Godot as loops without the suffix): <id>_idle_Loop, <id>_walk_Loop,
<id>_sprint_Loop, <id>_ads_raise, <id>_ads_lower, <id>_fire, <id>_reload, <id>_switch_out, <id>_switch_in,
<id>_pickup for the guns; <id>_idle_Loop, <id>_swing, <id>_switch_out, <id>_switch_in, <id>_pickup for the blade.
Keyed from the pose tables below (gun_specs / blade_specs) at 30 fps: monotone cubic (PCHIP) curves through hand-set
keys (ease into and out of every extreme, no overshoot except the overshoots keyed on purpose), anchors for the left
hand (on the foregrip, the cell, the charging handle, the pickup reach point) blended with smoothstep plus a keyed
arc offset, finger poses blended between the data's named poses (data/art_soldier.json hands.poses).
The reload is authored at a nominal length and its stage boundaries are data/anim.json first_person.reload.stages (the
same fractions ViewMotion.reload_stage() reads); the game plays it time-scaled to the weapon's reload_s. The pickup's
weapon swap is anim.json first_person.pickup.swap_at.

Checks printed per clip (VIEW_CLIP lines): every frame's view-model vertices (posed arms, weapon, cell, charging
handle) against max_reach_m and the near plane at the three fov_table rows, in game metres (x view_model.scale);
loops close; idle frame 0 = rest; a read-back of the written .glb against the baked locals.
--preview=<dir>: per clip a contact strip of ~10 frames rendered from the first-person camera (75 deg, near plane
as the game's) with the real arm and weapon meshes posed by the clip.
"""

import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_view_arms as arms  # noqa: E402
import build_weapons as bw  # noqa: E402
import gladius_bl as gbl  # noqa: E402
import view_bl  # noqa: E402
import view_geom as vg  # noqa: E402
import weapon_geom  # noqa: E402
from view_geom import Xf  # noqa: E402

ME = "tools/blender/build_view_clips.py"
OUT_DIR = "assets/generated/characters"
IDS = ("pilum_br", "sagittarii_rifle", "gladius_lux")
FPS = gbl.FPS
FINGERS = arms.FINGERS
Z3 = (0.0, 0.0, 0.0)
Z6 = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
# The three fov_table rows the tests use: (aspect, vertical fov deg).
ASPECTS = ((2520.0 / 1080.0, 75.0), (2048.0 / 1536.0, 85.0), (2176.0 / 1812.0, 95.0))

# Nominal (authored) lengths in seconds. Loops play at their own length (idle) or on the step phase (walk, sprint);
# ads clips are sampled at the ADS weight; the one-shots are time-scaled by the game to their gameplay lengths.
LENGTH = {"idle": 3.6, "walk": 1.0, "sprint": 0.8, "ads_raise": 0.27, "ads_lower": 0.27, "fire": 0.25,
          "reload": 1.2, "switch_out": 0.27, "switch_in": 0.3, "pickup": 0.7, "swing": 0.46}
LOOPS = ("idle", "walk", "sprint")


# --- small maths --------------------------------------------------------------------------------------------------------
def vec(a):
    return tuple(float(c) for c in a)


def xf_matrix(x: Xf) -> Matrix:
    return Matrix(((x.b[0][0], x.b[1][0], x.b[2][0]), (x.b[0][1], x.b[1][1], x.b[2][1]), (x.b[0][2], x.b[1][2], x.b[2][2])))


def quat_of(x: Xf) -> Quaternion:
    return xf_matrix(x).to_quaternion().normalized()


def xf_of(q: Quaternion, o=Z3) -> Xf:
    return Xf(Xf.from_quat((q.x, q.y, q.z, q.w)).b, o)


def mirror(x: Xf) -> Xf:
    """x-mirror M * x * M (ViewHands.mirror_xf)."""
    b = x.b
    nb = tuple(tuple(v * s for v, s in zip(col, sgn)) for col, sgn in zip(b, ((1, -1, -1), (-1, 1, 1), (-1, 1, 1))))
    return Xf(nb, (-x.o[0], x.o[1], x.o[2]))


def interp(a: Xf, b: Xf, t: float) -> Xf:
    """Godot's Transform3D.interpolate_with (slerp the rotation, lerp the origin)."""
    if t <= 0.0:
        return a
    if t >= 1.0:
        return b
    q = quat_of(a).slerp(quat_of(b), t)
    return xf_of(q, vg.lerp(a.o, b.o, t))


def smooth(t: float) -> float:
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def six(v) -> Xf:
    """[px, py, pz, rx, ry, rz] (metres, Godot YXZ degrees) -> Transform3D(Basis.from_euler(rot), pos)."""
    return Xf.euler_yxz(v[3:6], v[0:3])


# --- curves ---------------------------------------------------------------------------------------------------------------
def pchip(keys, u):
    """Monotone cubic through keys [(u, values)]: smooth through the middle keys, flat at extremes and at both ends."""
    if not keys:
        return None
    if u <= keys[0][0]:
        return vec(keys[0][1])
    if u >= keys[-1][0]:
        return vec(keys[-1][1])
    i = 0
    while i < len(keys) - 2 and u >= keys[i + 1][0]:
        i += 1
    n = len(vec(keys[0][1]))
    out = []
    for c in range(n):
        xs = [k[0] for k in keys]
        ys = [float(k[1][c]) for k in keys]
        h = [xs[k + 1] - xs[k] for k in range(len(xs) - 1)]
        d = [(ys[k + 1] - ys[k]) / h[k] if h[k] > 0 else 0.0 for k in range(len(h))]

        def slope(k):
            if k == 0 or k == len(xs) - 1:
                return 0.0
            if d[k - 1] * d[k] <= 0.0:
                return 0.0
            w1, w2 = 2.0 * h[k] + h[k - 1], h[k] + 2.0 * h[k - 1]
            return (w1 + w2) / (w1 / d[k - 1] + w2 / d[k])
        x0, x1, y0, y1 = xs[i], xs[i + 1], ys[i], ys[i + 1]
        hh = x1 - x0
        t = (u - x0) / hh if hh > 0 else 0.0
        m0, m1 = slope(i) * hh, slope(i + 1) * hh
        t2, t3 = t * t, t * t * t
        out.append((2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * m1)
    return tuple(out)


def steps(keys, u):
    """Named keys [(u, name)]: (a, b, t) with t the smoothstep blend from a to b at u."""
    if u <= keys[0][0]:
        return keys[0][1], keys[0][1], 0.0
    for k in range(len(keys) - 1):
        u0, a = keys[k]
        u1, b = keys[k + 1]
        if u <= u1:
            return a, b, smooth((u - u0) / (u1 - u0) if u1 > u0 else 1.0)
    return keys[-1][1], keys[-1][1], 0.0


def blend_poses(a: dict, b: dict, t: float) -> dict:
    """ViewHands.blend_poses."""
    out = {}
    for key, va in a.items():
        if key.startswith("_"):
            continue
        vb = b.get(key, va)
        if isinstance(va, list):
            out[key] = [float(x) + (float(vb[i]) - float(x)) * t for i, x in enumerate(va)]
        else:
            out[key] = float(va) + (float(vb) - float(va)) * t
    return out


# --- the rig ----------------------------------------------------------------------------------------------------------------
class Rig:
    def __init__(self, wid: str, art_all: dict, cam: dict, fp: dict):
        self.wid = wid
        self.art = art_all["weapons"][wid]
        self.fp = fp
        wc = cam["weapons"][wid]
        self.hold = Xf.euler_yxz(wc["hold_rot_deg"], vec(wc["hold_m"]))
        self.melee = "muzzle_m" not in self.art
        self.ads = None
        if "ads_dot_m" in wc:
            b = Xf.euler_yxz(wc.get("ads_rot_deg", [0, 0, 0]))
            self.ads = Xf(b.b, vg.sub(vec(wc["ads_dot_m"]), b.dir(vec(self.art["dot_m"]))))
        self.c = arms.hands_cfg()
        self.poses = self.c["poses"]
        self.finger_local = arms.right_rests(self.c)
        hands = self.art["hands"]
        self.hands = hands
        self.cell = bw.sub_xf(self.art, "cell") if "cell" in self.art else None
        self.charge = bw.sub_xf(self.art, "charge") if "charge" in self.art else None
        self.place = {}
        self.view_l = False
        self.elbow = {}
        self.elbow_w = {}  # a weapon-frame elbow that rides the weapon (the blade's sword arm, as today)
        self.pose = {}
        for side in ("r", "l"):
            h = hands[side]
            self.place[side] = bw._placement(h)
            self.pose[side] = str(h.get("pose", "grip"))
            if h.get("frame", "weapon") == "view":
                self.view_l = True
                self.elbow[side] = vec(h["elbow"])
            elif "elbow_view" in h:
                self.elbow[side] = vec(h["elbow_view"])
            else:
                self.elbow_w[side] = vec(h["elbow"])
                self.elbow[side] = self.hold.apply(vec(h["elbow"]))
        p = fp["pickup"]
        self.reach = bw._placement({"at": p["reach_view_m"], "fingers": p["reach_fingers"], "back": p["reach_back"]})
        self.reach_elbow = vec(p["reach_elbow_view_m"])
        self.bones = self._bones()
        self.rest_global = {b: g for b, _p, g in self.bones}
        self.parent = {b: p for b, p, _g in self.bones}
        self.rest_local = {}
        for b, par, g in self.bones:
            self.rest_local[b] = self.rest_global[par].inverse() * g if par else g

    # bones: (name, parent, global rest in the camera frame)
    def _bones(self):
        out = [("Weapon", "", self.hold)]
        if self.cell is not None:
            out.append(("Cell", "Weapon", self.hold * self.cell))
        if self.charge is not None:
            out.append(("Charge", "Weapon", self.hold * self.charge))
        for side in ("r", "l"):
            pre = side.upper() + "_"
            if side == "l" and self.view_l:
                hand = self.place[side]
                out.append((pre + "hand", "", hand))
            else:
                hand = self.hold * self.place[side]
                out.append((pre + "hand", "Weapon", hand))
            glob = {}
            for n in arms.bone_names():
                if n in ("hand", "forearm"):
                    continue
                par = arms.parent_of(n)
                loc = self.finger_local[n]
                if side == "l":
                    loc = mirror(loc)
                g = (glob[par] if par != "hand" else hand) * loc
                glob[n] = g
                out.append((pre + n, pre + par, g))
            out.append((pre + "elbow", "", Xf.translate(self.elbow[side])))
        return out

    def anchor(self, name: str, W: Xf, cell_local, charge_local):
        """The left hand's camera-frame placement and elbow for an anchor."""
        if name == "rest":
            if self.view_l:
                return self.place["l"], self.elbow["l"]
            return W * self.place["l"], self.elbow["l"]
        if name == "cell":
            h = self.hands["l_cell"]
            return W * cell_local * bw._placement(h), vec(h["elbow_view"])
        if name == "charge":
            h = self.hands["l_charge"]
            return W * Xf(self.charge.b, charge_local.o) * bw._placement(h), vec(h["elbow_view"])
        if name == "reach":
            return self.reach, self.reach_elbow
        raise KeyError(name)

    def finger_rots(self, side: str, pose: dict) -> dict:
        """Local finger transforms for a pose (ViewHands.apply_pose; the left mirrored)."""
        out = {}
        spread = pose.get("spread", [0, 0, 0, 0, 0])
        for fi, f in enumerate(FINGERS):
            curls = pose.get(f, [0, 0, 0])
            for s in range(arms.SEGMENTS):
                bone = "%s_%d" % (f, s)
                loc = self.finger_local[bone]
                q = Xf(loc.b)
                if s == 0:
                    q = q * Xf.axis_angle((0, 1, 0), float(spread[fi]))
                    if f == "thumb":
                        q = q * Xf.axis_angle((0, 0, 1), float(pose.get("thumb_roll", 0.0)))
                q = q * Xf.axis_angle((1, 0, 0), -float(curls[s]))
                x = Xf(q.b, loc.o)
                out[side.upper() + "_" + bone] = mirror(x) if side == "l" else x
        return out

    def evaluate(self, spec: dict, u: float) -> dict:
        """Bone locals (Xf) at normalised time u, plus "_pose" (finger pose per side) and "_cam" (hand placements in the
        camera frame) for the checks and previews."""
        e = pchip(spec.get("e"), u) or Z6
        w = pchip(spec.get("w"), u) or Z6
        wr = pchip(spec.get("wr"), u) or Z3
        d = six((w[0], w[1], w[2], w[3] + wr[0], w[4] + wr[1], w[5] + wr[2]))
        base = self.hold
        if "ads" in spec and self.ads is not None:
            # linear in time on purpose: the game samples ads_raise at time = ADS weight * length and removes exactly
            # this blend (ViewMotion.clip_ads_offset), leaving the keyed path offset w
            k0, k1 = spec["ads"][0], spec["ads"][-1]
            s = k0[1][0] + (k1[1][0] - k0[1][0]) * (u - k0[0]) / (k1[0] - k0[0])
            base = interp(self.hold, self.ads, s)
        W = six(e) * base * d
        loc = {"Weapon": W}
        cell_local = charge_local = None
        if self.cell is not None:
            off = six(pchip(spec.get("cell"), u) or Z6)
            cell_local = Xf((off * Xf(self.cell.b)).b, vg.add(self.cell.o, off.o))
            loc["Cell"] = cell_local
        if self.charge is not None:
            z = (pchip(spec.get("charge"), u) or (0.0,))[0]
            charge_local = Xf(self.charge.b, vg.add(self.charge.o, (0.0, 0.0, z)))
            loc["Charge"] = charge_local
        # right hand: stays on the grip (weapon frame)
        loc["R_hand"] = self.place["r"]
        r_cam = W * self.place["r"]
        # left hand: anchors, smoothstep between keys, plus the keyed arc (camera frame)
        a, b, t = steps(spec.get("l", [(0.0, "rest")]), u)
        ha, ea = self.anchor(a, W, cell_local, charge_local)
        hb, eb = self.anchor(b, W, cell_local, charge_local)
        l_cam = interp(ha, hb, t)
        arc = pchip(spec.get("larc"), u) or Z3
        l_cam = Xf(l_cam.b, vg.add(l_cam.o, arc))
        l_elbow = vg.add(vg.lerp(ea, eb, t), pchip(spec.get("lelb"), u) or Z3)
        loc["L_hand"] = l_cam if self.view_l else W.inverse() * l_cam
        r_elbow = self.elbow["r"]
        if "r" in self.elbow_w:
            # the blade's sword arm: the elbow rides the weapon as today; "relb" drops it in the wind-up
            r_elbow = W.apply(self.elbow_w["r"])
            if "relb_to" in spec:
                # through the cut the elbow is pulled toward a fixed body point low right (the forearm runs out of
                # the bottom-right corner instead of ending in the view)
                k = pchip(spec["relb_k"], u)[0]
                r_elbow = vg.lerp(r_elbow, vec(spec["relb_to"]), k)
        r_elbow = vg.add(r_elbow, pchip(spec.get("relb"), u) or Z3)
        loc["R_elbow"] = Xf.translate(r_elbow)
        loc["L_elbow"] = Xf.translate(l_elbow)
        poses = {}
        for side, key in (("r", "rpose"), ("l", "lpose")):
            pa, pb, pt = steps(spec.get(key, [(0.0, self.pose[side])]), u)
            poses[side] = blend_poses(self.poses[pa], self.poses[pb], pt)
            loc.update(self.finger_rots(side, poses[side]))
        loc["_pose"] = poses
        loc["_cam"] = {"r": r_cam, "l": l_cam, "W": W, "elbow_r": r_elbow, "elbow_l": l_elbow}
        return loc


# --- the pose tables -------------------------------------------------------------------------------------------------------
def stage_fn(fp: dict):
    stages = fp["reload"]["stages"]
    total = sum(float(s[1]) for s in stages)
    start = {}
    acc = 0.0
    for name, span in stages:
        start[name] = (acc / total, float(span) / total)
        acc += float(span)

    def at(name, p):
        s, span = start[name]
        return s + span * p
    return at


def gun_specs(fp: dict) -> dict:
    S = stage_fn(fp)
    swap = float(fp["pickup"]["swap_at"])
    tilt = (-0.05, 0.06, -0.07, 22.0, 16.0, -32.0)
    low_cell = (-0.05, -0.2, 0.05, 35.0, -12.0, -22.0)
    sprint = (-0.05, -0.08, 0.0, -14.0, 38.0, 22.0)

    def plus(a, b):
        return tuple(x + y for x, y in zip(a, b))
    specs = {}
    # idle: a slow breath, in from the rest pose and back (frame 0 = rest), a little sway across it
    specs["idle"] = {
        "w": [(0.0, Z6), (0.22, (0.0006, 0.0025, 0.0, 0.25, 0.15, 0.2)), (0.45, (0.0, 0.0045, 0.0, 0.55, 0.0, 0.0)),
              (0.7, (-0.0006, 0.002, 0.0, 0.2, -0.15, -0.2)), (1.0, Z6)]}
    # walk: one stride, a footfall at 0.25 and 0.75 (the gun dips and rolls toward the planted foot), rotation lags
    specs["walk"] = {
        "w": [(0.0, Z6), (0.25, (0.011, -0.012, 0.003, 0.0, 0.0, 0.0)), (0.5, (0.0, 0.002, 0.0, 0.0, 0.0, 0.0)),
              (0.75, (-0.011, -0.012, 0.003, 0.0, 0.0, 0.0)), (1.0, Z6)],
        "wr": [(0.0, Z3), (0.06, Z3), (0.31, (-1.0, 1.2, 1.6)), (0.56, (0.2, 0.0, 0.0)), (0.81, (-1.0, -1.2, -1.6)),
               (1.0, Z3)]}
    # sprint: the gun across the body (today's sprint pose), pumping once per step
    specs["sprint"] = {
        "w": [(0.0, sprint), (0.25, plus(sprint, (0.008, -0.016, 0.004, -3.0, 2.0, 4.0))),
              (0.5, plus(sprint, (0.0, 0.004, 0.0, 1.0, 0.0, 0.0))),
              (0.75, plus(sprint, (-0.008, -0.016, 0.004, -3.0, -2.0, -4.0))), (1.0, sprint)]}
    # ADS: the path from the hold to the ADS pose (the ads channel is the blend the game computes; w shapes the path
    # and is zero at both ends, so the end pose is exactly the ADS pose)
    specs["ads_raise"] = {"ads": [(0.0, (0.0,)), (1.0, (1.0,))],
                          "w": [(0.0, Z6), (0.35, (0.004, -0.01, 0.008, -1.5, 0.0, -4.0)),
                                (0.75, (0.001, -0.003, 0.002, -0.4, 0.0, -1.0)), (1.0, Z6)]}
    specs["ads_lower"] = {"ads": [(0.0, (1.0,)), (1.0, (0.0,))],
                          "w": [(0.0, Z6), (0.4, (0.004, -0.009, 0.008, -1.2, 0.0, -3.5)), (1.0, Z6)]}
    # fire: kick and recover with a small settle past rest (additive on the procedural kick spring)
    specs["fire"] = {"w": [(0.0, Z6), (0.12, (0.0, 0.003, 0.01, 2.5, 0.0, 0.6)), (0.4, (0.0, 0.0005, 0.002, 0.4, 0.0, 0.1)),
                           (0.65, (0.0, -0.001, -0.0015, -0.4, 0.0, -0.1)), (1.0, Z6)]}
    # reload: tilt (with a dip first), the hand leaves the foregrip while the gun is still turning, takes the cell out
    # and down (the spent one leaves with the hand), comes back with a fresh one and slaps it home, works the charging
    # handle (pull, hold, release), back to the handguard; the gun answers each tug and settles past rest at the end.
    specs["reload"] = {
        "w": [(0.0, Z6), (S("tilt", 0.25), (0.0, -0.006, 0.006, -3.0, -1.0, 3.0)),
              (S("tilt", 1.0), (-0.052, 0.066, -0.072, 25.0, 17.0, -36.0)), (S("hand_to_cell", 0.6), tilt),
              (S("cell_out", 0.3), (-0.047, 0.066, -0.07, 23.0, 15.0, -30.0)),
              (S("cell_out", 1.0), (-0.052, 0.055, -0.07, 21.0, 16.0, -33.0)), (S("cell_in", 0.7), tilt),
              (S("cell_in", 0.9), (-0.05, 0.072, -0.073, 26.0, 16.0, -29.0)),
              (S("charge", 0.12), (-0.045, 0.06, -0.066, 18.0, 14.0, -14.0)),
              (S("charge", 0.45), (-0.04, 0.056, -0.056, 13.0, 11.0, 5.0)),
              (S("charge", 0.62), (-0.036, 0.053, -0.05, 12.0, 10.0, 8.0)),
              (S("charge", 0.78), (-0.042, 0.066, -0.06, 16.0, 12.0, 3.0)),
              (S("return", 0.2), (-0.028, 0.038, -0.04, 9.0, 7.0, -2.0)),
              (S("return", 0.78), (0.002, -0.005, 0.004, -2.0, -1.0, 1.5)), (1.0, Z6)],
        "cell": [(0.0, Z6), (S("cell_out", 0.0), Z6), (S("cell_out", 0.2), (0.0, -0.012, 0.0, 0.0, 0.0, 0.0)),
                 (S("cell_out", 0.6), (-0.02, -0.09, 0.02, 18.0, -6.0, -10.0)), (S("cell_out", 1.0), low_cell),
                 (S("cell_in", 0.2), low_cell), (S("cell_in", 0.6), (-0.024, -0.075, 0.022, 16.0, -7.0, -11.0)),
                 (S("cell_in", 0.84), (0.0, -0.014, 0.002, 2.0, 0.0, -1.0)), (S("cell_in", 0.93), (0.0, 0.002, 0.0, 0.0, 0.0, 0.0)),
                 (S("cell_in", 1.0), Z6), (1.0, Z6)],
        "charge": [(0.0, (0.0,)), (S("charge", 0.45), (0.0,)), (S("charge", 0.62), (0.045,)), (S("charge", 0.7), (0.045,)),
                   (S("charge", 0.76), (0.0,)), (1.0, (0.0,))],
        "l": [(0.0, "rest"), (S("tilt", 0.35), "rest"), (S("hand_to_cell", 0.85), "cell"), (S("charge", 0.0), "cell"),
              (S("charge", 0.4), "charge"), (S("charge", 0.84), "charge"), (S("return", 0.7), "rest"), (1.0, "rest")],
        "larc": [(0.0, Z3), (S("tilt", 0.35), Z3), (S("hand_to_cell", 0.2), (-0.015, -0.035, 0.02)),
                 (S("hand_to_cell", 0.85), Z3), (S("charge", 0.0), Z3), (S("charge", 0.2), (0.0, 0.035, 0.015)),
                 (S("charge", 0.4), Z3), (S("charge", 0.84), Z3), (S("return", 0.3), (-0.01, 0.02, 0.0)),
                 (S("return", 0.7), Z3), (1.0, Z3)],
        # the elbow drops and comes back under the gun while the hand works the charging handle, so the forearm runs
        # down out of the view instead of across it
        "lelb": [(0.0, Z3), (S("charge", 0.0), Z3), (S("charge", 0.35), (-0.06, -0.16, 0.12)),
                 (S("charge", 0.84), (-0.06, -0.16, 0.12)), (S("return", 0.7), Z3), (1.0, Z3)],
        "lpose": [(0.0, "foregrip"), (S("tilt", 0.35), "foregrip"), (S("tilt", 0.9), "open"), (S("hand_to_cell", 0.7), "reach"),
                  (S("hand_to_cell", 1.0), "grip"), (S("cell_out", 1.0), "grip"), (S("cell_in", 0.06), "reach"),
                  (S("cell_in", 0.2), "grip"), (S("charge", 0.0), "grip"), (S("charge", 0.2), "reach"),
                  (S("charge", 0.4), "grip"), (S("charge", 0.84), "grip"), (S("return", 0.2), "reach"),
                  (S("return", 0.7), "foregrip"), (1.0, "foregrip")]}
    # switch: lowered about the eye (keeps every vertex at its distance), the support hand loosening first; raise with
    # a small overshoot as the new weapon arrives
    down = (0.0, 0.0, 0.0, -64.0, 0.0, 0.0)
    roll = (0.0, 0.0, 0.0, -10.0, 0.0, 25.0)
    specs["switch_out"] = {"e": [(0.0, Z6), (0.15, (0.0, 0.004, 0.0, 2.0, 0.0, 0.0)), (0.6, (0.0, -0.015, 0.0, -20.0, 0.0, 0.0)), (1.0, down)],
                           "w": [(0.0, Z6), (0.2, (0.0, 0.0, 0.0, 1.0, 0.0, -2.0)), (1.0, roll)],
                           "lpose": [(0.0, "foregrip"), (0.6, "relaxed"), (1.0, "relaxed")]}
    specs["switch_in"] = {"e": [(0.0, down), (0.5, (0.0, -0.01, 0.005, -16.0, 0.0, 0.0)), (0.78, (0.0, 0.004, 0.0, 3.0, 0.0, 0.0)), (1.0, Z6)],
                          "w": [(0.0, roll), (0.55, (0.0, 0.0, 0.0, -3.0, 0.0, 7.0)), (0.8, (0.0, 0.0, 0.0, 1.0, 0.0, -2.0)), (1.0, Z6)],
                          "lpose": [(0.0, "relaxed"), (0.5, "relaxed"), (0.9, "foregrip"), (1.0, "foregrip")]}
    # pickup: the support hand leaves the gun and reaches down-forward open while the gun lowers, closes on the loot at
    # the swap, and brings the new gun up into the hold with it
    specs["pickup"] = pickup_spec(swap, (0.0, 0.0, 0.0, -12.0, 10.0, 30.0), "foregrip")
    return specs


GUN_LIFT = (0.0, 0.004, 0.0, 2.5, 0.0, 0.0)
# the blade's sword forearm already runs close past the eye at the hold: its anticipation and settle never pitch it up
# (a 3 degree lift put it through the near plane in the game's check); they turn it instead
BLADE_LIFT = (0.0, -0.002, 0.0, -1.0, -2.0, 1.5)


def pickup_spec(swap: float, tilt, rest_pose: str, lift=GUN_LIFT) -> dict:
    return {
        "e": [(0.0, Z6), (0.07, lift), (0.25, (0.0, -0.01, 0.0, -18.0, 0.0, 0.0)),
              (swap, (0.0, -0.03, 0.02, -60.0, 0.0, 0.0)), (swap + 0.1, (0.0, -0.025, 0.015, -36.0, 0.0, 0.0)),
              (0.8, (0.0, -0.004, 0.0, -6.0, 0.0, 0.0)), (0.9, lift), (1.0, Z6)],
        "w": [(0.0, Z6), (0.3, tuple(x * 0.5 for x in tilt)), (swap, tilt), (0.75, tuple(x * 0.25 for x in tilt)),
              (0.9, tuple(x * -0.04 for x in tilt)), (1.0, Z6)],
        "l": [(0.0, "rest"), (0.05, "rest"), (0.28, "reach"), (swap - 0.02, "reach"), (swap + 0.24, "rest"), (1.0, "rest")],
        "larc": [(0.0, Z3), (0.05, Z3), (0.16, (-0.01, -0.01, -0.03)), (0.28, Z3), (swap - 0.02, (0.0, -0.035, -0.03)),
                 (swap + 0.12, (0.0, -0.02, -0.01)), (swap + 0.24, Z3), (1.0, Z3)],
        "lpose": [(0.0, rest_pose), (0.05, rest_pose), (0.2, "open"), (0.3, "open"), (swap - 0.05, "reach"), (swap, "grip"),
                  (swap + 0.2, "grip"), (0.85, rest_pose), (1.0, rest_pose)]}


def blade_specs(fp: dict) -> dict:
    swap = float(fp["pickup"]["swap_at"])
    specs = {}
    specs["idle"] = {"e": [(0.0, Z6), (0.45, (0.0, 0.004, 0.0, 0.6, 0.3, 0.4)), (1.0, Z6)],
                     "larc": [(0.0, Z3), (0.5, (0.0, 0.003, 0.0)), (1.0, Z3)]}
    # swing: a small drop before the wind-up, the wind-up held a beat (wrist cocked), a fast weighted cut across with
    # the wrist snapping through, follow-through, recovery with a settle; the guard hand pulls in against the cut
    specs["swing"] = {
        # a diagonal cut from upper right to lower left that crosses the middle of the view (the blade laid over by
        # the wrist), instead of a flat yaw that carried the blade out of the view for half the swing
        "e": [(0.0, Z6), (0.08, (0.006, -0.006, 0.0, -3.0, -4.0, 3.0)), (0.28, (0.03, 0.04, -0.01, 10.0, -12.0, -12.0)),
              (0.33, (0.031, 0.042, -0.01, 11.0, -13.0, -13.0)), (0.42, (-0.05, -0.015, -0.02, -10.0, 24.0, 22.0)),
              (0.52, (-0.075, -0.035, -0.025, -18.0, 36.0, 30.0)), (0.64, (-0.068, -0.03, -0.02, -16.0, 32.0, 27.0)),
              (0.9, (0.003, 0.002, 0.0, 1.5, -2.0, -2.0)), (1.0, Z6)],
        "w": [(0.0, Z6), (0.3, (0.0, 0.0, 0.0, 4.0, 0.0, -6.0)), (0.44, (0.0, 0.0, 0.0, -14.0, 0.0, 35.0)),
              (0.6, (0.0, 0.0, 0.0, -8.0, 0.0, 30.0)), (1.0, Z6)],
        "relb": [(0.0, Z3), (0.12, Z3), (0.3, (0.04, -0.14, -0.04)), (0.42, (0.0, -0.08, -0.04)), (0.6, Z3), (1.0, Z3)],
        "relb_to": (0.32, -0.55, -0.05),
        "relb_k": [(0.0, (0.0,)), (0.34, (0.0,)), (0.44, (1.0,)), (0.66, (1.0,)), (0.9, (0.0,)), (1.0, (0.0,))],
        "larc": [(0.0, Z3), (0.3, (0.02, -0.012, -0.005)), (0.44, (-0.045, -0.05, 0.0)), (0.7, (-0.035, -0.04, 0.0)), (1.0, Z3)]}
    down = (0.0, 0.0, 0.0, -64.0, 0.0, 0.0)
    roll = (0.0, 0.0, 0.0, 10.0, 0.0, -30.0)
    hand_down = (0.02, -0.26, 0.06)
    specs["switch_out"] = {"e": [(0.0, Z6), (0.15, BLADE_LIFT), (0.6, (0.0, -0.015, 0.0, -20.0, 0.0, 0.0)), (1.0, down)],
                           "w": [(0.0, Z6), (0.2, (0.0, 0.0, 0.0, -1.0, 0.0, 2.0)), (1.0, roll)],
                           "larc": [(0.0, Z3), (0.1, Z3), (1.0, hand_down)],
                           "lpose": [(0.0, "guard"), (0.6, "relaxed"), (1.0, "relaxed")]}
    specs["switch_in"] = {"e": [(0.0, down), (0.5, (0.0, -0.01, 0.005, -16.0, 0.0, 0.0)), (0.78, BLADE_LIFT), (1.0, Z6)],
                          "w": [(0.0, roll), (0.55, (0.0, 0.0, 0.0, 3.0, 0.0, -8.0)), (0.8, (0.0, 0.0, 0.0, -1.0, 0.0, 2.0)), (1.0, Z6)],
                          "larc": [(0.0, hand_down), (0.6, (0.0, -0.03, 0.01)), (0.85, (0.0, 0.004, 0.0)), (1.0, Z3)],
                          "lpose": [(0.0, "relaxed"), (0.5, "relaxed"), (0.9, "guard"), (1.0, "guard")]}
    specs["pickup"] = pickup_spec(swap, (0.0, 0.0, 0.0, 10.0, 0.0, -30.0), "guard", BLADE_LIFT)
    return specs


def clip_list(rig: Rig) -> list:
    if rig.melee:
        return ["idle", "swing", "switch_out", "switch_in", "pickup"]
    return ["idle", "walk", "sprint", "ads_raise", "ads_lower", "fire", "reload", "switch_out", "switch_in", "pickup"]


def action_name(wid: str, clip: str) -> str:
    return "%s_%s%s" % (wid, clip, "_Loop" if clip in LOOPS else "")


def bake(rig: Rig, spec: dict, clip: str) -> list:
    n = max(1, int(round(LENGTH[clip] * FPS)))
    return [rig.evaluate(spec, f / n) for f in range(n + 1)]


# --- checks ---------------------------------------------------------------------------------------------------------------
class Geometry:
    """The real meshes (item 4a geometry) for the reach / near-plane checks and the previews."""

    def __init__(self, rig: Rig):
        self.rig = rig
        self.arm = arms.build_arm(rig.c)
        self.parts = weapon_geom.build(rig.wid, rig.art, "fp")
        self.arm_rest = arms.globals_of(arms.right_rests(rig.c))

    def posed_arm(self, side: str, pose: dict, hand_cam: Xf, elbow_cam):
        to_elbow = hand_cam.inverse().apply(elbow_cam)
        return bw._posed_arm(self.arm, self.rig.c, pose, to_elbow, side == "l")

    def pieces(self, fr: dict):
        """[(name, geo, camera-frame Xf)] of one frame."""
        cam = fr["_cam"]
        W = cam["W"]
        out = [("Mesh", self.parts["Mesh"], W)]
        if self.rig.cell is not None and self.parts["Cell"].faces:
            out.append(("Cell", self.parts["Cell"], W * fr["Cell"]))
        if self.rig.charge is not None and self.parts["Charge"].faces:
            out.append(("Charge", self.parts["Charge"], W * fr["Charge"]))
        for side in ("r", "l"):
            geo = self.posed_arm(side, fr["_pose"][side], cam[side], cam["elbow_" + side])
            out.append(("Arm_" + side, geo, cam[side]))
        return out


def tri_list(geo):
    tris = []
    for f in geo.faces:
        ids = f[0]
        for k in range(1, len(ids) - 1):
            tris.append((ids[0], ids[k], ids[k + 1]))
    return tris


def measure(pieces, scale: float, near: float) -> dict:
    """Reach (farthest vertex), nearest vertex and near-plane cuts in view (any fov row), game metres."""
    far, nearest, cuts = 0.0, 1e9, 0
    who = set()
    nat_near = near / scale
    for _name, geo, xf in pieces:
        pts = [xf.apply(p) for p in geo.pos]
        for p in pts:
            d = math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2])
            far = max(far, d)
            nearest = min(nearest, d)
        close = [(-p[2] < nat_near * 3.0) for p in pts]
        if not any(close):
            continue
        for a, b, c in tri_list(geo):
            if not (close[a] or close[b] or close[c]):
                continue
            tri = (pts[a], pts[b], pts[c])
            for aspect, fov in ASPECTS:
                th = math.tan(math.radians(fov) * 0.5)
                tw = th * aspect
                hit = False
                for v in tri:
                    dd = -v[2]
                    if 0.0 < dd < nat_near and abs(v[0]) <= dd * tw and abs(v[1]) <= dd * th:
                        hit = True
                for i in range(3):
                    p0, p1 = tri[i], tri[(i + 1) % 3]
                    d0, d1 = -p0[2] - nat_near, -p1[2] - nat_near
                    if (d0 < 0.0) != (d1 < 0.0):
                        q = vg.lerp(p0, p1, d0 / (d0 - d1))
                        if abs(q[0]) <= nat_near * tw and abs(q[1]) <= nat_near * th:
                            hit = True
                if hit:
                    cuts += 1
                    who.add(_name)
                    break
    return {"far": far * scale, "nearest": nearest * scale, "cuts": cuts, "who": sorted(who)}


def local_error(a: dict, b: dict) -> float:
    worst = 0.0
    for k, x in a.items():
        if k.startswith("_"):
            continue
        y = b[k]
        worst = max(worst, vg.length(vg.sub(x.o, y.o)), math.degrees(quat_of(x).rotation_difference(quat_of(y)).angle) * 0.001)
    return worst


# --- Blender ---------------------------------------------------------------------------------------------------------------
def write_actions(rig: Rig, arm, baked: dict) -> None:
    arm.animation_data_create()
    pb = arm.pose.bones
    names = [b for b, _p, _g in rig.bones]
    for p in pb:
        p.rotation_mode = "QUATERNION"
    for act_name in sorted(baked):
        frames = baked[act_name]
        act = bpy.data.actions.new(act_name)
        arm.animation_data.action = act
        prev = {}
        for f, loc in enumerate(frames):
            for b in names:
                mb = rig.rest_local[b].inverse() * loc[b]
                q = quat_of(mb)
                if b in prev and prev[b].dot(q) < 0.0:
                    q = -q
                prev[b] = q
                pb[b].rotation_quaternion = q
                pb[b].location = mb.o
                pb[b].keyframe_insert("rotation_quaternion", frame=f)
                pb[b].keyframe_insert("location", frame=f)
        act.use_fake_user = True
    arm.animation_data.action = None
    for p in pb:
        p.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        p.location = (0.0, 0.0, 0.0)
    bpy.context.scene.frame_set(0)


def verify(path: str, baked: dict) -> tuple:
    """Reads the .glb back: every keyed translation / rotation equals the baked local (Godot numbers)."""
    doc, binary = gbl.read_glb(path)
    names = [n.get("name", "") for n in doc["nodes"]]
    worst_p = worst_r = 0.0
    seen = 0
    for anim in doc.get("animations", []):
        frames = baked.get(anim["name"])
        if frames is None:
            continue
        seen += 1
        for ch in anim["channels"]:
            bone = names[ch["target"]["node"]]
            kind = ch["target"]["path"]
            s = anim["samplers"][ch["sampler"]]
            times = gbl.accessor(doc, binary, s["input"])
            vals = gbl.accessor(doc, binary, s["output"])
            for t, v in zip(times, vals):
                f = int(round(t[0] * FPS))
                if f >= len(frames) or bone not in frames[f]:
                    continue
                want = frames[f][bone]
                if kind == "translation":
                    worst_p = max(worst_p, vg.length(vg.sub(v, want.o)))
                elif kind == "rotation":
                    got = Quaternion((v[3], v[0], v[1], v[2]))
                    worst_r = max(worst_r, math.degrees(got.rotation_difference(quat_of(want)).angle))
    return seen, worst_p, worst_r


def render_strip(geom: Geometry, frames: list, path: str, count: int, mats: dict, tile=(480, 206)) -> str:
    scene = bpy.context.scene
    cam = scene.camera
    scene.render.resolution_x, scene.render.resolution_y = tile
    view_bl.look(cam, Z3, (0.0, 0.0, -1.0), fov_deg=75.0)
    cam.data.clip_start = 0.05 / 0.45
    picks = sorted(set(int(round(i * (len(frames) - 1) / max(1, count - 1))) for i in range(count)))
    tmp = []
    for k, f in enumerate(picks):
        made = []
        for name, geo, xf in geom.pieces(frames[f]):
            made.append(view_bl.static_object("Prev_%s" % name, geo, mats, xf))
        p = path[:-4] + "_f%02d.png" % k
        view_bl.shoot(p)
        tmp.append(p)
        for obj in made:
            me = obj.data
            bpy.data.objects.remove(obj, do_unlink=True)
            bpy.data.meshes.remove(me, do_unlink=True)
    # compose a grid (4 per row)
    cols = 4
    rows = (len(tmp) + cols - 1) // cols
    w, h = tile
    W, H = cols * w + (cols - 1) * 4, rows * h + (rows - 1) * 4
    canvas = [0.08, 0.08, 0.09, 1.0] * (W * H)
    for k, p in enumerate(tmp):
        img = bpy.data.images.load(p)
        px = list(img.pixels[:])
        r, c = k // cols, k % cols
        ox, oy = c * (w + 4), (rows - 1 - r) * (h + 4)
        for y in range(h):
            row = (oy + y) * W + ox
            canvas[row * 4:(row + w) * 4] = px[y * w * 4:(y + 1) * w * 4]
        bpy.data.images.remove(img)
        os.remove(p)
    out = bpy.data.images.new("strip", W, H, alpha=False)
    out.pixels[:] = canvas
    out.filepath_raw = path
    out.file_format = "PNG"
    out.save()
    bpy.data.images.remove(out)
    return path


def build(wid: str, out_dir: str, preview: str, art_all: dict, cam_cfg: dict, fp: dict, scale: float, near: float,
          reach: float) -> None:
    gbl.reset_scene()
    rig = Rig(wid, art_all, cam_cfg, fp)
    specs = blade_specs(fp) if rig.melee else gun_specs(fp)
    if len(rig.bones) > 50:
        raise RuntimeError("%s: %d bones > 50" % (wid, len(rig.bones)))
    baked, by_clip = {}, {}
    for clip in clip_list(rig):
        frames = bake(rig, specs[clip], clip)
        baked[action_name(wid, clip)] = frames
        by_clip[clip] = frames
    arm = view_bl.armature("ViewRig", [(b, p, g) for b, p, g in rig.bones])
    write_actions(rig, arm, baked)
    out = "%s/view_clips_%s.glb" % (out_dir, wid)
    path = gbl.export_glb(out)
    seen, err_p, err_r = verify(path, baked)
    s = gbl.summary(path)
    if out.startswith(OUT_DIR + "/"):
        gbl.update_manifest(out, ME, "")
    print("VIEW_CLIPS %s out=%s bones=%d clips=%d bytes=%d sha256=%s readback_clips=%d readback_pos_err_m=%.7f readback_rot_err_deg=%.5f" % (
        wid, out, len(rig.bones), len(s["clips"]), s["bytes"], s["sha256"], seen, err_p, err_r))
    # the hold pose as the game builds it today (bone rests + the data's finger poses, nothing keyed)
    rest = {k: v for k, v in rig.evaluate({}, 0.0).items() if not k.startswith("_")}
    print("VIEW_CLIPS_REST %s idle_frame0_vs_hold_pose=%.7f" % (wid, local_error(rest, by_clip["idle"][0])))
    geom = Geometry(rig)
    worst = {"far": 0.0, "nearest": 9.0, "cuts": 0}
    for clip, frames in by_clip.items():
        m_all = {"far": 0.0, "nearest": 9.0, "cuts": 0, "cut_frames": []}
        for f, fr in enumerate(frames):
            m = measure(geom.pieces(fr), scale, near)
            m_all["far"] = max(m_all["far"], m["far"])
            m_all["nearest"] = min(m_all["nearest"], m["nearest"])
            m_all["cuts"] += m["cuts"]
            if m["cuts"]:
                m_all["cut_frames"].append("%d:%s" % (f, "+".join(m["who"])))
        close = local_error(frames[0], frames[-1]) if clip in LOOPS else -1.0
        ends = local_error(rest, frames[0]) + local_error(rest, frames[-1]) if clip not in LOOPS and clip not in ("ads_raise", "ads_lower") else -1.0
        print("VIEW_CLIP %s %s frames=%d length_s=%.3f reach_m=%.4f nearest_m=%.4f cuts=%d cut_frames=%s loop_close=%.6f ends_vs_rest=%.6f %s" % (
            wid, action_name(wid, clip), len(frames), (len(frames) - 1) / FPS, m_all["far"], m_all["nearest"], m_all["cuts"],
            m_all["cut_frames"][:8], close, ends,
            "OVER" if m_all["far"] >= reach or m_all["nearest"] <= near or m_all["cuts"] else "ok"))
        worst["far"] = max(worst["far"], m_all["far"])
        worst["nearest"] = min(worst["nearest"], m_all["nearest"])
        worst["cuts"] += m_all["cuts"]
    if rig.ads is not None:
        end = by_clip["ads_raise"][-1]["Weapon"]
        print("VIEW_CLIPS_ADS %s ads_raise_end_vs_ads=%.7f ads_lower_end_vs_hold=%.7f" % (
            wid, local_error({"W": rig.ads}, {"W": end}), local_error({"W": rig.hold}, {"W": by_clip["ads_lower"][-1]["Weapon"]})))
    print("VIEW_CLIPS_LIMITS %s reach_m=%.4f (limit %.2f) nearest_m=%.4f (near %.3f) cuts=%d" % (
        wid, worst["far"], reach, worst["nearest"], near, worst["cuts"]))
    if preview:
        mats = view_bl.materials()
        view_bl.preview_setup((480, 206))
        d = gbl.repo_path(preview)
        os.makedirs(d, exist_ok=True)
        for clip, frames in by_clip.items():
            p = render_strip(geom, frames, os.path.join(d, "%s_%s.png" % (wid, clip)), 12 if clip in ("reload", "pickup", "swing") else 8, mats)
            print("VIEW_CLIPS_PREVIEW %s" % p)


def main() -> None:
    a = gbl.args()
    art_all = gbl.read_json("data/art_soldier.json")
    cam_all = gbl.read_json("data/camera.json")["first_person"]["view_model"]
    fp = gbl.read_json("data/anim.json")["first_person"]
    scale = float(cam_all["scale"]["value"])
    near = float(cam_all["camera_near_m"]["value"])
    reach = float(cam_all["max_reach_m"]["value"])
    out_dir = str(a.get("out-dir", OUT_DIR)).rstrip("/")
    only = str(a["only"]).split(",") if a.get("only") else list(IDS)
    preview = str(a.get("preview", "")) if a.get("preview") else ""
    for wid in only:
        build(wid, out_dir, preview, art_all, cam_all, fp, scale, near, reach)


if __name__ == "__main__":
    main()
