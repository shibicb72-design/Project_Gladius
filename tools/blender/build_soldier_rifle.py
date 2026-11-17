"""M2 AN3: the third-person rifle RELOAD keyed in Blender, one clip per gun, on the soldier's own 22-bone rig.

    blender.cmd -b --factory-startup --python tools/blender/build_soldier_rifle.py -- [--out=<repo-relative .glb>]
        [--guns=<id,id>] [--dry]

Writes assets/generated/characters/soldier_rifle.glb: the armature "Armature" (gladius_bl.soldier_armature(), the same
22 bones and identity rests as soldier.glb and the runtime skeleton) with one action per gun, reload_<gun id>
(pilum_br, sagittarii_rifle), and nothing else (no mesh, no material). --dry solves and reports without writing.

Why keyed: the code-built reload (scripts/visual/soldier_animation.gd reload_clip) aims the left hand at the fixed
upper_body.left_hand_m, not at the shown gun's foregrip, so the hand jumps off the gun when the reload starts and
snaps back when the left-hand IK takes it again. Here every left-hand key is a point ON the shown gun (or the belt
pouch), so the hand rides the canted gun and the clip starts and ends exactly on the aimed pose with the left hand
on that gun's foregrip.

What the clip holds (all from data, nothing hand-placed in this file):
- Stage times: data/anim_third_person.json upper_body.reload_key_fractions over upper_body.reload_keyed
  .authored_frames frames at 30 fps (every fraction lands on a frame); the runtime scales the clip to the weapon's
  WeaponDef.reload_s (SoldierAnimation.resolve_reload -> ClipLibrary.fit).
- The rifle cant (reload_cant_deg, about the barrel) on the RightHand and the chest lean (reload_chest_deg) on the
  Chest: the code-built clip's numbers, interpolated with the monotone cubic of build_soldier_keyed.
- The right arm: the aim clip's arm (SoldierAnimation.aim_clip at pitch 0), solved with a port of
  SoldierRig.arm_rotations (shortest-arc two-bone) so the first and last frames equal the aimed pose.
- The left arm: per key a target (reload_keyed.left: foregrip / cell / charge on the gun, scaled by the gun's
  soldier.gun.weapons.<gun>.scale, or pouch on the body) plus an offset and a hand turn; between keys the hand moves
  from the previous key's point to the next one's (smoothstep), both evaluated on the CURRENT gun pose, so a hand on
  the magazine follows the canted gun. Solved with the same SoldierRig.arm_rotations port and the IK's own elbow pole
  (upper_body.left_pole).
- LeftUpperArm / RightUpperArm position keys: rest + SoldierAnimation.shoulder_offset (shoulder_inset_m /
  shoulder_drop_m), exactly the aim clip's, so the shoulders do not pop.
Conventions (build_soldier_keyed): pose-bone quaternions = Godot bone-local rotations (identity rests); a pose-bone
location is the Godot local offset from the rest. Every other bone holds its rest (the runtime keeps only the tracks
the code-built reload has: SoldierAnimation.resolve_reload).

Prints one RIFLE_CLIP line per gun (frames, IK miss, start/end hand-to-foregrip error, largest step) and one
RIFLE_CLIPS summary line; records the file in tools/blender/manifest.json (only when its row is missing or differs).
"""

import math
import os
import sys

import bpy
from mathutils import Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gladius_bl as gbl  # noqa: E402
import soldier_data  # noqa: E402
import build_soldier_clips as bsc  # noqa: E402
import build_soldier_keyed as bsk  # noqa: E402

OUT = "assets/generated/characters/soldier_rifle.glb"
ME = "tools/blender/build_soldier_rifle.py"
FPS = gbl.FPS
GUNS = ("pilum_br", "sagittarii_rifle")
FORWARD = Vector((0.0, 0.0, -1.0))  # Godot Vector3.FORWARD
RIGHT = Vector((1.0, 0.0, 0.0))  # Godot Vector3.RIGHT


