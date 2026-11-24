"""A3: the new hand-keyed third-person clips on the soldier's own 22-bone rig (both armour sets share the rig).

    blender.cmd -b --factory-startup --python tools/blender/a3_clips.py -- [--out=<repo-relative .glb>]
        [--only=<clip,clip>] [--preview=<dir under build/a3/preview>] [--no-mesh] [--compare]

Writes assets/generated/characters/soldier_a3.glb: the armature "Armature" (gladius_bl.soldier_armature(), the same 22
bones and identity rests as soldier.glb / soldier_keyed.glb and the runtime skeleton) with one action per clip and
nothing else (no mesh, no material). Built from nothing: no source clip, manifest derived_from "". It reuses the
authoring machinery of build_soldier_keyed.py (pose tables, monotone-cubic channels, two-bone solves, the FK check) and
the writer / read-back of build_soldier_clips.py; neither of those files nor their .glb changes.

Clips (slots of the same names in data/anim_sources.json, candidate "blender"):

  blade_swing_a   0.667 s  the forehand cut: up over the right shoulder, down across to the left hip.
  blade_swing_b   0.667 s  the backhand cut: from over the left shoulder, level across the front, out to the right.
      SoldierPose plays a swing clip from clip_from_s to clip_to_s over data/anim.json poses.swing.s (0.34 s, frozen),
      on poses.swing.clip_bones (upper body). Both clips are authored at TWICE the swing time (20 frames, so 20 keys
      instead of 10 carry the arc) and start and end on the blade guard (poses.blade). The blade's fastest travel (the
      cut) must lie inside the strike window (poses.swing strike_from .. strike_to, as fractions of the clip): the
      script checks it and fails (A3_ERROR, exit code 1) when it does not. Damage and timing are not touched.
      The right hand IS the weapon (the runtime mounts it on RightHand with an identity turn: blade along the hand's
      -Z, edges along its +-Y), so a "gun" row places the grip, the blade direction and the top edge.

  hit_front / hit_back / hit_left / hit_right   0.40 s  short flinches, named by where the hit CAME FROM.
      Frame 0 is the rest pose, so the runtime's additive delta (ClipLibrary.fit(..., true), then gait.hit.scale) is
      the keyed turn itself. Only Spine, Chest and the upper arms move (the filter of the existing hit layer); no
      Hips, leg, Neck or Head key leaves rest. hit_right is the exact mirror of hit_left.

  victory         2.40 s  the winner's cheer: the weapon hand punched up overhead and pumped three times, the left
      fist at the chest; it ends raised (the end screen opens data/ui.json end_screen_delay_s = 3.0 s after the
      match ends, so 2.4 s fits inside). Upper body only at runtime (the legs keep their locomotion).

Prints one A3_CLIP line per clip (length, IK miss, biggest one-frame step, arm clearance against the torso, and for
the swings the cut's place in the strike window and the blade's nearest pass to the head), A3_HIT lines (peak turn per
filtered bone; --compare adds the same numbers for the UAL Hit_Chest / Hit_Head of soldier_clips.glb), and one A3_CLIPS
summary line with the sha256; records the file in tools/blender/manifest.json.
--preview=<dir>: side and front strips (10 frames) per clip under build/a3/preview/<dir>/ (the legionary near mesh,
a box standing in for the weapon).
"""

import math
import os
import sys

import bpy
from mathutils import Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gladius_bl as gbl  # noqa: E402
import build_soldier_clips as bsc  # noqa: E402
import build_soldier_keyed as bsk  # noqa: E402

OUT = "assets/generated/characters/soldier_a3.glb"
SCRATCH = "build/a3/scratch/soldier_a3_only.glb"
ME = "tools/blender/a3_clips.py"
FPS = gbl.FPS
BLADE_M = 0.60  # the blade's reach from the grip, for the checks only (the mesh is the game's)
HEAD_KEEP_OUT_M = 0.24  # the blade never passes nearer the head centre than this (check only)
HIT_BONES = ("Spine", "Chest", "LeftUpperArm", "RightUpperArm")
SWING_AUTHORED_S = 20.0 / FPS  # 20 frames, twice the 0.34 s swing (rounded to the frame grid)

