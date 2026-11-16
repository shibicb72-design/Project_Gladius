"""M2 AN2 item 2: the CC0 library clips retargeted onto the soldier's own 22-bone rig, cleaned and baked in Blender.

    blender.cmd -b --factory-startup --python tools/blender/build_soldier_clips.py -- [--out=<repo-relative .glb>]
        [--only=<clip,clip>] [--preview=<dir under build/an2/preview>] [--no-mesh]

Writes assets/generated/characters/soldier_clips.glb: the armature "Armature" (gladius_bl.soldier_armature(), the
same 22 bones and identity rests as soldier.glb and the runtime skeleton) with one action per clip and nothing else
(no mesh, no material). Looping clips are named <clip>_Loop (Godot's importer loops them and drops the suffix).

Source: assets/third_party/quaternius_ual/UAL1_Standard.glb (CC0, read-only). The script reads the source's joints and
clips straight from the .glb (glTF space = Godot space: +Y up; the importer's bone-axis heuristic would only add a
transform to undo), so the factory-empty scene holds only our armature (and, for the checks and previews, the near
soldier mesh built by tools/blender/build_soldier.py, removed from the scene before the export).

Per clip (table CLIPS below; numbers in tools/blender/soldier_clips_design.json):
1. Retarget. World-space bone orientations relative to the source rest go through the facing change (the UAL faces +Z
   with its left on +X, the soldier faces -Z with its right on +X: a half turn about +Y, which keeps the left foot the
   left foot) and a per-bone rest-shape alignment (our arms hang, the UAL's are a T), the bone mapping of
   data/anim_sources.json rigs.ual (spine_02 -> Spine, spine_03 -> Chest, clavicles folded into the upper arms,
   ball_l/r -> LeftToes/RightToes; fingers keep the glove's grip). Positions (pelvis, ankles) are the source's scaled
   by the leg-length ratio k about the ground origin, so a planted source foot stays planted.
2. Legs (clips with "ik"): each ankle goes where the scaled source ankle went; the lowest sole point of the clip is put
   on the ground (y = 0; soles from the boot part's box in the game's part data); stride scaling and a stance time warp
   (sprint) lengthen the stride; planted heel / ball / toe points are pinned (they move back at exactly the clip's
   natural ground speed, zero drift); toes bend up instead of going through the floor; no sole point below the ground;
   the pelvis drops where a foot is out of reach (legs never past leg_reach_max of their length); two-bone solve in
   the clip's own knee plane.
3. Neck: today's runtime meaning (anim_retarget.gd): the Neck root keeps its rest position and takes the source neck's
   world orientation, the Head its local turn under it; the clips whose consumer carries the neck on the chest top
   (the corpse's death, the reviver: soldier_corpse.gd, soldier_pose.gd) bake it carried.
4. Loops: the last seam_frames frames blend into the first (identical first and last frame per bone); the reviver's
   working loop (anim_third_person.json poses.revive clip_loop_from_s..to_s) is closed the same way.
5. Arms (clips that show them): forearm and hand vertices of the near mesh stay outside the torso's cross-section
   (torso, pauldrons, pteruges: vertices skinned to Hips / Spine / Chest) by arm_margin_m; the upper arm turns out
   where they do not.
6. Ground (death, revive): the posed near mesh never goes below y = 0 and the lowest vertex touches it.
Prints one SOLDIER_CLIP line per clip (measured numbers) and one SOLDIER_CLIPS summary line; records the file in
tools/blender/manifest.json (derived_from quaternius_ual_standard_glb).

--preview=<dir>: per clip a strip of evenly spaced frames (side view; also front for death and the hits) of the near
mesh posed by the baked clip, Workbench, under build/an2/preview/<dir>/. --only bakes a subset into a scratch file
(build/an2/scratch/soldier_clips_only.glb; manifest untouched). --no-mesh skips the mesh checks (arms, ground).
"""

import bisect
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gladius_bl as gbl  # noqa: E402
import soldier_data  # noqa: E402

OUT = "assets/generated/characters/soldier_clips.glb"
SCRATCH = "build/an2/scratch/soldier_clips_only.glb"
ME = "tools/blender/build_soldier_clips.py"
SOURCE = "assets/third_party/quaternius_ual/UAL1_Standard.glb"
DERIVED = "quaternius_ual_standard_glb"
DESIGN = "tools/blender/soldier_clips_design.json"
FPS = gbl.FPS
LEGS = ("Left", "Right")
# Our bone -> the humanoid profile name data/anim_sources.json rigs use (only the forearms differ).
PROFILE = {"LeftForeArm": "LeftLowerArm", "RightForeArm": "RightLowerArm"}
FACING = Quaternion((0.0, 1.0, 0.0), math.pi)  # source (+Z forward, left +X) -> ours (-Z forward, right +X)


def smoothstep(a, b, x):
    if b <= a:
        return 1.0 if x >= b else 0.0
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3.0 - 2.0 * t)


def qfix(q, ref):
    """q in the hemisphere of ref (same rotation)."""
    return -q if q.dot(ref) < 0.0 else q


def qangle_deg(a, b):
    d = max(-1.0, min(1.0, abs(a.normalized().dot(b.normalized()))))
    return math.degrees(2.0 * math.acos(d))


# --- the source (.glb read directly) ------------------------------------------------------------------------------------
class Source:
    def __init__(self, rel):
        doc, binary = gbl.read_glb(gbl.repo_path(rel))
        self.doc, self.bin = doc, binary
        nodes = doc["nodes"]
        self.names = [n.get("name", "") for n in nodes]
        self.index = {n: i for i, n in enumerate(self.names)}
        self.parent = [-1] * len(nodes)
        for i, n in enumerate(nodes):
            for c in n.get("children", []):
                self.parent[c] = i
        self.rest = []
        for n in nodes:
            t = n.get("translation", [0.0, 0.0, 0.0])
            r = n.get("rotation", [0.0, 0.0, 0.0, 1.0])
            s = n.get("scale", [1.0, 1.0, 1.0])
            self.rest.append((Vector(t), Quaternion((r[3], r[0], r[1], r[2])), Vector(s)))
        self.order = []
        seen = set()

        def visit(i):
            if i in seen:
                return
            if self.parent[i] >= 0:
                visit(self.parent[i])
            seen.add(i)
            self.order.append(i)
        for i in range(len(nodes)):
            visit(i)
        self.anims = {a["name"]: a for a in doc.get("animations", [])}
        self.rest_globals = self._fk({})

    def clip(self, name):
        anim = self.anims[name]
        channels = {}
        length = 0.0
        for ch in anim["channels"]:
            sampler = anim["samplers"][ch["sampler"]]
            if sampler.get("interpolation", "LINEAR") != "LINEAR":
                raise RuntimeError("%s: only LINEAR samplers are read" % name)
            times = [v[0] for v in gbl.accessor(self.doc, self.bin, sampler["input"])]
            values = gbl.accessor(self.doc, self.bin, sampler["output"])
            length = max(length, times[-1])
            channels[(ch["target"]["node"], ch["target"]["path"])] = (times, values)
        return {"name": name, "channels": channels, "length": length}

    @staticmethod
    def _interp(times, values, t, path):
        if t <= times[0]:
            v = values[0]
            i, w, v2 = 0, 0.0, values[0]
        elif t >= times[-1]:
            v = values[-1]
            i, w, v2 = 0, 0.0, values[-1]
        else:
            i = bisect.bisect_right(times, t) - 1
            w = (t - times[i]) / (times[i + 1] - times[i])
            v, v2 = values[i], values[i + 1]
        if path == "rotation":
            a = Quaternion((v[3], v[0], v[1], v[2]))
            b = Quaternion((v2[3], v2[0], v2[1], v2[2]))
            return a.slerp(qfix(b, a), w) if w > 0.0 else a
        return Vector(v).lerp(Vector(v2), w) if w > 0.0 else Vector(v)

    def _fk(self, local):
        out = [None] * len(self.names)
        for i in self.order:
            t, r, s = local.get(i, self.rest[i])
            m = Matrix.LocRotScale(t, r, s)
            out[i] = m if self.parent[i] < 0 else out[self.parent[i]] @ m
        return out

    def sample(self, clip, t):
        local = {}
        for i in range(len(self.names)):
            t0, r0, s0 = self.rest[i]
            ch = clip["channels"]
            tr = ch.get((i, "translation"))
            ro = ch.get((i, "rotation"))
            sc = ch.get((i, "scale"))
            local[i] = (self._interp(*tr, t, "translation") if tr else t0,
                        self._interp(*ro, t, "rotation") if ro else r0,
                        self._interp(*sc, t, "scale") if sc else s0)
        return self._fk(local)