# --- the runtime's maths, ported ------------------------------------------------------------------------------------------
def arc(v0, v1):
    """Godot Quaternion(arc_from, arc_to): the shortest arc from v0 to v1."""
    n0, n1 = v0.normalized(), v1.normalized()
    c = n0.cross(n1)
    d = n0.dot(n1)
    if c.length < 1e-9:
        if d > 0.0:
            return Quaternion()
        raise ValueError("opposite vectors in arc()")
    s = math.sqrt((1.0 + d) * 2.0)
    return Quaternion((s * 0.5, c.x / s, c.y / s, c.z / s))


def arm_rotations(rig, side, target, pole, epsilon):
    """SoldierRig.arm_rotations: [upper, fore, hand] local rotations putting the hand at target (rest-space metres,
    root = the UpperArm's rest), bending toward pole; the hand's global turn is the chest's. Also the miss (m)."""
    root = rig.rest[side + "UpperArm"]
    first = rig.local[side + "ForeArm"]
    second = rig.local[side + "Hand"]
    a, b = first.length, second.length
    reach = (target - root).length
    distance = max(abs(a - b) + epsilon, min(a + b - epsilon, reach))
    direction = (target - root).normalized()
    bend = (pole - direction * pole.dot(direction)).normalized()
    along = (a * a + distance * distance - b * b) / (2.0 * distance)
    elbow = root + direction * along + bend * math.sqrt(max(a * a - along * along, 0.0))
    end = root + direction * distance
    upper = arc(first, elbow - root)
    fore = arc(second, end - elbow)
    return [upper, (upper.inverted() @ fore).normalized(), fore.inverted()], max(0.0, reach - distance)


def shoulder_offset(side, ub):
    """SoldierAnimation.shoulder_offset."""
    return Vector((float(ub["shoulder_inset_m"]) * (1.0 if side == "Left" else -1.0), -float(ub["shoulder_drop_m"]), 0.0))


def axis_angle(axis, deg):
    return Quaternion(axis, math.radians(float(deg)))


def fk_hand(rig, loc, ua_pos, side):
    """The hand's position in the chest frame (chest unturned): UpperArm at ua_pos (rest + shoulder offset)."""
    u = loc[side + "UpperArm"]
    f = u @ loc[side + "ForeArm"]
    return ua_pos + u @ rig.local[side + "ForeArm"] + f @ rig.local[side + "Hand"]


# --- the gun ----------------------------------------------------------------------------------------------------------
class RifleGun:
    """One gun's points in its mesh frame (first-person units, barrel -Z, top +Y) and its third-person scale."""

    def __init__(self, gun_id):
        held = gbl.read_json("data/art_soldier.json")["soldier"]["gun"]["weapons"][gun_id]
        art = gbl.read_json("data/art_soldier.json")["weapons"][gun_id]
        self.id = gun_id
        self.scale = float(held["scale"])
        self.grip = bsk.V(held["grip_m"])
        self.points = {"foregrip": bsk.V(held["foregrip_m"]), "cell": bsk.V(art["cell"]["at"]),
                       "charge": bsk.V(art["charge"]["at"])}

    def point(self, name, hand_at, gun_q):
        """A gun point in the chest frame: the RightHand (the grip) at hand_at turned by gun_q."""
        return hand_at + gun_q @ ((self.points[name] - self.grip) * self.scale)