STAND_FEET = bsk.STAND_FEET
HIPS = [0.0, 0.955, 0.0]

# The blade guard between swings (data/anim.json + data/anim_third_person.json poses.blade: RightUpperArm [14, 0, 12],
# RightForeArm [48, 0, 0], RightHand [-40, 0, 0], Chest [0, 10, 0]) as a grip row in the chest frame, so every swing
# starts and ends where the guard holds the sword.
GUARD = {"at": [0.49, -0.41, -0.40], "dir": [-0.03, 0.37, -0.93], "up": [-0.21, 0.905, 0.37], "pole": [0.3, -1.0, 1.0]}
GUARD_LEFT = {"UpperArm": [10, 0, -14], "ForeArm": [36, 0, 0], "Hand": [0, 0, 0]}
GUARD_BODY = {"hips": HIPS, "hrot": [0, 0, 0], "spine": [0, 0, 0], "chest": [0, 10, 0], "head": [0, 0, 0]}


def swing_clips():
    def guard(t):
        return dict(t=t, **GUARD_BODY, foot=STAND_FEET, gun=GUARD, arm={"Left": GUARD_LEFT})

    # A: the forehand cut. Wind up over the right shoulder (the right shoulder goes back), cut down and across with
    # the lower edge leading (the top edge faces up and right), finish low by the left hip with the chest turned in.
    def at(frame):
        return frame / float(FPS)

    a = {"name": "blade_swing_a", "length": SWING_AUTHORED_S, "carry_neck": True, "left_on_gun": False, "swing": True, "keys": [
        guard(0.0),
        # half way up: the wind-up is two keys, so the arm travels an arc instead of arriving in one frame
        {"t": at(2), "spine": [1, -4, 0], "chest": [2, -2, -1],
         "gun": {"at": [0.50, -0.12, -0.26], "dir": [0.08, 0.80, -0.50], "up": [-0.1, 0.4, 0.9], "pole": [0.8, -0.7, 0.8]},
         "arm": {"Left": {"UpperArm": [22, 0, -18], "ForeArm": [44, 0, 0]}}},
        {"t": at(4), "spine": [2, -8, 0], "chest": [4, -16, -3],
         "gun": {"at": [0.46, 0.16, -0.08], "dir": [0.25, 0.85, 0.45], "up": [0.0, -0.5, 0.85], "pole": [1.0, -0.2, 0.5]},
         "arm": {"Left": {"UpperArm": [30, 0, -22], "ForeArm": [52, 0, 0]}}},
        {"t": at(7), "spine": [-3, 6, 0], "chest": [-6, 20, 2],
         "gun": {"at": [0.10, -0.10, -0.50], "dir": [-0.45, -0.10, -1.0], "up": [0.6, 0.8, 0.0], "pole": [1.0, -0.8, 0.2]},
         "arm": {"Left": {"UpperArm": [0, 0, -28], "ForeArm": [60, 0, 0]}}},
        # the finish: low, outside the left hip, the left arm drawn back and out of the blade's way
        {"t": at(10), "spine": [-6, 12, 0], "chest": [-10, 30, 3],
         "gun": {"at": [0.00, -0.38, -0.30], "dir": [-0.80, -0.62, -0.40], "up": [0.4, 0.8, -0.3], "pole": [1.0, -0.5, 0.8]},
         "arm": {"Left": {"UpperArm": [-30, 0, -34], "ForeArm": [78, 0, 0]}}},
        {"t": at(14), "spine": [-5, 10, 0], "chest": [-8, 26, 2],
         "gun": {"at": [0.03, -0.39, -0.31], "dir": [-0.76, -0.58, -0.45], "up": [0.4, 0.8, -0.3], "pole": [1.0, -0.5, 0.8]},
         "arm": {"Left": {"UpperArm": [-26, 0, -32], "ForeArm": [72, 0, 0]}}},
        guard(SWING_AUTHORED_S)]}
    # B: the backhand cut. The sword hand crosses high to the left with the palm down (the blade lies back over the
    # left shoulder, the left arm hangs clear under it), the blade sweeps level from the left, across the front and
    # out to the right with the lower edge leading (the top edge trails), and finishes out to the right with the
    # chest opened.
    b = {"name": "blade_swing_b", "length": SWING_AUTHORED_S, "carry_neck": True, "left_on_gun": False, "swing": True, "keys": [
        guard(0.0),
        {"t": at(2), "spine": [0, 4, 0], "chest": [1, 18, 0],
         "gun": {"at": [0.24, -0.20, -0.38], "dir": [-0.75, 0.40, -0.50], "up": [0.2, 0.6, 0.7], "pole": [0.6, -1.0, 0.2]},
         "arm": {"Left": {"UpperArm": [0, 0, -12], "ForeArm": [26, 0, 0]}}},
        {"t": at(4), "spine": [0, 8, 0], "chest": [2, 26, 0],
         "gun": {"at": [-0.08, 0.00, -0.30], "dir": [-0.70, 0.35, 0.60], "up": [0.6, 0.0, 0.7], "pole": [0.5, -1.0, -0.5]},
         "arm": {"Left": {"UpperArm": [-15, 0, -8], "ForeArm": [20, 0, 0]}}},
        {"t": at(7), "spine": [0, -1, 0], "chest": [0, -2, 0],
         "gun": {"at": [0.16, -0.06, -0.50], "dir": [-0.35, 0.0, -1.0], "up": [-1.0, 0.0, 0.35], "pole": [0.8, -1.0, 0.2]},
         "arm": {"Left": {"UpperArm": [4, 0, -16], "ForeArm": [36, 0, 0]}}},
        {"t": at(10), "spine": [1, -9, 0], "chest": [3, -26, -2],
         "gun": {"at": [0.50, 0.00, -0.28], "dir": [0.85, 0.15, -0.50], "up": [-0.5, 0.0, -0.85], "pole": [0.6, -1.0, 0.5]},
         "arm": {"Left": {"UpperArm": [26, 0, -16], "ForeArm": [50, 0, 0]}}},
        {"t": at(14), "spine": [1, -8, 0], "chest": [2, -22, -1],
         "gun": {"at": [0.49, -0.02, -0.26], "dir": [0.88, 0.15, -0.42], "up": [-0.5, 0.0, -0.85], "pole": [0.6, -1.0, 0.5]},
         "arm": {"Left": {"UpperArm": [22, 0, -16], "ForeArm": [46, 0, 0]}}},
        guard(SWING_AUTHORED_S)]}
    return [a, b]