# --- our rig ----------------------------------------------------------------------------------------------------------
class Rig:
    def __init__(self, src: Source, design: dict):
        self.rows = soldier_data.rest_table()
        self.bones = [b for b, _p, _a in self.rows]
        self.parent = {b: p for b, p, _a in self.rows}
        self.rest = {b: Vector(a) for b, _p, a in self.rows}
        self.local = {b: (self.rest[b] - self.rest[p]) if p else self.rest[b].copy() for b, p, _a in self.rows}
        self.children = {b: [c for c in self.bones if self.parent[c] == b] for b in self.bones}
        rig = gbl.read_json("data/anim_sources.json")["rigs"]["ual"]["bones"]
        self.map = {}
        for b in self.bones:
            name = rig.get(PROFILE.get(b, b))
            if name is not None:
                self.map[b] = src.index[name]
        self.src = src
        sg = src.rest_globals
        self.src_rest_q = [m.to_quaternion().normalized() for m in sg]
        self.src_rest_p = [m.translation.copy() for m in sg]
        # Leg-length ratio (hip joint to ankle, rest), ours / source.
        ours = (self.rest["LeftLowerLeg"] - self.rest["LeftUpperLeg"]).length + (self.rest["LeftFoot"] - self.rest["LeftLowerLeg"]).length
        si = src.index
        theirs = (self.src_rest_p[si["calf_l"]] - self.src_rest_p[si["thigh_l"]]).length + (self.src_rest_p[si["foot_l"]] - self.src_rest_p[si["calf_l"]]).length
        self.k = ours / theirs
        self.leg = {s: ((self.rest[s + "LowerLeg"] - self.rest[s + "UpperLeg"]).length, (self.rest[s + "Foot"] - self.rest[s + "LowerLeg"]).length) for s in LEGS}
        # Rest-shape alignment per bone (anim_retarget.gd bake: our rest child direction -> the source's, turned).
        self.align = {}
        for b in self.bones:
            shape = self.align.get(self.parent[b], Quaternion()) if self.parent[b] else Quaternion()
            if b in self.map:
                kids = [c for c in self.children[b] if c in self.map]
                if b == "Hips":
                    kids = ["Spine"]
                if len(kids) == 1:
                    ours_d = self.rest[kids[0]] - self.rest[b]
                    theirs_d = FACING @ (self.src_rest_p[self.map[kids[0]]] - self.src_rest_p[self.map[b]])
                    if ours_d.length > 1e-6 and theirs_d.length > 1e-6:
                        shape = ours_d.normalized().rotation_difference(theirs_d.normalized())
            self.align[b] = shape
        # Soles: the boot part's box (the game's soldier_clips.gd sole_points), bone-local (identity rests).
        boot = {p["name"]: p for p in soldier_data.parts()}
        self.sole = {}
        for s, tag in (("Left", "l"), ("Right", "r")):
            part = boot["boot_" + tag]
            at, size = Vector(part["at"]), Vector(part["size"])
            lo, hi = at - size * 0.5, at + size * 0.5
            foot, toes = self.rest[s + "Foot"], self.rest[s + "Toes"]
            heel = Vector((at.x, lo.y, hi.z)) - foot
            ball = Vector((at.x, lo.y, toes.z)) - foot
            tip = Vector((at.x, lo.y, lo.z)) - toes
            self.sole[s] = {"heel": heel, "ball": ball, "tip": tip, "toes": toes - foot}
        self.sole_y = min(boot["boot_l"]["at"][1] - boot["boot_l"]["size"][1] * 0.5, boot["boot_r"]["at"][1] - boot["boot_r"]["size"][1] * 0.5)
        # Our pose = k * FACING * source + offset: the source rest maps onto our rest standing on y = 0.
        down = Vector((0.0, self.sole_y, 0.0))
        self.thighs = (self.rest["LeftUpperLeg"] + self.rest["RightUpperLeg"]) * 0.5
        src_thighs = (self.src_rest_p[si["thigh_l"]] + self.src_rest_p[si["thigh_r"]]) * 0.5
        self.off_thighs = (self.thighs - down) - self.k * (FACING @ src_thighs)
        self.off_ankle = {s: (self.rest[s + "Foot"] - down) - self.k * (FACING @ self.src_rest_p[si["foot_" + s[0].lower()]]) for s in LEGS}
        self.design = design

    # FK from local rotations, hips and neck positions -> (global rotations, global positions)
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

    def locals_from(self, grot):
        out = {}
        for b in self.bones:
            p = self.parent[b]
            out[b] = (grot[b] if not p else grot[p].inverted() @ grot[b]).normalized()
        return out

    def contact_points(self, side, ankle, foot_q, toes_q):
        s = self.sole[side]
        toes = ankle + foot_q @ s["toes"]
        return {"heel": ankle + foot_q @ s["heel"], "ball": ankle + foot_q @ s["ball"], "tip": toes + toes_q @ s["tip"]}


# --- retarget ---------------------------------------------------------------------------------------------------------
def retarget_frame(rig: Rig, g, drift):
    """Global rotations of our bones and the scaled pelvis / ankle positions for one source pose g (node matrices)."""
    src = rig.src
    grot = {}
    for b in rig.bones:
        if b in rig.map:
            n = rig.map[b]
            q = g[n].to_quaternion().normalized()
            grot[b] = (FACING @ q @ rig.src_rest_q[n].inverted() @ FACING.inverted() @ rig.align[b]).normalized()
        else:
            p = rig.parent[b]
            grot[b] = grot[p].copy() if p else Quaternion()
    si = src.index
    # the hips from the source's hip-joint midpoint (the legs keep the source's geometry whatever the pelvis pivots)
    mid = (g[si["thigh_l"]].translation + g[si["thigh_r"]].translation) * 0.5
    hips = rig.k * (FACING @ (mid - drift)) + rig.off_thighs + grot["Hips"] @ (rig.rest["Hips"] - rig.thighs)
    ankles = {s: rig.k * (FACING @ (g[si["foot_" + s[0].lower()]].translation - drift)) + rig.off_ankle[s] for s in LEGS}
    return {"grot": grot, "hips": hips, "ankle": ankles}


