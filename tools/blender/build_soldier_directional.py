"""Bake contact-led strafe and back-pedal cycles on the existing soldier armature.

blender.cmd -b --factory-startup --python tools/blender/build_soldier_directional.py --

Each foot moves at constant ground speed while planted. In recovery it lifts and
travels to the next contact, with the same directional velocity at both ends.
The cycles start on the left contact so the engine can blend them in phase.
"""

import math
import os
import sys

from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_soldier_clips as export
import build_soldier_keyed as keyed
import gladius_bl as gbl

OUT = "assets/generated/characters/soldier_directional.glb"
SCRIPT = "tools/blender/build_soldier_directional.py"
STANCE = 0.50


def foot(phase, stride, lift):
    travel = stride * (0.5 * STANCE - phase)
    if phase <= STANCE:
        return travel, 0.0
    recovery = (phase - STANCE) / (1.0 - STANCE)
    eased = recovery * recovery * (3.0 - 2.0 * recovery)
    return travel + stride * eased, lift * math.sin(math.pi * recovery)


def bake(rig, direction, stride, lateral, frame_count):
    gun = keyed.Gun()
    frames = []
    worst_miss = 0.0
    for frame in range(frame_count):
        phase = frame / frame_count
        hips = rig.rest["Hips"].copy()
        hips.y += -0.127 + 0.012 * math.sin(4.0 * math.pi * phase) ** 2
        pose = {"hips": hips, "hrot": (0.0, 0.0, -3.0 * direction.x), "foot": {}}
        for index, side in enumerate(keyed.SIDES):
            sign = 2 * index - 1
            offset, height = foot((phase + index * 0.5) % 1.0, stride, 0.16 if lateral else 0.19)
            target = rig.rest[side + "Foot"] + direction * offset
            target.x = sign * (0.125 if lateral else 0.155) + direction.x * offset
            target.y += height
            if lateral:
                # The crossing leg travels in its own fore/aft lane.
                target.z += sign * direction.x * 0.11
            pose["foot"][side] = {"at": target, "rot": (0.0, -sign * 8.0, 0.0), "pole": (sign * 0.12, 0.0, -1.0)}
        solved, miss = keyed.solve_frame(rig, gun, pose, {})
        worst_miss = max(worst_miss, miss)
        frames.append(solved)
    frames.append(export.copy_frame(frames[0]))
    return frames, worst_miss


def main():
    out = str(gbl.args().get("out", OUT))
    gbl.reset_scene()
    rig = keyed.KRig()
    arm = gbl.soldier_armature()
    arm.animation_data_create()
    actions = {}
    sources = gbl.read_json("data/anim_sources.json")["clips"]
    for slot, direction, lateral in (
        ("strafe_l", (-1.0, 0.0, 0.0), True),
        ("strafe_r", (1.0, 0.0, 0.0), True),
        ("walk_back", (0.0, 0.0, 1.0), False),
    ):
        source = sources[slot]["blender"][0]
        name = source["clip"] + "_Loop"
        stride = float(source["directional_cycle_m"])
        frames, miss = bake(rig, Vector(direction), stride, lateral, 16)
        actions[name] = frames
        export.write_action(rig, arm, name, frames)
        print(f"DIRECTIONAL {name} cycle_m={stride:.3f} ik_miss_m={miss:.5f}")
    arm.animation_data.action = None
    for bone in arm.pose.bones:
        bone.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        bone.location = (0.0, 0.0, 0.0)
    path = gbl.export_glb(out)
    rotation_error, position_error = export.verify(path, rig, actions)
    print(f"DIRECTIONAL readback_rot_deg={rotation_error:.4f} readback_pos_mm={position_error:.3f}")
    if out == OUT:
        gbl.update_manifest(OUT, SCRIPT)


if __name__ == "__main__":
    main()