def hit_clips():
    """Flinches from the rest pose. Angles are degrees about the bone's own X, Y, Z (data/anim.json poses note: torso
    forward = -X, +Y turns the chest to its left, +Z tips the chest top to its left; an arm forward = +X, left arm
    out = -Z, right arm out = +Z). The runtime scales every turn by gait.hit.scale."""
    def arms(left, right):
        return {"Left": {"UpperArm": left, "ForeArm": [0, 0, 0], "Hand": [0, 0, 0]},
                "Right": {"UpperArm": right, "ForeArm": [0, 0, 0], "Hand": [0, 0, 0]}}

    def rest(t):
        return {"t": t, "hips": [0.0, 0.96, 0.0], "hrot": [0, 0, 0], "spine": [0, 0, 0], "chest": [0, 0, 0], "head": [0, 0, 0],
                "arm": arms([0, 0, 0], [0, 0, 0])}

    def clip(name, peak, back):
        return {"name": name, "length": 0.4, "carry_neck": False, "left_on_gun": False, "no_gun": True, "hit": True,
                "keys": [rest(0.0), dict(t=0.07, **peak), dict(t=0.19, **back), rest(0.4)]}

    # from the front: the chest is knocked back, the shoulders roll forward round it, then a small nod back in
    # (round 2: about the size of the UAL Hit_Chest the layer played before: Spine and Chest 9.6, upper arms 12-13 deg)
    front = clip("hit_front",
                 {"spine": [5, 1, 0], "chest": [8, 3, 0], "arm": arms([10, 0, -5], [10, 0, 5])},
                 {"spine": [-1.5, 0, 0], "chest": [-2.5, 0, 0], "arm": arms([-3, 0, 0], [-3, 0, 0])})
    # from behind: the chest lurches forward, the arms trail back
    back = clip("hit_back",
                {"spine": [-5, -1, 0], "chest": [-9, -3, 0], "arm": arms([-11, 0, -4], [-11, 0, 4])},
                {"spine": [1.5, 0, 0], "chest": [2.5, 0, 0], "arm": arms([3, 0, 0], [3, 0, 0])})
    # from the left: the left shoulder is driven back (+Y) and the chest top is pushed to the right (-Z)
    left = clip("hit_left",
                {"spine": [0, 5, -3], "chest": [1.5, 10, -6], "arm": arms([-7, 0, -10], [4, 0, 3])},
                {"spine": [0, -1.5, 1], "chest": [0, -2.5, 1.5], "arm": arms([2, 0, 0], [-2, 0, 0])})
    return [front, back, left]