def source_frames(rig: Rig, clip, spec, times):
    src = rig.src
    root = src.index["root"]
    root_rest = src.rest_globals[root].translation
    out = []
    for t in times:
        g = src.sample(clip, t)
        drift = Vector((0.0, 0.0, 0.0))
        if not spec.get("root_motion", False):
            d = g[root].translation - root_rest
            drift = Vector((d.x, 0.0, d.z))
        out.append(retarget_frame(rig, g, drift))
    return out


# --- legs -------------------------------------------------------------------------------------------------------------
def _frame(x, y):
    """A rotation whose local X is along x and local -Y along y (x made orthogonal to y; columns X, Y = -y, Z = X x Y)."""
    y = y.normalized()
    x = (x - y * x.dot(y)).normalized()
    z = x.cross(-y)
    return Matrix((x, -y, z)).transposed().to_quaternion()


def solve_leg(rig: Rig, side, grot, hips, ankle):
    """Two-bone solve with a hinge knee: the thigh points at the knee, the shin at the ankle `ankle`; the knee bends
    about the thigh's own X (anim.json: knee bend = -X on the lower leg) toward the retargeted knee pushed along the
    thigh's front (a stable pole even for a straight leg); the foot keeps its global orientation."""
    up, lo, ft = side + "UpperLeg", side + "LowerLeg", side + "Foot"
    a, b = rig.leg[side]
    root = hips + grot["Hips"] @ (rig.rest[up] - rig.rest["Hips"])
    pole = root + grot[up] @ rig.local[lo] + grot[up] @ Vector((0.0, 0.0, -0.25))
    to_foot = ankle - root
    reach = max(abs(a - b) + 1e-4, min(a + b - 1e-4, to_foot.length))
    d = to_foot.normalized()
    bend = (pole - root) - d * (pole - root).dot(d)
    if bend.length < 1e-4:
        bend = grot[up] @ Vector((0.0, 0.0, -1.0))
    bend.normalize()
    along = (a * a + reach * reach - b * b) / (2.0 * reach)
    elbow = root + d * along + bend * math.sqrt(max(a * a - along * along, 0.0))
    end = root + d * reach
    d1 = (elbow - root).normalized()
    d2 = (end - elbow).normalized()
    hinge = d2.cross(d1)
    if hinge.length < 1e-3:
        hinge = d1.cross(bend)  # straight leg: the axis across the bend plane
    hinge.normalize()
    # thigh: rest child direction -> d1, rest X -> hinge
    rest_up = rig.local[lo].normalized()
    q_rest = _frame(Vector((1.0, 0.0, 0.0)), rest_up)
    q_up = _frame(hinge, d1) @ q_rest.inverted()
    # shin: a turn about X (thigh-local) from the rest shin direction to d2
    want = q_up.inverted() @ d2
    rest_lo = rig.local[ft].normalized()
    ang = math.atan2(want.z, -want.y) - math.atan2(rest_lo.z, -rest_lo.y)
    q_lo = q_up @ Quaternion((1.0, 0.0, 0.0), -ang)
    grot[up] = q_up.normalized()
    grot[lo] = q_lo.normalized()
    knee_at = root + grot[up] @ rig.local[lo]
    got = knee_at + grot[lo] @ rig.local[ft]
    return (got - ankle).length


def measure_gait(points, n, dt, contact, loop, floor=None):
    """The game's SoldierClips.measure on per-frame contact points {key: [Vector per frame]}: speed of the touching
    points against the hips while down (within `contact` of the lowest point, or of `floor`), contact fraction."""
    if floor is None:
        floor = min(p.y for pts in points.values() for p in pts)
    travel = time = 0.0
    down = 0
    steps = n if loop else n - 1
    for i in range(steps):
        j = (i + 1) % n
        moved, touching = 0.0, 0
        for pts in points.values():
            a, b = pts[i], pts[j]
            if a.y <= floor + contact and b.y <= floor + contact:
                moved += b.z - a.z
                touching += 1
        if touching:
            travel += moved / touching
            time += dt
            down += 1
    speed = travel / time if time > 0 else 0.0
    return {"speed": speed, "floor": floor, "contact": down / max(steps, 1)}


def foot_slide(points, n, dt, contact, speed, loop):
    """tests/test_soldier_footslide.gd's drift on the clip itself: the ground moves back at `speed`; per contact (a
    point down >= 3 frames) the farthest it gets on the ground plane from where it touched down."""
    floor = min(p.y for pts in points.values() for p in pts)
    frames = 2 * n if loop else n
    worst = 0.0
    for pts in points.values():
        run, start, far = 0, None, 0.0
        for i in range(frames + 1):
            k = i % n
            is_down = i < frames and pts[k].y <= floor + contact
            if is_down:
                w = Vector((pts[k].x, 0.0, pts[k].z - speed * dt * i))
                if run == 0:
                    start = w
                run += 1
                far = max(far, (w - start).length)
            elif run:
                if run >= 3:
                    worst = max(worst, far)
                run, far = 0, 0.0
    return worst


def blur_circular(values, radius, loop):
    n = len(values)
    out = []
    for i in range(n):
        acc = wsum = 0.0
        for d in range(-radius, radius + 1):
            j = i + d
            if loop:
                j %= n
            elif j < 0 or j >= n:
                continue
            w = 1.0 - abs(d) / (radius + 1.0)
            acc += values[j] * w
            wsum += w
        out.append(acc / wsum)
    return out


def max_filter(values, radius, loop):
    n = len(values)
    out = []
    for i in range(n):
        best = values[i]
        for d in range(-radius, radius + 1):
            j = i + d
            if loop:
                j %= n
            elif j < 0 or j >= n:
                continue
            best = max(best, values[j])
        out.append(best)
    return out