# --- the clip -----------------------------------------------------------------------------------------------------------
def build(rig, ub, gun):
    keyed = ub["reload_keyed"]
    fractions = [float(f) for f in ub["reload_key_fractions"]]
    n = int(keyed["authored_frames"])
    key_frames = [f * n for f in fractions]
    for kf in key_frames:
        if abs(kf - round(kf)) > 1e-6:
            raise ValueError("reload_key_fractions x authored_frames must be whole frames: %s" % key_frames)
    key_frames = [int(round(kf)) for kf in key_frames]
    left = keyed["left"]
    if len(left) != len(fractions) or len(ub["reload_cant_deg"]) != len(fractions) or len(ub["reload_chest_deg"]) != len(fractions):
        raise ValueError("reload_keyed.left, reload_cant_deg and reload_chest_deg need one entry per key fraction")
    eps = float(ub["epsilon_m"])
    length = n / float(FPS)
    times = [f * length for f in fractions]
    cant = bsk.mono_cubic(times, [float(v) for v in ub["reload_cant_deg"]], False)
    lean = bsk.mono_cubic(times, [float(v) for v in ub["reload_chest_deg"]], False)
    shift = {s: shoulder_offset(s, ub) for s in bsk.SIDES}
    ua_pos = {s: rig.rest[s + "UpperArm"] + shift[s] for s in bsk.SIDES}
    right_at = bsk.V(ub["right_hand_m"])
    right, _ = arm_rotations(rig, "Right", right_at - shift["Right"], bsk.V(ub["right_pole"]), eps)
    left_pole = bsk.V(ub["left_pole"])
    pouch = bsk.V(keyed["pouch_m"])
    chest_at = rig.rest["Chest"]

    def target(k, gun_q, chest_q):
        """Key k's left-hand point and turn in the chest frame, on the current gun and chest pose."""
        row = left[k]
        off = bsk.V(row.get("off_m", (0, 0, 0)))
        if row["at"] == "pouch":
            at = chest_q.inverted() @ (pouch + off - chest_at) + chest_at
        else:
            at = gun.point(row["at"], right_at, gun_q) + gun_q @ off
        return at, bsk.E(row.get("hand_deg", (0, 0, 0)))

    frames, worst_miss = [], 0.0
    hands = []
    for f in range(n + 1):
        t = f / float(FPS)
        gun_q = axis_angle(FORWARD, cant(t))
        chest_q = axis_angle(RIGHT, lean(t))
        k = 0
        while k < len(key_frames) - 2 and f >= key_frames[k + 1]:
            k += 1
        u = (f - key_frames[k]) / float(key_frames[k + 1] - key_frames[k])
        w = bsk.smooth(u)
        a_at, a_q = target(k, gun_q, chest_q)
        b_at, b_q = target(k + 1, gun_q, chest_q)
        at = a_at.lerp(b_at, w)
        hand_q = a_q.slerp(b_q, w)
        then = left[k].get("then_m")
        if then is not None and u < 0.5:
            push = bsk.V(then)
            at += (push if left[k]["at"] == "pouch" else gun_q @ push) * math.sin(math.pi * u * 2.0)
        loc = {b: Quaternion() for b in rig.bones}
        loc["Chest"] = chest_q
        loc["RightUpperArm"], loc["RightForeArm"] = right[0], right[1]
        loc["RightHand"] = (right[2] @ gun_q).normalized()
        arm, miss = arm_rotations(rig, "Left", at - shift["Left"], left_pole, eps)
        worst_miss = max(worst_miss, miss)
        loc["LeftUpperArm"], loc["LeftForeArm"] = arm[0], arm[1]
        fore_global = arm[0] @ arm[1]
        loc["LeftHand"] = (fore_global.inverted() @ hand_q).normalized()
        frames.append({"loc": loc, "hips": rig.rest["Hips"].copy(), "neck": rig.rest["Neck"].copy(),
                       "ua": {s: ua_pos[s].copy() for s in bsk.SIDES}})
        hands.append((fk_hand(rig, loc, ua_pos["Left"], "Left"), gun.point("foregrip", fk_hand(rig, loc, ua_pos["Right"], "Right"), gun_q)))
    start_err = (hands[0][0] - hands[0][1]).length
    end_err = (hands[-1][0] - hands[-1][1]).length
    far = max((h - g).length for h, g in hands)
    step = max((hands[i][0] - hands[i - 1][0]).length for i in range(1, len(hands)))
    stats = {"frames": n, "length": length, "key_frames": key_frames, "miss": worst_miss, "start_err": start_err,
             "end_err": end_err, "far": far, "step": step}
    return frames, stats


def write_upper_arm_positions(rig, arm, name, frames):
    """Adds the UpperArm location keys (pose-bone location = Godot local offset from the rest) to the action
    build_soldier_clips.write_action just wrote and left assigned."""
    act = bpy.data.actions[name]
    arm.animation_data.action = act
    pb = arm.pose.bones
    for f, fr in enumerate(frames):
        for side in bsk.SIDES:
            off = fr["ua"][side] - rig.rest[side + "UpperArm"]
            pb[side + "UpperArm"].location = (off.x, off.y, off.z)
            pb[side + "UpperArm"].keyframe_insert("location", frame=f)