def victory_clip():
    """The winner's cheer. The weapon hand goes up overhead (weapon pointing at the sky, its top edge turned back) and
    pumps three times; the left fist comes up to the chest and beats with it. It ends raised."""
    high = {"dir": [0.08, 1.0, -0.12], "up": [0.0, 0.1, 1.0], "pole": [1.0, -0.5, -0.1]}

    def top():
        return dict(high, at=[0.32, 0.575, -0.06])  # the arm all but straight, the fist above the helmet's top

    def dip():
        return dict(high, at=[0.35, 0.40, -0.08])  # 17 cm down: the pump has to read from across the arena

    def fist(upper, fore):
        return {"Left": {"UpperArm": [upper, 0, -16], "ForeArm": [fore, 0, 0], "Hand": [0, 0, 0]}}

    keys = [
        {"t": 0.0, "hips": HIPS, "hrot": [0, 0, 0], "spine": [0, 0, 0], "chest": [0, 0, 0], "head": [0, 0, 0], "foot": STAND_FEET,
         "gun": bsk.LOW_READY, "arm": {"Left": {"UpperArm": [20, 0, -8], "ForeArm": [70, 0, 0], "Hand": [0, 0, 0]}}},
        # on the way up: out in front of the shoulder first, so the lift is an arc and not a one-frame jump
        {"t": 0.20, "spine": [1, -2, -1], "chest": [2, -4, -1],
         "gun": {"at": [0.40, 0.04, -0.32], "dir": [-0.10, 0.60, -0.80], "up": [0.0, 0.8, 0.6], "pole": [1.0, -0.8, 0.2]}, "arm": fist(14, 96)},
        {"t": 0.45, "hips": [0.0, 0.96, 0.0], "spine": [3, -4, -2], "chest": [7, -8, -3], "head": [6, -6, 0], "gun": top(), "arm": fist(10, 112)},
        {"t": 0.70, "chest": [3, -8, -3], "gun": dip(), "arm": fist(10, 124)},
        {"t": 0.95, "chest": [7, -8, -3], "gun": top(), "arm": fist(10, 112)},
        {"t": 1.20, "chest": [3, -8, -3], "gun": dip(), "arm": fist(10, 124)},
        {"t": 1.45, "chest": [7, -8, -3], "gun": top(), "arm": fist(10, 112)},
        {"t": 1.70, "chest": [3, -8, -3], "gun": dip(), "arm": fist(10, 124)},
        {"t": 2.00, "chest": [7, -6, -2], "head": [8, -4, 0],
         "gun": {"at": [0.32, 0.575, -0.06], "dir": [0.12, 1.0, -0.10], "up": [0.0, 0.1, 1.0], "pole": [1.0, -0.5, -0.1]}, "arm": fist(10, 116)},
        {"t": 2.40, "chest": [6, -7, -2], "head": [7, -5, 0],
         "gun": {"at": [0.33, 0.56, -0.06], "dir": [0.06, 1.0, -0.12], "up": [0.0, 0.1, 1.0], "pole": [1.0, -0.5, -0.1]}, "arm": fist(10, 114)}]
    return {"name": "victory", "length": 2.4, "carry_neck": True, "left_on_gun": False, "keys": keys}