def fix_legs(rig: Rig, frames, spec, cfg, n, loop, dt, report):
    """Places the ankles (ground, stride, pinning, reach) and solves both legs in every frame (see the docstring)."""
    contact = float(cfg["contact_height_m"])
    pin_h = contact + float(cfg["pin_extra_m"])

    def pts(f, side):
        fr = frames[f]
        return rig.contact_points(side, fr["ankle"][side], fr["grot"][side + "Foot"], fr["grot"][side + "Toes"])
    # 1. ground: the clip's stance level on y = 0 (the whole body moves, the legs keep their shape). The level is a low
    # percentile of each foot's lowest sole point per frame, not the minimum: the UAL's heel strikes dip a few cm
    # under its own stance level (they are lifted out of the floor in step 4).
    lows = sorted(min(p.y for p in pts(f, s).values()) for f in range(n) for s in LEGS)
    low = lows[int(len(lows) * float(cfg["ground_percentile"]))]
    for fr in frames:
        fr["hips"].y -= low
        for s in LEGS:
            fr["ankle"][s].y -= low
    report["ground_shift_m"] = -low
    # 2. stride: the feet's fore-aft offset from the pelvis scaled
    stride = float(spec.get("stride", 1.0))
    if abs(stride - 1.0) > 1e-6:
        for fr in frames:
            for s in LEGS:
                fr["ankle"][s].z = fr["hips"].z + stride * (fr["ankle"][s].z - fr["hips"].z)
    # 3. natural speed of the (scaled) source feet, then the pinning
    raw_points = {}
    for s in LEGS:
        for key in ("heel", "ball", "tip"):
            raw_points[s + key] = [pts(f, s)[key] for f in range(n)]
    gait = bool(spec.get("gait"))

    def velocity(key, f, d):
        """Velocity over the frame step from f to f + d (d = +1 forward, -1 backward)."""
        g = (f + d) % n if loop else min(max(f + d, 0), n - 1)
        if g == f:
            return None
        return (raw_points[key][g] - raw_points[key][f]) * (float(d) / dt)
    # Natural speed: the planted points' backward speed. A point is planted when it is within pin_h of the ground AND
    # moves like the ground over the step into or out of the frame (back at about the natural speed, little sideways):
    # a low swing (the crouch shuffle) or the UAL's one-frame touchdown dwell is not a stance. Estimated from the
    # median of the backward speeds near the ground, then refined over the steps that pass.
    vel = {k: [[velocity(k, f, d) for d in (1, -1)] for f in range(n)] for k in raw_points}
    near = [(k, f) for k in raw_points for f in range(n) if raw_points[k][f].y <= pin_h]
    speed = 0.0
    zs = sorted(v.z for k, f in near for v in vel[k][f] if v is not None and v.z > 0.0)
    if gait and zs:
        speed = zs[len(zs) // 2]
        for _ in range(3):
            tol = max(float(cfg["pin_speed_tol_mps"]), float(cfg["pin_speed_tol_frac"]) * abs(speed))
            ok = [v.z for k, f in near for v in vel[k][f] if v is not None and abs(v.z - speed) <= tol and abs(v.x) <= tol]
            if ok:
                speed = sum(ok) / len(ok)
    tol = max(float(cfg["pin_speed_tol_mps"]), float(cfg["pin_speed_tol_frac"]) * abs(speed))

    def moves_like_ground(key, f):
        return any(v is not None and abs(v.z - speed) <= tol and abs(v.x) <= tol for v in vel[key][f])
    report["raw_speed"] = measure_gait({k: v for k, v in raw_points.items() if not k.endswith("ball")}, n, dt, contact, loop, 0.0)["speed"] if gait else 0.0
    report["raw_slide"] = foot_slide({k: v for k, v in raw_points.items() if not k.endswith("ball")}, n, dt, contact, report["raw_speed"], loop)
    decay = int(cfg["pin_release_frames"])
    planted = {s: [False] * n for s in LEGS}
    for s in LEGS:
        keys = ("heel", "ball", "tip")
        down = [{k: raw_points[s + k][f].y <= pin_h and moves_like_ground(s + k, f) for k in keys} for f in range(n)]
        start = 0
        if loop:
            air = [not any(d.values()) for d in down]
            best, best_len = None, 0
            for i in range(n):
                if air[i] and not air[(i - 1) % n]:
                    length = 0
                    while length < n and air[(i + length) % n]:
                        length += 1
                    if length > best_len:
                        best, best_len = i, length
            if best is not None:
                start = (best + best_len // 2) % n
        locks = {}
        held = Vector((0.0, 0.0, 0.0))  # the correction when the last stance ended
        corr = Vector((0.0, 0.0, 0.0))  # the correction shown in the previous frame
        age = 10 ** 6  # frames since the last stance ended
        stance_age = 0  # frames since this stance began
        press_from = 0.0  # vertical correction when this stance began
        press = int(cfg["press_frames"])
        result = [None] * n
        for step in range(n):
            f = (start + step) % n
            p = pts(f, s)
            for k in keys:
                if not down[f][k]:
                    locks.pop(k, None)
            if not locks:
                stance_age = 0

            def current():
                # xz: every locked point back on its pinned path; y: the lowest locked point onto the ground,
                # eased in over press_frames from the correction the stance began with
                cs = []
                for k, (at, st) in locks.items():
                    want = at + Vector((0.0, 0.0, speed * dt * (step - st)))
                    c = want - p[k]
                    cs.append(Vector((c.x, 0.0, c.z)))
                if not cs:
                    return None
                c = sum(cs, Vector()) / len(cs)
                flat = -min(p[k].y for k in locks)
                c.y = press_from + (flat - press_from) * smoothstep(0.0, float(press), float(stance_age + 1))
                return c
            if not locks:
                press_from = corr.y
            c = current()
            base = c if c is not None else held * (1.0 - smoothstep(0.0, float(decay), float(age)))
            for k in keys:
                if down[f][k] and k not in locks:
                    locks[k] = (p[k] + base, step)
            c = current()
            if c is not None:
                corr = c
                held = c
                age = 0
                stance_age += 1
            else:
                age += 1
                corr = held * (1.0 - smoothstep(0.0, float(decay), float(age)))
            result[f] = frames[f]["ankle"][s] + corr
            planted[s][f] = c is not None
        for f in range(n):
            frames[f]["ankle"][s] = result[f]
    # 4. toes bend up instead of going through the floor; then no sole point under the floor
    for fr in frames:
        for s in LEGS:
            fq = fr["grot"][s + "Foot"]
            tq = fr["grot"][s + "Toes"]
            sp = rig.contact_points(s, fr["ankle"][s], fq, tq)
            if sp["tip"].y < 0.0 and sp["ball"].y >= -1e-4:
                axis = tq @ Vector((1.0, 0.0, 0.0))
                lo_a, hi_a = 0.0, math.radians(float(cfg["toe_bend_max_deg"]))
                for _ in range(24):
                    mid = 0.5 * (lo_a + hi_a)
                    q = Quaternion(axis, mid) @ tq
                    if rig.contact_points(s, fr["ankle"][s], fq, q)["tip"].y < 0.0:
                        lo_a = mid
                    else:
                        hi_a = mid
                fr["grot"][s + "Toes"] = (Quaternion(axis, hi_a) @ tq).normalized()
                sp = rig.contact_points(s, fr["ankle"][s], fq, fr["grot"][s + "Toes"])
            lowest = min(p.y for p in sp.values())
            if lowest < 0.0:
                fr["ankle"][s].y -= lowest
    # 4b. a foot that is not planted keeps its sole above the contact height (the game counts anything within
    # contact_height_m of the floor as a contact): a heel that brushes the floor at the strike, or a low shuffle,
    # hovers just above it instead of dragging
    clear = contact + float(cfg["swing_clear_extra_m"])
    for s in LEGS:
        need = []
        for f, fr in enumerate(frames):
            sp = rig.contact_points(s, fr["ankle"][s], fr["grot"][s + "Foot"], fr["grot"][s + "Toes"])
            need.append(0.0 if planted[s][f] else max(0.0, clear - min(p.y for p in sp.values())))
        lift = blur_circular(max_filter(need, 1, loop), 1, loop)
        for f, fr in enumerate(frames):
            if not planted[s][f]:
                fr["ankle"][s].y += max(lift[f], need[f])
    # 5. reach: the pelvis drops where an ankle is out of reach (leg_reach_max of the leg), smoothed
    reach_max = float(cfg["leg_reach_max"])
    drops = []
    for fr in frames:
        need = 0.0
        for s in LEGS:
            a, b = rig.leg[s]
            root = fr["hips"] + fr["grot"]["Hips"] @ (rig.rest[s + "UpperLeg"] - rig.rest["Hips"])
            v = fr["ankle"][s] - root
            flat = math.hypot(v.x, v.z)
            r = (a + b) * reach_max
            if v.length > r:
                need = max(need, (root.y - fr["ankle"][s].y) - math.sqrt(max(r * r - flat * flat, 0.0)))
        drops.append(need)
    smooth = blur_circular(max_filter(drops, 2, loop), 2, loop)
    report["pelvis_drop_max_m"] = max(smooth) if smooth else 0.0
    worst = 0.0
    for fr, d in zip(frames, smooth):
        fr["hips"].y -= max(d, 0.0)
        for s in LEGS:
            worst = max(worst, solve_leg(rig, s, fr["grot"], fr["hips"], fr["ankle"][s]))
    report["ik_miss_mm"] = worst * 1000.0
    return speed


def time_warp(n, stance, scale):
    """Source times for n output frames when stance frames play `scale` as long (flight frames longer, same total)."""
    dens = [scale if stance[i] else 1.0 for i in range(n)]
    s_n = sum(1 for x in stance if x)
    f_n = n - s_n
    if f_n == 0:
        return [i / float(n) for i in range(n + 1)]
    e = (n - scale * s_n) / f_n
    dens = [scale if stance[i] else e for i in range(n)]
    dens = blur_circular(dens, 1, True)
    total = sum(dens)
    dens = [d * n / total for d in dens]
    cum = [0.0]
    for d in dens:
        cum.append(cum[-1] + d)
    out = []
    for k in range(n + 1):
        u = float(k)
        i = min(max(bisect.bisect_right(cum, u) - 1, 0), n - 1)
        w = (u - cum[i]) / dens[i] if dens[i] > 0 else 0.0
        out.append((i + min(max(w, 0.0), 1.0)) / float(n))
    return out


# --- per clip ---------------------------------------------------------------------------------------------------------
def bake_clip(rig: Rig, spec, cfg):
    src = rig.src
    clip = src.clip(spec["src"])
    length = clip["length"]
    n = max(1, int(round(length * FPS)))
    dt = length / n
    loop = bool(spec.get("loop", False))
    report = {"length": length, "frames": n}
    times = [length * i / n for i in range(n + 1)]
    count = n if loop else n + 1  # loops: frame n is frame 0 again (appended at the end)
    warp = float(spec.get("stance_time", 1.0))
    if abs(warp - 1.0) > 1e-6:
        # stance frames from a plain pass (any sole point of either foot within the pin height of the clip's floor)
        probe = source_frames(rig, clip, spec, times[:n])
        pin_h = float(cfg["contact_height_m"]) + float(cfg["pin_extra_m"])
        heights = [[min(p.y for p in rig.contact_points(s, fr["ankle"][s], fr["grot"][s + "Foot"], fr["grot"][s + "Toes"]).values()) for s in LEGS] for fr in probe]
        low = min(min(h) for h in heights)
        stance = [min(h) <= low + pin_h for h in heights]
        times = [length * u for u in time_warp(n, stance, warp)]
        report["stance_frames"] = sum(1 for x in stance if x)
    frames = source_frames(rig, clip, spec, times[:count])
    if loop:
        # the source's own seam: rotation transfer at t = 0 against t = length
        ends = source_frames(rig, clip, spec, [0.0, length])
        report["source_seam"] = (max(qangle_deg(ends[0]["grot"][b], ends[1]["grot"][b]) for b in rig.bones),
                                 (ends[0]["hips"] - ends[1]["hips"]).length * 1000.0)
        # blend the last seam_frames frames into the first: they take the end-to-start difference progressively,
        # so frame n - 1 runs into frame 0 like any other step
        cnt = int(cfg["seam_frames"])
        for i in range(1, cnt + 1):
            f = n - i
            if f <= 0:
                break
            w = smoothstep(0.0, 1.0, (cnt + 1 - i) / float(cnt + 1))
            fr = frames[f]
            for b in rig.bones:
                d = qfix(ends[0]["grot"][b] @ ends[1]["grot"][b].inverted(), Quaternion())
                fr["grot"][b] = (Quaternion().slerp(d, w) @ fr["grot"][b]).normalized()
            fr["hips"] = fr["hips"] + (ends[0]["hips"] - ends[1]["hips"]) * w
            for s in LEGS:
                fr["ankle"][s] = fr["ankle"][s] + (ends[0]["ankle"][s] - ends[1]["ankle"][s]) * w
    # plain numbers (rotation transfer only, as the runtime retarget did): for the before/after report
    lean = math.radians(float(spec.get("lean_deg", 0.0)))
    if lean:
        turn = Quaternion((1.0, 0.0, 0.0), -lean)
        upper = set()
        for b in rig.bones:
            p = b
            while p and p != "Hips":
                p = rig.parent[p]
            if p == "Hips" and b != "Hips" and not any(x in b for x in ("Leg", "Foot", "Toes")):
                upper.add(b)
        for fr in frames:
            for b in upper:
                fr["grot"][b] = (turn @ fr["grot"][b]).normalized()
    if spec.get("lock_hips_xz", False):
        # SoldierGait turns the feet about the pelvis' ground point (strafes): a swaying pelvis would carry the turned
        # feet with it. The pelvis keeps its mean ground position; the legs are solved to the feet afterwards.
        mx = sum(fr["hips"].x for fr in frames) / len(frames)
        mz = sum(fr["hips"].z for fr in frames) / len(frames)
        for fr in frames:
            fr["hips"].x, fr["hips"].z = mx, mz
    speed = 0.0
    if spec.get("ik", False):
        speed = fix_legs(rig, frames, spec, cfg, count, loop, dt, report)
    # neck
    carried = bool(spec.get("carry_neck", False))
    neck_off = rig.rest["Neck"] - rig.rest["Chest"]
    out = []
    for fr in frames:
        grot = fr["grot"]
        hips = fr["hips"]
        neck = rig.rest["Neck"].copy()
        if carried:
            # chest global position by FK of the hips subtree
            # the head keeps only its own nod on the source neck (the neck's bend is not carried: as the runtime
            # corpse always showed it, the helmet stays clear of the gorget)
            loc = rig.locals_from(grot)
            _g, gp = rig.fk(loc, hips, neck)
            nod = grot["Neck"].inverted() @ grot["Head"]
            grot["Neck"] = grot["Chest"].copy()
            grot["Head"] = (grot["Chest"] @ nod).normalized()
            neck = gp["Chest"] + grot["Chest"] @ neck_off
        loc = rig.locals_from(grot)
        out.append({"loc": loc, "hips": hips.copy(), "neck": neck})
    if loop:
        out.append(copy_frame(out[0]))
    report["natural_speed"] = speed
    return out, report


def copy_frame(fr):
    return {"loc": {b: q.copy() for b, q in fr["loc"].items()}, "hips": fr["hips"].copy(), "neck": fr["neck"].copy()}


def seam(frames, a, b):
    rot = max(qangle_deg(frames[a]["loc"][k], frames[b]["loc"][k]) for k in frames[a]["loc"])
    pos = max((frames[a]["hips"] - frames[b]["hips"]).length, (frames[a]["neck"] - frames[b]["neck"]).length)
    return rot, pos * 1000.0


def close_seam(frames, at_end, target, count):
    """Blends frames at_end-count+1 .. at_end toward the pose that continues into `target` (frame at_end == target)."""
    end = frames[at_end]
    goal = frames[target]
    for i in range(count):
        f = at_end - i
        if f < 0:
            break
        w = smoothstep(0.0, 1.0, 1.0 - i / float(count))
        fr = frames[f]
        for k in fr["loc"]:
            d = goal["loc"][k] @ end["loc"][k].inverted()
            d = qfix(d, Quaternion())
            fr["loc"][k] = (Quaternion().slerp(d, w) @ fr["loc"][k]).normalized()
        fr["hips"] = fr["hips"] + (goal["hips"] - end["hips"]) * w
        fr["neck"] = fr["neck"] + (goal["neck"] - end["neck"]) * w
    frames[at_end] = copy_frame(goal) if at_end != target else frames[at_end]


# --- mesh checks ------------------------------------------------------------------------------------------------------
class MeshCheck:
    def __init__(self, rig: Rig, arm):
        import numpy as np
        import build_soldier
        import soldier_geom
        self.np = np
        self.rig = rig
        self.arm = arm
        design = json.loads(open(gbl.repo_path(build_soldier.DESIGN), "r", encoding="utf-8").read())
        self.design = design
        rests = soldier_data.rest_table()
        geo = soldier_geom.Soldier(design, "near", rests).build()
        self.obj = build_soldier.build_object("SoldierNear", geo, arm, design, rig.bones)
        groups = {g.index: g.name for g in self.obj.vertex_groups}
        dom = []
        for v in self.obj.data.vertices:
            best, bw = "", -1.0
            for ge in v.groups:
                if ge.weight > bw:
                    best, bw = groups[ge.group], ge.weight
            dom.append(best)
        self.dom = dom
        self.torso = {"Chest": np.array([i for i, b in enumerate(dom) if b in ("Chest", "Spine")]),
                      "Hips": np.array([i for i, b in enumerate(dom) if b == "Hips"])}
        self.arm_v = {s: np.array([i for i, b in enumerate(dom) if b in (s + "ForeArm", s + "Hand", s + "Fingers")]) for s in LEGS}
        self.n = len(self.obj.data.vertices)
        # The cape is cloth (the shader lifts it, cape_lift): it does not hold the body off the floor. Its vertices are
        # the ones on the sway surface (2nd UV map u = surface id, build_soldier.build_object).
        sway = soldier_data.surface_id(soldier_data.read_json("data/art_astra.json")["soldier"]["material"]["cape"]["surface"])
        me = self.obj.data
        uv = me.uv_layers["UV2"].data
        cape = set()
        for poly in me.polygons:
            for li, vi in zip(poly.loop_indices, poly.vertices):
                if int(round(uv[li].uv[0])) == sway:
                    cape.add(vi)
        self.solid = np.array([i not in cape for i in range(self.n)])

    def pose(self, fr):
        pb = self.arm.pose.bones
        for b in self.rig.bones:
            p = pb[b]
            p.rotation_mode = "QUATERNION"
            q = fr["loc"][b]
            p.rotation_quaternion = (q.w, q.x, q.y, q.z)
            p.location = (0.0, 0.0, 0.0)
        h = fr["hips"] - self.rig.rest["Hips"]
        pb["Hips"].location = (h.x, h.y, h.z)
        nk = fr["neck"] - self.rig.rest["Neck"]
        pb["Neck"].location = (nk.x, nk.y, nk.z)
        bpy.context.view_layer.update()

    def verts(self, fr):
        """Godot-space vertex positions of the near mesh posed by frame fr."""
        np = self.np
        self.pose(fr)
        dg = bpy.context.evaluated_depsgraph_get()
        ev = self.obj.evaluated_get(dg)
        me = ev.to_mesh()
        co = np.empty(len(me.vertices) * 3, dtype=np.float64)
        me.vertices.foreach_get("co", co)
        ev.to_mesh_clear()
        co = co.reshape(-1, 3)
        return np.stack([co[:, 0], co[:, 2], -co[:, 1]], axis=1)

    def clearance(self, V, grot, gpos, side, arm_points=None):
        """Smallest distance (m) of the side's forearm/hand vertices outside the torso's star-shaped cross-section in
        the Chest and the Hips frames (negative = inside), and the hand's distance from the torso axis."""
        np = self.np
        A = V[self.arm_v[side]] if arm_points is None else arm_points
        best = 1.0
        axis = 1.0
        bins_a = 24
        for bone, idx in self.torso.items():
            R = np.array(grot[bone].inverted().to_matrix())
            o = np.array(gpos[bone])
            T = (V[idx] - o) @ R.T
            P = (A - o) @ R.T
            ylo, yhi = T[:, 1].min(), T[:, 1].max()
            yb = 0.04
            ny = int((yhi - ylo) / yb) + 1
            table = np.zeros((ny, bins_a))
            ty = ((T[:, 1] - ylo) / yb).astype(int)
            ta = ((np.arctan2(T[:, 2], T[:, 0]) + math.pi) / (2 * math.pi) * bins_a).astype(int) % bins_a
            tr = np.hypot(T[:, 0], T[:, 2])
            np.maximum.at(table, (ty, ta), tr)
            table = np.maximum(table, np.maximum(np.roll(table, 1, axis=1), np.roll(table, -1, axis=1)))
            inside_y = (P[:, 1] >= ylo) & (P[:, 1] <= yhi)
            if not inside_y.any():
                continue
            Q = P[inside_y]
            qy = ((Q[:, 1] - ylo) / yb).astype(int).clip(0, ny - 1)
            qa = ((np.arctan2(Q[:, 2], Q[:, 0]) + math.pi) / (2 * math.pi) * bins_a).astype(int) % bins_a
            qr = np.hypot(Q[:, 0], Q[:, 2])
            rb = table[qy, qa]
            ok = rb > 0
            if ok.any():
                best = min(best, float((qr[ok] - rb[ok]).min()))
            hand = (np.array(gpos[side + "Hand"]) - o) @ R.T
            if ylo <= hand[1] <= yhi:
                axis = min(axis, float(math.hypot(hand[0], hand[2])))
        return best, axis

    def fix_arms(self, frames, loop, cfg):
        """Turns the upper arms out (about the chest's front axis) where the forearm or hand is inside the torso."""
        np = self.np
        margin = float(cfg["arm_margin_m"])
        step = math.radians(float(cfg["arm_step_deg"]))
        most = int(float(cfg["arm_max_deg"]) / float(cfg["arm_step_deg"]))
        n = len(frames) - (1 if loop else 0)
        angles = {s: [0.0] * n for s in LEGS}
        for f in range(n):
            V = self.verts(frames[f])
            grot, gpos = self.rig.fk(frames[f]["loc"], frames[f]["hips"], frames[f]["neck"])
            for s in LEGS:
                base = V[self.arm_v[s]]
                c, _ax = self.clearance(V, grot, gpos, s, base)
                if c >= margin:
                    continue
                pivot = np.array(gpos[s + "UpperArm"])
                ax = grot["Chest"] @ Vector((0.0, 0.0, -1.0 if s == "Left" else 1.0))
                for k in range(1, most + 1):
                    R = np.array(Quaternion(ax, step * k).to_matrix())
                    moved = (base - pivot) @ R.T + pivot
                    c, _ax = self.clearance(V, grot, gpos, s, moved)
                    angles[s][f] = step * k
                    if c >= margin:
                        break
        for s in LEGS:
            sm = blur_circular(max_filter(angles[s], 2, loop), 2, loop)
            for f in range(n):
                if sm[f] <= 1e-6:
                    continue
                grot, _gp = self.rig.fk(frames[f]["loc"], frames[f]["hips"], frames[f]["neck"])
                ax = grot["Chest"] @ Vector((0.0, 0.0, -1.0 if s == "Left" else 1.0))
                new = Quaternion(ax, sm[f]) @ grot[s + "UpperArm"]
                frames[f]["loc"][s + "UpperArm"] = (grot["Chest"].inverted() @ new).normalized()
            angles[s] = sm
        if loop:
            frames[n] = copy_frame(frames[0])
        return max(max(angles["Left"]), max(angles["Right"])) if n else 0.0

    def ground(self, frames, cfg):
        """Every frame: the lowest vertex of the posed mesh on y = 0 (lifts out of the floor, lowers onto it)."""
        lows = [float(self.verts(fr)[self.solid, 1].min()) for fr in frames]
        shift = blur_circular([-y for y in lows], int(cfg["ground_blur_frames"]), False)
        shift = [max(s, -y) for s, y in zip(shift, lows)]
        for fr, s in zip(frames, shift):
            fr["hips"].y += s
            fr["neck"].y += s
        return max(abs(s) for s in shift)

    def stats(self, frames):
        """Min arm clearance, min hand-axis distance, min and end mesh height over the frames."""
        clear, axis, low = 1.0, 1.0, 10.0
        for fr in frames:
            V = self.verts(fr)
            grot, gpos = self.rig.fk(fr["loc"], fr["hips"], fr["neck"])
            for s in LEGS:
                c, a = self.clearance(V, grot, gpos, s)
                clear, axis = min(clear, c), min(axis, a)
            low = min(low, float(V[self.solid, 1].min()))
        end = self.verts(frames[-1])
        return {"arm_clear": clear, "hand_axis": axis, "min_y": low, "end_min_y": float(end[self.solid, 1].min()),
                "end_max_y": float(end[:, 1].max())}


# --- measurement of the final clip ------------------------------------------------------------------------------------
def final_points(rig: Rig, frames):
    pts = {}
    for s in LEGS:
        pts[s + "heel"], pts[s + "tip"] = [], []
    for fr in frames:
        grot, gpos = rig.fk(fr["loc"], fr["hips"], fr["neck"])
        for s in LEGS:
            sp = rig.contact_points(s, gpos[s + "Foot"], grot[s + "Foot"], grot[s + "Toes"])
            pts[s + "heel"].append(sp["heel"])
            pts[s + "tip"].append(sp["tip"])
    return pts


# --- write ------------------------------------------------------------------------------------------------------------
def write_action(rig: Rig, arm, name, frames):
    act = bpy.data.actions.new(name)
    arm.animation_data.action = act
    pb = arm.pose.bones
    prev = {}
    for f, fr in enumerate(frames):
        for b in rig.bones:
            q = fr["loc"][b]
            if b in prev:
                q = qfix(q, prev[b])
            prev[b] = q
            p = pb[b]
            p.rotation_mode = "QUATERNION"
            p.rotation_quaternion = (q.w, q.x, q.y, q.z)
            p.keyframe_insert("rotation_quaternion", frame=f)
        h = fr["hips"] - rig.rest["Hips"]
        pb["Hips"].location = (h.x, h.y, h.z)
        pb["Hips"].keyframe_insert("location", frame=f)
        nk = fr["neck"] - rig.rest["Neck"]
        pb["Neck"].location = (nk.x, nk.y, nk.z)
        pb["Neck"].keyframe_insert("location", frame=f)
    act.use_fake_user = True
    return act


def verify(path, rig: Rig, baked):
    """Reads the written .glb back: per action the Hips translation and every joint rotation at every key equal the
    baked values (glTF quaternions are the Godot local rotations: identity rest bases)."""
    doc, binary = gbl.read_glb(path)
    names = [n.get("name", "") for n in doc["nodes"]]
    worst_r = worst_p = 0.0
    for anim in doc.get("animations", []):
        name = anim["name"]
        if name not in baked:
            continue
        frames = baked[name]
        for ch in anim["channels"]:
            bone = names[ch["target"]["node"]]
            path_ = ch["target"]["path"]
            sampler = anim["samplers"][ch["sampler"]]
            times = gbl.accessor(doc, binary, sampler["input"])
            values = gbl.accessor(doc, binary, sampler["output"])
            for t, v in zip(times, values):
                f = int(round(t[0] * FPS))
                if f >= len(frames):
                    continue
                if path_ == "rotation":
                    want = frames[f]["loc"][bone]
                    worst_r = max(worst_r, qangle_deg(Quaternion((v[3], v[0], v[1], v[2])), want))
                elif path_ == "translation" and bone in ("Hips", "Neck"):
                    want = frames[f]["hips"] if bone == "Hips" else frames[f]["neck"]
                    worst_p = max(worst_p, (Vector(v) - want).length)
    return worst_r, worst_p * 1000.0


# --- previews ---------------------------------------------------------------------------------------------------------
def preview_frame(rig: Rig, fr):
    """The frame as the game shows it: the neck root rides the chest top (the runtime head lock lets it sink with the
    chest; a clip that keeps the Neck at rest would otherwise show a stretched neck in a still)."""
    out = copy_frame(fr)
    grot, gpos = rig.fk(fr["loc"], fr["hips"], fr["neck"])
    head = grot["Head"]
    out["neck"] = gpos["Chest"] + grot["Chest"] @ (rig.rest["Neck"] - rig.rest["Chest"])
    out["loc"]["Neck"] = grot["Chest"].copy()
    out["loc"]["Head"] = (grot["Chest"].inverted() @ head).normalized()
    return out


def render_strips(check: MeshCheck, baked, specs, out_dir, count):
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
    w, h = 300, 400
    scene.render.resolution_x = w
    scene.render.resolution_y = h
    scene.render.image_settings.file_format = "PNG"
    build_soldier._preview_colours(check.obj, check.design)
    # a floor line: a thin dark slab at y = 0
    bpy.ops.mesh.primitive_plane_add(size=6.0, location=(0.0, 0.0, -0.001))
    floor = bpy.context.active_object
    floor.name = "PreviewFloor"
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    os.makedirs(out_dir, exist_ok=True)
    written = []
    tmp = os.path.join(out_dir, "_tile.png")
    for spec in specs:
        name = spec["name"]
        frames = baked[name]
        n = len(frames)
        pick = [int(round(i * (n - 1) / float(count - 1))) for i in range(count)]
        xs = [fr["hips"].x for fr in frames]
        zs = [fr["hips"].z for fr in frames]
        cx, cz = 0.5 * (min(xs) + max(xs)), 0.5 * (min(zs) + max(zs))
        span = max(max(xs) - min(xs), max(zs) - min(zs))
        cam_data.ortho_scale = 2.4 + span
        views = ["side"] + (["front"] if spec.get("front_view") else [])
        for view in views:
            strip = None
            for f in pick:
                check.pose(preview_frame(check.rig, frames[f]))
                # Blender: x = Godot x, y = -Godot z, z = Godot y
                target = Vector((cx, -cz, 0.95))
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
    if os.path.exists(tmp):
        os.remove(tmp)
    return written


# --- main -------------------------------------------------------------------------------------------------------------
def main():
    a = gbl.args()
    design = gbl.read_json(DESIGN)
    cfg = dict(design["clean"])
    gait_cfg = soldier_data.config()["gait"]
    cfg["contact_height_m"] = float(gait_cfg["contact_height_m"])
    only = [x for x in str(a.get("only", "")).split(",") if x] if a.get("only") else []
    out = str(a.get("out", SCRATCH if only else OUT))
    specs = [s for s in design["clips"] if not s["name"].startswith("_") and (not only or s["name"] in only)]
    gbl.reset_scene()
    src = Source(SOURCE)
    rig = Rig(src, design)
    arm = gbl.soldier_armature()
    arm.animation_data_create()
    use_mesh = not a.get("no-mesh")
    if not use_mesh and out == OUT:
        raise SystemExit("--no-mesh skips the arm and ground fixes: use it with --only or --out only")
    check = MeshCheck(rig, arm) if use_mesh else None
    stats = gbl.read_json("data/stats.json")["movement"]
    move = float(stats["base_speed_mps"])
    speeds = {"walk_slow": move * float(gait_cfg["walk_slow_blend"]), "walk_fwd": move,
              "run_fwd": move * float(stats["sprint_speed_multiplier"]["value"])}
    revive = soldier_data.config()["poses"]["revive"]
    print("SOLDIER_CLIPS_RIG k=%.4f sole_y=%.3f bones=%d mapped=%d" % (rig.k, rig.sole_y, len(rig.bones), len(rig.map)))
    baked, lines, actions = {}, [], {}
    dt_default = 1.0 / FPS
    for spec in specs:
        frames, rep = bake_clip(rig, spec, cfg)
        loop = bool(spec.get("loop", False))
        n = rep["frames"]
        dt = rep["length"] / n
        sub = spec.get("subloop")
        if sub:
            f_from = int(round(float(revive[sub[0]]) * FPS))
            f_to = int(round(float(revive[sub[1]]) * FPS))
            rep["subloop_before"] = seam(frames, f_from, f_to)
            close_seam(frames, f_to, f_from, int(cfg["subloop_seam_frames"]))
            rep["subloop_after"] = seam(frames, f_from, f_to)
        if check is not None and spec.get("arms"):
            rep["arm_turn_deg"] = math.degrees(check.fix_arms(frames, loop, cfg))
        if check is not None and spec.get("ground"):
            rep["ground_fix_m"] = check.ground(frames, cfg)
            if loop:
                frames[n] = copy_frame(frames[0])
        if loop:
            # first == last per bone by construction; the step into the seam against the largest other step
            first_last = seam(frames, 0, n)
            seam_step = seam(frames, n - 1, n)
            other = [seam(frames, i, i + 1) for i in range(n - 1)]
            seam_after = first_last + seam_step + (max(o[0] for o in other), max(o[1] for o in other))
        pts = final_points(rig, frames)
        contact = cfg["contact_height_m"]
        m = measure_gait(pts, n, dt, contact, loop)
        speed = m["speed"] if spec.get("gait") else 0.0
        slide = foot_slide(pts, n, dt, contact, speed, loop) if spec.get("ik") else float("nan")
        ms = check.stats(frames) if check is not None else {}
        baked[spec["name"] + ("_Loop" if loop else "")] = frames
        baked_key = spec["name"] + ("_Loop" if loop else "")
        actions[baked_key] = frames
        line = "SOLDIER_CLIP %s src=%s len=%.3f frames=%d loop=%d" % (spec["name"], spec["src"], rep["length"], n, int(loop))
        if loop:
            line += " source_seam=%.2fdeg/%.1fmm first_vs_last=%.3fdeg/%.2fmm seam_step=%.2fdeg/%.1fmm max_other_step=%.2fdeg/%.1fmm" % (rep["source_seam"] + seam_after)
        if sub:
            line += " subloop_seam_before=%.2fdeg/%.1fmm subloop_seam=%.3fdeg/%.2fmm" % (rep["subloop_before"] + rep["subloop_after"])
        if spec.get("gait"):
            slot = spec["gait"]
            cycle = speed * rep["length"]
            line += " stride_cycle_m=%.3f natural_mps=%.2f raw_mps=%.2f" % (cycle, speed, rep.get("raw_speed", 0.0))
            if slot in speeds and speed > 0:
                line += " play_rate@%.2f=%.3fx (raw %.3fx) cycles_per_s=%.3f" % (speeds[slot], speeds[slot] / speed,
                                                                             speeds[slot] / max(rep.get("raw_speed", 0.0), 1e-6), speeds[slot] / cycle)
        if spec.get("ik"):
            line += " slide_m=%.4f raw_slide_m=%.4f ik_miss_mm=%.2f pelvis_drop_m=%.3f" % (slide, rep.get("raw_slide", float("nan")), rep.get("ik_miss_mm", 0.0), rep.get("pelvis_drop_max_m", 0.0))
        if ms:
            line += " arm_clear_m=%.3f hand_axis_m=%.3f min_y_m=%.3f end_min_y_m=%.3f" % (ms["arm_clear"], ms["hand_axis"], ms["min_y"], ms["end_min_y"])
        if "arm_turn_deg" in rep:
            line += " arm_turn_max_deg=%.1f" % rep["arm_turn_deg"]
        if "ground_fix_m" in rep:
            line += " ground_fix_max_m=%.3f" % rep["ground_fix_m"]
        print(line)
        lines.append(line)
    # export: the armature and its actions only (the check mesh is deleted; the previews build it again)
    if check is not None:
        mesh = check.obj.data
        bpy.data.objects.remove(check.obj, do_unlink=True)
        bpy.data.meshes.remove(mesh, do_unlink=True)
        check = None
    for name in sorted(actions):
        write_action(rig, arm, name, actions[name])
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)
    bpy.context.scene.frame_set(0)
    path = gbl.export_glb(out)
    err_r, err_p = verify(path, rig, actions)
    s = gbl.summary(path)
    if out == OUT:
        gbl.update_manifest(out, ME, DERIVED)
    clips = " ".join("%s:%.3fs" % (k, v) for k, v in sorted(s["clips"].items()))
    print("SOLDIER_CLIPS out=%s clips=%d %s bones=%d triangles=%d bytes=%d sha256=%s readback_rot_err_deg=%.4f readback_pos_err_mm=%.3f" % (
        out, len(s["clips"]), clips, s["bones"], s["triangles"], s["bytes"], s["sha256"], err_r, err_p))
    if a.get("preview") and use_mesh:
        check = MeshCheck(rig, arm)
        out_dir = gbl.repo_path("build/an2/preview/" + str(a["preview"]))
        written = render_strips(check, baked, [dict(sp, name=sp["name"] + ("_Loop" if sp.get("loop") else "")) for sp in specs], out_dir, int(design["preview_frames"]))
        print("SOLDIER_CLIPS_PREVIEW %d strips in %s" % (len(written), out_dir))


if __name__ == "__main__":
    main()