def verify_upper_arms(path, rig, baked):
    """The written UpperArm translations equal the local rest plus the shoulder offset (mm)."""
    doc, binary = gbl.read_glb(path)
    names = [nd.get("name", "") for nd in doc["nodes"]]
    worst = 0.0
    for anim in doc.get("animations", []):
        frames = baked.get(anim["name"])
        if frames is None:
            continue
        for ch in anim["channels"]:
            bone = names[ch["target"]["node"]]
            if ch["target"]["path"] != "translation" or not bone.endswith("UpperArm"):
                continue
            side = bone[:-len("UpperArm")]
            sampler = anim["samplers"][ch["sampler"]]
            times = gbl.accessor(doc, binary, sampler["input"])
            values = gbl.accessor(doc, binary, sampler["output"])
            for t, v in zip(times, values):
                f = min(len(frames) - 1, int(round(t[0] * FPS)))
                want = rig.local[bone] + (frames[f]["ua"][side] - rig.rest[bone])
                worst = max(worst, (Vector(v) - want).length)
    return worst * 1000.0


def key_counts(path):
    """Per action, the fewest and most keys of any channel in the written file."""
    doc, _binary = gbl.read_glb(path)
    out = {}
    for anim in doc.get("animations", []):
        counts = [doc["accessors"][s["input"]]["count"] for s in anim["samplers"]]
        out[anim["name"]] = (min(counts), max(counts))
    return out


def manifest_row_matches(out):
    path = gbl.repo_path(gbl.MANIFEST)
    if not os.path.exists(path):
        return False
    files = gbl.read_json(gbl.MANIFEST).get("files", {})
    row = files.get("res://" + out, {})
    return row.get("made_by") == ME and row.get("derived_from", "") == ""


def main():
    a = gbl.args()
    out = str(a.get("out", OUT))
    guns = [g for g in str(a.get("guns", "")).split(",") if g] or list(GUNS)
    ub = soldier_data.config()["upper_body"]
    gbl.reset_scene()
    rig = bsk.KRig()
    actions = {}
    for gun_id in guns:
        frames, st = build(rig, ub, RifleGun(gun_id))
        name = "reload_" + gun_id
        actions[name] = frames
        print("RIFLE_CLIP %s frames=%d len=%.4f keys=%s ik_miss_mm=%.2f start_err_mm=%.3f end_err_mm=%.3f far_from_foregrip_m=%.3f max_hand_step_mm=%.1f" % (
            name, st["frames"], st["length"], st["key_frames"], st["miss"] * 1000.0, st["start_err"] * 1000.0,
            st["end_err"] * 1000.0, st["far"], st["step"] * 1000.0))
    if a.get("dry"):
        for side in bsk.SIDES:
            print("RIFLE_RIG %s upper_arm_rest=%s fore=%.4f hand=%.4f" % (side, tuple(round(x, 4) for x in rig.rest[side + "UpperArm"]),
                  rig.local[side + "ForeArm"].length, rig.local[side + "Hand"].length))
        print("RIFLE_CLIPS dry run: nothing written")
        return
    arm = gbl.soldier_armature()
    arm.animation_data_create()
    for name in sorted(actions):
        bsc.write_action(rig, arm, name, actions[name])
        write_upper_arm_positions(rig, arm, name, actions[name])
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)
    bpy.context.scene.frame_set(0)
    path = gbl.export_glb(out)
    err_r, err_p = bsc.verify(path, rig, actions)
    err_ua = verify_upper_arms(path, rig, actions)
    s = gbl.summary(path)
    for name, (lo, hi) in sorted(key_counts(path).items()):
        print("RIFLE_KEYS %s min=%d max=%d want=%d" % (name, lo, hi, len(actions[name])))
    if out == OUT and not manifest_row_matches(out):
        gbl.update_manifest(out, ME, "")
    listed = " ".join("%s:%.4fs" % (k, v) for k, v in sorted(s["clips"].items()))
    print("RIFLE_CLIPS out=%s clips=%d %s bones=%d triangles=%d bytes=%d sha256=%s readback_rot_err_deg=%.4f readback_pos_err_mm=%.3f readback_upper_arm_err_mm=%.3f" % (
        out, len(s["clips"]), listed, s["bones"], s["triangles"], s["bytes"], s["sha256"], err_r, err_p, err_ua))


if __name__ == "__main__":
    main()