# --- checks -----------------------------------------------------------------------------------------------------------
def _segment_distance(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
    return (p - (a + ab * t)).length


def swing_report(rig, frames, length):
    """Where the cut is: the time of the blade tip's fastest travel as a fraction of the clip, the tip's speed there,
    the fraction where the tip is farthest forward, and the blade's nearest pass to the head centre."""
    tips, near = [], 10.0
    for fr in frames:
        gr, gp = rig.fk(fr["loc"], fr["hips"], fr["neck"])
        hand = gp["RightHand"]
        tip = hand + gr["RightHand"] @ Vector((0.0, 0.0, -BLADE_M))
        tips.append(tip)
        near = min(near, _segment_distance(gp["Head"], hand, tip))
    best, best_i = 0.0, 0
    for i in range(len(tips) - 1):
        v = (tips[i + 1] - tips[i]).length * FPS
        if v > best:
            best, best_i = v, i
    fwd_i = min(range(len(tips)), key=lambda i: tips[i].z)
    return {"cut_frac": ((best_i + 0.5) / FPS) / length, "cut_mps": best, "fwd_frac": (fwd_i / float(FPS)) / length, "head_m": near}


def peak_turns(frames, bones):
    """Per bone, the largest turn (degrees) away from the first frame."""
    out = {}
    for b in bones:
        q0 = frames[0]["loc"][b]
        out[b] = max(bsc.qangle_deg(q0, fr["loc"][b]) for fr in frames)
    return out


def moved_bones(rig, frames, eps_deg=0.01):
    q = [b for b in rig.bones if max(bsc.qangle_deg(frames[0]["loc"][b], fr["loc"][b]) for fr in frames) > eps_deg]
    return q


def glb_peak_turns(rel, clip, bones):
    """The same peaks read from a written .glb (the UAL flinches of soldier_clips.glb, for comparison)."""
    doc, binary = gbl.read_glb(gbl.repo_path(rel))
    names = [n.get("name", "") for n in doc["nodes"]]
    out = {}
    for anim in doc.get("animations", []):
        if anim["name"] != clip:
            continue
        for ch in anim["channels"]:
            bone = names[ch["target"]["node"]]
            if ch["target"]["path"] != "rotation" or bone not in bones:
                continue
            values = gbl.accessor(doc, binary, anim["samplers"][ch["sampler"]]["output"])
            qs = [Quaternion((v[3], v[0], v[1], v[2])) for v in values]
            out[bone] = max(bsc.qangle_deg(qs[0], q) for q in qs)
    return out


# --- main -------------------------------------------------------------------------------------------------------------
def main():
    a = gbl.args()
    c, cover = bsk.cfg()
    only = [x for x in str(a.get("only", "")).split(",") if x] if a.get("only") else []
    out = str(a.get("out", SCRATCH if only else OUT))
    swing_cfg = gbl.read_json("data/anim.json")["poses"]["swing"]
    lo, hi = float(swing_cfg["strike_from"]), float(swing_cfg["strike_to"])
    errors = []
    gbl.reset_scene()
    rig = bsk.KRig()
    gun = bsk.Gun()
    arm = gbl.soldier_armature()
    arm.animation_data_create()
    use_mesh = not a.get("no-mesh")
    check = bsc.MeshCheck(rig, arm) if use_mesh else None
    clips = swing_clips() + hit_clips() + [victory_clip()]
    clips = [cl for cl in clips if not only or cl["name"] in only or (cl["name"] == "hit_left" and "hit_right" in only)]
    actions, specs = {}, []
    for clip in clips:
        bsk.MISSES.clear()
        frames, miss = bsk.bake(rig, gun, clip)
        name = clip["name"]
        if bsk.MISSES:
            print("A3_MISS %s %s" % (name, " ".join("%s=%.0fmm" % (k, v * 1000) for k, v in sorted(bsk.MISSES.items()))))
            errors.append("%s: IK miss over 5 mm (%s)" % (name, ", ".join(sorted(bsk.MISSES))))
        actions[name] = frames
        specs.append(dict(clip, action=name))
        worst_bone, worst_step = "", 0.0
        for i in range(len(frames) - 1):
            for b in rig.bones:
                d = bsc.qangle_deg(frames[i]["loc"][b], frames[i + 1]["loc"][b])
                if d > worst_step:
                    worst_bone, worst_step = "%s@%d" % (b, i), d
        line = "A3_CLIP %s len=%.3f frames=%d ik_miss_mm=%.2f max_step=%.2fdeg step_bone=%s" % (
            name, float(clip["length"]), len(frames) - 1, miss * 1000.0, worst_step, worst_bone)
        if check is not None:
            ms = check.stats(frames)
            line += " arm_clear_m=%.3f min_y_m=%.3f" % (ms["arm_clear"], ms["min_y"])
            # which arm, and in which frame, comes nearest the torso (forearm / hand vertices against the torso's
            # cross-section; negative = inside it): one entry per side
            for side in bsc.LEGS:
                worst, worst_f = 1.0, -1
                for i, fr in enumerate(frames):
                    grot, gpos = rig.fk(fr["loc"], fr["hips"], fr["neck"])
                    cl, _axis = check.clearance(check.verts(fr), grot, gpos, side)
                    if cl < worst:
                        worst, worst_f = cl, i
                line += " %s_arm_clear=%.3f@%d" % (side.lower(), worst, worst_f)
        if clip.get("swing"):
            r = swing_report(rig, frames, float(clip["length"]))
            inside = lo <= r["cut_frac"] <= hi
            line += " cut_frac=%.3f window=%.2f..%.2f in_window=%d cut_mps=%.1f fwd_frac=%.3f blade_head_m=%.3f" % (
                r["cut_frac"], lo, hi, int(inside), r["cut_mps"], r["fwd_frac"], r["head_m"])
            if not inside:
                errors.append("%s: the cut (%.3f of the clip) is outside the strike window %.2f..%.2f" % (name, r["cut_frac"], lo, hi))
            if r["head_m"] < HEAD_KEEP_OUT_M:
                errors.append("%s: the blade passes %.3f m from the head centre (keep out %.2f)" % (name, r["head_m"], HEAD_KEEP_OUT_M))
        print(line)
        if clip.get("hit"):
            moved = moved_bones(rig, frames)
            extra = [b for b in moved if b not in HIT_BONES]
            if extra:
                errors.append("%s: bones outside the hit filter move: %s" % (name, ",".join(extra)))
            pk = peak_turns(frames, HIT_BONES)
            print("A3_HIT %s %s moved=%s" % (name, " ".join("%s=%.2fdeg" % (b, pk[b]) for b in HIT_BONES), ",".join(moved)))
        if name == "hit_left":
            actions["hit_right"] = bsk.mirror(rig, frames)
            specs.append(dict(clip, name="hit_right", action="hit_right"))
            print("A3_CLIP hit_right mirror_of=hit_left len=%.3f" % float(clip["length"]))
    if a.get("compare"):
        for ual in ("Hit_Chest", "Hit_Head"):
            pk = glb_peak_turns("assets/generated/characters/soldier_clips.glb", ual, HIT_BONES)
            print("A3_HIT_UAL %s %s" % (ual, " ".join("%s=%.2fdeg" % (b, pk.get(b, -1.0)) for b in HIT_BONES)))
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
    print("A3_CLIPS out=%s clips=%d %s bones=%d triangles=%d bytes=%d sha256=%s readback_rot_err_deg=%.4f readback_pos_err_mm=%.3f" % (
        out, len(s["clips"]), listed, s["bones"], s["triangles"], s["bytes"], s["sha256"], err_r, err_p))
    if err_r > 0.1 or err_p > 0.05:  # 0.04 deg is the float32 round trip of the exporter (round 1)
        errors.append("read-back differs from the bake (%.4f deg, %.3f mm)" % (err_r, err_p))
    if a.get("preview") and use_mesh:
        check = bsc.MeshCheck(rig, arm)
        out_dir = gbl.repo_path("build/a3/preview/" + str(a["preview"]))
        written = bsk.render_strips(check, rig, actions, specs, c, cover, out_dir, 10)
        print("A3_CLIPS_PREVIEW %d strips in %s" % (len(written), out_dir))
    for e in errors:
        print("A3_ERROR " + e)
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
